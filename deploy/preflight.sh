#!/usr/bin/env sh
# Standalone preflight: validate compose config, free disk, existing dependency health and bundle
# completeness for a release, without changing any container.
#   sh /opt/event-capture/releases/vX.Y.Z/deploy/preflight.sh vX.Y.Z
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=deploy/lib.sh
. "$SCRIPT_DIR/lib.sh"

RELEASE_TAG="${1:?usage: preflight.sh vX.Y.Z}"
validate_release_tag "$RELEASE_TAG"
preflight_checks "$(release_dir "$RELEASE_TAG")"
