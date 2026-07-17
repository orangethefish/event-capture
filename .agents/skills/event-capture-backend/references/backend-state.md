# Backend State

## Source of Truth

- Current code lives under `backend/`.
- `AGENTS.md` is the current-state status document for the backend.
- Target architecture and longer-horizon gaps are documented in:
  - `.codex/docs/BACKEND_IMPLEMENTATION_PLAN.md`
  - `.codex/docs/IMPLEMENTATION_PLAN.md`

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
  - Wired into Redis-backed Spring Session, rate limiting, SSE fan-out, and worker jobs when configured
  - Integration tests use a Redis Testcontainer
- Local storage root:
  - `${java.io.tmpdir}/event-capture-storage`
  - Controlled by `APP_STORAGE_LOCAL_ROOT`

## What Exists Today

- Host magic-link auth with HttpSession-backed `ROLE_HOST` access
- Conditional Google OAuth success flow
- Dual CSRF bootstrap routes at `/api/v1/csrf` and `/api/v1/auth/csrf`
- Host event CRUD
- Public event lookup by `{slug}/{shareToken}`
- Guest session cookie flow
- Public gallery feed
- SSE broker with local delivery plus Redis pub/sub propagation across API instances
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
- Broker unit tests for `photo_ready`, `photo_hidden`, `photo_unhidden`, and `photo_deleted` emitter delivery
- Opt-in live R2 smoke coverage gated by `EVENT_CAPTURE_LIVE_R2_SMOKE=true`
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
- Session store still defaults to servlet session unless `APP_SESSION_STORE_TYPE=redis`
- Cleanup scheduling relies on periodic scans plus idempotent handlers rather than explicit deduplication state

## Known Traps

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
