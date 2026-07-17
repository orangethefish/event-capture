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
- Guest session cookie flow
- Public gallery feed
- SSE broker with in-process delivery in explicit `local` mode and Redis pub/sub propagation in explicit `redis` mode
- Upload init, presigned single-part and multipart R2 preparation, local-storage binary upload fallback, multipart completion, and finalize
- Async worker-driven photo processing after finalize
- Upload-processing failures now mark corrupt/invalid media `FAILED` without waiting through delayed retry backoff loops
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
- Opt-in live R2 smoke coverage gated by `EVENT_CAPTURE_LIVE_R2_SMOKE=true`; the 2026-07-17 run with confirmed local configuration failed at the first presigned single-part `PUT` with HTTP `400`
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
- Media resizing still runs through Java/ImageIO after source decode, even when native helper tools are used to decode HEIC/HEIF or WEBP inputs
- Public media still falls back to backend asset endpoints unless `APP_STORAGE_PUBLIC_BASE_URL` is configured
- Local mode uses an in-memory `MapSessionRepository` and process-local rate limits, SSE, and job dispatch; it is intentionally non-durable and single-process only
- Cleanup scheduling relies on periodic scans plus idempotent handlers rather than explicit deduplication state

## Known Traps

- Direct-to-R2 upload is not production-verified: the live smoke test currently receives HTTP `400` on the first presigned single-part `PUT`. The configured endpoint shape and generated URL domain/signed-header metadata passed non-secret validation, but the provider error body is not retained by the test.
- `APP_INFRASTRUCTURE_MODE` is canonical. `APP_SESSION_STORE_TYPE` is only a legacy fallback, and conflicting values fail startup.
- Upload finalize currently verifies object presence and size, but not media signatures, declared MIME consistency, or an end-to-end checksum.
- Expired R2 multipart upload intents do not yet abort the underlying incomplete multipart upload.
- Both CSRF bootstrap routes are valid today:
  - `AuthController` exposes `GET /api/v1/auth/csrf`
  - `CsrfController` exposes `GET /api/v1/csrf`
- OAuth is conditional:
  - `ApiSecurityConfig` only enables `oauth2Login` if a `ClientRegistrationRepository` bean exists
  - This avoids test boot failures when no OAuth client is configured
- `events` stores both:
  - `share_token_hash`
  - `share_token_value`
  - The latter is returned in host-facing `sharePath`
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
