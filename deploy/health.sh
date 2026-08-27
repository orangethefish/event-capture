#!/usr/bin/env sh
# Standalone health gate for a release: API + worker container health, plus readiness through the
# frontend proxy at http://127.0.0.1:${PUBLIC_PORT}/actuator/health/readiness.
#   sh /srv/event-capture/releases/vX.Y.Z/deploy/health.sh vX.Y.Z
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=deploy/lib.sh
. "$SCRIPT_DIR/lib.sh"

RELEASE_TAG="${1:?usage: health.sh vX.Y.Z}"
validate_release_tag "$RELEASE_TAG"
RD=$(release_dir "$RELEASE_TAG")

if health_check "$RD"; then
  log "health OK for $RELEASE_TAG"
  exit 0
fi
die "health check failed for $RELEASE_TAG"
