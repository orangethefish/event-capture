# Event Capture Application Completion Plan

## Purpose and Status

This is the active, dependency-ordered plan for closing the backend audit gaps and delivering the photo-only v1 application. It was written from the repository state audited on 2026-07-17.

- `backend/` and `AGENTS.md` describe what runs today.
- `BACKEND_IMPLEMENTATION_PLAN.md` describes the target backend architecture.
- `IMPLEMENTATION_PLAN.md` describes the product-level target.
- This document turns the verified mismatches and missing application work into executable phases.

A phase is not complete when code merely compiles. Its specified tests must be written first, the relevant focused tests must pass during development, and the full affected suite must pass before moving on.

## Fixed Scope and Engineering Rules

- v1 supports host accounts, events, share links and QR codes, account-free guest sessions, photo uploads, a live gallery, host moderation, and downloadable exports.
- Do not add video, guest accounts, collaborator hosts, comments, reactions, or a marketing site without a requirement change.
- Production remains PostgreSQL, Redis, Cloudflare R2, separate `api` and `worker` roles, and Angular under the same parent domain as the API.
- Local development may use H2 and local storage, but runtime modes must be explicit and deterministic.
- Write or update tests before changing backend runtime code. Prefer MockMvc or container-backed integration tests for behavior crossing security, controllers, persistence, Redis, or storage.
- Apply schema changes only through new Flyway migrations; never edit an applied migration for a deployed environment.
- Preserve originals privately. Only processed, re-encoded variants may be public.
- Keep secrets out of Git, logs, test reports, guidance, and generated artifacts. `.env` is machine-local and untracked; `env.example` documents variable names and safe examples.
- Keep `CLAUDE.md` and `.claude/` as physical, byte-identical mirrors of `AGENTS.md` and `.agents/` whenever canonical guidance changes.

## Historical Audited Baseline (before Phases 1 and 2)

The backend already has the principal API surface, API/worker role gating, magic-link auth, conditional Google OAuth, guest sessions, event CRUD, R2 and local storage abstractions, direct single/multipart R2 uploads, async photo processing, live SSE events, moderation, async exports, cleanup jobs, and PostgreSQL/Redis Testcontainers coverage.

Historical result: the forced backend test run passed 44 tests with no failures; the live R2 smoke test was initially the one skipped opt-in test. At the audited baseline, the targeted live test failed at the first presigned single-part R2 `PUT` with HTTP `400`, and the provider response body was discarded. Phase 2 subsequently added sanitized provider diagnostics; final verification with a replacement token exposed and resolved provider-sized multipart ID persistence and quoted ETag test-client handling. The baseline therefore included these mismatches:

1. Redis-free local host auth is not operational because Spring Session Redis auto-configuration activates even when `APP_SESSION_STORE_TYPE=none`.
2. Credentialed CORS allows `X-CSRF-TOKEN`, while the configured cookie CSRF repository expects `X-XSRF-TOKEN`.
3. Upload finalize validates object presence and size but not media signatures, declared MIME consistency, or an end-to-end checksum.
4. SMTP delivery failures can log the live magic-link URL/token.
5. Guest-controlled client filenames can become unsafe ZIP entry names.
6. Expired R2 multipart intents do not abort the underlying incomplete multipart upload.
7. A forced-open event after its scheduled close can create an already-expired guest session.
8. Event PATCH input cannot reliably distinguish an omitted schedule field from an explicit `null`.
9. Gallery pagination uses only `createdAt`, which is unstable for timestamp ties and concurrent inserts.
10. Redis job consumers can skip pre-existing backlog, do not reclaim abandoned pending messages, and move delayed jobs non-atomically. Database commits and job publication are not transactional together.
11. Google OAuth end-to-end behavior, suspicious-flow challenges, operational dead-letter visibility, production R2 configuration validation, and S3-compatible integration coverage are incomplete.
12. Theme/cover configuration and the complete Angular guest and host application are missing.
13. At the audited baseline, the live direct-to-R2 path failed at the first presigned single-part upload with HTTP `400`.

## Progress

