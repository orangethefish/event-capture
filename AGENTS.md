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
- Phase 3 lifecycle behavior is implemented: mandatory close times for new events, closure-time retention snapshots, tri-state PATCH semantics, and compound opaque feed cursors.
- Share tokens are persisted only as a SHA-256 lookup hash plus AES-256-GCM ciphertext and key ID. Host share paths decrypt the original token; public lookup remains hash-based and existing API paths/shapes are unchanged.
- The optional Release B preflight scans events in bounded UUID-keyset batches and safely reports missing encryption data, unknown keys, decryption/hash failures, missing closes, and invalid windows. Backfill and preflight cannot run together.
- Post-B backfill performs ciphertext-only key rotation, and normal startup rejects any database key ID absent from the configured API/worker keyring.
- Flyway V6 enforces non-null close/ciphertext/key ID fields, nonblank encrypted fields, ordered upload windows, and physical removal of `share_token_value`. No release or application data has been deployed, so Phase 3 is complete for the greenfield first deployment: Flyway can migrate a fresh database directly through V6. The coordinated cutover applies only to a future upgrade from a pre-V6 environment.
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
- Upload initialization accepts an optional client SHA-256 checksum; finalize always computes the stored object's SHA-256, persists it on the upload intent and photo, rejects mismatches, and removes mismatched objects.
- Multipart upload part numbers and local part sizes must match the advertised plan, completion requires every contiguous part exactly once, and repeated complete/finalize calls are idempotent. R2 `NoSuchUpload`/404 completion is accepted as prior success only when `HEAD` confirms the final object.
- Completed multipart state is persisted. Expired incomplete multipart uploads are aborted before object prefixes and intent state are deleted; R2 `NoSuchUpload` is treated as an idempotent abort success.
- Upload finalize verifies stored size and digest, creates the `Photo` in `UPLOADED` state, returns `202 Accepted`, and enqueues background processing.
- AWS SDK upload checksum calculation is set to `WHEN_REQUIRED` for R2 compatibility; generated presigned PUTs are tested to exclude unsupported automatic full-object CRC32 headers.
- Background job dispatch selects direct in-process execution in `local` mode and Redis Streams in `redis` mode. Initial and delayed work is persisted in the PostgreSQL transactional outbox, removing the lossy Redis delayed-ZSET move; backlog recovery and abandoned pending-message reclaim are implemented. Existing-group startup always deletes its bootstrap record, including the `BUSYGROUP` path.
- Worker maintenance now scans for:
  - deleted-photo purge jobs after the 7-day retention window
  - retained-event purge jobs when `retentionExpiresAt` is due
  - expired export archive cleanup
  - expired upload-intent cleanup
