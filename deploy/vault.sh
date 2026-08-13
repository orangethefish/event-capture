# shellcheck shell=sh
# Vault integration for the event-capture production VM.
#
# This script intentionally talks to Vault with curl rather than placing a long-lived token in
# the environment. It reads a short-lived AppRole token, renders the Docker Compose env file
# atomically, and never prints a Vault response body (which can contain a secret or token).
#
# Required VM-local file, mode 0600 and owned by the deploy user:
#   /opt/event-capture/shared/vault-auth
#   VAULT_ADDR=https://vault.orangethefish.id.vn
#   VAULT_CACERT=/opt/event-capture/shared/vault-ca.pem   # omit only with a public CA chain
#   VAULT_CONNECT_TO=vault.orangethefish.id.vn:443:127.0.0.1:8200  # optional VM-local route
#   VAULT_ROLE_ID=<AppRole role ID>
#   VAULT_SECRET_ID=<AppRole secret ID>
#
# Vault KV v2 paths are fixed to secret/data/event-capture/<environment>/{database,redis,
# storage,smtp,auth,app}. The deployed AppRole must have read access only to its own environment.

VAULT_AUTH_FILE="${VAULT_AUTH_FILE:-/opt/event-capture/shared/vault-auth}"
VAULT_SECRET_PATH_PREFIX="${VAULT_SECRET_PATH_PREFIX:-secret/data/event-capture}"
VAULT_ADDR=""
VAULT_CACERT=""
VAULT_CONNECT_TO=""
VAULT_ROLE_ID=""
VAULT_SECRET_ID=""

vault_auth_field() {
  _key="$1"
  awk -F= -v key="$_key" '$1 == key { sub(/^[^=]*=/, ""); print; exit }' "$VAULT_AUTH_FILE"
}

vault_require_nonempty() {
  _value="$1"; _name="$2"
  [ -n "$_value" ] || die "missing $_name in Vault"
  _newline='
'
  _carriage_return=$(printf '\r')
  case "$_value" in
    *"$_newline"*|*"$_carriage_return"*) die "$_name must not contain a newline" ;;
  esac
}

# Load fixed fields without sourcing the file. Sourcing a credentials file would execute any
# injected shell syntax as the deploy account.
vault_load_auth() {
  [ -f "$VAULT_AUTH_FILE" ] || die "missing vault auth file: $VAULT_AUTH_FILE"
  [ -r "$VAULT_AUTH_FILE" ] || die "vault auth file is not readable: $VAULT_AUTH_FILE"

  VAULT_ADDR=$(vault_auth_field VAULT_ADDR)
  VAULT_CACERT=$(vault_auth_field VAULT_CACERT)
  VAULT_CONNECT_TO=$(vault_auth_field VAULT_CONNECT_TO)
  VAULT_ROLE_ID=$(vault_auth_field VAULT_ROLE_ID)
  VAULT_SECRET_ID=$(vault_auth_field VAULT_SECRET_ID)
  vault_require_nonempty "$VAULT_ADDR" VAULT_ADDR
  vault_require_nonempty "$VAULT_ROLE_ID" VAULT_ROLE_ID
  vault_require_nonempty "$VAULT_SECRET_ID" VAULT_SECRET_ID
  case "$VAULT_ADDR" in
    https://*) ;;
    *) die "VAULT_ADDR must be an HTTPS URL" ;;
  esac
  if [ -n "$VAULT_CACERT" ]; then
    [ -r "$VAULT_CACERT" ] || die "VAULT_CACERT is not readable: $VAULT_CACERT"
  fi
  case "$VAULT_CONNECT_TO" in
    *[!A-Za-z0-9._:-]*) die "VAULT_CONNECT_TO has an invalid format" ;;
  esac
}

vault_curl() {
  if [ -n "$VAULT_CONNECT_TO" ]; then
    set -- --connect-to "$VAULT_CONNECT_TO" "$@"
  fi
  if [ -n "$VAULT_CACERT" ]; then
    curl --fail --silent --show-error --proto '=https' --tlsv1.2 --max-time 10 --cacert "$VAULT_CACERT" "$@"
  else
    curl --fail --silent --show-error --proto '=https' --tlsv1.2 --max-time 10 "$@"
  fi
}

vault_temp_file() {
  _file=$(mktemp "${TMPDIR:-/tmp}/event-capture-vault.XXXXXX") || die "could not create a Vault temporary file"
  chmod 0600 "$_file" || die "could not protect a Vault temporary file"
  printf '%s' "$_file"
}

