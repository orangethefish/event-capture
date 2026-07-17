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

## Audited Baseline

The backend already has the principal API surface, API/worker role gating, magic-link auth, conditional Google OAuth, guest sessions, event CRUD, R2 and local storage abstractions, direct single/multipart R2 uploads, async photo processing, live SSE events, moderation, async exports, cleanup jobs, and PostgreSQL/Redis Testcontainers coverage.

The forced backend test run passed 44 tests with no failures; the live R2 smoke test was initially the one skipped opt-in test. After the local `.env` configuration was confirmed for direct use, the targeted live test ran and failed at the first presigned single-part R2 `PUT` with HTTP `400`. Non-secret validation confirmed the endpoint/account/bucket shapes and the generated R2 API URL/signed-header metadata; the test currently discards the provider error body, so the exact presigner/request incompatibility remains undiagnosed. The baseline therefore includes these mismatches:

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
13. The live direct-to-R2 path is not production-verified because the provider rejects the first presigned single-part upload with HTTP `400`.

## Progress

- Phase 1 was completed on 2026-07-17 with tests written before runtime changes.
- Audit items 1, 2, 4, and 5 are resolved: Redis-free local auth is operational, runtime infrastructure selection is explicit, CORS accepts `X-XSRF-TOKEN` only for the configured origin, magic-link logs are token-safe, and ZIP entry names are traversal-safe.
- Production and worker-only local modes, unavailable required Redis, and conflicting canonical/legacy infrastructure settings now fail startup.
- Security and controller errors use standardized ProblemDetails; liveness is process-focused and readiness includes the database plus mode-aware Redis health.
- Phase 2 is the next backend phase. Phase 7 remains on hold.

## Approved Decisions and Active Hold

The product owner approved these decisions on 2026-07-17:

- Keep an explicit Redis-free local mode for a single API process, while requiring Redis for production and all split-role deployments.
- Replace raw share-token persistence with a hash for lookup plus an encrypted recoverable value for the host-facing share link. A one-way hash alone cannot redisplay the same link.
- Enforce strict revocation: a hidden, deleted, or expired asset must stop being retrievable even if its previous URL is known. Use backend-authorized delivery or short-lived signed CDN URLs plus cache controls.
- Evaluate libvips first for decoding, orientation normalization, resizing, and metadata removal. Keep the Java implementation behind the same interface until parity tests pass.
- Use npm with the Angular CLI when frontend work is eventually authorized.

Frontend implementation is explicitly paused. Do not scaffold Angular, generate a frontend client, or implement Phase 7 until the product owner finishes and explicitly approves the wireframe and design. Backend contract and OpenAPI stabilization may continue.

## Phase 0 — Repository and Secret Hygiene

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

## Phase 1 — Critical Security and Deterministic Runtime Selection

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

## Phase 2 — Upload, Storage, and Media Integrity

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

## Phase 3 — Event Lifecycle, Data Model, and Stable API Contracts

### Tests first

- Cover every event state boundary, including forced open after scheduled close, forced close, future open, exact close time, retention expiry, and timezone/UTC serialization.
- Add PATCH contract tests for omitted, explicit `null`, and replacement values for each nullable schedule field; validate open-before-close and retention constraints.
- Add cursor tests with identical timestamps, concurrent inserts, deletions/moderation between pages, and no duplicates or omissions.
- Add ownership and cross-event authorization tests for every host and guest resource identifier.
- Add migration tests for share-token storage changes, indexes, theme/cover fields, and existing-row backfill behavior.

### Implementation

- Define guest-session expiry independently from a past scheduled close when a valid manual override keeps uploads open. Never issue an already-expired session.
- Use tri-state PATCH inputs so omission means “leave unchanged” and explicit `null` means “clear.”
- Use a stable compound cursor such as `(createdAt, id)` and deterministic ordering for gallery and host feeds.
- Add new Flyway migrations for missing constraints and indexes discovered by query review.
- Implement the approved recoverable share-token design and a safe migration/rotation path.
- Add v1 event theme and cover-photo fields only to the extent needed by the specified guest page and host editor.
- Freeze and regenerate the OpenAPI contract after these changes.

### Exit criteria

- Lifecycle transitions are deterministic at boundary instants.
- PATCH and pagination contracts cannot lose user intent or records.
- Existing events migrate without silently breaking share links.

## Phase 4 — Durable Jobs and Realtime Convergence

### Tests first