- Upload worker processing now creates gallery and thumbnail variants asynchronously, marks photos `READY` or `FAILED`, and emits `photo_ready` only after processing. Duplicate handlers take a pessimistic photo lock, overwrite deterministic per-photo variant keys, and remove the full variant prefix on terminal failure.
- `PROCESS_UPLOAD` distinguishes permanent invalid/corrupt media from transient storage, native-command, and dependency failures. Transient failures use bounded exponential retries and become terminal/DLQ-visible only after exhaustion.
- Upload worker media inspection verifies JPEG, PNG, WEBP, HEIC, and HEIF signatures against the declared MIME type, rejects truncated/spoofed content, validates encoded/decoded dimensions and pixel limits, and normalizes JPEG EXIF orientation before publishing.
- Native media commands have a 60-second timeout and bounded diagnostic output.
- The media variant pipeline is selected through `APP_MEDIA_PROCESSOR=java|libvips`: Java remains the portable local/test fallback, while production Compose selects libvips for bounded auto-rotating, metadata-stripping re-encoding. Production images include `libvips-tools`, HEIF, and WEBP helpers.
- Export jobs are now executed asynchronously and can return a signed or local download URL once `READY`. Duplicate builds take a pessimistic export-job lock, use a deterministic archive key, and remove that key on terminal failure even if its database path did not commit.
- Public feeds can build asset URLs from `APP_STORAGE_PUBLIC_BASE_URL` outside production. Production rejects a non-empty public base URL and uses backend-authorized asset reads so strict hide/delete/disable/expiry revocation cannot be bypassed by an old CDN object URL.
- Public asset reads and export reads stream through the storage abstraction instead of reading directly from the filesystem.
- Unit tests covering `EventService`, `AuthService`, `GuestSessionService`, `SimpleRateLimiter`, `UploadService`, and `R2ObjectStorageService`.
- Integration tests now run against PostgreSQL and Redis Testcontainers for the main backend behavior path, including Redis-backed host sessions, while keeping local storage for binary assets.
- Split-runtime integration coverage now uses command-line overrides to guarantee separate `api` and `worker` boot paths share PostgreSQL and Redis. A real HTTP SSE client on API A observes API B changes, disconnects across a state transition, resynchronizes from REST, reconnects, and observes the next live event.
- `GalleryEventBrokerTest` covers `photo_ready`, `photo_hidden`, `photo_unhidden`, and `photo_deleted` emitter payload delivery.
- `phase4ProcessTest` launches child API/worker JVMs against PostgreSQL and AOF-backed Redis, proving outbox replay after publish-before-commit termination, pending reclaim after handler-commit-before-ack termination, and recovery of readiness/publication/consumption across Redis stop/start.
- The storage-side-effect audit covers deterministic media/export keys, pessimistic handler locks, orphan-prefix cleanup, and uncertain multipart-completion recovery.
- Deployment-owned Prometheus rules and executable `promtool` tests cover outbox stall/backlog, pending work, retries, DLQ depth, terminal/publish failures, p95 handler latency, and missing queue metrics. Bitbucket and Jenkins validate them with pinned Prometheus `v3.5.0`.
- A MinIO Testcontainers suite exercises the R2 adapter contract through real S3-compatible HTTP for presigned single-part upload, multipart completion, abort, head/read/write, export reads, and prefix cleanup.
- The complete backend verification passes 154 standard tests with 0 failures/errors and 1 skipped opt-in live R2 test, plus the child-process Phase 4 recovery test and the OpenAPI contract test; `spotlessCheck` passes, and the separately enabled live R2 smoke test passes against Cloudflare.
- The live R2 test verifies direct single-part and multipart upload, asynchronous processing, export generation/read, incomplete-upload cleanup, and retention cleanup without exposing signed URLs or credentials. Provider-issued multipart upload IDs are stored as opaque text, and quoted provider ETags are JSON-encoded as opaque values.

### Intentionally Temporary

- The Java media variant processor remains available for portable local/test use; production selects the libvips processor. Both paths re-encode public variants, and libvips is validated in the production image rather than required on the host machine.
- Metadata stripping is achieved through public-variant re-encoding (`strip` in libvips) rather than a separate metadata service.
- Production deliberately serves media through authorized backend asset endpoints for strict revocation. Direct CDN/custom-domain delivery remains disabled until a revocation-safe edge strategy is implemented.
- Cleanup scheduling is simple and currently relies on periodic scans plus idempotent job handlers rather than explicit deduplication state.
- Local infrastructure is intentionally process-local and non-durable: sessions, rate limits, gallery events, and background jobs are lost on restart and cannot coordinate multiple instances.
- Backend `PUT` upload binary endpoints still exist for `local` storage mode. The intended production path is presigned direct upload to R2.
- Phase 4 is complete for the approved backend scope: transactional outbox/delays, reclaim/retries/DLQ, child-process crash/restart and Redis-interruption proof, live multi-API SSE disconnect/resync proof, storage-side-effect idempotency auditing, and deployment-owned alerts are implemented. Broader dashboards remain later observability work.


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
  - `backend/src/main/java/com/eventcapture/backend/infra/storage/StorageConfigurationValidator.java`
  - `backend/src/main/resources/application.yml`
- Auth:
  - `backend/src/main/java/com/eventcapture/backend/auth/AuthController.java`
  - `backend/src/main/java/com/eventcapture/backend/auth/AuthService.java`
- Events:
  - `backend/src/main/java/com/eventcapture/backend/event/Event.java`
  - `backend/src/main/java/com/eventcapture/backend/event/EventService.java`
  - `backend/src/main/java/com/eventcapture/backend/event/ShareTokenCipher.java`
  - `backend/src/main/java/com/eventcapture/backend/event/ShareTokenReleaseBPreflightService.java`
  - `backend/src/main/java/com/eventcapture/backend/event/ShareTokenDatabaseKeyringValidator.java`
  - `backend/src/main/java/com/eventcapture/backend/host/HostController.java`
- Public guest flow:
  - `backend/src/main/java/com/eventcapture/backend/guest/PublicEventController.java`
  - `backend/src/main/java/com/eventcapture/backend/guest/GuestSessionService.java`
