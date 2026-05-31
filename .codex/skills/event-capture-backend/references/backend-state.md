# Backend State

## Source of Truth

- Current code lives under `backend/`.
- Target architecture and missing pieces are documented in:
  - `/home/orange/Documents/event-capture/AGENTS.md`
  - `/home/orange/Documents/event-capture/.codex/docs/BACKEND_IMPLEMENTATION_PLAN.md`
  - `/home/orange/Documents/event-capture/.codex/docs/IMPLEMENTATION_PLAN.md`

## Build and Runtime

- Spring Boot: `3.5.14`
- Gradle wrapper: generated project under `backend/`
- Java build quirk:
  - `build.gradle` uses a Java `22` toolchain
  - `JavaCompile` uses `--release 21`
  - This exists because the local machine had a working `javac 22` but not a usable Java 21 compiler path
- Default local database:
  - H2 in PostgreSQL compatibility mode
  - Configured in `backend/src/main/resources/application.yml`
- Test database:
  - H2 in PostgreSQL compatibility mode
  - Configured in `backend/src/test/resources/application-test.yml`
- Redis:
  - Included as dependencies
  - Not wired into tests
  - Test profile excludes Redis auto-configuration
- Local storage root:
  - `${java.io.tmpdir}/event-capture-storage`
  - Controlled by `APP_STORAGE_LOCAL_ROOT`

## What Exists Today

- Host magic-link auth with HttpSession-backed `ROLE_HOST` access
- Conditional Google OAuth success flow
- Host event CRUD
- Public event lookup by `{slug}/{shareToken}`
- Guest session cookie flow
- Public gallery feed
- SSE broker in-process only
- Upload init, direct backend binary upload, multipart assembly, finalize
- Inline variant creation during finalize
- Host moderation endpoints
- Export job records and status lookup
- Flyway schema for all core domain tables
- MockMvc integration tests for:
  - host auth
  - event creation
  - guest upload
  - public gallery visibility
  - moderation
- Unit tests for:
  - event state rules and slug/share-path behavior
  - magic-link request and consume lifecycle
  - guest session create/resume/validation lifecycle
  - in-memory rate limiter windows

## Temporary Substitutions vs Planned Architecture

- Local filesystem storage instead of Cloudflare R2
- Backend-served upload binary endpoints instead of presigned browser upload URLs
- Inline media processing instead of worker jobs
- Variant files are copies of originals, not resized/stripped derivatives
- In-memory rate limiting instead of Redis-backed throttling
- In-process SSE fan-out instead of Redis pub/sub
- Export jobs are persisted but not asynchronously executed

## Known Traps

- CSRF route mismatch:
  - `AuthController` exposes `GET /api/v1/auth/csrf`
  - `SecurityConfig` currently permits `/api/v1/csrf`
  - If a task touches CSRF bootstrap behavior, reconcile that mismatch first
- OAuth is conditional:
  - `SecurityConfig` only enables `oauth2Login` if a `ClientRegistrationRepository` bean exists
  - This avoids test boot failures when no OAuth client is configured
- `events` stores both:
  - `share_token_hash`
  - `share_token_value`
  - The latter is returned in host-facing `sharePath`
- `upload_intents.upload_token_hash` exists but is not used to authorize the binary upload endpoints
- Public asset URLs are opaque tokens, but access is still checked against:
  - photo visibility
  - photo readiness
  - gallery enabled
  - retention expiry

## Commands

- Compile:
  - `cd /home/orange/Documents/event-capture/backend && ./gradlew compileJava`
- Test:
  - `cd /home/orange/Documents/event-capture/backend && ./gradlew test`
- Run app:
  - `cd /home/orange/Documents/event-capture/backend && ./gradlew bootRun`
