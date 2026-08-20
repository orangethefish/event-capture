#!/usr/bin/env sh
# Resolve the immutable sha256 digest of a pushed Harbor artifact by reference (tag). Prints the
# digest (sha256:...) to stdout. Used by the release job after push to pin images by digest.
#
# Credentials from the environment: HARBOR_USER, HARBOR_PASSWORD
#   deploy/ci/harbor-digest.sh --api https://harbor.example.com/api/v2.0 \
#       --project event-capture --repository event-capture-backend --reference vX.Y.Z
set -eu

command -v curl >/dev/null 2>&1 || { echo "curl required" >&2; exit 1; }
command -v jq   >/dev/null 2>&1 || { echo "jq required" >&2; exit 1; }

usage() { echo "usage: harbor-digest.sh --api URL --project P --repository R --reference REF" >&2; exit 2; }

api=""; project=""; repository=""; reference=""
while [ $# -gt 0 ]; do
  case "$1" in
    --api) api="${2:-}"; shift 2 ;;
    --project) project="${2:-}"; shift 2 ;;
    --repository) repository="${2:-}"; shift 2 ;;
    --reference) reference="${2:-}"; shift 2 ;;
    *) usage ;;
  esac
done
[ -n "$api" ] && [ -n "$project" ] && [ -n "$repository" ] && [ -n "$reference" ] || usage
: "${HARBOR_USER:?HARBOR_USER must be set}"
: "${HARBOR_PASSWORD:?HARBOR_PASSWORD must be set}"

digest=$(curl -fsS --retry 3 --retry-delay 5 -u "$HARBOR_USER:$HARBOR_PASSWORD" \
  "$api/projects/$project/repositories/$repository/artifacts/$reference" | jq -r '.digest')

printf '%s' "$digest" | grep -Eq '^sha256:[0-9a-f]{64}$' \
  || { echo "unexpected digest for $repository:$reference: '$digest'" >&2; exit 1; }
printf '%s\n' "$digest"
