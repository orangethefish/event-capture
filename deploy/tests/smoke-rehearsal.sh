#!/usr/bin/env bash
# Controlled VM smoke rehearsal for the deploy/rollback scripts. Runs the REAL scripts against a
# local stack built from source (standing in for Harbor images), proving:
#   1. first deployment reaches readiness
#   2. an idempotent redeploy is a safe no-op re-run
#   3. a readiness failure with NO migration change auto-rolls back to the previous release
#   4. a readiness failure WITH a migration change stops for operator recovery (no auto-downgrade)
#
# This needs a Docker host with JDK 21 + Node 20 (to build images) and free time; it is NOT run in
# the mirror-only Bitbucket pipeline. Run from a POSIX shell at the repo root:
#   sh deploy/tests/smoke-rehearsal.sh
# Reuse pre-built images to skip the slow build:
#   EVENT_CAPTURE_SMOKE_SKIP_BUILD=1 sh deploy/tests/smoke-rehearsal.sh
set -euo pipefail

REPO_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
cd "$REPO_ROOT"

BACKEND_IMG="event-capture-backend:smoke"
FRONTEND_IMG="event-capture-frontend:smoke"
BROKEN_IMG="event-capture-backend:smoke-broken-doesnotexist"
SMOKE_PORT="${EVENT_CAPTURE_SMOKE_PORT:-18080}"

command -v docker  >/dev/null 2>&1 || { echo "docker required" >&2; exit 1; }
command -v openssl >/dev/null 2>&1 || { echo "openssl required" >&2; exit 1; }

# Isolate this stack from any real local 'event-capture' project.
export COMPOSE_PROJECT_NAME=event-capture-smoke
export EVENT_CAPTURE_COMPOSE_OVERRIDE=docker-compose.smoke.yml
export EVENT_CAPTURE_SKIP_FETCH=1
export EVENT_CAPTURE_HEALTH_TIMEOUT="${EVENT_CAPTURE_HEALTH_TIMEOUT:-240}"
export EVENT_CAPTURE_DISK_MIN_MB=100

OPT=$(mktemp -d)
export EVENT_CAPTURE_ROOT="$OPT"
export EVENT_CAPTURE_SHARED_ENV="$OPT/shared/production.env"

fail=0
pass() { printf 'PASS  %s\n' "$1"; }
bad()  { printf 'FAIL  %s\n' "$1"; fail=1; }

cleanup() {
  echo "--- teardown ---"
  # Any release dir has the compose files; use v0.0.1 to bring the shared project down.
  if [ -f "$OPT/releases/v0.0.1/docker-compose.yml" ]; then
    docker compose --project-name "$COMPOSE_PROJECT_NAME" \
      --env-file "$EVENT_CAPTURE_SHARED_ENV" \
      --env-file "$OPT/releases/v0.0.1/release.env" \
      -f "$OPT/releases/v0.0.1/docker-compose.yml" \
      -f "$OPT/releases/v0.0.1/$EVENT_CAPTURE_COMPOSE_OVERRIDE" \
      down -v --remove-orphans >/dev/null 2>&1 || true
  fi
  rm -rf "$OPT"
}
trap cleanup EXIT

# --- Build the smoke images from source (unless reusing) --------------------------------------
if [ "${EVENT_CAPTURE_SMOKE_SKIP_BUILD:-0}" != "1" ]; then
  echo "--- building backend jar + image ---"
  ( cd backend && ./gradlew --no-daemon bootJar )
  docker build -t "$BACKEND_IMG" backend
  echo "--- building frontend dist + image ---"
  ( cd frontend && npm ci && npm run build -- --configuration production )
  docker build -t "$FRONTEND_IMG" frontend
else
  docker image inspect "$BACKEND_IMG" >/dev/null 2>&1 || { echo "missing $BACKEND_IMG (unset EVENT_CAPTURE_SMOKE_SKIP_BUILD)" >&2; exit 1; }
  docker image inspect "$FRONTEND_IMG" >/dev/null 2>&1 || { echo "missing $FRONTEND_IMG" >&2; exit 1; }
fi

# --- Shared secrets env (dummy but structurally valid) ----------------------------------------
mkdir -p "$OPT/shared" "$OPT/releases"
KEY=$(openssl rand -base64 32)
ABUSE=$(openssl rand -base64 32)
cat > "$EVENT_CAPTURE_SHARED_ENV" <<ENV
APP_BASE_URL=http://127.0.0.1:${SMOKE_PORT}
APP_FRONTEND_ORIGIN=http://127.0.0.1:${SMOKE_PORT}
POSTGRES_USER=event_capture
POSTGRES_PASSWORD=smoke
APP_ABUSE_KEY_SECRET=${ABUSE}
APP_SHARE_TOKEN_ACTIVE_KEY_ID=smoke
APP_SHARE_TOKEN_KEYRING=smoke=${KEY}
APP_SMTP_HOST=localhost
APP_MAIL_FROM=smoke@example.com
ENV
chmod 600 "$EVENT_CAPTURE_SHARED_ENV"

