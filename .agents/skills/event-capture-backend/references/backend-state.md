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
  - Selected explicitly with `APP_INFRASTRUCTURE_MODE=redis` for Spring Session, rate limiting, SSE fan-out, and worker jobs
  - Integration tests use a Redis Testcontainer
- Local storage root:
  - `${java.io.tmpdir}/event-capture-storage`
  - Controlled by `APP_STORAGE_LOCAL_ROOT`

## What Exists Today

- Host magic-link auth with HttpSession-backed `ROLE_HOST` access
- Conditional Google OAuth success flow
- Dual CSRF bootstrap routes at `/api/v1/csrf` and `/api/v1/auth/csrf`
- Deterministic `local` and `redis` infrastructure selection for sessions, rate limits, SSE, and jobs; production and worker-only local modes fail startup
- Credentialed CORS restricted to the configured frontend origin with `X-XSRF-TOKEN`
- Standardized ProblemDetail security/controller errors, safe magic-link delivery logs, safe ZIP entry names, and mode-aware readiness
- Host event CRUD
- Public event lookup by `{slug}/{shareToken}`
- Mandatory event close times, persisted lifecycle/retention snapshots, tri-state PATCH semantics, and compound opaque feed cursors
- Encrypted-only share-token persistence using a SHA-256 lookup hash plus AES-256-GCM ciphertext/key ID; Flyway V6 removes `share_token_value`
- Optional bounded Release B preflight, hash-verified backfill/rotation, and normal startup validation of every referenced database key ID
- Transactional job outbox publication plus Redis backlog and abandoned-pending-message recovery
- Guest session cookie flow
- Public gallery feed
- SSE broker with in-process delivery in explicit `local` mode and Redis pub/sub propagation in explicit `redis` mode
- Upload init, presigned single-part and multipart R2 preparation, local-storage binary upload fallback, multipart completion, and finalize
- Async worker-driven photo processing after finalize
- All `PROCESS_UPLOAD` failures are currently non-retryable and mark the photo `FAILED`; Phase 4 must selectively retry transient storage, command, and dependency failures while keeping invalid/corrupt media permanent
- Host moderation endpoints
- Async export job creation, status lookup, signed/local download URLs, and expired-download enforcement
- Flyway schema for all core domain tables
- Storage abstraction for local filesystem and Cloudflare R2
- Redis Streams worker jobs with delayed retries and a dead-letter stream
- Worker maintenance cleanup for deleted photos, retained events, expired exports, and expired upload intents
- MockMvc integration tests for host auth, event flows, guest uploads, gallery visibility, moderation, cleanup, Redis-backed sessions, and worker-driven processing
- Split-runtime integration tests for separate `api` and `worker` contexts on shared PostgreSQL and Redis
- Local-runtime integration tests for Redis-free auth/session/CSRF/logout, CORS, ProblemDetails, and health groups
- Startup tests for production/worker local-mode rejection, contradictory settings, and unavailable required Redis
- Unit tests proving magic-link logs omit tokens/URLs and export ZIP names are traversal-safe
- Broker unit tests for `photo_ready`, `photo_hidden`, `photo_unhidden`, and `photo_deleted` emitter delivery
- Opt-in live R2 smoke coverage gated by `EVENT_CAPTURE_LIVE_R2_SMOKE=true`; the 2026-07-17 workflow passes direct single-part and multipart upload, asynchronous processing, export, incomplete-upload cleanup, and retention cleanup
- Unit tests for:
  - event state rules and slug/share-path behavior
  - magic-link request and consume lifecycle
  - guest session create/resume/validation lifecycle
  - in-memory rate limiter windows
  - upload finalize and presign behavior
  - R2 presign and multipart completion behavior
  - native source decode fallback behavior for HEIC/HEIF and WEBP

## Temporary Substitutions vs Planned Architecture

- Local filesystem storage remains the default local/dev provider even though R2 support is implemented
- Backend-served upload binary endpoints still exist for `local` storage mode even though presigned direct upload is implemented for `r2`
- Production media processing uses libvips; Java/ImageIO remains the portable local/test fallback
- Production media reads use backend-authorized asset endpoints for strict revocation; a public base URL remains available only outside production
- Local mode uses an in-memory `MapSessionRepository` and process-local rate limits, SSE, and job dispatch; it is intentionally non-durable and single-process only
- Cleanup scheduling relies on periodic scans plus idempotent handlers rather than explicit deduplication state

## Active Completion Gaps

- Phase 3 Release B is implemented in source but remains operationally incomplete until the target zero-count preflight, backup/restore, non-rolling V6 cutover, and smoke-test evidence succeeds.
- Redis delayed-ZSET delivery is still non-atomic, and Phase 4 must finish crash/retry convergence plus bounded transient `PROCESS_UPLOAD` retries.
- Moderation transitions, strict asset cache headers, remaining-lifetime export presigns, and retention-purge multipart aborts remain Phase 6 work.

## Known Traps

- Treat provider multipart upload IDs and ETags as opaque values: IDs persist as text, and ETags must be JSON-encoded rather than interpolated into request bodies.
- `APP_INFRASTRUCTURE_MODE` is canonical. `APP_SESSION_STORE_TYPE` is only a legacy fallback, and conflicting values fail startup.
- Both CSRF bootstrap routes are valid today:
  - `AuthController` exposes `GET /api/v1/auth/csrf`
  - `CsrfController` exposes `GET /api/v1/csrf`
- OAuth is conditional:
  - `ApiSecurityConfig` only enables `oauth2Login` if a `ClientRegistrationRepository` bean exists
  - This avoids test boot failures when no OAuth client is configured
- `events` stores `share_token_hash`, `share_token_ciphertext`, and `share_token_key_id`; V6 removes recoverable plaintext.
- Host `sharePath` always decrypts ciphertext, public lookup remains hash-based, and startup rejects a keyring missing any referenced database key ID.
- Release A and Release B binaries are incompatible across V6; follow the coordinated cutover/restore runbook instead of rolling or down-migrating.
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
