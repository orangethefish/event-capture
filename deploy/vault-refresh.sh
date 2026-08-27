#!/usr/bin/env sh
# Standalone Vault secret refresh. Run this to pull secrets from Vault without
# a full deployment, e.g. after rotating a credential in Vault.
#
# Usage:
#   sh /srv/event-capture/releases/vX.Y.Z/deploy/vault-refresh.sh [environment]
#
# After running, restart services to pick up the new secrets:
#   docker compose ... restart backend-api backend-worker
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=deploy/lib.sh
. "$SCRIPT_DIR/lib.sh"
# shellcheck source=deploy/vault.sh
. "$SCRIPT_DIR/vault.sh"

VAULT_ENV="${1:-production}"
log "=== refreshing secrets from Vault (environment: $VAULT_ENV) ==="
vault_fetch_secrets "$VAULT_ENV"
log "=== secrets refreshed; restart services to apply ==="
