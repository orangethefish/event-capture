#!/usr/bin/env sh
# Rollback guard. Invoked by deploy.sh when a release fails its health gate (or directly by an
# operator: sh .../deploy/rollback.sh vX.Y.Z).
#
# Policy:
#  - No previous release (first deploy) -> mark FAILED, operator recovery.
#  - Flyway migrations UNCHANGED vs the previous release -> automatically restore the previous
#    application image pins and re-check readiness.
#  - Flyway migrations CHANGED -> do NOT auto-downgrade (unsafe schema/rollback mismatch);
#    preserve logs + the fresh backup, mark FAILED, require operator recovery.
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=deploy/lib.sh
. "$SCRIPT_DIR/lib.sh"

RELEASE_TAG="${1:?usage: rollback.sh vX.Y.Z}"
validate_release_tag "$RELEASE_TAG"
RD=$(release_dir "$RELEASE_TAG")
PREV_DIR=$(current_release_dir 2>/dev/null || true)

capture_failure_logs "$RD"

if [ -z "${PREV_DIR:-}" ] || [ ! -d "${PREV_DIR:-/nonexistent}" ] || [ "$PREV_DIR" = "$RD" ]; then
  warn "no previous release to roll back to (first deploy)."
  printf 'first-deploy failure: no prior release to restore\n' > "$RD/FAILED"
  exit 1
fi

if migrations_changed "$RD" "$PREV_DIR"; then
  warn "Flyway migrations changed vs previous release ($PREV_DIR)."
  warn "Refusing automatic downgrade to avoid an unsafe schema/rollback mismatch."
  {
    echo "reason=migrations-changed-since-previous-release"
    echo "previous_release=$PREV_DIR"
    echo "fresh_backup=$(ls -1 "$RD"/backup/*.sql.gz 2>/dev/null | tail -n1 || echo none)"
    echo "action=operator-recovery-required"
  } > "$RD/FAILED"
  die "migrations changed; operator recovery required"
fi

log "no migration change; restoring previous release pins from $PREV_DIR"
compose "$PREV_DIR" up -d --no-deps backend-api
wait_container_healthy "$PREV_DIR" backend-api || die "rollback failed: previous backend-api unhealthy"
compose "$PREV_DIR" up -d --no-deps backend-worker
wait_container_healthy "$PREV_DIR" backend-worker || die "rollback failed: previous backend-worker unhealthy"
compose "$PREV_DIR" up -d --no-deps frontend
_port=$(env_field "$PREV_DIR/release.env" PUBLIC_PORT 2>/dev/null || echo 8080)
wait_http_ready "http://127.0.0.1:${_port:-8080}/actuator/health/readiness" \
  || die "rollback failed: readiness gate on restored release"

# 'current' stays pointing at the previous (good) release; do not repoint it.
printf 'rolled_back_to=%s after=%s reason=no-migration-change\n' \
  "$(basename "$PREV_DIR")" "$RELEASE_TAG" > "$RD/ROLLED_BACK"
log "rollback complete; previous release $(basename "$PREV_DIR") is live"
exit 0
