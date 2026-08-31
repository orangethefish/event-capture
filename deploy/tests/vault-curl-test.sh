#!/usr/bin/env sh
# Unit tests for vault_curl() in deploy/vault.sh. Pure logic, no network and no real Vault.
#   sh deploy/tests/vault-curl-test.sh
#
# This file exists because of a shipped regression: the commit that dropped VAULT_CACERT support
# deleted the if/else branch that CONTAINED both curl invocations, leaving vault_curl() as a
# function that only rewrote "$@" and returned. It emitted nothing and exited 0, so the
# `|| die "Vault AppRole login failed"` transport guard never fired and the failure surfaced
# one step later as the misleading "Vault AppRole login returned no client token" - a message
# blaming Vault's response for a request that was never sent.
#
# The tests therefore assert on the OBSERVED INVOCATION of curl, not on the function's exit
# status: a silent no-op passes any status-only assertion, which is exactly how this shipped.
#
# Covers:
#   vault_curl() -> actually execs curl and forwards its stdout to the caller
#                -> pins TLS (--proto '=https' --tlsv1.2), bounds time, and keeps --fail so an
#                   HTTP error becomes a transport failure instead of an empty body
#                -> prepends --connect-to only when VAULT_CONNECT_TO is set, before the caller's
#                   own arguments, and preserves argument order and embedded spaces
set -eu

HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# vault.sh calls die()/log() from lib.sh and reads $SHARED_ENV at fetch time.
# shellcheck source=deploy/lib.sh
. "$HERE/../lib.sh"
# shellcheck source=deploy/vault.sh
. "$HERE/../vault.sh"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
fail=0
pass() { printf 'PASS %s\n' "$1"; }
bad()  { printf 'FAIL %s\n' "$1"; fail=1; }

# Stub curl ahead of the real one: record argv one-per-line, echo a body, honour a forced status.
mkdir -p "$TMP/bin"
cat > "$TMP/bin/curl" <<'STUB'
#!/usr/bin/env sh
: > "$CURL_ARGS_FILE"
for a in "$@"; do printf '%s\n' "$a" >> "$CURL_ARGS_FILE"; done
printf '%s' "${CURL_STUB_STDOUT:-}"
exit "${CURL_STUB_STATUS:-0}"
STUB
chmod +x "$TMP/bin/curl"
PATH="$TMP/bin:$PATH"
export PATH
CURL_ARGS_FILE="$TMP/args"
export CURL_ARGS_FILE

has_arg() { grep -Fxq -e "$1" "$CURL_ARGS_FILE"; }

# --- curl is actually invoked, and its stdout reaches the caller ------------------------------
VAULT_CONNECT_TO=""
CURL_STUB_STDOUT='{"auth":{"client_token":"s.stub"}}'
export CURL_STUB_STDOUT
: > "$CURL_ARGS_FILE"
out=$(vault_curl https://vault.example/v1/auth/approle/login)
if [ -s "$CURL_ARGS_FILE" ]; then pass "vault_curl execs curl"; else bad "vault_curl execs curl (NO-OP: nothing ran)"; fi
if [ "$out" = "$CURL_STUB_STDOUT" ]; then pass "vault_curl returns the response body"; else bad "vault_curl returns the response body (got '$out')"; fi

# --- transport hardening flags survive ---------------------------------------------------------
for flag in --fail --silent --show-error --tlsv1.2; do
  if has_arg "$flag"; then pass "passes $flag"; else bad "passes $flag"; fi
done
if has_arg '=https'; then pass "pins --proto '=https'"; else bad "pins --proto '=https'"; fi
if has_arg '--max-time'; then pass "bounds the request with --max-time"; else bad "bounds the request with --max-time"; fi

# A non-2xx must propagate as a nonzero status so the caller's transport guard fires. Without
# --fail curl exits 0 on an HTTP 403 and the error body is parsed as a missing token instead.
CURL_STUB_STATUS=22
export CURL_STUB_STATUS
if ( vault_curl https://vault.example/v1/auth/approle/login >/dev/null 2>&1 ); then
  bad "propagates a curl failure status"
else
  pass "propagates a curl failure status"
fi
unset CURL_STUB_STATUS

# --- --connect-to is conditional, and precedes the caller's arguments --------------------------
# Cloudflare Tunnel fronts Vault with a publicly-trusted edge cert, so the default CA store is
# correct and no --cacert belongs here. VAULT_CONNECT_TO stays supported for a VM-local route.
VAULT_CONNECT_TO=""
: > "$CURL_ARGS_FILE"
vault_curl https://vault.example/v1/x >/dev/null
if has_arg '--connect-to'; then bad "omits --connect-to when unset"; else pass "omits --connect-to when unset"; fi

VAULT_CONNECT_TO="vault.example:443:127.0.0.1:8200"
: > "$CURL_ARGS_FILE"
vault_curl -X POST --data-binary '@/tmp/payload json' https://vault.example/v1/x >/dev/null
if has_arg '--connect-to' && has_arg "$VAULT_CONNECT_TO"; then
  pass "adds --connect-to when set"
else
  bad "adds --connect-to when set"
fi
# The route override must reach curl as an option ahead of the caller's own arguments, not as a
# positional appended after the URL. It is deliberately NOT asserted to be argv[1]: vault_curl's
# own hardening flags are prepended by the curl invocation itself and legitimately come first.
connect_idx=$(grep -n -Fx -e '--connect-to' "$CURL_ARGS_FILE" | cut -d: -f1)
caller_idx=$(grep -n -Fx -e '-X' "$CURL_ARGS_FILE" | cut -d: -f1)
if [ -n "$connect_idx" ] && [ -n "$caller_idx" ] && [ "$connect_idx" -lt "$caller_idx" ]; then
  pass "--connect-to precedes the caller's arguments"
else
  bad "--connect-to precedes the caller's arguments (connect='$connect_idx' caller='$caller_idx')"
fi
if [ "$(tail -n 1 "$CURL_ARGS_FILE")" = 'https://vault.example/v1/x' ]; then
  pass "preserves caller argument order"
else
  bad "preserves caller argument order"
fi
# An argument containing a space must arrive as ONE argv entry, not word-split into two.
if has_arg '@/tmp/payload json'; then pass "preserves an argument containing a space"; else bad "preserves an argument containing a space"; fi

if [ "$fail" -eq 0 ]; then
  echo "ALL TESTS PASSED"; exit 0
else
  echo "SOME TESTS FAILED"; exit 1
fi
