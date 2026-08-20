#!/usr/bin/env sh
# Generate the release manifest: an auditable record tying the root + submodule commits to the
# published image references and digests, plus the Flyway fingerprint. Produced by the root tag
# pipeline (archived in Jenkins) and re-derived by the deploy job for the VM release record.
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)

usage() {
  echo "usage: generate-release-manifest.sh --release-tag vX.Y.Z --root-commit SHA --backend-commit SHA --frontend-commit SHA --backend-image REF --frontend-image REF --backend-digest sha256:... --frontend-digest sha256:... --migrations-dir DIR --output FILE" >&2
  exit 2
}

release_tag=""; root_commit=""; backend_commit=""; frontend_commit=""
backend_image=""; frontend_image=""; backend_digest=""; frontend_digest=""
migrations_dir=""; output=""
while [ $# -gt 0 ]; do
  case "$1" in
    --release-tag) release_tag="${2:-}"; shift 2 ;;
    --root-commit) root_commit="${2:-}"; shift 2 ;;
    --backend-commit) backend_commit="${2:-}"; shift 2 ;;
    --frontend-commit) frontend_commit="${2:-}"; shift 2 ;;
    --backend-image) backend_image="${2:-}"; shift 2 ;;
    --frontend-image) frontend_image="${2:-}"; shift 2 ;;
    --backend-digest) backend_digest="${2:-}"; shift 2 ;;
    --frontend-digest) frontend_digest="${2:-}"; shift 2 ;;
    --migrations-dir) migrations_dir="${2:-}"; shift 2 ;;
    --output) output="${2:-}"; shift 2 ;;
    *) usage ;;
  esac
done
[ -n "$release_tag" ] && [ -n "$root_commit" ] && [ -n "$backend_commit" ] && [ -n "$frontend_commit" ] \
  && [ -n "$backend_image" ] && [ -n "$frontend_image" ] && [ -n "$backend_digest" ] \
  && [ -n "$frontend_digest" ] && [ -n "$migrations_dir" ] && [ -n "$output" ] || usage

printf '%s' "$release_tag"     | grep -Eq '^v[0-9]+\.[0-9]+\.[0-9]+$' || { echo "invalid release tag" >&2; exit 1; }
printf '%s' "$backend_digest"  | grep -Eq '^sha256:[0-9a-f]{64}$'     || { echo "invalid backend digest" >&2; exit 1; }
printf '%s' "$frontend_digest" | grep -Eq '^sha256:[0-9a-f]{64}$'     || { echo "invalid frontend digest" >&2; exit 1; }

fp=$("$SCRIPT_DIR/flyway-fingerprint.sh" "$migrations_dir")
flyway_max=$(printf '%s\n' "$fp" | awk -F= '$1=="FLYWAY_MAX_VERSION"{print $2}')
flyway_sha=$(printf '%s\n' "$fp" | awk -F= '$1=="FLYWAY_MIGRATIONS_SHA256"{print $2}')
built_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)

cat > "$output" <<JSON
{
  "release_tag": "$release_tag",
  "built_at": "$built_at",
  "root_commit": "$root_commit",
  "submodules": {
    "backend": "$backend_commit",
    "frontend": "$frontend_commit"
  },
  "images": {
    "backend": { "reference": "$backend_image", "digest": "$backend_digest" },
    "frontend": { "reference": "$frontend_image", "digest": "$frontend_digest" }
  },
  "flyway": {
    "max_version": "$flyway_max",
    "migrations_sha256": "$flyway_sha"
  }
}
JSON

echo "wrote $output" >&2
