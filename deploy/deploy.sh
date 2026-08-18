#!/usr/bin/env sh
# Controlled production update for one release. Invoked by the Jenkins deploy job over SSH:
#   sh /opt/event-capture/releases/vX.Y.Z/deploy/deploy.sh vX.Y.Z
#
# Order: preflight -> start/verify postgres+redis (no refresh) -> pg backup -> pull the 3 pinned
# images -> recreate api, worker, frontend in order -> health gate. On failure it hands off to the
# rollback guard (rollback.sh). A failed release always exits non-zero so the tag pipeline fails.
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=deploy/lib.sh
. "$SCRIPT_DIR/lib.sh"

RELEASE_TAG="${1:?usage: deploy.sh vX.Y.Z}"
validate_release_tag "$RELEASE_TAG"
RD=$(release_dir "$RELEASE_TAG")

log "=== controlled update: $RELEASE_TAG ==="

# Capture the previous successful release BEFORE anything changes (used by the rollback guard).
PREV_DIR=$(current_release_dir 2>/dev/null || true)
if [ -n "${PREV_DIR:-}" ]; then
  log "previous release: $PREV_DIR"
else
  log "no previous release (first deploy)"
fi

preflight_checks "$RD"
maybe_refresh_vault_secrets
# Vault may have created shared/production.env during a first deployment. Validate the fully
# layered Compose model only after that refresh so a missing local env file cannot block Vault.
compose "$RD" config -q || die "docker compose config failed for $RD"
start_dependencies "$RD"
create_backup "$RD"
fetch_app_images "$RD"

if recreate_app "$RD" && health_check "$RD"; then
  record_deployment "$RD"
  ln -sfn "$RD" "$CURRENT_LINK"
  printf 'deployed_at=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$RD/DEPLOYED"
  log "=== deployment SUCCESS: $RELEASE_TAG ==="
  exit 0
fi

warn "health gate failed for $RELEASE_TAG; invoking rollback guard"
if "$SCRIPT_DIR/rollback.sh" "$RELEASE_TAG"; then
  die "release $RELEASE_TAG failed; previous version restored (see $RD/ROLLED_BACK)"
else
  die "release $RELEASE_TAG failed and requires operator recovery (see $RD/FAILED)"
fi
