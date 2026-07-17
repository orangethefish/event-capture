# Event Capture Repo Guide

## Product Direction

- Build a mobile-first wedding event capture app where hosts create events, share a QR code or link, guests join with a display name, upload photos, and watch a live gallery update during the event.
- Frontend target remains Angular. Backend target remains Spring Boot. The intended production storage path is Cloudflare R2, with PostgreSQL for app data and Redis for sessions, fan-out, and background jobs.
- v1 scope is still guest event pages plus a host dashboard. Do not expand into video, guest accounts, collaborator hosts, comments, reactions, or a marketing site unless requirements change.

## Current Repo State

- `backend` is now a working Spring Boot 3.5.x Gradle project.
- The frontend has not been scaffolded yet.
- Frontend implementation is explicitly paused until the product owner finishes and approves the wireframe and design. Backend work may continue without scaffolding or implementing Angular.
- Root planning docs are in `.agents/docs/IMPLEMENTATION_PLAN.md` and `.agents/docs/BACKEND_IMPLEMENTATION_PLAN.md`.
- The dependency-ordered work needed to close the audited gaps and complete the v1 application is in `.agents/docs/APPLICATION_COMPLETION_PLAN.md`.
- `backend/` plus this `AGENTS.md` are the source of truth for what runs today. The planning docs remain target-state references.
- Production-oriented environment variables are documented in `env.example`.

## Backend Status

### Implemented

- Package-by-feature Spring Boot backend under `backend/src/main/java/com/eventcapture/backend`.
- One deployable backend artifact with runtime-role gating:
  - `api` role exposes controllers, security, OpenAPI, SSE subscriptions, and auth/session flows
  - `worker` role runs background job consumers and keeps only actuator endpoints public
  - `all` role exists for integration tests and local combined boot paths
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
- CSRF cookie/header support for host endpoints, with both `GET /api/v1/auth/csrf` and canonical `GET /api/v1/csrf`.
- Credentialed CORS is restricted to `APP_FRONTEND_ORIGIN` and allows the canonical `X-XSRF-TOKEN` header required by `CookieCsrfTokenRepository`.
- Security-filter and controller-advice failures use standardized `application/problem+json` responses.
- Magic-link delivery logs never include the live URL or token; SMTP failures return a safe `502` error.
- Export archive entry names are normalized to traversal-safe basenames with deterministic duplicate suffixes.
- Actuator liveness remains process-focused, while readiness includes the database and the mode-aware Redis health contributor.
- Host APIs for event list/create/get/update, host photo feed, moderation, export-job creation/status, and export download with expiry enforcement.
- Public APIs for event lookup, guest session create/resume, gallery feed, SSE stream subscription, upload init, multipart part URL issuance, binary upload endpoints, multipart complete, finalize, and public asset fetch.
- OpenAPI is exposed through Springdoc on the API role.
- SSE fan-out uses local in-process delivery in explicit `local` infrastructure mode and Redis pub/sub propagation in explicit `redis` mode.
- Upload validation for allowed content types and size limits.
- Storage abstraction with:
  - local filesystem-backed storage for tests and lightweight local development
  - Cloudflare R2-backed storage using AWS SDK for Java v2
- UUID generation uses UUIDv7-style ordered IDs through `uuid-creator`.
- Host sessions use an in-memory `MapSessionRepository` in explicit `local` mode and `RedisSessionRepository` in explicit `redis` mode. Spring Session auto-configuration is disabled so selection is deterministic.
- Rate limiting selects the in-memory implementation in `local` mode and Redis-backed counters in `redis` mode.
- Upload init and multipart part responses now include `requiredHeaders` for direct-to-storage uploads.
- R2-backed single-part and multipart upload preparation is implemented:
  - single-part upload init returns a presigned upload URL
  - multipart upload init stores a real multipart upload ID
  - multipart complete calls storage-backed multipart completion
- Upload finalize now verifies the stored object, creates the `Photo` in `UPLOADED` state, returns `202 Accepted`, and enqueues background processing.
- Background job dispatch selects in-process scheduling in `local` mode and Redis Streams with delayed retry scheduling in `redis` mode. Backlog recovery, pending-message reclaim, and atomic delayed delivery remain completion work.
- Worker maintenance now scans for:
  - deleted-photo purge jobs after the 7-day retention window
  - retained-event purge jobs when `retentionExpiresAt` is due
  - expired export archive cleanup
  - expired upload-intent cleanup
