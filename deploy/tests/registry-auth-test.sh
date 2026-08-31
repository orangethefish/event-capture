#!/usr/bin/env sh
# Unit tests for the registry-credential preflight in deploy/lib.sh. Pure logic, no Docker,
# no network and no registry.
#   sh deploy/tests/registry-auth-test.sh
#
# This exists because image pulls happen ON THE VM, not on the Jenkins agent, by deliberate
# design: Jenkins holds push credentials, the VM holds a separate pull-only Harbor robot in its
# own Docker credential store, and Jenkinsfile.deploy never transfers registry credentials.
# When that VM-side `docker login` was never performed, the first symptom was a compose pull
# failing with "no basic auth credentials" - AFTER preflight had passed, postgres and redis had
# been started, and a database backup had been taken. The credential fault is knowable before
# any of that work, so it is checked up front.
#
# Covers:
#   registry_host_of()  -> the registry host of a digest-pinned reference, port included
#   registry_credentials_present() -> an auths entry, a credential helper, or neither
#   check_registry_credentials() -> fails legibly before any container work, and stays out of
#                                  the way of the build/skip modes that never pull
set -eu

HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=deploy/lib.sh
. "$HERE/../lib.sh"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
fail=0
pass() { printf 'PASS %s\n' "$1"; }
bad()  { printf 'FAIL %s\n' "$1"; fail=1; }

check_host() {
  _got=$(registry_host_of "$1")
  if [ "$_got" = "$2" ]; then pass "host of $1 -> $2"; else bad "host of $1 -> $2 (got '$_got')"; fi
}

# --- registry host extraction ------------------------------------------------------------------
check_host 'registry.orangethefish.id.vn/duyhoa2210/event-capture-backend@sha256:abc' 'registry.orangethefish.id.vn'
check_host 'registry.example.com:5000/proj/img@sha256:abc' 'registry.example.com:5000'
check_host 'registry.example.com/deep/nested/path/img@sha256:abc' 'registry.example.com'
# A bare Docker Hub name has no registry host component; it must not be mistaken for one.
check_host 'postgres:16-alpine' ''
check_host 'library/postgres:16' ''

# --- credential presence -------------------------------------------------------------------------
HOST='registry.orangethefish.id.vn'

# No config file at all: exactly the never-logged-in case this check exists to catch.
if registry_credentials_present "$TMP/absent/config.json" "$HOST"; then
  bad "missing config.json -> no credentials"
else
  pass "missing config.json -> no credentials"
fi

# A config that authenticates a DIFFERENT registry must not count as credentials for this one.
mkdir -p "$TMP/other"
cat > "$TMP/other/config.json" <<'JSON'
{ "auths": { "index.docker.io": { "auth": "eHg6eXk=" } } }
JSON
if registry_credentials_present "$TMP/other/config.json" "$HOST"; then
  bad "auths for another registry -> no credentials"
else
  pass "auths for another registry -> no credentials"
fi

mkdir -p "$TMP/ok"
cat > "$TMP/ok/config.json" <<'JSON'
{ "auths": { "registry.orangethefish.id.vn": { "auth": "eHg6eXk=" } } }
JSON
if registry_credentials_present "$TMP/ok/config.json" "$HOST"; then
  pass "auths entry for this registry -> credentials present"
else
  bad "auths entry for this registry -> credentials present"
fi

# A credential helper stores the secret outside config.json, leaving an EMPTY auths entry. The
# check must not read that emptiness as "not logged in".
mkdir -p "$TMP/helper"
cat > "$TMP/helper/config.json" <<'JSON'
{ "auths": { "registry.orangethefish.id.vn": {} }, "credsStore": "pass" }
JSON
if registry_credentials_present "$TMP/helper/config.json" "$HOST"; then
  pass "credential helper -> credentials present"
else
  bad "credential helper -> credentials present"
fi

mkdir -p "$TMP/credhelpers"
cat > "$TMP/credhelpers/config.json" <<'JSON'
{ "credHelpers": { "registry.orangethefish.id.vn": "ecr-login" } }
JSON
if registry_credentials_present "$TMP/credhelpers/config.json" "$HOST"; then
  pass "per-registry credHelper -> credentials present"
else
  bad "per-registry credHelper -> credentials present"
fi

# --- check_registry_credentials(): gating and outcome ------------------------------------------
# die() exits, so every call is made in a subshell and judged by its status.
RD="$TMP/release"
mkdir -p "$RD"
echo "EVENT_CAPTURE_BACKEND_IMAGE=registry.orangethefish.id.vn/p/backend@sha256:abc" > "$RD/release.env"

DOCKER_CONFIG="$TMP/absent"
export DOCKER_CONFIG
if ( check_registry_credentials "$RD" ) >/dev/null 2>&1; then
  bad "no credentials -> preflight fails"
else
  pass "no credentials -> preflight fails"
fi

# The failure must name the registry and the remedy, not just report a denial.
msg=$( ( check_registry_credentials "$RD" ) 2>&1 || true )
case "$msg" in
  *registry.orangethefish.id.vn*docker\ login*) pass "failure names the registry and docker login" ;;
  *) bad "failure names the registry and docker login (got '$msg')" ;;
esac

DOCKER_CONFIG="$TMP/ok"
export DOCKER_CONFIG
if ( check_registry_credentials "$RD" ) >/dev/null 2>&1; then
  pass "credentials present -> preflight passes"
else
  bad "credentials present -> preflight passes"
fi

# The smoke rehearsal builds or reuses local images and never pulls; it must not be blocked by a
# registry it does not use.
DOCKER_CONFIG="$TMP/absent"
export DOCKER_CONFIG
if ( EVENT_CAPTURE_SKIP_FETCH=1 check_registry_credentials "$RD" ) >/dev/null 2>&1; then
  pass "EVENT_CAPTURE_SKIP_FETCH=1 skips the registry check"
else
  bad "EVENT_CAPTURE_SKIP_FETCH=1 skips the registry check"
fi
if ( EVENT_CAPTURE_BUILD_IMAGES=1 check_registry_credentials "$RD" ) >/dev/null 2>&1; then
  pass "EVENT_CAPTURE_BUILD_IMAGES=1 skips the registry check"
else
  bad "EVENT_CAPTURE_BUILD_IMAGES=1 skips the registry check"
fi

# An unreadable or absent release.env is a bundle fault reported by its own preflight check;
# this one must not pre-empt it with a confusing credential error.
if ( check_registry_credentials "$TMP/nosuchrelease" ) >/dev/null 2>&1; then
  pass "missing release.env defers to the bundle check"
else
  bad "missing release.env defers to the bundle check"
fi
unset DOCKER_CONFIG

if [ "$fail" -eq 0 ]; then
  echo "ALL TESTS PASSED"; exit 0
else
  echo "SOME TESTS FAILED"; exit 1
fi
