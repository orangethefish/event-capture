# Backend State

## Source of Truth

- Current code lives under `backend/`.
- `AGENTS.md` is the current-state status document for the backend.
- Target architecture and longer-horizon gaps are documented in:
  - `.agents/docs/BACKEND_IMPLEMENTATION_PLAN.md`
  - `.agents/docs/IMPLEMENTATION_PLAN.md`
  - `.agents/docs/APPLICATION_COMPLETION_PLAN.md`

## Build and Runtime

- Spring Boot: `3.5.14`
- Gradle wrapper: generated project under `backend/`
- Java:
  - `build.gradle` now targets a Java `21` toolchain
  - `JavaCompile` still uses `--release 21`
- Default local database:
  - H2 in PostgreSQL compatibility mode
  - Configured in `backend/src/main/resources/application.yml`
- Test database:
  - PostgreSQL Testcontainers for integration coverage
  - Configured via dynamic Spring properties in the integration suites
- Redis:
  - Selected explicitly with `APP_INFRASTRUCTURE_MODE=redis` for Spring Session, abuse counters/clearance, SSE fan-out, and worker jobs
  - Integration tests use a Redis Testcontainer
- Local storage root:
  - `${java.io.tmpdir}/event-capture-storage`
  - Controlled by `APP_STORAGE_LOCAL_ROOT`

## What Exists Today

- Host magic-link auth with compatible JSON consume, browser `303` completion, allowlisted persisted return paths, pessimistic single-use consume, normalized identity linking, and explicit Spring Session fixation rotation
- Conditional Google OAuth authorization-code/state flow with shared-session state-bound return paths, verified `sub`/email claims, safe terminal redirects, and cleanup
- Dual CSRF bootstrap routes at `/api/v1/csrf` and `/api/v1/auth/csrf`
- Deterministic `local` and `redis` infrastructure selection for sessions, abuse counters/clearance, SSE, and jobs; production and worker-only local modes fail startup
- Credentialed CORS restricted to the configured frontend origin with `X-XSRF-TOKEN`/`X-Challenge-Token`, plus exposed retry/correlation headers
- Standardized ProblemDetail security/controller errors, safe magic-link delivery logs, safe ZIP entry names, and mode-aware readiness
- Host event CRUD
- Public event lookup by `{slug}/{shareToken}`
- Mandatory event close times, persisted lifecycle/retention snapshots, tri-state PATCH semantics, and compound opaque feed cursors
- Encrypted-only share-token persistence using a SHA-256 lookup hash plus AES-256-GCM ciphertext/key ID; Flyway V6 removes `share_token_value`
- Optional bounded Release B preflight, hash-verified backfill/rotation, and normal startup validation of every referenced database key ID
- Transactional job outbox publication, database-backed delayed scheduling, Redis backlog recovery, and abandoned-pending-message reclaim that cannot be starved by steady new work
- Guest session cookie flow
- Public gallery feed
- SSE broker with in-process delivery in explicit `local` mode and Redis pub/sub propagation in explicit `redis` mode
- Upload init, presigned single-part and multipart R2 preparation, local-storage binary upload fallback, multipart completion, and finalize
- Async worker-driven photo processing after finalize
- `PROCESS_UPLOAD` retries transient storage, native-command, and dependency failures with bounded exponential backoff while invalid/corrupt media and invalid job targets remain permanent
- Host moderation endpoints
- Async export job creation, status lookup, signed/local download URLs, and expired-download enforcement
- Flyway schema for all core domain tables plus V7 magic-link return paths
- Operation-aware local/Redis rolling-window abuse enforcement with HMAC-only subjects, Turnstile clearance, trusted-proxy client IP resolution, safe `403`/`429`/`503` metadata, and fail-closed production behavior
- Storage abstraction for local filesystem and Cloudflare R2
- Redis Streams worker jobs with outbox-backed delayed retries and a dead-letter stream
- Current gauges for unpublished outbox count/age, pending stream entries, and DLQ depth, plus retry/failure/claim counters and tagged handler-duration histograms
- Worker maintenance cleanup for deleted photos, retained events, expired exports, and expired upload intents
- MockMvc integration tests for host auth, event flows, guest uploads, gallery visibility, moderation, cleanup, Redis-backed sessions, and worker-driven processing
- Split-runtime integration tests for separate `api` and `worker` contexts on genuinely shared PostgreSQL and Redis, including real cross-instance HTTP SSE disconnect/REST-resync/reconnect proof
- Local-runtime integration tests for Redis-free auth/session/CSRF/logout, CORS, ProblemDetails, and health groups
- OS-process Phase 4 tests for outbox publish-before-commit crash replay, handler-commit-before-ack reclaim, duplicate drain, and AOF-backed Redis stop/start while API and worker JVMs remain alive
- Deployable Prometheus alert rules and executable `promtool` tests for current queue and handler meters
- Startup tests for production/worker local-mode rejection, contradictory settings, and unavailable required Redis
- Unit tests proving magic-link logs omit tokens/URLs and export ZIP names are traversal-safe
- Broker unit tests for `photo_ready`, `photo_hidden`, `photo_unhidden`, and `photo_deleted` emitter delivery
- Opt-in live R2 smoke coverage gated by `EVENT_CAPTURE_LIVE_R2_SMOKE=true`; the 2026-07-17 workflow passes direct single-part and multipart upload, asynchronous processing, export, incomplete-upload cleanup, and retention cleanup
- Unit tests for:
  - event state rules and slug/share-path behavior
  - magic-link request and consume lifecycle
  - guest session create/resume/validation lifecycle
  - local and Redis abuse rolling-window behavior
  - upload finalize and presign behavior
  - R2 presign and multipart completion behavior
  - native source decode fallback behavior for HEIC/HEIF and WEBP