- Phase 1 was completed on 2026-07-17 with tests written before runtime changes.
- Audit items 1, 2, 4, and 5 are resolved: Redis-free local auth is operational, runtime infrastructure selection is explicit, CORS accepts `X-XSRF-TOKEN` only for the configured origin, magic-link logs are token-safe, and ZIP entry names are traversal-safe.
- Production and worker-only local modes, unavailable required Redis, and conflicting canonical/legacy infrastructure settings now fail startup.
- Security and controller errors use standardized ProblemDetails; liveness is process-focused and readiness includes the database plus mode-aware Redis health.
- Phase 2 implementation was completed on 2026-07-17 with media-fixture, checksum, multipart, cleanup, presigner, production-validation, and S3-compatible storage tests written before runtime changes.
- The full backend suite passes 137 tests with 0 failures/errors and 1 skipped opt-in live R2 test; `spotlessCheck` and the canonical `openApiCheck` pass. The production image was built and the exact libvips command was validated as the non-root runtime user.
- Phase 3 Release A and both deployable Release B stages are implemented in source with tests written first. The target Release B maintenance-window cutover remains the Phase 3 completion gate.
- Phase 4 is the next code phase after that cutover; its transactional outbox and pending-message recovery foundation already exists.
- Phase 2's live-provider exit gate passed on 2026-07-17 using the replacement token loaded directly from the ignored `.env`. The live run exposed two covered regressions: provider multipart upload IDs now persist as opaque text through Flyway V3, and the smoke client JSON-encodes quoted provider ETags.
- Phase 7 remains on hold.

## Approved Decisions and Active Hold

The product owner approved these decisions on 2026-07-17:

- Keep an explicit Redis-free local mode for a single API process, while requiring Redis for production and all split-role deployments.
- Replace raw share-token persistence with a hash for lookup plus an encrypted recoverable value for the host-facing share link. A one-way hash alone cannot redisplay the same link.
- Enforce strict revocation: a hidden, deleted, disabled, or expired asset must stop being retrievable even if its previous URL is known. Production uses private R2 plus backend-authorized delivery; direct CDN/custom-domain delivery remains disabled until an equivalent revocation-safe edge strategy exists.
- Evaluate libvips first for decoding, orientation normalization, resizing, and metadata removal. Keep the Java implementation behind the same interface until parity tests pass.
- Use npm with the Angular CLI when frontend work is eventually authorized.

Frontend implementation is explicitly paused. Do not scaffold Angular, generate a frontend client, or implement Phase 7 until the product owner finishes and explicitly approves the wireframe and design. Backend contract and OpenAPI stabilization may continue.

## Phase 0 - Repository and Secret Hygiene

### Tests and checks first

- Add a repository check that fails when `.env` is tracked, when known secret-file patterns are staged, or when canonical guidance and its physical mirrors differ.
- Add a secret scanner to CI with a documented false-positive process.
- Add a deterministic mirror verification command that compares relative file sets and SHA-256 hashes.

### Implementation

- Confirm `.env` remains ignored and untracked; keep real values only on developer machines and in deployment secret stores.
- Correct stale current-state guidance and keep target-state documents clearly labeled.
- Create the physical `CLAUDE.md` and `.claude/` copies from the canonical guidance.
- Document Java 21, Docker/Testcontainers, native media tools, Redis, PostgreSQL, and R2 prerequisites without assuming every developer machine has identical global tooling.

### Exit criteria

- A clean checkout can run the repository checks without accessing secrets.
- Guidance mirror verification is byte-for-byte clean.
- No tracked file contains live credentials or tokens.

## Phase 1 - Critical Security and Deterministic Runtime Selection

**Status: completed 2026-07-17.** The focused local/Redis suites and the complete formatted backend suite pass.

### Tests first

- Boot the API with the explicit local session mode and no Redis; prove CSRF bootstrap, magic-link consume, authenticated `me`, and logout work without Redis connection attempts.
- Boot the API and worker in Redis mode; prove Spring Session, rate limiting, SSE fan-out, and job dispatch select Redis-backed implementations.
- Add credentialed CORS preflight and mutation tests using `X-XSRF-TOKEN`, allowed frontend origins, cookies, rejected origins, and rejected unlisted headers.
- Add mail-delivery failure tests proving logs and error responses contain neither the raw magic-link token nor URL.
- Add export tests using names such as `../outside.jpg`, absolute paths, separators, duplicate normalized names, control characters, and empty names.
- Add production-profile startup tests for invalid session/runtime combinations.

### Implementation