# Authenticate with Vault using AppRole and return a short-lived client token. The role ID and
# secret ID are written to 0600 temp files so they never appear in a process command line.
vault_login() {
  _role_file=$(vault_temp_file)
  _secret_file=$(vault_temp_file)
  _payload_file=$(vault_temp_file)
  trap 'rm -f "${_role_file:-}" "${_secret_file:-}" "${_payload_file:-}"' EXIT HUP INT TERM
  printf '%s' "$VAULT_ROLE_ID" > "$_role_file"
  printf '%s' "$VAULT_SECRET_ID" > "$_secret_file"
  jq -n --rawfile role "$_role_file" --rawfile secret "$_secret_file" \
    '{role_id: $role, secret_id: $secret}' > "$_payload_file" \
    || die "could not build Vault AppRole request"

  _response=$(vault_curl -X POST -H 'Content-Type: application/json' \
    --data-binary "@$_payload_file" "${VAULT_ADDR}/v1/auth/approle/login") \
    || die "Vault AppRole login failed"
  _token=$(printf '%s' "$_response" | jq -er '.auth.client_token | select(type == "string" and length > 0)') \
    || die "Vault AppRole login returned no client token"
  rm -f "$_role_file" "$_secret_file" "$_payload_file"
  trap - EXIT HUP INT TERM
  printf '%s' "$_token"
}

# Read a secret from Vault KV v2. Returns its .data.data object as JSON. The short-lived token is
# held in a protected curl config file rather than a -H process argument.
vault_read() {
  _token="$1"; _path="$2"
  _config_file=$(vault_temp_file)
  trap 'rm -f "${_config_file:-}"' EXIT HUP INT TERM
  printf '%s\n' "header = \"X-Vault-Token: $_token\"" > "$_config_file"
  _response=$(vault_curl --config "$_config_file" "${VAULT_ADDR}/v1/${VAULT_SECRET_PATH_PREFIX}/${_path}") \
    || die "Vault read failed for ${VAULT_SECRET_PATH_PREFIX}/${_path}"
  rm -f "$_config_file"
  trap - EXIT HUP INT TERM
  printf '%s' "$_response" | jq -ec '.data.data | select(type == "object")' \
    || die "Vault returned an invalid KV v2 response for ${VAULT_SECRET_PATH_PREFIX}/${_path}"
}

json_field() {
  printf '%s' "$1" | jq -er --arg key "$2" '.[$key] | select(type == "string")'
}

json_required() {
  _value=$(json_field "$1" "$2") || die "missing or non-string $3 in Vault"
  vault_require_nonempty "$_value" "$3"
  printf '%s' "$_value"
}

# Docker Compose treats single-quoted env-file values literally. Reject newlines (not valid for
# the application's secret formats) and escape a literal single quote for Compose's parser.
env_quote() {
  _value="$1"; _name="$2"
  _newline='
'
  _carriage_return=$(printf '\r')
  case "$_value" in
    *"$_newline"*|*"$_carriage_return"*) die "$_name must not contain a newline" ;;
  esac
  printf "'"
  printf '%s' "$_value" | sed "s/'/\\\\'/g"
  printf "'\n"
}

write_env_line() {
  _key="$1"; _value="$2"
  printf '%s=' "$_key"
  env_quote "$_value" "$_key"
}