## Temporary Substitutions vs Planned Architecture

- Local filesystem storage remains the default local/dev provider even though R2 support is implemented
- Backend-served upload binary endpoints still exist for `local` storage mode even though presigned direct upload is implemented for `r2`
- Production media processing uses libvips; Java/ImageIO remains the portable local/test fallback
- Production media reads use backend-authorized asset endpoints for strict revocation; a public base URL remains available only outside production
- Local mode uses an in-memory `MapSessionRepository` and process-local abuse counters/clearance, SSE, and job dispatch; it is intentionally non-durable and single-process only
- Cleanup scheduling relies on periodic scans plus idempotent handlers rather than explicit deduplication state

## Active Completion Gaps

- Phase 3 is complete for the current undeployed greenfield target. The first deployment migrates a fresh database through V6; the Release A-to-B runbook applies only to a future upgrade from existing pre-V6 data.
- Phase 4 is complete for the approved backend scope. Crash/restart and Redis interruption proof, live SSE disconnect/resync, storage-side-effect idempotency auditing, and deployment-owned alert rules are implemented; broader dashboards remain a later observability phase.
- Phase 5 is complete. Browser magic links, verified Google OIDC, session fixation protection, distributed abuse policy, Turnstile, proxy trust, API-only provider configuration, and production validation are covered by unit, HTTP, PostgreSQL, Redis, and embedded-OIDC tests.
- Moderation transitions, strict asset cache headers, remaining-lifetime export presigns, and retention-purge multipart aborts remain Phase 6 work.

## Known Traps

- Treat provider multipart upload IDs and ETags as opaque values: IDs persist as text, and ETags must be JSON-encoded rather than interpolated into request bodies.
- `APP_INFRASTRUCTURE_MODE` is canonical. `APP_SESSION_STORE_TYPE` is only a legacy fallback, and conflicting values fail startup.
- Both CSRF bootstrap routes are valid today:
  - `AuthController` exposes `GET /api/v1/auth/csrf`
  - `CsrfController` exposes `GET /api/v1/csrf`
- OAuth is conditional: the Google client registration and `oauth2Login` wiring exist only for an all-or-nothing ID/secret/redirect-URI configuration. Production additionally requires an explicit HTTPS callback.
- `APP_AUTH_SUCCESS_PATH` is canonical; `APP_OAUTH_SUCCESS_PATH` is only a deprecated fallback. Both magic links and OAuth use the same allowlisted frontend return-path policy.
- Forwarded client IPs are trusted only from configured proxy CIDRs. Forwarded host/protocol values never generate email links or OAuth callbacks.
- `events` stores `share_token_hash`, `share_token_ciphertext`, and `share_token_key_id`; V6 removes recoverable plaintext.
- Host `sharePath` always decrypts ciphertext, public lookup remains hash-based, and startup rejects a keyring missing any referenced database key ID.
- A greenfield deployment runs directly through V7 with maintenance flags disabled. If an existing pre-V6 environment is ever upgraded, Release A and Release B binaries remain incompatible across V6 and require the coordinated cutover/restore runbook.
- `upload_intents.upload_token_hash` is still not used to authorize the local-storage binary upload endpoints
- Public asset URLs are opaque tokens, but access is still checked against:
  - photo visibility
  - photo readiness
  - gallery enabled
  - retention expiry

## Commands

- Compile:
  - `cd backend && ./gradlew compileJava`
- Test:
  - `cd backend && ./gradlew test`
- Run app:
  - `cd backend && ./gradlew bootRun`