- Uploads and gallery:
  - `backend/src/main/java/com/eventcapture/backend/media/UploadService.java`
  - `backend/src/main/java/com/eventcapture/backend/media/MediaInspectionService.java`
  - `backend/src/main/java/com/eventcapture/backend/media/MediaVariantProcessor.java`
  - `backend/src/main/java/com/eventcapture/backend/media/JavaMediaVariantProcessor.java`
  - `backend/src/main/java/com/eventcapture/backend/media/LibvipsMediaVariantProcessor.java`
  - `backend/src/main/java/com/eventcapture/backend/gallery/GalleryService.java`
  - `backend/src/main/java/com/eventcapture/backend/gallery/GalleryEventBroker.java`
  - `backend/src/main/java/com/eventcapture/backend/gallery/PublicAssetUrlBuilder.java`
  - `backend/src/main/java/com/eventcapture/backend/infra/storage/LocalStorageService.java`
  - `backend/src/main/java/com/eventcapture/backend/infra/storage/ObjectStorageService.java`
  - `backend/src/main/java/com/eventcapture/backend/infra/storage/R2ObjectStorageService.java`
  - `backend/src/main/java/com/eventcapture/backend/infra/storage/StorageConfig.java`
- Jobs and async processing:
  - `backend/src/main/java/com/eventcapture/backend/jobs/`
  - `backend/src/main/java/com/eventcapture/backend/jobs/JobQueueMonitor.java`
  - `backend/src/main/java/com/eventcapture/backend/jobs/JobCrashCheckpoint.java`
  - `backend/deploy/prometheus/event-capture-alerts.yml`
  - `backend/src/main/java/com/eventcapture/backend/media/MediaProcessingService.java`
  - `backend/src/main/java/com/eventcapture/backend/media/NativeMediaCommandException.java`
  - `backend/src/main/java/com/eventcapture/backend/media/TransientMediaProcessingException.java`
  - `backend/src/main/java/com/eventcapture/backend/export/ExportArchiveService.java`
- Persistence:
  - `backend/src/main/resources/db/migration/V1__initial_schema.sql`
  - `backend/src/main/resources/db/migration/V2__upload_media_integrity.sql`
  - `backend/src/main/resources/db/migration/V3__widen_multipart_upload_id.sql`
  - `backend/src/main/resources/db/migration/V4__phase3_release_a.sql`
  - `backend/src/main/resources/db/migration/V5__transactional_outbox.sql`
  - `backend/src/main/resources/db/migration/V6__phase3_release_b.sql`
- Tests:
  - `backend/src/test/java/com/eventcapture/backend/integration/BackendIntegrationTest.java`
  - `backend/src/test/java/com/eventcapture/backend/integration/DistributedRuntimeIntegrationTest.java`
  - `backend/src/phase4ProcessTest/java/com/eventcapture/backend/integration/Phase4ProcessRecoveryIntegrationTest.java`
  - `backend/src/test/java/com/eventcapture/backend/integration/WorkerRoleIntegrationTest.java`
  - `backend/src/test/java/com/eventcapture/backend/integration/LocalRuntimeIntegrationTest.java`
  - `backend/src/test/java/com/eventcapture/backend/integration/RuntimeConfigurationIntegrationTest.java`
  - `backend/src/test/java/com/eventcapture/backend/integration/LiveR2SmokeIntegrationTest.java`
  - `backend/src/test/java/com/eventcapture/backend/integration/S3CompatibleStorageIntegrationTest.java`
  - `backend/src/test/java/com/eventcapture/backend/integration/Phase3MigrationIntegrationTest.java`
  - `backend/src/test/java/com/eventcapture/backend/integration/Phase3ReleaseBMigrationH2Test.java`
  - `backend/src/test/java/com/eventcapture/backend/integration/Phase3ReleaseBMigrationPostgresIntegrationTest.java`
  - `backend/src/test/java/com/eventcapture/backend/gallery/GalleryEventBrokerTest.java`
  - `backend/src/test/java/com/eventcapture/backend/media/UploadServiceTest.java`
  - `backend/src/test/java/com/eventcapture/backend/media/UploadServicePhase2Test.java`
  - `backend/src/test/java/com/eventcapture/backend/media/MediaInspectionServiceTest.java`
  - `backend/src/test/java/com/eventcapture/backend/media/LibvipsMediaVariantProcessorTest.java`
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
  - `uploads/init` accepts optional `checksumSha256` (64 hexadecimal characters) and returns `requiredHeaders` for single-part direct upload flows.
  - multipart part numbers are limited to the calculated part count; completion requires the exact contiguous part set and is idempotent.
  - `uploads/{uploadId}/parts` returns `requiredHeaders` for multipart part uploads.
  - `uploads/{uploadId}/finalize` returns `202 Accepted` with `processingStatus=UPLOADED` before worker completion.
  - backend `PUT` binary routes are used only when `APP_STORAGE_PROVIDER=local`.

