# Event Capture Repo Guide

## Product Direction

- Build a mobile-first wedding event capture app where hosts create events, share a QR code or link, guests join with a display name, upload photos, and watch a live gallery update during the event.
- Frontend target remains Angular. Backend target remains Spring Boot. The intended production storage path is Cloudflare R2, with PostgreSQL for app data and Redis for sessions, fan-out, and background jobs.
- v1 scope is still guest event pages plus a host dashboard. Do not expand into video, guest accounts, collaborator hosts, comments, reactions, or a marketing site unless requirements change.

## Current Repo State

- `backend` is now a working Spring Boot 3.5.x Gradle project.
- The frontend has not been scaffolded yet.
- Root planning docs are in `.codex/docs/IMPLEMENTATION_PLAN.md` and `.codex/docs/BACKEND_IMPLEMENTATION_PLAN.md`.
- Production-oriented environment variables are documented in `env.example`.

## Backend Status

### Implemented

- Package-by-feature Spring Boot backend under `backend/src/main/java/com/eventcapture/backend`.
- Flyway baseline schema for:
  - `hosts`
  - `host_identities`
  - `magic_link_tokens`
  - `events`
  - `guest_sessions`
  - `upload_intents`
  - `photos`
  - `photo_variants`
  - `moderation_actions`
  - `export_jobs`
- Host magic-link auth with session-backed host access.
- Conditional Google OAuth success handling. OAuth login wiring only activates if a `ClientRegistrationRepository` exists.
- CSRF cookie/header support for host endpoints, with `GET /api/v1/auth/csrf` permitted in security config.
- Host APIs for event list/create/get/update, host photo feed, moderation, and export-job creation/status.
- Public APIs for event lookup, guest session create/resume, gallery feed, SSE stream subscription, upload init, multipart part URL issuance, binary upload endpoints, multipart complete, finalize, and public asset fetch.
- In-process SSE broker for `photo_ready`, `photo_hidden`, `photo_unhidden`, and `photo_deleted`.
- Upload validation for allowed content types and size limits.
- Storage abstraction with:
  - local filesystem-backed storage for tests and lightweight local development
  - Cloudflare R2-backed storage using AWS SDK for Java v2
- Upload init and multipart part responses now include `requiredHeaders` for direct-to-storage uploads.
- R2-backed single-part and multipart upload preparation is implemented:
  - single-part upload init returns a presigned upload URL
  - multipart upload init stores a real multipart upload ID
  - multipart complete calls storage-backed multipart completion
- Upload finalize now verifies the stored object through the active storage provider before creating photo records and inline variants.
- Public asset reads now stream through the storage abstraction instead of reading directly from the filesystem.
- Unit tests covering `EventService`, `AuthService`, `GuestSessionService`, `SimpleRateLimiter`, `UploadService`, and `R2ObjectStorageService`.
- Integration tests covering host auth/profile/logout, event create/get/update, export jobs, public event lookup, guest session resume, single-part uploads, multipart uploads, public gallery visibility, public asset fetch, moderation, and the new upload response contract.

### Intentionally Temporary

- Public media variants are currently copies of originals, not resized derivatives.
- Public media is still served through backend asset endpoints, not a CDN/custom domain.
- No worker runtime role yet. Processing happens inline during finalize.
- No EXIF stripping yet.
- Export jobs are stored and exposed, but not executed asynchronously.
- Rate limiting is an in-memory helper, not Redis-backed.
- SSE fan-out is in-process only, not Redis pub/sub backed.
- Session store is servlet session by default. Redis-backed Spring Session is not wired into tests.
- Backend `PUT` upload binary endpoints still exist for `local` storage mode. The intended production path is presigned direct upload to R2.

## Important Backend Files

- App entry/config:
  - `backend/src/main/java/com/eventcapture/backend/EventCaptureBackendApplication.java`
  - `backend/src/main/java/com/eventcapture/backend/infra/config/AppProperties.java`
  - `backend/src/main/java/com/eventcapture/backend/infra/config/SecurityConfig.java`
  - `backend/src/main/resources/application.yml`
- Auth:
  - `backend/src/main/java/com/eventcapture/backend/auth/AuthController.java`
  - `backend/src/main/java/com/eventcapture/backend/auth/AuthService.java`
- Events:
  - `backend/src/main/java/com/eventcapture/backend/event/EventService.java`
  - `backend/src/main/java/com/eventcapture/backend/host/HostController.java`
- Public guest flow:
  - `backend/src/main/java/com/eventcapture/backend/guest/PublicEventController.java`
  - `backend/src/main/java/com/eventcapture/backend/guest/GuestSessionService.java`
- Uploads and gallery:
  - `backend/src/main/java/com/eventcapture/backend/media/UploadService.java`
  - `backend/src/main/java/com/eventcapture/backend/gallery/GalleryService.java`
  - `backend/src/main/java/com/eventcapture/backend/gallery/GalleryEventBroker.java`
  - `backend/src/main/java/com/eventcapture/backend/infra/storage/LocalStorageService.java`
  - `backend/src/main/java/com/eventcapture/backend/infra/storage/ObjectStorageService.java`
  - `backend/src/main/java/com/eventcapture/backend/infra/storage/R2ObjectStorageService.java`
  - `backend/src/main/java/com/eventcapture/backend/infra/storage/StorageConfig.java`