- Upload worker processing now creates gallery and thumbnail variants asynchronously, marks photos `READY` or `FAILED`, and emits `photo_ready` only after processing.
- Upload-processing jobs now mark invalid/corrupt media `FAILED` without waiting through delayed retry backoff loops.
- Upload worker decoding now uses native helper tools for HEIC/HEIF and WEBP when Java cannot decode the source directly, and public variants are always re-encoded instead of copying original bytes through unchanged.
- Export jobs are now executed asynchronously and can return a signed or local download URL once `READY`.
- Public feeds now build asset URLs from `APP_STORAGE_PUBLIC_BASE_URL` when configured; local storage continues to use backend asset endpoints.
- Public asset reads and export reads stream through the storage abstraction instead of reading directly from the filesystem.
- Unit tests covering `EventService`, `AuthService`, `GuestSessionService`, `SimpleRateLimiter`, `UploadService`, and `R2ObjectStorageService`.
- Integration tests now run against PostgreSQL and Redis Testcontainers for the main backend behavior path, including Redis-backed host sessions, while keeping local storage for binary assets.
- Split-runtime integration coverage now exercises separate `api` and `worker` boot paths against shared PostgreSQL and Redis, including worker-only job consumption, moderation state convergence, and maintenance cleanup.
- `GalleryEventBrokerTest` now covers `photo_ready`, `photo_hidden`, `photo_unhidden`, and `photo_deleted` emitter payload delivery.
- An opt-in live R2 smoke test covers direct upload, multipart completion, async processing, export generation, and retention cleanup when `EVENT_CAPTURE_LIVE_R2_SMOKE=true`. With the confirmed local R2 configuration, the current test run fails at the first presigned single-part `PUT` with HTTP `400`, so direct-to-R2 upload is not yet production-verified.

### Intentionally Temporary

- Media processing still relies on Java/ImageIO resizing after source decode, even when native helper tools are used to decode HEIC/HEIF or WEBP inputs.
- EXIF stripping is still achieved through public-variant re-encoding rather than a dedicated metadata pipeline.
- Public media is still served through backend asset endpoints unless `APP_STORAGE_PUBLIC_BASE_URL` is configured.
- Cleanup scheduling is simple and currently relies on periodic scans plus idempotent job handlers rather than explicit deduplication state.
- Local infrastructure is intentionally process-local and non-durable: sessions, rate limits, gallery events, and background jobs are lost on restart and cannot coordinate multiple instances.
- Backend `PUT` upload binary endpoints still exist for `local` storage mode. The intended production path is presigned direct upload to R2.

- Upload finalize verifies object presence and size but does not yet validate media signatures, declared MIME consistency, or a client/server checksum.
- Expired R2 multipart upload intents delete stored object prefixes but do not abort incomplete multipart uploads.
- The live R2 smoke path currently receives HTTP `400` on its first presigned single-part `PUT`. Diagnose the provider response and presigner/request compatibility with a failing test before changing storage code.

## Approved Completion Decisions

- Support an explicit Redis-free single-process local mode. Require Redis for production and separate API/worker deployments.
- Persist share tokens as a lookup hash plus an encrypted recoverable value for the host-facing share link; do not store the recoverable token as plaintext.
- Enforce strict public-asset revocation: hidden, deleted, disabled, or expired media must stop being retrievable even through a previously known URL.
- Evaluate libvips first for the native media pipeline and require parity tests before replacing the current Java implementation.
- Use npm and Angular CLI when frontend work is authorized. Frontend work remains paused until the product owner explicitly approves the completed wireframe and design.

## Important Backend Files

- App entry/config:
  - `backend/src/main/java/com/eventcapture/backend/EventCaptureBackendApplication.java`
  - `backend/src/main/java/com/eventcapture/backend/infra/config/AppProperties.java`
  - `backend/src/main/java/com/eventcapture/backend/infra/config/ApiSecurityConfig.java`
  - `backend/src/main/java/com/eventcapture/backend/infra/config/WorkerSecurityConfig.java`
  - `backend/src/main/java/com/eventcapture/backend/infra/config/SessionConfig.java`
  - `backend/src/main/java/com/eventcapture/backend/infra/config/LocalSessionConfig.java`
  - `backend/src/main/java/com/eventcapture/backend/infra/config/RedisSessionConfig.java`
  - `backend/src/main/java/com/eventcapture/backend/infra/config/RuntimeInfrastructureValidator.java`
  - `backend/src/main/java/com/eventcapture/backend/infra/config/InfrastructureHealthConfig.java`
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
  - `backend/src/main/java/com/eventcapture/backend/gallery/PublicAssetUrlBuilder.java`
  - `backend/src/main/java/com/eventcapture/backend/infra/storage/LocalStorageService.java`
  - `backend/src/main/java/com/eventcapture/backend/infra/storage/ObjectStorageService.java`
  - `backend/src/main/java/com/eventcapture/backend/infra/storage/R2ObjectStorageService.java`
  - `backend/src/main/java/com/eventcapture/backend/infra/storage/StorageConfig.java`
- Jobs and async processing:
  - `backend/src/main/java/com/eventcapture/backend/jobs/`
  - `backend/src/main/java/com/eventcapture/backend/media/MediaProcessingService.java`
  - `backend/src/main/java/com/eventcapture/backend/export/ExportArchiveService.java`
- Persistence:
  - `backend/src/main/resources/db/migration/V1__initial_schema.sql`
