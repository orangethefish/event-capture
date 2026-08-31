# Deployment

How to stand up Event Capture from nothing. Companion documents: `R2_DEPLOYMENT.md` for the
bucket and its CORS policy, `OPERATIONS_RUNBOOK.md` for day-two operations.

## Topology: one origin

The SPA and the API are served from a **single public origin**. The frontend container runs
nginx, serves the built Angular app, and proxies three prefixes to the API:

```
https://app.example.com/              -> Angular SPA (nginx static)
https://app.example.com/api/v1/*      -> backend-api:8080
https://app.example.com/login/oauth2/* -> backend-api:8080
https://app.example.com/actuator/*    -> backend-api:8080
```

This is not a stylistic choice. Three things depend on it:

1. **Cookies.** The host session cookie and the guest session cookie are both `SameSite=Lax`.
   Browsers do not send `Lax` cookies on cross-site requests, so serving the SPA on
   `app.example.com` while the API lives on `api.example.com` breaks host login and guest
   sessions entirely. Moving to `SameSite=None` would work only until third-party cookie
   blocking (already the default in Safari) removes it again.
2. **Media URLs.** `PublicAssetUrlBuilder` emits relative paths
   (`/api/v1/public/assets/{token}`) whenever `APP_STORAGE_PUBLIC_BASE_URL` is empty - which
   production requires, so that hiding or deleting a photo actually revokes access. Those URLs
   only resolve if the API is reachable under the SPA's origin.
3. **No production CORS.** Same-origin requests need no preflight and no credentialed CORS
   exception.

Set `APP_BASE_URL` and `APP_FRONTEND_ORIGIN` to that same origin.

If you terminate TLS at your own ingress and route the prefixes there instead, that is fine -
just keep the single-origin property, and keep `proxy_buffering off` on `/api/v1/` (see SSE
below).

## Prerequisites

- Docker and Docker Compose
- JDK 21 (to build the backend jar) and Node 20+ (to build the SPA)
- PostgreSQL 16 and Redis 7 (provided by the compose file)
- A Cloudflare R2 bucket, configured per `R2_DEPLOYMENT.md`
- SMTP credentials (magic-link sign-in does not work without them)
- A Cloudflare Turnstile site key and secret

## 1. Build the artifacts

The images copy pre-built output; nothing compiles inside the Dockerfiles.

```bash
cd backend  && ./gradlew bootJar
cd ../frontend && npm ci && npm run build -- --configuration production
```

## 2. Generate secrets

Two values have placeholder defaults that the backend **refuses to start with** in production
(`AuthConfigurationValidator`):

```bash
openssl rand -base64 32   # APP_ABUSE_KEY_SECRET
openssl rand -base64 32   # the key material for APP_SHARE_TOKEN_KEYRING
```

`APP_SHARE_TOKEN_KEYRING` is `<key-id>=<base64 32-byte key>`, and
`APP_SHARE_TOKEN_ACTIVE_KEY_ID` must name a key present in it. Never drop a key ID that
existing ciphertext still references - startup fails if the database holds a key ID the
keyring does not.

## 3. Configure

### Option A: HashiCorp Vault (recommended for production)

Store secrets in Vault and let the deploy scripts fetch them automatically.
See `VAULT_PRODUCTION_RUNBOOK.md` for the required TLS, least-privilege AppRole, and Jenkins
credential boundaries; `VAULT_SETUP.md` retains the field examples. Quick start:

1. Set up Vault with AppRole auth and store secrets under `secret/data/event-capture/production/`
2. Create `/srv/event-capture/shared/vault-auth` on the VM with `VAULT_ADDR`, `VAULT_ROLE_ID`, `VAULT_SECRET_ID`
3. Set `EVENT_CAPTURE_VAULT_ENABLED=1` in Jenkins or before running `deploy.sh`

The deploy script generates `production.env` from Vault before starting services.

### Option B: Manual secrets file

```bash
cp env.example .env
```

Edit `.env` and copy to `/srv/event-capture/shared/production.env` on the VM (mode 0600).

