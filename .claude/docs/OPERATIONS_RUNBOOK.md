# Backend Operations and Recovery Runbook

## Release checks

From `backend/` run:

- `./gradlew spotlessCheck test`
- `./gradlew openApiCheck`
- build both production images and smoke API-only and worker-only roles against PostgreSQL, Redis, and private R2

The Phase 0 wrapper scripts are not present yet. Until they are added, compare the relative file sets and SHA-256 hashes under `.agents/` and `.claude/`, compare `AGENTS.md` with `CLAUDE.md`, and use `git check-ignore -v .env` plus `git ls-files -- .env` for the local hygiene gate. CI additionally runs Gitleaks, dependency reporting, the container build, and preserves the Bitbucket-to-GitHub mirror step.

## Outbox and worker recovery

Jobs and gallery notifications are committed to `outbox_messages` with domain state. Prometheus exports the Micrometer meters with normalized names. Monitor:

- `eventcapture_outbox_unpublished_count`
- `eventcapture_outbox_oldest_age_seconds`
- `eventcapture_outbox_age_seconds`
- `eventcapture_outbox_publish_failures_total`
- `eventcapture_jobs_stream_pending_current`
- `eventcapture_jobs_stream_claimed_total`
- `eventcapture_jobs_retries_total`
- `eventcapture_jobs_dead_letters_total`
- `eventcapture_jobs_dead_letters_current`
- `eventcapture_jobs_handler_duration_seconds_bucket` by `job_type` and `outcome`
- `eventcapture_jobs_terminal_failures_total`
- `eventcapture_exports_requested_total`
- `eventcapture_exports_completed_total`
- `eventcapture_exports_failed_total`
- `eventcapture_cleanup_provider_failures_total` by `cleanup_type`

Import `backend/deploy/prometheus/event-capture-alerts.yml` into the deployment monitoring stack. CI validates both that file and `event-capture-alerts.test.yml` with pinned Prometheus `v3.5.0`. The rules cover outbox stall/backlog, pending work, retry storms, DLQ depth, terminal failures, publish failures, p95 handler latency, missing metrics, terminal export failures, and provider cleanup failures by type. Threshold changes belong to deployment review and must keep the executable rule tests current.
A publish-success/mark-success crash may duplicate delivery; handlers are required to be idempotent. Delays remain in PostgreSQL `outbox_messages.available_at` until due, and Redis receives only immediate stream records. Consumer groups start at the beginning of the stream, and idle pending entries are reclaimed before new polling so recovery cannot be starved by steady traffic. Do not acknowledge a record manually until its domain handler state has been verified. SSE is a state-change hint; clients resynchronize from the REST feed after reconnect. The live split-runtime test proves disconnect, REST resync, and reconnect across two Redis-backed API instances.

For an incident, inspect unpublished outbox age/count, Redis group/pending state, the DLQ stream, and the target photo/export/purge state using correlation IDs. Restore Redis service and workers before replaying. Do not delete pending/outbox rows to make dashboards green.

### Recovery verification

`./gradlew phase4ProcessTest` launches real child JVMs and halts them at ambiguous publication/acknowledgement boundaries. It also stops and restarts AOF-backed Redis while API and worker processes remain alive. Keep `APP_JOBS_RECLAIM_IDLE` above a healthy handler handoff in deployments; the one-second test value is not a production recommendation. Full proof and the storage audit are recorded in `.agents/docs/PHASE4_RESILIENCE.md`.
## PostgreSQL backup and restore drill

Before schema enforcement releases, take a provider-native snapshot plus a logical backup. Quarterly, restore to an isolated database, run Flyway validation without applying unreviewed migrations, verify event/share-token counts and key IDs, boot an API/worker pair, and complete a create/join/upload/process/export journey. Record recovery time and data-loss window.

## Phase 3 greenfield deployment and future pre-V6 upgrades

No release or application database has been deployed for the current target. The first deployment creates a fresh database and lets Flyway apply V1 through V8 directly. Supply the configured keyring to API and worker nodes, and keep both `APP_SHARE_TOKEN_BACKFILL_ENABLED=false` and `APP_SHARE_TOKEN_RELEASE_B_PREFLIGHT_ENABLED=false`. There is no legacy data to backfill, preflight, or cut over.

After migration, verify readiness, create a new event, retrieve its host share path, resolve it publicly, join as a guest, and verify `events.share_token_value` is absent. Monitor decryption failures, host-event 5xx responses, readiness, and Flyway logs.