- Enqueue work before a worker consumer group exists and prove it is processed after startup.
- Simulate a worker crash after message delivery and prove pending messages are reclaimed after an idle threshold.
- Test retry limits, exponential delay, poison-message dead-lettering, delayed-job atomicity, duplicate delivery, and handler idempotency.
- Simulate database commit success with publication failure and process restart; prove committed work is eventually published exactly enough for idempotent completion.
- Run multiple API instances and a separate worker against shared PostgreSQL/Redis; verify SSE state convergence and resync after disconnection.
- Assert metrics for queue age, pending count, retries, dead letters, handler duration, and terminal failures.

### Implementation

- Create consumer groups from the beginning of the stream or otherwise explicitly drain backlog.
- Reclaim abandoned pending messages with a supported Redis Streams pending/claim strategy.
- Make delayed-job promotion atomic, for example with a reviewed Lua operation.
- Use idempotency keys and persisted terminal state in every handler.
- Add a transactional outbox (recommended) between PostgreSQL state changes and Redis publication, with a relay and replay-safe consumers.
- Expose dead-letter and retry health through metrics and actionable alerts rather than logs alone.
- Keep the in-process dispatcher only for the explicit single-process local mode.

### Exit criteria

- Restart and crash tests demonstrate eventual completion without skipped committed work.
- Duplicate delivery is harmless.
- Operators can detect and diagnose stuck or dead-lettered jobs.

## Phase 5 — Authentication, OAuth, and Abuse Controls

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

## Phase 6 — Privacy, Moderation, Delivery, and Exports

### Tests first

- Test asset access before and after hide, unhide, delete, gallery disablement, retention expiry, and purge using both backend and selected CDN/signed delivery paths.
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

## Phase 7 — Angular Guest and Host Application

**Status: PAUSED by product-owner direction.**

This phase is retained as future scope only. Do not scaffold or implement it until the product owner explicitly approves the completed wireframe and design. After that approval, begin only when Phases 1–3 have frozen the consumed auth, event, upload, gallery, and pagination contracts.

### Tests first

- Establish Angular unit/component tests and Playwright end-to-end tests before feature implementation.
- Cover mobile viewport navigation, accessibility, keyboard use, camera/library selection, upload progress and retry, offline/interrupted requests, multipart uploads, SSE reconnect/resync, and gallery pagination.
- Cover host magic-link and Google login, event create/edit, schedule clearing, QR/share flow, moderation, export polling/download, cover/theme editing, expired sessions, and CSRF failures.
- Add generated-client or contract tests that fail when the backend OpenAPI schema changes incompatibly.

### Implementation

- Scaffold a mobile-first Angular application with feature boundaries for auth, host events, guest event entry, uploads, gallery, moderation, and exports.
- Guest surface: resolve share link, create/resume display-name session, upload from camera/library, use direct single/multipart storage requests, show progress/retry, reconnect SSE with feed resync, and display event closed/expired/disabled states.
- Host surface: request/consume magic links, Google login, list/create/edit events, configure upload windows and retention, show/download QR/share links, moderate the live feed, request/poll/download exports, and configure the approved cover/theme fields.
- Use credentialed API requests with the canonical CSRF bootstrap/header contract.
- Meet responsive layout, accessible labels/focus, reduced-motion, image loading, and gallery performance requirements.

### Exit criteria

- The complete guest and host v1 journeys pass on supported mobile and desktop browsers.
- No frontend flow depends on undocumented backend behavior.

## Phase 8 — Operations, Deployment, and Delivery Confidence

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

## Phase 9 — Release Validation

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
| Sessions, CSRF, CORS | Policy/config selectors | Required | Required for Redis mode | — | Required |
| Event lifecycle and PATCH | Required | Required | Required | — | Required |
| Upload validation/media | Required | Required | Required | Required | Required |
| Jobs/retries/outbox | Required | Focused API tests | Required, including crash/restart | Storage side effects | Indirect journey |
| Gallery/SSE/moderation | Broker and cursor logic | Required | Required, split runtime | Delivery policy | Required |
| Exports/retention | Naming and policy | Required | Required | Required | Required |
| OAuth/abuse | Risk and redirect policy | Required | Required where state persists | — | Required |

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

## First Implementation Batch After Decisions

1. Write the no-Redis and Redis-mode boot/auth tests.
2. Write failing CORS/CSRF, token-redaction, and ZIP traversal tests.
3. Implement deterministic runtime selection and the three critical security fixes.
4. Run focused suites, then `cd backend && ./gradlew test`.
5. Write failing event lifecycle, tri-state PATCH, and compound-cursor tests.
6. Implement those contract fixes and freeze the OpenAPI contract; do not generate a frontend client or scaffold Angular while the frontend hold is active.

This sequence establishes a secure, deterministic base before storage hardening, durable jobs, and frontend delivery.