- Make session, rate-limit, job-dispatch, and gallery-broker modes explicit configuration choices. Disable Redis session repositories and Redis-dependent auto-configuration in the supported local mode.
- Fail startup for split roles or production profiles when Redis is required but unavailable or contradictory settings are supplied.
- Align CORS with `CookieCsrfTokenRepository` and the Angular credentialed request contract.
- Redact token-bearing magic-link data from all logs. Return a correlation-safe delivery failure without exposing the URL.
- Normalize export entry names to a safe basename, generate deterministic collision suffixes, and reject any entry that cannot be made safe.
- Standardize API error responses and ensure readiness reflects required dependency failures while liveness remains process-focused.

### Exit criteria

- Local standalone auth works without Redis.
- Production/split runtime cannot silently fall back to in-memory infrastructure.
- Cross-origin host mutations work only for configured origins with the correct CSRF header.
- Logs and ZIP archives pass the security tests.

## Phase 2 - Upload, Storage, and Media Integrity

Status: complete. Runtime behavior, local and S3-compatible contracts, production-image libvips execution, and the opt-in live Cloudflare R2 workflow all pass.

### Tests first

- Add a media-fixture matrix covering valid and spoofed JPEG, PNG, WEBP, HEIC, and HEIF files; extension/MIME disagreement; truncated and decompression-bomb candidates; orientation; dimensions; and metadata removal.
- First preserve and safely surface the R2 error code/message in live-test diagnostics, then add a failing presigned-PUT compatibility test that reproduces the current HTTP `400` without logging the bearer URL or credentials.
- Test exact size boundaries, declared-versus-stored size mismatches, checksum success/failure, invalid multipart part numbers, missing/duplicate parts, stale intents, repeated complete/finalize calls, and idempotency.
- Extend the storage contract tests with abort-multipart behavior and prove cleanup aborts before deleting intent state.
- Add an integration suite against an S3-compatible test service for presign, single-part upload, multipart completion, abort, object verification, variant writes, export reads, and cleanup.
- Keep the opt-in live R2 smoke path for final provider-specific verification.

### Implementation

- Resolve the live presigned `PUT` failure against the official Cloudflare R2 request contract and the pinned AWS SDK for Java version; keep any provider-specific signing behavior inside the storage adapter and cover it with tests.
- Introduce a media inspection boundary that verifies magic bytes and decoded format against the allowed declared type before a photo can become public.
- Add an optional client checksum to upload initialization and require a verified storage checksum or server-computed digest at finalize/processing according to provider capabilities.
- Validate decoded dimensions and resource limits before expensive transformations.
- Add `abortMultipartUpload` to the storage abstraction and persist enough upload metadata for reliable expiration cleanup.
- Replace ImageIO-only resizing with the selected native processing pipeline while preserving re-encoding, orientation normalization, bounded dimensions, and metadata stripping.
- Validate production R2 configuration at startup, including bucket, credentials, endpoint/account settings, presign TTL, and the selected public delivery strategy.
- Document or provision restrictive R2 CORS for only the required frontend origins, methods, and headers.

### Exit criteria

- Spoofed or corrupt content cannot reach `READY`.
- Expired or failed multipart uploads do not remain billable indefinitely.
- The same storage contract passes locally, against the S3-compatible integration service, and in the opt-in live R2 smoke test.

## Phase 3 - Lifecycle, Contracts, Pagination, and Encrypted Share Tokens

**Status: implemented in source; target Release B cutover pending.** Release A is additive and rolling-compatible. Release B is an intentionally coordinated, non-rolling schema/runtime cutover. Theme and cover-photo contracts remain excluded until design approval.

### Implemented Release A

- Effective-dated global retention settings with a Flyway-seeded 365-day default, closure snapshots, and persisted expiry.
- Mandatory close times for new events, centralized lifecycle state, tri-state PATCH semantics, and compound opaque feed cursors.
- AES-256-GCM share-token encryption with event UUID AAD, lookup hashes, rolling-compatible dual read/write, and bounded backfill/rotation.
- Canonical OpenAPI snapshot checking and ownership/cursor/lifecycle regression coverage.

### Implemented Release B readiness patch