Every stored key ID must remain configured on every node. Normal startup enforces this invariant. Backfill and preflight flags are mutually exclusive, and both are false during normal operation. The keyring is supplied by the deployment secret store; it must never be committed, printed, or captured with ciphertext/token values.

If a future environment already contains pre-V6 Release A data, Release B remains a maintenance-window, non-rolling migration. Freeze writes, stop every Release A API and worker, run the SQL/application preflights with deployment-equivalent keyrings, verify backup/restore evidence, and follow `.agents/docs/PHASE3_RELEASE.md`. Do not roll across V6, create a down migration, or reconstruct plaintext manually.

## R2 recovery expectations

R2 originals remain private and are the export source of truth until retention/deletion cleanup. Public variants can be regenerated from retained originals. Export archives are disposable and can be rebuilt while their source event is retained. Provider cleanup failures must leave database rows for retry. Retention purge aborts incomplete multipart uploads before deleting prefixes and domain rows. Media variants and exports use deterministic keys plus pessimistic handler locks; terminal and retention cleanup deletes deterministic prefixes so pre-commit storage writes cannot become unaddressable. A repeated R2 multipart completion accepts `NoSuchUpload` only when `HEAD` confirms the final object.

Export archives expire at the earlier of build completion plus 24 hours or event retention. Each R2 signed GET is shorter when configured presign TTL, remaining archive lifetime, or remaining retention lifetime requires it. Missing originals and expired retention are permanent export failures; storage/network/5xx failures retain the existing five-attempt backoff.

Expired archives and upload intents are processed one locked transaction at a time. If a provider call fails, restore provider access and allow the next scan to retry the same deterministic key; later due items continue independently. Use only identifier-safe logs and the cleanup-type metric. Do not remove the retained row manually. The full recovery checklist is in `.agents/docs/PHASE6_PRIVACY.md`.

Exercise throttling, denied credentials, missing objects, multipart abort idempotency, and the opt-in live-R2 workflow. Never enable a public base URL in production until an edge design preserves hide/delete/disable/expiry revocation.

## Auth and external providers

Production API nodes require explicit HTTPS base/frontend URLs, secure host and guest cookies, SMTP host/from/timeouts, Turnstile site/secret/hostname settings, trusted-proxy CIDRs, and a deployment-specific abuse HMAC secret. Google OAuth is optional, but its ID, secret, and explicit HTTPS callback URI are all-or-nothing. Provider credentials belong only on API nodes; do not pass them to workers.

Before release, render `backend/compose.prod.yml` with non-secret fixtures, then smoke the deployed API through its real TLS proxy. Verify the browser magic-link `303` success and fixed failure routes, token-free destinations, `no-store`/`no-referrer`, inclusive expiry, single-use replay rejection, pre-authentication session rotation, Redis rolling TTL, logout, CSRF, and `HttpOnly; Secure; SameSite=Lax; Path=/` host/guest cookies. Confirm the XSRF cookie is Secure and intentionally JavaScript-readable.

For Google, verify consent success and denial, callback failure, state rejection, first-login verified-email linking, subsequent `sub` login, and callback completion on a different API instance. Never expose provider error descriptions. For Turnstile, exercise an operation-specific challenged request, invalid token, hostname/action mismatch, provider outage, 15-minute shared clearance, and hard-cap precedence. Provider outage must return retryable `503`; hard denial must return `429` with a conservative `Retry-After`.

Validate the proxy trust boundary with a known client address: forwarded chains are honored only when the socket peer is in `APP_HTTP_TRUSTED_PROXY_CIDRS`, and canonical email/OAuth URLs always come from configured base/callback URLs. Inspect Redis keys only by prefix/count; identifiers are HMACed and raw IPs, emails, event IDs, guest IDs, session IDs, tokens, secrets, and provider responses must not be logged.

## Observability and privacy

Every HTTP response includes `X-Correlation-ID`; safe caller-provided IDs are preserved and unsafe values are replaced. Logs and metrics must never contain share tokens, magic-link tokens, encryption keys/ciphertext, presigned URLs, cookies, SMTP/OAuth secrets, filenames, or raw challenge tokens. Public assets use backend authorization with `no-store`, `no-cache`, zero-age, `Pragma`, `Expires`, and `nosniff` headers on GET/HEAD success and denial.
