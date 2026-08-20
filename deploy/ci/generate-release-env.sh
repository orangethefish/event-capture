#!/usr/bin/env sh
# Generate the non-secret per-release release.env consumed by docker-compose on the VM. Called by
# the Jenkins deploy job from validated parameters. Contains only image references, the public
# port, the release tag and the Flyway fingerprint. NEVER any secret.
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)

usage() {
  echo "usage: generate-release-env.sh --release-tag vX.Y.Z --backend-image REF --frontend-image REF --public-port N --migrations-dir DIR --output FILE" >&2
  exit 2
}

release_tag=""; backend_image=""; frontend_image=""; public_port=""; migrations_dir=""; output=""
while [ $# -gt 0 ]; do
  case "$1" in
    --release-tag) release_tag="${2:-}"; shift 2 ;;
    --backend-image) backend_image="${2:-}"; shift 2 ;;
    --frontend-image) frontend_image="${2:-}"; shift 2 ;;
    --public-port) public_port="${2:-}"; shift 2 ;;
    --migrations-dir) migrations_dir="${2:-}"; shift 2 ;;
    --output) output="${2:-}"; shift 2 ;;
    *) usage ;;
  esac
done
[ -n "$release_tag" ] && [ -n "$backend_image" ] && [ -n "$frontend_image" ] \
  && [ -n "$public_port" ] && [ -n "$migrations_dir" ] && [ -n "$output" ] || usage

printf '%s' "$release_tag"   | grep -Eq '^v[0-9]+\.[0-9]+\.[0-9]+$'  || { echo "invalid release tag: $release_tag" >&2; exit 1; }
printf '%s' "$backend_image" | grep -Eq '@sha256:[0-9a-f]{64}$'      || { echo "backend image must be digest-pinned" >&2; exit 1; }
printf '%s' "$frontend_image"| grep -Eq '@sha256:[0-9a-f]{64}$'      || { echo "frontend image must be digest-pinned" >&2; exit 1; }
printf '%s' "$public_port"   | grep -Eq '^[0-9]+$'                   || { echo "public port must be numeric" >&2; exit 1; }

fp=$("$SCRIPT_DIR/flyway-fingerprint.sh" "$migrations_dir")

{
  echo "# Generated per release by the event-capture deploy job. Non-secret; do not edit by hand."
  echo "RELEASE_TAG=$release_tag"
  echo "EVENT_CAPTURE_BACKEND_IMAGE=$backend_image"
  echo "EVENT_CAPTURE_FRONTEND_IMAGE=$frontend_image"
  echo "PUBLIC_PORT=$public_port"
  printf '%s\n' "$fp"
} > "$output"

echo "wrote $output" >&2