- Persistence:
  - `backend/src/main/resources/db/migration/V1__initial_schema.sql`
- Tests:
  - `backend/src/test/java/com/eventcapture/backend/integration/BackendIntegrationTest.java`
  - `backend/src/test/java/com/eventcapture/backend/media/UploadServiceTest.java`
  - `backend/src/test/java/com/eventcapture/backend/infra/storage/R2ObjectStorageServiceTest.java`
  - `backend/src/test/resources/application-test.yml`

## Implemented API Surface

### Auth

- `POST /api/v1/auth/magic-link/request`
- `GET /api/v1/auth/magic-link/consume`
- `GET /api/v1/auth/me`
- `GET /api/v1/auth/csrf`
- `POST /api/v1/auth/logout`
- `GET /api/v1/auth/oauth2/authorization/google`
- `GET /login/oauth2/code/google`

### Host

- `GET /api/v1/host/events`
- `POST /api/v1/host/events`
- `GET /api/v1/host/events/{eventId}`
- `PATCH /api/v1/host/events/{eventId}`
- `GET /api/v1/host/events/{eventId}/photos`
- `POST /api/v1/host/events/{eventId}/photos/{photoId}/hide`
- `POST /api/v1/host/events/{eventId}/photos/{photoId}/unhide`
- `POST /api/v1/host/events/{eventId}/photos/{photoId}/delete`
- `POST /api/v1/host/events/{eventId}/exports`
- `GET /api/v1/host/events/{eventId}/exports/{exportId}`

### Public

- `GET /api/v1/public/events/{slug}/{shareToken}`
- `POST /api/v1/public/events/{slug}/{shareToken}/guest-session`
- `GET /api/v1/public/events/{slug}/{shareToken}/photos`
- `GET /api/v1/public/events/{slug}/{shareToken}/stream`
- `POST /api/v1/public/events/{slug}/{shareToken}/uploads/init`
- `POST /api/v1/public/events/{slug}/{shareToken}/uploads/{uploadId}/parts`
- `PUT /api/v1/public/events/{slug}/{shareToken}/uploads/{uploadId}/binary`
- `PUT /api/v1/public/events/{slug}/{shareToken}/uploads/{uploadId}/parts/{partNumber}/binary`
- `POST /api/v1/public/events/{slug}/{shareToken}/uploads/{uploadId}/complete`
- `POST /api/v1/public/events/{slug}/{shareToken}/uploads/{uploadId}/finalize`
- `GET /api/v1/public/assets/{publicToken}`
- Current contract notes:
  - `uploads/init` returns `requiredHeaders` for single-part direct upload flows.
  - `uploads/{uploadId}/parts` returns `requiredHeaders` for multipart part uploads.
  - backend `PUT` binary routes are used only when `APP_STORAGE_PROVIDER=local`.

## Local Commands

- Run tests:
  - `cd backend && ./gradlew test`
- Compile only:
  - `cd backend && ./gradlew compileJava`
- Start app locally:
  - `cd backend && ./gradlew bootRun`

## Backend Workflow Rules

- Update `AGENTS.md` whenever repo changes alter the implemented backend status, temporary substitutions, environment/config surface, important files, API behavior/contracts, or next likely work.
- Treat `AGENTS.md` maintenance as part of the definition of done for meaningful backend changes, not as optional follow-up cleanup.
- Write or update backend tests before changing runtime code.
- Prefer MockMvc integration tests for behavior that crosses controller, security, persistence, or local storage boundaries. Use narrower unit tests only when the behavior is isolated enough that an integration test would add little value.
- Treat a backend change as incomplete until the relevant tests exist and `cd backend && ./gradlew test` passes.

## Environment Notes

- The generated Gradle project is configured to use a Java 22 toolchain while compiling with `--release 21`, because the local machine had a working `javac 22` but an unusable Java 21 compiler path.
- Default runtime DB is H2 for local startup unless `APP_DATASOURCE_*` overrides are set.
- Test profile uses H2 and disables Redis auto-configuration.
- Storage provider defaults to `local`.
- Local storage defaults to `${java.io.tmpdir}/event-capture-storage` unless `APP_STORAGE_LOCAL_ROOT` is set.
- R2 production variables are listed in `env.example`:
  - `APP_STORAGE_PROVIDER=r2`
  - `APP_STORAGE_R2_BUCKET`
  - `APP_STORAGE_R2_ACCOUNT_ID`
  - optional `APP_STORAGE_R2_ENDPOINT`
  - `APP_STORAGE_R2_ACCESS_KEY`
  - `APP_STORAGE_R2_SECRET_KEY`
  - optional `APP_STORAGE_R2_PRESIGN_TTL`

## Next Likely Work

- Add worker-role processing for thumbnails, gallery variants, and EXIF stripping.
- Move public variant delivery from backend streaming to a CDN/custom-domain strategy once worker-generated variants exist.
- Replace in-memory rate limiting and SSE fan-out with Redis-backed implementations.
- Wire Redis-backed Spring Session and production cookie/session settings.
- Implement real asynchronous export building and signed archive download.
- Add an opt-in live R2 smoke/integration test path once shared non-dev R2 credentials and a test bucket strategy exist.
- Add PostgreSQL and Redis Testcontainers integration once the backend moves off the current lightweight local/test setup.