- Backfill verifies the recovered token hash before encrypting or rotating and aborts the batch with token-safe errors on any mismatch or recovery failure.
- Optional bounded, read-only application preflight reports missing encryption fields, unknown key IDs, decryption failures, hash mismatches, null closes, and invalid windows without exposing token material.
- The SQL preflight lists safe operational close-time fields, encryption aggregates, invalid windows, referenced key IDs, and missing due-closure snapshots. It performs no updates.
- API and worker production configuration includes the secret-backed keyring plus mutually exclusive backfill and preflight flags.

### Implemented Release B enforcement

- Flyway V6 makes scheduled close, ciphertext, and key ID non-null; rejects blank encrypted fields and invalid upload windows; and physically drops `share_token_value`.
- `Event` is encrypted-only. Creation hashes and encrypts the transient raw token before persistence; host share paths always decrypt ciphertext; public lookup remains hash-based.
- Post-B backfill rotates only old-key ciphertext. Normal startup fails if any database key ID is absent from the configured keyring.
- PostgreSQL migration tests cover V3-to-V5 compatibility, real AES-GCM V5-to-V6 data, every invalid V5 gate condition in isolated schemas, and physical plaintext-column removal. H2 covers clean V1-to-V6.
- The canonical OpenAPI check reports no contract delta.

### Deployment gate and exit criteria

- Phase 3 is complete only after the target environment follows `.agents/docs/PHASE3_RELEASE.md`: zero-count SQL/application preflights, authoritative legacy close-time remediation, due-closure snapshots, verified backup/restore evidence, full Release A shutdown, single-worker V6 migration, smoke tests, and monitored traffic restoration.
- Rollback after V6 is snapshot restore plus the Release A binary and full old keyring; there is no down migration or manual plaintext reconstruction.

## Phase 4 - Durable Jobs and Realtime Convergence

**Status: partially implemented and next after the Release B target cutover.** Transactional outbox publication, beginning-of-stream consumer groups, abandoned pending-message reclaim, delayed retries, a DLQ, idempotent handlers, and queue/worker metrics exist. Remaining work is atomic delayed delivery plus exhaustive crash/restart, retry-classification, and convergence proof.

### Remaining tests first

- Prove Redis delayed delivery cannot lose a job between due selection and stream publication.
- Simulate publish-success/mark-success crashes, duplicate publication, worker termination after delivery, and repeated process restarts; prove eventual completion through idempotent handlers.
- Add bounded transient `PROCESS_UPLOAD` retry tests for storage, native command, and dependency failures while keeping invalid/corrupt media permanent.
- Run multiple API instances and separate workers against shared PostgreSQL/Redis; verify SSE state convergence and REST resync after disconnection.
- Assert actionable metrics/health for outbox age, pending count, retries, dead letters, handler duration, and terminal failures.

### Remaining implementation

- Replace the Redis delayed-ZSET due-read/remove sequence with an atomic move or an equivalent outbox-only scheduling path.
- Preserve at-least-once outbox/stream semantics and make every side-effecting handler safe under duplicate publication and delivery.
- Classify transient upload-processing failures for bounded exponential retry and DLQ/terminal visibility; keep media-validation failures non-retryable.
- Expose stuck outbox, pending, retry, and dead-letter conditions through deployable alerts rather than logs alone.
- Keep the in-process dispatcher only for explicit single-process local mode.

### Exit criteria

- Restart and crash tests demonstrate eventual completion without skipped committed work.
- Duplicate delivery is harmless, delayed delivery is atomic, and transient work has bounded retries.
- Operators can detect and diagnose stuck, retrying, terminal, or dead-lettered jobs.

## Phase 5 - Authentication, OAuth, and Abuse Controls

**Status: partially implemented.** Magic links, sessions, conditional Google OAuth, CSRF/CORS, and base rate limits exist; full integration coverage, safe frontend redirects, and risk-based challenge policy remain.

### Tests first

- Add magic-link request, expiry, one-time consume, replay, rolling-session, logout, CSRF, delivery-failure, and rate-limit integration coverage.
- Add Google OAuth end-to-end integration coverage with a mock authorization server, including existing/new host linking, denied consent, invalid state, callback failure, and safe frontend redirects.
- Test redirect allowlists so user-controlled input cannot produce an open redirect.
- Add risk-policy tests that distinguish normal guest join/upload traffic from suspicious bursts and prove challenge verification fails closed only when required.

### Implementation

