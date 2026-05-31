# Event Capture Repo Guide

## Product Direction

- Build a mobile-first wedding event capture app where hosts create events, share a QR code or link, guests join with a display name, upload photos, and watch a live gallery update during the event.
- Frontend target remains Angular. Backend target remains Spring Boot. The intended production storage path is Cloudflare R2, with PostgreSQL for app data and Redis for sessions, fan-out, and background jobs.
- v1 scope is still guest event pages plus a host dashboard. Do not expand into video, guest accounts, collaborator hosts, comments, reactions, or a marketing site unless requirements change.

## Current Repo State

- `backend` is now a working Spring Boot 3.5.x Gradle project.
- The frontend has not been scaffolded yet.
- Root planning docs are in `.codex/docs/IMPLEMENTATION_PLAN.md` and `.codex/docs/BACKEND_IMPLEMENTATION_PLAN.md`.

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
- CSRF cookie/header support for host endpoints.
- Host APIs for event list/create/get/update, host photo feed, moderation, and export-job creation/status.
- Public APIs for event lookup, guest session create/resume, gallery feed, SSE stream subscription, upload init, multipart part URL issuance, binary upload endpoints, multipart complete, finalize, and public asset fetch.
- In-process SSE broker for `photo_ready`, `photo_hidden`, `photo_unhidden`, and `photo_deleted`.
- Upload validation for allowed content types and size limits.
- Local filesystem-backed storage adapter for uploads and variants.
- Integration tests covering host auth, event creation, guest upload, public gallery visibility, and moderation.

### Intentionally Temporary

- Storage is local filesystem, not Cloudflare R2.
- Public media variants are currently copies of originals, not resized derivatives.
- No worker runtime role yet. Processing happens inline during finalize.
- No EXIF stripping yet.
- Export jobs are stored and exposed, but not executed asynchronously.
- Rate limiting is an in-memory helper, not Redis-backed.
- SSE fan-out is in-process only, not Redis pub/sub backed.
- Session store is servlet session by default. Redis-backed Spring Session is not wired into tests.

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
- Persistence:
  - `backend/src/main/resources/db/migration/V1__initial_schema.sql`
- Tests:
  - `backend/src/test/java/com/eventcapture/backend/integration/BackendIntegrationTest.java`
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

## Local Commands

- Run tests:
  - `cd backend && ./gradlew test`
- Compile only:
  - `cd backend && ./gradlew compileJava`
- Start app locally:
  - `cd backend && ./gradlew bootRun`

## Environment Notes

- The generated Gradle project is configured to use a Java 22 toolchain while compiling with `--release 21`, because the local machine had a working `javac 22` but an unusable Java 21 compiler path.
- Default runtime DB is H2 for local startup unless `APP_DATASOURCE_*` overrides are set.
- Test profile uses H2 and disables Redis auto-configuration.
- Local storage defaults to `${java.io.tmpdir}/event-capture-storage` unless `APP_STORAGE_LOCAL_ROOT` is set.

## Next Likely Work

- Replace local upload/storage flow with real Cloudflare R2 presigned uploads.
- Add worker-role processing for thumbnails, gallery variants, and EXIF stripping.
- Replace in-memory rate limiting and SSE fan-out with Redis-backed implementations.
- Wire Redis-backed Spring Session and production cookie/session settings.
- Implement real asynchronous export building and signed archive download.
- Add PostgreSQL and Redis Testcontainers integration once the backend moves off the current lightweight local/test setup.