read_fp() { deploy/ci/flyway-fingerprint.sh backend/src/main/resources/db/migration; }
FP=$(read_fp)
FP_MAX=$(printf '%s\n' "$FP" | awk -F= '$1=="FLYWAY_MAX_VERSION"{print $2}')
FP_SHA=$(printf '%s\n' "$FP" | awk -F= '$1=="FLYWAY_MIGRATIONS_SHA256"{print $2}')

# layout_release <tag> <backend-image> <fmax> <fsha>
layout_release() {
  tag="$1"; bimg="$2"; fmax="$3"; fsha="$4"
  rd="$OPT/releases/$tag"
  mkdir -p "$rd/deploy"
  cp docker-compose.yml "$rd/"
  cp deploy/tests/docker-compose.smoke.yml "$rd/$EVENT_CAPTURE_COMPOSE_OVERRIDE"
  cp deploy/lib.sh deploy/deploy.sh deploy/rollback.sh deploy/preflight.sh deploy/backup.sh deploy/health.sh "$rd/deploy/"
  cat > "$rd/release.env" <<EOF
RELEASE_TAG=$tag
EVENT_CAPTURE_BACKEND_IMAGE=$bimg
EVENT_CAPTURE_FRONTEND_IMAGE=$FRONTEND_IMG
PUBLIC_PORT=$SMOKE_PORT
FLYWAY_MAX_VERSION=$fmax
FLYWAY_MIGRATIONS_SHA256=$fsha
EOF
  echo '{"release_tag":"'"$tag"'"}' > "$rd/release-manifest.json"
  printf '%s' "$rd"
}

run_deploy() { # <tag> -> echoes exit code, never aborts
  set +e
  sh "$OPT/releases/$1/deploy/deploy.sh" "$1"
  rc=$?
  set -e
  echo "$rc"
}

echo "=== Scenario 1: first deployment ==="
layout_release v0.0.1 "$BACKEND_IMG" "$FP_MAX" "$FP_SHA" >/dev/null
rc=$(run_deploy v0.0.1)
[ "$rc" = 0 ] && [ -f "$OPT/releases/v0.0.1/DEPLOYED" ] && [ "$(readlink "$OPT/current")" = "$OPT/releases/v0.0.1" ] \
  && pass "first deploy reached readiness" || bad "first deploy (rc=$rc)"

echo "=== Scenario 2: idempotent redeploy ==="
rc=$(run_deploy v0.0.1)
[ "$rc" = 0 ] && [ -f "$OPT/releases/v0.0.1/DEPLOYED" ] \
  && pass "idempotent redeploy is a safe no-op" || bad "idempotent redeploy (rc=$rc)"

echo "=== Scenario 3: readiness failure, no migration change -> auto-rollback ==="
layout_release v0.0.2 "$BROKEN_IMG" "$FP_MAX" "$FP_SHA" >/dev/null
rc=$(run_deploy v0.0.2)
[ "$rc" != 0 ] && [ -f "$OPT/releases/v0.0.2/ROLLED_BACK" ] && [ "$(readlink "$OPT/current")" = "$OPT/releases/v0.0.1" ] \
  && pass "auto-rolled back to v0.0.1 (no migration change)" || bad "auto-rollback (rc=$rc)"

echo "=== Scenario 4: readiness failure WITH migration change -> operator recovery ==="
layout_release v0.0.3 "$BROKEN_IMG" "$((FP_MAX + 1))" "deadbeef" >/dev/null
rc=$(run_deploy v0.0.3)
[ "$rc" != 0 ] && [ -f "$OPT/releases/v0.0.3/FAILED" ] && [ ! -f "$OPT/releases/v0.0.3/ROLLED_BACK" ] && [ "$(readlink "$OPT/current")" = "$OPT/releases/v0.0.1" ] \
  && pass "stopped for operator recovery (migration changed)" || bad "operator-recovery path (rc=$rc)"

echo
if [ "$fail" -eq 0 ]; then echo "SMOKE REHEARSAL PASSED"; exit 0; else echo "SMOKE REHEARSAL FAILED"; exit 1; fi
