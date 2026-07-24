#!/usr/bin/env sh
# Standalone compressed PostgreSQL backup for a release, retained in its release directory.
#   sh /opt/event-capture/releases/vX.Y.Z/deploy/backup.sh vX.Y.Z
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=deploy/lib.sh
. "$SCRIPT_DIR/lib.sh"

RELEASE_TAG="${1:?usage: backup.sh vX.Y.Z}"
validate_release_tag "$RELEASE_TAG"
create_backup "$(release_dir "$RELEASE_TAG")"