### Values most often set wrong (applies to both options)

| Variable | Why it matters |
|---|---|
| `APP_BASE_URL`, `APP_FRONTEND_ORIGIN` | Must be the **same** origin (see above) |
| `APP_HTTP_TRUSTED_PROXY_CIDRS` | Must include the nginx container's network, or `ClientIpResolver` sees only the proxy address and every per-IP abuse limit collapses into one bucket |
| `APP_STORAGE_PUBLIC_BASE_URL` | Must be **empty**; a non-empty value is rejected in production because a cached CDN URL would survive a hide or delete |
| `APP_AUTH_FAILURE_PATH` | Must be a real Angular route (`/host/login/callback`) |
| `APP_GOOGLE_REDIRECT_URI` | `https://<origin>/login/oauth2/code/google` - the public origin, not an api. subdomain |
| `APP_CHALLENGE_MODE` | Production forces `turnstile`; the API will not start otherwise |

## 4. Start

```bash
docker compose up -d
docker compose ps
```

Services: `postgres`, `redis`, `backend-api`, `backend-worker`, `frontend`.

Flyway migrates V1 through V8 on first boot. On a greenfield database both Release B
maintenance flags stay `false` - they are not startup prerequisites. Only an environment
upgrading from pre-V6 data needs `PHASE3_RELEASE.md`.

`backend-api` and `backend-worker` are the same image with different `APP_RUNTIME_ROLE`
values. The API exposes controllers, security and SSE; the worker runs job consumers and
exposes only actuator endpoints. Both require `APP_INFRASTRUCTURE_MODE=redis` - Redis carries
sessions, cross-instance SSE fan-out, job streams and the distributed abuse counters. The
Redis-free `local` mode is single-process only and is not a production configuration.

## 5. Smoke test

```bash
ORIGIN=https://app.example.com

# API is reachable through the SPA origin. Must be JSON, not index.html - if you get HTML with
# a 200 here, the proxy rules are not in effect.
curl -s $ORIGIN/api/v1/csrf

# Readiness includes the database and the mode-aware Redis contributor.
curl -s $ORIGIN/actuator/health/readiness

# SPA deep links fall through to index.html.
curl -s -o /dev/null -w '%{http_code}\n' $ORIGIN/host/events
```

Then walk one real journey: sign in, create an event, open the share link in a second browser,
join, upload a photo, and confirm it appears **without reloading** (that last part is the only
end-to-end proof that SSE is flowing through the proxy unbuffered).

## Server-Sent Events

`/api/v1/public/events/{slug}/{token}/stream` is a long-lived response that never completes.
nginx's default response buffering holds events until a buffer fills, which makes the live
gallery look broken. The shipped `nginx.conf.template` sets, on the `/api/v1/` location:

```
proxy_buffering off;
proxy_cache off;
chunked_transfer_encoding on;
proxy_read_timeout 3600s;
```

Any other proxy or ingress in front of this needs the equivalent.

## Uploads

`client_max_body_size 26m` matches `app.upload.max-size-bytes` (25 MiB). Files above
`app.upload.multipart-threshold-bytes` (8 MiB) use multipart upload, which for R2 means the
browser PUTs each part directly to storage - so the R2 bucket CORS policy must allow `PUT`
from the frontend origin and expose `ETag`. `backend/r2-cors.example.json` is the template.

## Scaling

- `backend-api` scales horizontally; Redis carries sessions and SSE fan-out between instances.
- `backend-worker` scales horizontally; jobs are consumed from a Redis Stream consumer group
  with pending-message reclaim, so an instance dying mid-job does not lose work.
- `frontend` is stateless.
- PostgreSQL and Redis are the stateful tier. Redis runs with AOF so job streams and consumer
  offsets survive a restart.

## Rollback

The images are immutable and tagged per commit, so rolling the application back is a tag
change. Flyway migrations are **not** automatically reversible - check whether the version you
are rolling back to predates a migration the running database has applied, and restore from a
PostgreSQL backup if so. Deploy the worker and API from the same commit; they share the schema.