- Redirect successful login to the configured Angular dashboard route, preserving only allowlisted relative destinations.
- Pass SMTP and OAuth configuration through local/deployment manifests without placing secrets in tracked files.
- Add Cloudflare Turnstile behind a provider interface and invoke it only for suspicious join/upload flows based on documented signals.
- Tune rate limits by event, guest session, host session, IP, and operation; provide safe retry metadata.
- Confirm secure cookie, SameSite, proxy-header, TLS, session fixation, and session TTL behavior in the deployed topology.

### Exit criteria

- Magic-link and Google login work end to end from Angular through the API.
- No auth error path leaks credentials or permits an untrusted redirect.
- Abuse controls do not challenge ordinary event traffic by default.

## Phase 6 - Privacy, Moderation, Delivery, and Exports

**Status: partially implemented.** Authorized asset reads, moderation endpoints, exports, and cleanup exist; state-machine, cache-header, lifetime-bound presign, multipart-purge, and partial-failure gaps remain.

### Tests first

- Test backend-authorized asset access before and after hide, unhide, delete, gallery disablement, retention expiry, and purge, including `no-store`, zero-cache, and `nosniff` headers.
- Test cache headers and URL expiry so previously known URLs follow the approved revocation policy.
- Test export authorization, state transitions, safe naming, originals-only contents, deleted/foreign photo exclusion, signed download expiry, `410 Gone`, archive cleanup, and repeated requests.
- Test retention cleanup idempotency and partial provider failures.

### Implementation

- Implement the approved strict-revocation delivery model and document its caching tradeoffs.
- Ensure moderation and retention state changes invalidate or rapidly expire public access.
- Complete export archive behavior, observability, retry handling, and cleanup through the storage abstraction.
- Make event retention and privacy behavior visible and understandable in host settings.

### Exit criteria

- A hidden, deleted, disabled, or expired asset follows the approved access policy even when its old URL is known.
- Exports are authorized, traversal-safe, time-limited, and cleaned up.

## Phase 7 - Angular Guest and Host Application

**Status: PAUSED by product-owner direction.**

This phase is retained as future scope only. Do not scaffold or implement it until the product owner explicitly approves the completed wireframe and design. After that approval, begin only when Phases 1-3 have frozen the consumed auth, event, upload, gallery, and pagination contracts.

### Tests first

- Establish Angular unit/component tests and Playwright end-to-end tests before feature implementation.
- Cover mobile viewport navigation, accessibility, keyboard use, camera/library selection, upload progress and retry, offline/interrupted requests, multipart uploads, SSE reconnect/resync, and gallery pagination.
- Cover host magic-link and Google login, event create/edit, schedule clearing, QR/share flow, moderation, export polling/download, cover/theme editing, expired sessions, and CSRF failures.
- Add generated-client or contract tests that fail when the backend OpenAPI schema changes incompatibly.

### Implementation

- Scaffold a mobile-first Angular application with feature boundaries for auth, host events, guest event entry, uploads, gallery, moderation, and exports.
- Guest surface: resolve share link, create/resume display-name session, upload from camera/library, use direct single/multipart storage requests, show progress/retry, reconnect SSE with feed resync, and display event closed/expired/disabled states.
- Host surface: request/consume magic links, Google login, list/create/edit events, configure upload windows, show/download QR/share links, moderate the live feed, request/poll/download exports, and configure design-approved cover/theme fields when those contracts exist.
- Use credentialed API requests with the canonical CSRF bootstrap/header contract.
- Meet responsive layout, accessible labels/focus, reduced-motion, image loading, and gallery performance requirements.

### Exit criteria

- The complete guest and host v1 journeys pass on supported mobile and desktop browsers.
- No frontend flow depends on undocumented backend behavior.

## Phase 8 - Operations, Deployment, and Delivery Confidence

### Tests and checks first

- Add CI jobs for backend unit/integration tests, frontend tests/lint/build, OpenAPI compatibility, migration validation, secret scanning, dependency vulnerability review, container builds, and guidance mirror verification.
- Add deployment smoke tests for API-only and worker-only roles, readiness/liveness, database migrations, Redis, SMTP, OAuth, storage, SSE, and a real image round trip.
- Add backup/restore drills for PostgreSQL and documented R2 lifecycle/recovery expectations.

### Implementation

