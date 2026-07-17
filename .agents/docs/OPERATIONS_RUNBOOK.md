# Backend Operations and Recovery Runbook

## Release checks

From `backend/` run:

- `./gradlew spotlessCheck test`
- `./gradlew openApiCheck`
- build both production images and smoke API-only and worker-only roles against PostgreSQL, Redis, and private R2

From the repository root run `scripts/verify-guidance-mirrors.ps1` and `scripts/verify-secret-hygiene.ps1`. CI additionally runs Gitleaks, dependency reporting, the container build, and preserves the Bitbucket-to-GitHub mirror step.

## Outbox and worker recovery

Jobs and gallery notifications are committed to `outbox_messages` with domain state. Monitor:

- `eventcapture.outbox.age.seconds`
- `eventcapture.outbox.publish.failures`
- `eventcapture.jobs.stream.pending.count`
- `eventcapture.jobs.stream.claimed`
- `eventcapture.jobs.retries`
- `eventcapture.jobs.dead.letters`
- `eventcapture.jobs.handler.duration.millis`
- `eventcapture.jobs.terminal.failures`

A publish-success/mark-success crash may duplicate delivery; handlers are required to be idempotent. Consumer groups start at the beginning of the stream, and idle pending entries are claimed by a live worker. Do not acknowledge a record manually until its domain handler state has been verified. SSE is a state-change hint; clients resynchronize from the REST feed after reconnect.

For an incident, inspect unpublished outbox age/count, Redis group/pending state, the DLQ stream, and the target photo/export/purge state using correlation IDs. Restore Redis service and workers before replaying. Do not delete pending/outbox rows to make dashboards green.

## PostgreSQL backup and restore drill

Before schema enforcement releases, take a provider-native snapshot plus a logical backup. Quarterly, restore to an isolated database, run Flyway validation without applying unreviewed migrations, verify event/share-token counts and key IDs, boot an API/worker pair, and complete a create/join/upload/process/export journey. Record recovery time and data-loss window.

## R2 recovery expectations

R2 originals remain private and are the export source of truth until retention/deletion cleanup. Public variants can be regenerated from retained originals. Export archives are disposable and can be rebuilt while their source event is retained. Provider cleanup failures must leave database rows for retry. Retention purge aborts incomplete multipart uploads before deleting prefixes and domain rows.

Exercise throttling, denied credentials, missing objects, multipart abort idempotency, and the opt-in live-R2 workflow. Never enable a public base URL in production until an edge design preserves hide/delete/disable/expiry revocation.

## Auth and external providers

In staging, verify SMTP failure redaction, magic-link expiry/replay, Google consent denial/callback failure, the configured frontend success route, secure/SameSite cookies behind the production proxy/TLS topology, and session fixation/rolling TTL. Turnstile secrets are required only when `APP_CHALLENGE_MODE=turnstile`; normal traffic remains unchallenged and challenged traffic fails closed.

## Observability and privacy

Every HTTP response includes `X-Correlation-ID`; safe caller-provided IDs are preserved and unsafe values are replaced. Logs and metrics must never contain share tokens, magic-link tokens, encryption keys/ciphertext, presigned URLs, cookies, SMTP/OAuth secrets, or raw challenge tokens. Public assets use backend authorization with `no-store`, zero-cache, and `nosniff` headers.