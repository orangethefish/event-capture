#!/usr/bin/env sh
# Unit tests for the rollback-guard decision logic in deploy/lib.sh. Pure logic, no Docker.
#   sh deploy/tests/rollback-guard-test.sh
#
# Covers:
#   migrations_changed()  -> identical fingerprint = unchanged (auto-rollback allowed);
#                            different max/sha or missing = changed (operator recovery, fail-safe)
#   validate_release_tag() -> strict vMAJOR.MINOR.PATCH only
set -eu

HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=deploy/lib.sh
. "$HERE/../lib.sh"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
fail=0
pass() { printf 'PASS %s\n' "$1"; }
bad()  { printf 'FAIL %s\n' "$1"; fail=1; }

# mk_release <name> <max|-> <sha|-> : writes $TMP/<name>/release.env, echoes its dir.
mk_release() {
  d="$TMP/$1"; mkdir -p "$d"
  {
    echo "RELEASE_TAG=vtest"
    [ "$2" = "-" ] || echo "FLYWAY_MAX_VERSION=$2"
    [ "$3" = "-" ] || echo "FLYWAY_MIGRATIONS_SHA256=$3"
  } > "$d/release.env"
  printf '%s' "$d"
}

A=$(mk_release new1 8 abc123);  B=$(mk_release prev1 8 abc123)
if migrations_changed "$A" "$B"; then bad "identical fingerprint -> unchanged"; else pass "identical fingerprint -> unchanged (auto-rollback)"; fi

A=$(mk_release new2 9 abc123);  B=$(mk_release prev2 8 abc123)
if migrations_changed "$A" "$B"; then pass "different max version -> changed (operator recovery)"; else bad "different max version -> changed"; fi

A=$(mk_release new3 8 def456);  B=$(mk_release prev3 8 abc123)
if migrations_changed "$A" "$B"; then pass "different migrations sha -> changed (operator recovery)"; else bad "different migrations sha -> changed"; fi

A=$(mk_release new4 - -);       B=$(mk_release prev4 8 abc123)
if migrations_changed "$A" "$B"; then pass "missing new fingerprint -> changed (fail-safe)"; else bad "missing new fingerprint -> changed"; fi

A=$(mk_release new5 8 abc123);  B=$(mk_release prev5 - -)
if migrations_changed "$A" "$B"; then pass "missing prev fingerprint -> changed (fail-safe)"; else bad "missing prev fingerprint -> changed"; fi

for good in v0.0.1 v1.2.3 v10.20.30; do
  if ( validate_release_tag "$good" ) 2>/dev/null; then pass "accepts $good"; else bad "accepts $good"; fi
done
for tag in v1.2 1.2.3 v1.2.3-rc1 vX.Y.Z v1.2.3.4 ""; do
  if ( validate_release_tag "$tag" ) 2>/dev/null; then bad "rejects '$tag'"; else pass "rejects '$tag'"; fi
done

if [ "$fail" -eq 0 ]; then
  echo "ALL TESTS PASSED"; exit 0
else
  echo "SOME TESTS FAILED"; exit 1
fi