- Update Compose and deployment manifests to pass all non-secret configuration and reference secret stores for SMTP, OAuth, Turnstile, database, Redis, and R2 credentials.
- Add structured redacted logs, trace/correlation IDs, metrics, dashboards, and alerts for auth delivery, uploads, media failures, queues, dead letters, SSE subscribers, exports, cleanup, dependency health, and storage latency.
- Define migration rollout and rollback procedures for separate API/worker deploys.
- Pin and document Java 21 and native media runtime dependencies in development and container environments.

### Exit criteria

- A fresh environment can be deployed from documentation without relying on a developer's global machine state.
- Alerts identify user-impacting dependency, queue, upload, and auth failures.
- Restore and rollback procedures have been exercised rather than only documented.

## Phase 9 - Release Validation

- Run the full backend suite with PostgreSQL and Redis Testcontainers.
- Run all Angular unit/component, lint, build, and Playwright suites.
- Run the S3-compatible storage integration suite and the opt-in live R2 smoke suite using deployment-equivalent configuration.
- Validate real SMTP and Google OAuth in staging with redacted logs.
- Validate Turnstile normal and challenged flows.
- Exercise event creation, QR join, guest resume, single/multipart upload, processing, SSE updates, moderation, export, expiry, and cleanup end to end.
- Test current supported iOS Safari, Android Chrome, and desktop Chrome/Firefox/Edge at narrow and wide viewports.
- Perform upload concurrency, SSE fan-out, worker restart, Redis interruption, and storage-throttling tests against explicit acceptance thresholds.
- Complete accessibility, privacy, dependency, secret, and threat-model reviews.

The release candidate is acceptable only when all required checks pass and remaining risks have an owner and an explicit product decision.

## Required Test Matrix

| Area | Unit | MockMvc/component | PostgreSQL/Redis containers | S3-compatible/live R2 | Browser E2E |
| --- | --- | --- | --- | --- | --- |
| Sessions, CSRF, CORS | Policy/config selectors | Required | Required for Redis mode | N/A | Required |
| Event lifecycle and PATCH | Required | Required | Required | N/A | Required |
| Upload validation/media | Required | Required | Required | Required | Required |
| Jobs/retries/outbox | Required | Focused API tests | Required, including crash/restart | Storage side effects | Indirect journey |
| Gallery/SSE/moderation | Broker and cursor logic | Required | Required, split runtime | Delivery policy | Required |
| Exports/retention | Naming and policy | Required | Required | Required | Required |
| OAuth/abuse | Risk and redirect policy | Required | Required where state persists | N/A | Required |

## Definition of Complete

The application is complete for v1 when:

- Every in-scope guest and host journey is usable from the Angular application and covered end to end.
- Security-critical audit findings are fixed and regression-tested.
- Production roles require and verify PostgreSQL, Redis, R2, SMTP/OAuth as configured, while the documented local mode behaves deterministically.
- Uploads are content-validated, processed asynchronously, privacy-safe, retryable, and cleaned up.
- Jobs survive publication failure, duplicate delivery, worker crashes, and restarts without silently losing committed work.
- Moderation, retention, public delivery, and exports enforce the approved privacy semantics.
- CI, deployment smoke tests, observability, alerts, backup/restore, and operational documentation are in place.
- `AGENTS.md`, `.agents/`, `CLAUDE.md`, and `.claude/` accurately and identically describe the delivered state.

## Resolved Decision Record

1. Local infrastructure: explicit Redis-free single-process mode; Redis required for production and split roles.
2. Share links: hash for lookup plus an encrypted recoverable token.
3. Public delivery: strict revocation of already-known asset URLs.
4. Media processor: evaluate libvips first.
5. Frontend tooling: npm and Angular CLI selected, with all frontend work paused pending explicit wireframe/design approval.

## Next Implementation Sequence

1. Complete the documentation-only synchronization and verify canonical/mirror hashes and `.env` hygiene.
2. Write the Phase 3 lifecycle, PATCH, cursor, ownership, migration, and encryption tests.
3. Deliver Release A additively, run focused suites, then `./gradlew spotlessCheck test` and the OpenAPI/repository checks.
4. Run the operational close-time and ciphertext backfills in the target environment.
5. Deliver Release B only after its data gates pass; do not collapse the two migrations into one rollout.
6. Continue with the remaining Phase 4-6 and backend-only Phase 0/8/9 deltas. Angular remains paused.
