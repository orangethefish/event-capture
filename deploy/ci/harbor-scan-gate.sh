#!/usr/bin/env sh
# Harbor vulnerability scan gate (scan-on-push + poll). After the release job pushes an image,
# Harbor auto-scans it (Trivy). This polls until the scan finishes, then fails on any FIXABLE
# CRITICAL vulnerability, so a fixable-Critical release never proceeds to deployment.
#
# Credentials come from the environment (Jenkins Harbor CI robot), never the command line:
#   HARBOR_USER, HARBOR_PASSWORD
#
#   deploy/ci/harbor-scan-gate.sh --api https://harbor.example.com/api/v2.0 \
#       --project event-capture --repository event-capture-backend --reference vX.Y.Z [--timeout 600]
set -eu

require() { command -v "$1" >/dev/null 2>&1 || { echo "required command not found: $1" >&2; exit 1; }; }
require curl
require jq

usage() {
  echo "usage: harbor-scan-gate.sh --api URL --project P --repository R --reference REF [--timeout SECONDS]" >&2
  exit 2
}

api=""; project=""; repository=""; reference=""; timeout=600
while [ $# -gt 0 ]; do
  case "$1" in
    --api) api="${2:-}"; shift 2 ;;
    --project) project="${2:-}"; shift 2 ;;
    --repository) repository="${2:-}"; shift 2 ;;
    --reference) reference="${2:-}"; shift 2 ;;
    --timeout) timeout="${2:-}"; shift 2 ;;
    *) usage ;;
  esac
done
[ -n "$api" ] && [ -n "$project" ] && [ -n "$repository" ] && [ -n "$reference" ] || usage
: "${HARBOR_USER:?HARBOR_USER must be set}"
: "${HARBOR_PASSWORD:?HARBOR_PASSWORD must be set}"

base="$api/projects/$project/repositories/$repository/artifacts/$reference"

hcurl() {
  curl -fsS --retry 3 --retry-delay 5 -u "$HARBOR_USER:$HARBOR_PASSWORD" "$@"
}

echo "polling Harbor scan status for $project/$repository:$reference (timeout ${timeout}s)" >&2
end=$(( $(date +%s) + timeout ))
status="Unknown"
while :; do
  overview=$(hcurl "$base?with_scan_overview=true" || echo '{}')
  status=$(printf '%s' "$overview" | jq -r '[.scan_overview[]?.scan_status] | map(select(. != null)) | first // "Unknown"')
  case "$status" in
    Success) echo "scan finished: Success" >&2; break ;;
    Error|Stopped) echo "scan ended in state: $status" >&2; exit 1 ;;
  esac
  if [ "$(date +%s)" -ge "$end" ]; then
    echo "timed out waiting for scan to finish (last status: $status)" >&2
    exit 1
  fi
  echo "  scan status: $status; waiting..." >&2
  sleep 10
done

# Precise fixable-Critical count from the full vulnerability report.
report=$(hcurl "$base/additions/vulnerabilities")
fixable_critical=$(printf '%s' "$report" | jq '[.[].vulnerabilities[]?
  | select(.severity == "Critical")
  | select(.fix_version != null and .fix_version != "")] | length')

echo "fixable Critical vulnerabilities: ${fixable_critical:-unknown}" >&2
if [ "${fixable_critical:-1}" -gt 0 ]; then
  echo "FAIL: $fixable_critical fixable Critical vulnerabilities in $repository:$reference" >&2
  printf '%s' "$report" | jq -r '.[].vulnerabilities[]?
    | select(.severity=="Critical")
    | select(.fix_version != null and .fix_version != "")
    | "  - \(.id) \(.package)@\(.version) -> fix \(.fix_version)"' >&2 || true
  exit 1
fi

echo "PASS: no fixable Critical vulnerabilities in $repository:$reference" >&2
