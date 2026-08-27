#!/usr/bin/env bash
# One-time production VM bootstrap for event-capture. Idempotent: safe to re-run.
#
# Run as root (or with sudo) on the target VM:
#   HARBOR_REGISTRY=harbor.example.com \
#   HARBOR_VM_ROBOT_USER='robot$event-capture+vm' \
#   HARBOR_VM_ROBOT_PASSWORD='...' \
#   sudo -E bash deploy/provision-vm.sh
#
# What it does:
#   - verifies/installs Docker Engine + Compose v2
#   - creates a non-root 'deploy' user in the docker group
#   - logs Docker in to Harbor with the PULL-ONLY VM robot account (as the deploy user)
#   - creates /opt/event-capture/{releases,shared,backups}
#   - writes shared/production.env (0600) from a template if absent (never overwrites secrets)
#
# It does NOT install or modify the host nginx / Cloudflare configuration. Those stay VM-managed
# (see event-capture.conf, cloudflare-real-ip.conf) and keep the public service on loopback.
set -euo pipefail

DEPLOY_USER="${DEPLOY_USER:-deploy}"
OPT_ROOT="${EVENT_CAPTURE_ROOT:-/srv/event-capture}"

log() { printf '[provision] %s\n' "$*"; }
die() { printf '[provision] ERROR: %s\n' "$*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "run as root (sudo)"

# --- Host packages the deploy scripts require --------------------------------------------------
# deploy/lib.sh needs docker, curl, awk, grep, df and date; deploy/vault.sh additionally needs jq.
# jq is the one routinely absent from a minimal Debian/Ubuntu image, and its absence does not
# surface until the first Vault-enabled deploy dies on the VM with "required command not found:
# jq" - after Jenkins has already transferred the release bundle. Install it up front instead.
MISSING_PKGS=""
command -v jq   >/dev/null 2>&1 || MISSING_PKGS="$MISSING_PKGS jq"
command -v curl >/dev/null 2>&1 || MISSING_PKGS="$MISSING_PKGS curl"
if [ -n "$MISSING_PKGS" ]; then
	command -v apt-get >/dev/null 2>&1 \
		|| die "missing required commands:$MISSING_PKGS (no apt-get here; install them manually)"
	log "installing missing host packages:$MISSING_PKGS"
	# Deliberately unquoted: MISSING_PKGS is a package list built from literals above.
	DEBIAN_FRONTEND=noninteractive apt-get update -qq
	DEBIAN_FRONTEND=noninteractive apt-get install -y -qq $MISSING_PKGS
fi

# --- Docker Engine + Compose v2 --------------------------------------------------------------
if ! command -v docker >/dev/null 2>&1; then
	if [ "${INSTALL_DOCKER:-1}" = "1" ] && command -v apt-get >/dev/null 2>&1; then
		log "installing Docker Engine via get.docker.com"
		curl -fsSL https://get.docker.com | sh
	else
		die "docker not installed and auto-install disabled/unsupported; install Docker Engine first"
	fi
fi
docker compose version >/dev/null 2>&1 || die "Docker Compose v2 plugin missing (need 'docker compose', not docker-compose)"
systemctl enable --now docker >/dev/null 2>&1 || true
log "docker: $(docker --version); compose: $(docker compose version | head -n1)"

# --- Non-root deploy user ---------------------------------------------------------------------
if ! id -u "$DEPLOY_USER" >/dev/null 2>&1; then
	log "creating user $DEPLOY_USER"
	useradd --create-home --shell /bin/bash "$DEPLOY_USER"
fi
if ! id -nG "$DEPLOY_USER" | tr ' ' '\n' | grep -qx docker; then
	log "adding $DEPLOY_USER to the docker group"
	usermod -aG docker "$DEPLOY_USER"
fi

# --- Directory layout -------------------------------------------------------------------------
log "creating $OPT_ROOT/{releases,shared,backups}"
install -d -o "$DEPLOY_USER" -g "$DEPLOY_USER" -m 0755 "$OPT_ROOT" "$OPT_ROOT/releases" "$OPT_ROOT/backups"
install -d -o "$DEPLOY_USER" -g "$DEPLOY_USER" -m 0700 "$OPT_ROOT/shared"

# --- shared/production.env (secrets, VM-managed, never transferred) ---------------------------
SHARED_ENV="$OPT_ROOT/shared/production.env"
if [ -f "$SHARED_ENV" ]; then
	log "shared/production.env already present; leaving it untouched"
else
	log "writing shared/production.env TEMPLATE (0600) - fill in the real secrets before deploying"
	cat > "$SHARED_ENV" <<'ENVTEMPLATE'
# event-capture production secrets + non-secret runtime config (VM-managed, 0600).
# The Jenkins deploy job layers a generated non-secret release.env (image pins) on top of this.
# NEVER commit this file or let Jenkins transfer it. See env.example for the full documented set.
APP_BASE_URL=https://app.example.com
APP_FRONTEND_ORIGIN=https://app.example.com
APP_HTTP_TRUSTED_PROXY_CIDRS=172.28.0.0/24
APP_ABUSE_KEY_SECRET=change-me
APP_SHARE_TOKEN_ACTIVE_KEY_ID=prod-v1
APP_SHARE_TOKEN_KEYRING=prod-v1=change-me
POSTGRES_USER=event_capture
POSTGRES_PASSWORD=change-me
APP_SMTP_HOST=smtp.example.com
APP_SMTP_USERNAME=mailer@example.com
APP_SMTP_PASSWORD=change-me
APP_MAIL_FROM=Event Capture <mailer@example.com>
APP_TURNSTILE_SITE_KEY=change-me
APP_TURNSTILE_SECRET=change-me
APP_TURNSTILE_EXPECTED_HOSTNAME=app.example.com
APP_STORAGE_R2_BUCKET=event-capture-prod
APP_STORAGE_R2_ACCOUNT_ID=change-me
APP_STORAGE_R2_ACCESS_KEY=change-me
APP_STORAGE_R2_SECRET_KEY=change-me
APP_GOOGLE_CLIENT_ID=
APP_GOOGLE_CLIENT_SECRET=
APP_GOOGLE_REDIRECT_URI=
ENVTEMPLATE
	chown "$DEPLOY_USER:$DEPLOY_USER" "$SHARED_ENV"
	chmod 0600 "$SHARED_ENV"
fi

# --- Read-only Harbor login (VM robot, pull-only), as the deploy user -------------------------
if [ -n "${HARBOR_REGISTRY:-}" ] && [ -n "${HARBOR_VM_ROBOT_USER:-}" ] && [ -n "${HARBOR_VM_ROBOT_PASSWORD:-}" ]; then
	log "logging Docker in to $HARBOR_REGISTRY as the pull-only VM robot (user $DEPLOY_USER)"
	sudo -u "$DEPLOY_USER" sh -c 'printf "%s" "$1" | docker login "$2" --username "$3" --password-stdin' \
		_ "$HARBOR_VM_ROBOT_PASSWORD" "$HARBOR_REGISTRY" "$HARBOR_VM_ROBOT_USER"
else
	log "HARBOR_* not fully provided; skipping Harbor login. Run 'docker login $HARBOR_REGISTRY' as $DEPLOY_USER with the pull-only VM robot before the first deploy."
fi

log "done. Next: fill in $SHARED_ENV, ensure the host nginx (event-capture.conf + cloudflare-real-ip.conf) is in place, and authorize the Jenkins prod-ssh-key for $DEPLOY_USER."