## Local Commands

- Run tests:
  - `cd backend && ./gradlew test`
- Bitbucket Pipelines runs the container-backed integration suites with Docker and
  `TESTCONTAINERS_RYUK_DISABLED=true`, because Bitbucket does not permit Testcontainers'
  privileged Ryuk resource-reaper container. The verification step builds and shares the
  `bootJar` output as `build/libs/*.jar` for the separate Docker-image step.
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
- Session/worker/media/public-asset variables now include:
  - `APP_RUNTIME_ROLE=api|worker`
  - `APP_INFRASTRUCTURE_MODE=local|redis`
  - legacy `APP_SESSION_STORE_TYPE=none|redis` is accepted only when `APP_INFRASTRUCTURE_MODE` is unset
  - `APP_SESSION_COOKIE_NAME`
  - `APP_SESSION_NAMESPACE`
  - `APP_SESSION_TTL`
  - `APP_SESSION_SECURE_COOKIES`
  - `APP_SHARE_TOKEN_ACTIVE_KEY_ID`
  - `APP_SHARE_TOKEN_KEYRING` from the deployment secret store, retaining every referenced key ID
  - `APP_SHARE_TOKEN_BACKFILL_ENABLED=false` except for a controlled backfill/rotation node
  - `APP_SHARE_TOKEN_RELEASE_B_PREFLIGHT_ENABLED=false` except for a controlled audit node
  - `APP_SHARE_TOKEN_BACKFILL_BATCH_SIZE`
  - A greenfield first deployment keeps both Release B maintenance flags disabled; they are not startup prerequisites.
  - `APP_JOBS_OUTBOX_RELAY_DELAY`, `APP_JOBS_RECLAIM_IDLE`, and `APP_JOBS_QUEUE_MONITOR_DELAY`
  - `APP_MEDIA_PROCESSOR=java|libvips`
  - `APP_MEDIA_MAX_WIDTH`, `APP_MEDIA_MAX_HEIGHT`, and `APP_MEDIA_MAX_PIXELS`
  - optional `APP_STORAGE_PUBLIC_BASE_URL`; it must be empty in production until revocation-safe edge delivery exists
- R2 production variables are listed in `env.example`:
  - `APP_STORAGE_PROVIDER=r2`
  - `APP_STORAGE_R2_BUCKET`
  - `APP_STORAGE_R2_ACCOUNT_ID`
  - optional `APP_STORAGE_R2_ENDPOINT`
  - `APP_STORAGE_R2_ACCESS_KEY`
  - `APP_STORAGE_R2_SECRET_KEY`
  - optional `APP_STORAGE_R2_PRESIGN_TTL`
- Production R2 startup validates private/backend delivery, bucket, credentials, account/HTTPS endpoint, minimum 5 MiB multipart parts, and a positive presign TTL no longer than seven days.
- Restrictive direct-upload CORS is documented in `.agents/docs/R2_DEPLOYMENT.md`; `backend/r2-cors.example.json` allows only the configured frontend origin, `PUT`, required signed headers, and exposed `ETag`.
- The opt-in live R2 smoke test is enabled with `EVENT_CAPTURE_LIVE_R2_SMOKE=true` and reuses the existing `APP_STORAGE_*` R2 variables.

## Next Likely Work

- Preserve the completed Phase 4 child-process, Redis-interruption, live SSE resync, storage-idempotency, and alert-rule gates while continuing Phases 5-6 and later backend operational work.
- Use `.agents/docs/PHASE3_RELEASE.md` only if a future environment must upgrade existing pre-V6 data. The current undeployed greenfield environment migrates directly through V6 with the configured keyring and both maintenance flags disabled.
- Preserve the completed Phase 1 through Phase 3 runtime/security contracts and keep the full backend and OpenAPI checks passing after every backend phase.
- Do not scaffold or implement the Angular frontend until the product owner explicitly approves the completed wireframe and design; backend work may continue meanwhile.