- Tests:
  - `backend/src/test/java/com/eventcapture/backend/integration/BackendIntegrationTest.java`
  - `backend/src/test/java/com/eventcapture/backend/integration/DistributedRuntimeIntegrationTest.java`
  - `backend/src/test/java/com/eventcapture/backend/integration/WorkerRoleIntegrationTest.java`
  - `backend/src/test/java/com/eventcapture/backend/integration/LocalRuntimeIntegrationTest.java`
  - `backend/src/test/java/com/eventcapture/backend/integration/RuntimeConfigurationIntegrationTest.java`
  - `backend/src/test/java/com/eventcapture/backend/integration/LiveR2SmokeIntegrationTest.java`
  - `backend/src/test/java/com/eventcapture/backend/gallery/GalleryEventBrokerTest.java`
  - `backend/src/test/java/com/eventcapture/backend/media/UploadServiceTest.java`
  - `backend/src/test/java/com/eventcapture/backend/media/NativeSourceImageDecoderTest.java`
  - `backend/src/test/java/com/eventcapture/backend/gallery/PublicAssetUrlBuilderTest.java`
  - `backend/src/test/java/com/eventcapture/backend/infra/storage/R2ObjectStorageServiceTest.java`
  - `backend/src/test/resources/application-test.yml`

## Implemented API Surface

### Auth

- `POST /api/v1/auth/magic-link/request`
- `GET /api/v1/auth/magic-link/consume`
- `GET /api/v1/auth/me`
- `GET /api/v1/csrf`
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
- `GET /api/v1/host/events/{eventId}/exports/{exportId}/download`
- Current contract notes:
  - expired exports no longer expose `downloadUrl`
  - export download returns `410 Gone` after `archiveExpiresAt`

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
  - `uploads/{uploadId}/finalize` returns `202 Accepted` with `processingStatus=UPLOADED` before worker completion.
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

## Repository Guidance Mirroring

- Treat `AGENTS.md` and the complete `.agents/` tree as the canonical repository guidance.
- Keep `CLAUDE.md` as a byte-for-byte physical copy of `AGENTS.md`.
- Keep the complete `.claude/` tree as a byte-for-byte, file-for-file physical copy of `.agents/`, including docs, rules, skills, references, and skill agent metadata.
- Whenever `AGENTS.md` or any file under `.agents/` changes, update its physical mirror in the same change and verify that the canonical and mirrored files are identical.
- Do not place machine-local secrets in either guidance tree. Keep `.env` untracked and use `env.example` for documented configuration.

## Environment Notes

- Local and dev builds now target a Java 21 toolchain directly, and the runtime images also remain on Java 21.
- Default runtime DB is H2 for local startup unless `APP_DATASOURCE_*` overrides are set.
- Integration tests use PostgreSQL and Redis Testcontainers via dynamic Spring properties, with Redis-backed Spring Session enabled in the test profile.
- Storage provider defaults to `local`.
- Local storage defaults to `${java.io.tmpdir}/event-capture-storage` unless `APP_STORAGE_LOCAL_ROOT` is set.
- Session/worker/public-asset variables now include:
  - `APP_RUNTIME_ROLE=api|worker`
  - `APP_INFRASTRUCTURE_MODE=local|redis`
  - legacy `APP_SESSION_STORE_TYPE=none|redis` is accepted only when `APP_INFRASTRUCTURE_MODE` is unset
  - `APP_SESSION_COOKIE_NAME`
  - `APP_SESSION_NAMESPACE`
  - `APP_SESSION_TTL`
  - `APP_SESSION_SECURE_COOKIES`
  - optional `APP_STORAGE_PUBLIC_BASE_URL`
- R2 production variables are listed in `env.example`:
  - `APP_STORAGE_PROVIDER=r2`
  - `APP_STORAGE_PUBLIC_BASE_URL` should be treated as required for production R2/CDN deployments
  - `APP_STORAGE_R2_BUCKET`
  - `APP_STORAGE_R2_ACCOUNT_ID`
  - optional `APP_STORAGE_R2_ENDPOINT`
  - `APP_STORAGE_R2_ACCESS_KEY`
  - `APP_STORAGE_R2_SECRET_KEY`
  - optional `APP_STORAGE_R2_PRESIGN_TTL`
- The opt-in live R2 smoke test is enabled with `EVENT_CAPTURE_LIVE_R2_SMOKE=true` and reuses the existing `APP_STORAGE_*` R2 variables.

## Next Likely Work

- Proceed to Phase 2 of `.agents/docs/APPLICATION_COMPLETION_PLAN.md`: upload, storage, and media integrity, beginning with failing media-fixture and live-R2 diagnostic tests.
- Preserve the completed Phase 1 runtime/security contracts and keep the full backend suite passing after every backend phase.
- Do not scaffold or implement the Angular frontend until the product owner explicitly approves the completed wireframe and design; backend contract stabilization may continue meanwhile.
