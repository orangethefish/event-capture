#!/usr/bin/env sh
# Deterministic fingerprint of the backend's Flyway versioned migrations. Printed as two
# release.env lines and embedded into release.env + release-manifest.json by the deploy job. The
# rollback guard compares this fingerprint between releases to decide whether an automatic
# downgrade is safe (unchanged) or requires operator recovery (changed).
#
#   deploy/ci/flyway-fingerprint.sh backend/src/main/resources/db/migration
set -eu

DIR="${1:?usage: flyway-fingerprint.sh <migrations-dir>}"
[ -d "$DIR" ] || { echo "migrations dir not found: $DIR" >&2; exit 1; }
command -v sha256sum >/dev/null 2>&1 || { echo "sha256sum is required" >&2; exit 1; }

pattern='^V[0-9]+(\.[0-9]+)*__.*\.sql$'

max=$(ls -1 "$DIR" 2>/dev/null | grep -E "$pattern" \
  | sed -E 's/^V([0-9]+(\.[0-9]+)*)__.*/\1/' | sort -V | tail -n1)

# Hash file names + contents in a stable order so an added/edited/removed migration changes it.
sha=$(cd "$DIR" && ls -1 | grep -E "$pattern" | LC_ALL=C sort \
  | while IFS= read -r f; do sha256sum "$f"; done | sha256sum | awk '{print $1}')

printf 'FLYWAY_MAX_VERSION=%s\n' "${max:-0}"
printf 'FLYWAY_MIGRATIONS_SHA256=%s\n' "$sha"