# Fetch all secrets and atomically write the Compose env file.
vault_fetch_secrets() {
  _env="${1:-production}"
  printf '%s' "$_env" | grep -Eq '^[A-Za-z0-9][A-Za-z0-9_-]*$' \
    || die "invalid Vault environment: $_env"

  require_cmd curl jq awk sed grep mktemp chmod mv rm
  vault_load_auth
  log "authenticating with Vault at $VAULT_ADDR"
  _token=$(vault_login)
  log "Vault login successful"
  log "fetching secrets for environment: $_env"

  _db=$(vault_read "$_token" "$_env/database")
  _redis=$(vault_read "$_token" "$_env/redis")
  _storage=$(vault_read "$_token" "$_env/storage")
  _smtp=$(vault_read "$_token" "$_env/smtp")
  _auth=$(vault_read "$_token" "$_env/auth")
  _app=$(vault_read "$_token" "$_env/app")

  _base_url=$(json_required "$_app" base_url app.base_url)
  _frontend_origin=$(json_required "$_app" frontend_origin app.frontend_origin)
  _trusted_proxy_cidrs=$(json_required "$_app" trusted_proxy_cidrs app.trusted_proxy_cidrs)
  _db_username=$(json_required "$_db" username database.username)
  _db_password=$(json_required "$_db" password database.password)
  _redis_host=$(json_required "$_redis" host redis.host)
  _redis_port=$(json_required "$_redis" port redis.port)
  _storage_provider=$(json_required "$_storage" provider storage.provider)
  _storage_bucket=$(json_required "$_storage" bucket storage.bucket)
  _storage_account_id=$(json_field "$_storage" account_id || true)
  _storage_endpoint=$(json_field "$_storage" endpoint || true)
  _storage_access_key=$(json_required "$_storage" access_key storage.access_key)
  _storage_secret_key=$(json_required "$_storage" secret_key storage.secret_key)
  [ -n "$_storage_account_id" ] || [ -n "$_storage_endpoint" ] \
    || die "one of storage.account_id or storage.endpoint is required in Vault"
  _smtp_host=$(json_required "$_smtp" host smtp.host)
  _smtp_port=$(json_required "$_smtp" port smtp.port)
  _smtp_username=$(json_field "$_smtp" username || true)
  _smtp_password=$(json_field "$_smtp" password || true)
  _mail_from=$(json_required "$_smtp" from smtp.from)
  _abuse_key_secret=$(json_required "$_auth" abuse_key_secret auth.abuse_key_secret)
  _share_token_active_key_id=$(json_required "$_auth" share_token_active_key_id auth.share_token_active_key_id)
  _share_token_keyring=$(json_required "$_auth" share_token_keyring auth.share_token_keyring)
  _turnstile_site_key=$(json_required "$_auth" turnstile_site_key auth.turnstile_site_key)
  _turnstile_secret=$(json_required "$_auth" turnstile_secret auth.turnstile_secret)
  _turnstile_expected_hostname=$(json_required "$_auth" turnstile_expected_hostname auth.turnstile_expected_hostname)
  _google_client_id=$(json_field "$_auth" google_client_id || true)
  _google_client_secret=$(json_field "$_auth" google_client_secret || true)
  _google_redirect_uri=$(json_field "$_auth" google_redirect_uri || true)

  _out="$SHARED_ENV"
  _tmp="${_out}.tmp.$$"
  umask 077
  trap 'rm -f "${_tmp:-}"' EXIT HUP INT TERM
  {
    printf '%s\n' '# Generated by deploy/vault.sh. Do not edit; refresh from Vault.'
    write_env_line APP_BASE_URL "$_base_url"
    write_env_line APP_FRONTEND_ORIGIN "$_frontend_origin"
    write_env_line APP_HTTP_TRUSTED_PROXY_CIDRS "$_trusted_proxy_cidrs"
    write_env_line POSTGRES_USER "$_db_username"
    write_env_line POSTGRES_PASSWORD "$_db_password"
    write_env_line APP_DATASOURCE_USERNAME "$_db_username"
    write_env_line APP_DATASOURCE_PASSWORD "$_db_password"
    write_env_line SPRING_DATA_REDIS_HOST "$_redis_host"
    write_env_line SPRING_DATA_REDIS_PORT "$_redis_port"
    write_env_line APP_STORAGE_PROVIDER "$_storage_provider"
    write_env_line APP_STORAGE_R2_BUCKET "$_storage_bucket"
    write_env_line APP_STORAGE_R2_ACCOUNT_ID "$_storage_account_id"
    write_env_line APP_STORAGE_R2_ENDPOINT "$_storage_endpoint"
    write_env_line APP_STORAGE_R2_ACCESS_KEY "$_storage_access_key"
    write_env_line APP_STORAGE_R2_SECRET_KEY "$_storage_secret_key"
    write_env_line APP_SMTP_HOST "$_smtp_host"
    write_env_line APP_SMTP_PORT "$_smtp_port"
    write_env_line APP_SMTP_USERNAME "$_smtp_username"
    write_env_line APP_SMTP_PASSWORD "$_smtp_password"
    write_env_line APP_MAIL_FROM "$_mail_from"
    write_env_line APP_ABUSE_KEY_SECRET "$_abuse_key_secret"
    write_env_line APP_SHARE_TOKEN_ACTIVE_KEY_ID "$_share_token_active_key_id"
    write_env_line APP_SHARE_TOKEN_KEYRING "$_share_token_keyring"
    write_env_line APP_TURNSTILE_SITE_KEY "$_turnstile_site_key"
    write_env_line APP_TURNSTILE_SECRET "$_turnstile_secret"
    write_env_line APP_TURNSTILE_EXPECTED_HOSTNAME "$_turnstile_expected_hostname"
    write_env_line APP_GOOGLE_CLIENT_ID "$_google_client_id"
    write_env_line APP_GOOGLE_CLIENT_SECRET "$_google_client_secret"
    write_env_line APP_GOOGLE_REDIRECT_URI "$_google_redirect_uri"
  } > "$_tmp"
  chmod 0600 "$_tmp"
  mv "$_tmp" "$_out"
  _tmp=""
  trap - EXIT HUP INT TERM
  log "secrets refreshed into $_out"
}

vault_refresh_secrets() {
  vault_fetch_secrets "${1:-production}"
  log "secrets refreshed; restart affected services to apply them"
}
