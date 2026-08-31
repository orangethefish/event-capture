# Event Capture Vault Production Runbook

Event Capture reads Vault **only from the deployment VM**. Jenkins transfers a digest-pinned release over SSH; the VM authenticates to Vault, renders `/srv/event-capture/shared/production.env` atomically, and starts Compose. Jenkins must not receive application secrets, Vault tokens, AppRole Role IDs, or Secret IDs.

## Verified current state

On 2026-08-13, the local Vault is initialized and unsealed, with a KV v2 engine at `secret/`. It is currently a single-node deployment using file storage and Shamir unseal, so it is not HA and cannot recover unattended. Before making it the sole long-term production authority, migrate to durable integrated Raft storage, run a restore drill, and configure supported KMS/HSM auto-unseal.

The public endpoint at `https://vault.orangethefish.id.vn` is operational through a TLS-preserving Cloudflare configuration.

## TLS requirements

1. Keep Cloudflare SSL/TLS mode at **Full (strict)**. Flexible must never front Vault.
2. Install a valid `vault.orangethefish.id.vn` certificate on the origin. A Cloudflare Origin CA certificate is acceptable for a Cloudflare-only endpoint; a public CA certificate also supports direct administrator access.
3. Keep Vault bound to loopback and do not expose port 8200. The Cloudflare Tunnel connector reaches that listener from the Vault host itself and makes only outbound connections, so no inbound forward to 8200 exists or should be created. Deploy clients must therefore reach Vault through `https://vault.orangethefish.id.vn`, never through a loopback or NAT shortcut.
4. Verify from a different machine, without `-k`:

   ```bash
   curl --fail --silent --show-error https://vault.orangethefish.id.vn/v1/sys/health
   ```

   The result must state `"initialized":true` and `"sealed":false`.

## Created least-privilege deploy role

The following Vault objects were created:

- Policy: `event-capture-production-vm`
- AppRole: `event-capture-production-vm`

The policy allows only `read` on these exact KV v2 paths, with no list or write capabilities:

```
secret/data/event-capture/production/database
secret/data/event-capture/production/redis
secret/data/event-capture/production/storage
secret/data/event-capture/production/smtp
secret/data/event-capture/production/auth
secret/data/event-capture/production/app
```

The AppRole is bound to `127.0.0.1/32`, uses a five-minute token (ten-minute maximum), permits eight token uses, has no default policy, and retains its Secret ID for 90 days. This is intentionally VM-local: if the deploy VM moves, create a new role/Secret ID with its new fixed egress address.

Enable Vault audit logging before placing production secrets in the server:

```bash
sudo install -d -o vault -g vault -m 0700 /var/log/vault
VAULT_ADDR=https://127.0.0.1:8200 VAULT_SKIP_VERIFY=true \
  vault audit enable file file_path=/var/log/vault/audit.json mode=0600
```

Also set `VAULT_ENABLE_FILE_PERMISSIONS_CHECK=true` in Vault's systemd environment and restart in a maintenance window.

## Populate the secret contract

The deployment script fails closed unless all required values are present and strings. Never use placeholder values in Vault.

| Path | Required keys |
|---|---|
| `database` | `username`, `password` |
| `redis` | `host`, `port` |
| `storage` | `provider`, `bucket`, `access_key`, `secret_key`, and either `account_id` or `endpoint` |
| `smtp` | `host`, `port`, `from`; `username`/ `password` may be blank only for a provider that permits it |
| `auth` | `abuse_key_secret`, `share_token_active_key_id`, `share_token_keyring`, `turnstile_site_key`, `turnstile_secret`, `turnstile_expected_hostname`; all three Google fields are optional but must be supplied together when enabled |
| `app` | `base_url`, `frontend_origin`, `trusted_proxy_cidrs` |

The production Compose network fixes Postgres and Redis addresses internally. The Vault values for Redis remain part of the documented secret contract but do not expose a public data service.

Use the existing example commands in `VAULT_SETUP.md` to populate the six objects. Set `base_url` and `frontend_origin` to the same public Event Capture origin and keep `APP_STORAGE_PUBLIC_BASE_URL` empty.

## Install the VM authentication file

Generate a Role ID and a response-wrapped Secret ID from an operator terminal:

```bash
ROLE_ID=$(vault read -field=role_id auth/approle/role/event-capture-production-vm/role-id)
WRAPPED_SECRET_ID=$(vault write -wrap-ttl=10m -f -field=wrapping_token \
  auth/approle/role/event-capture-production-vm/secret-id)
```

On the VM console, unwrap the Secret ID and store it in `/srv/event-capture/shared/vault-auth`, owned by `deploy:deploy` and mode `0600`. No CA file is copied to the VM: the deploy VM reaches Vault through the Cloudflare edge, which presents a publicly trusted certificate, so the system CA store is the correct trust source. The production auth file has exactly these keys, and no others:

```
VAULT_ADDR=https://vault.orangethefish.id.vn
VAULT_ROLE_ID=<role ID>
VAULT_SECRET_ID=<unwrapped Secret ID>
```

Do not add `VAULT_CACERT`: `deploy/vault.sh` no longer reads it, so setting it is silently ignored rather than applied.

Do not add `VAULT_CONNECT_TO` under the current topology. It rewrites the TCP destination while leaving the URL hostname intact, so `VAULT_CONNECT_TO=vault.orangethefish.id.vn:443:127.0.0.1:8200` makes the deploy VM dial its own loopback instead of the Cloudflare edge. That pairing was correct only when Vault ran on the deploy VM behind a NAT forward with a private origin certificate, which is why it was introduced alongside `VAULT_CACERT`; with a Cloudflare Tunnel there is no inbound forward and nothing is listening on the deploy VM's port 8200. A stale entry fails the deploy with `curl: (7) Failed to connect to 127.0.0.1 port 8200` while the log line still names the public URL. Set it only if a local Vault listener genuinely exists on the deploy VM, in which case it needs its own trusted origin certificate.

Do not use `VAULT_SKIP_VERIFY` in deployment automation. The deploy script safely parses this file rather than sourcing it, prevents secret values from reaching process arguments, uses a short-lived AppRole token, and does not log Vault response bodies.

After all six secret paths exist, validate as the deploy user:

```bash
sudo -u deploy sh -c '
  set -eu
  . /srv/event-capture/current/deploy/lib.sh
  . /srv/event-capture/current/deploy/vault.sh
  vault_fetch_secrets production
  test "$(stat -c %a /srv/event-capture/shared/production.env)" = 600
'
```

Then use the existing Jenkins parameters `VAULT_ENABLED=true` and `VAULT_ENV=production`.

## Jenkins credential inventory

Create only these Jenkins credentials:

| ID | Type | Value |
|---|---|---|
| `prod-ssh-key` | SSH Username with private key | Dedicated `deploy` SSH key for the VM; no interactive sudo |
| `prod-known-hosts` | Secret file | Pinned VM Ed25519 `known_hosts` entry |
| `bitbucket-scm-read` | SSH Username with private key | Read-only repository/submodule deploy key |

Configure `HARBOR_REGISTRY`, `HARBOR_PROJECT`, `DEPLOY_SSH_HOST`, `DEPLOY_SSH_USER=deploy`, `ROOT_REPO_URL`, and optionally `PUBLIC_PORT` as Jenkins global environment values. Keep the pull-only Harbor robot credential in the VM Docker credential store.

Never store a Vault root token, unseal share, AppRole Role ID, AppRole Secret ID, provider credential, database password, or share-token keyring in Jenkins.
