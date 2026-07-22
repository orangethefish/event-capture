# Backend Implementation Plan

## Summary

- Build the backend as a Spring Boot 3.5.x servlet application on Java 21 with Gradle.
- Use one codebase with two runtime roles: `api` and `worker`.
- Use PostgreSQL for application data, Redis for sessions, distributed abuse enforcement, SSE fan-out, and background queueing, and Cloudflare R2 for object storage.
- Use Spring Data JPA as the default persistence model, Flyway for SQL migrations, RFC 9457 Problem Details for errors, and OpenAPI for API documentation.
- Keep the system cookie-authenticated for hosts, guest-session based for contributors, and mobile-web optimized for direct browser uploads.

## Architecture

### Runtime topology

- `api` role: REST endpoints, auth, guest session issuance, upload init and finalize, gallery reads, SSE, moderation, export requests.
- `worker` role: media processing, export zip creation, soft-delete cleanup, retention cleanup.
- External services: PostgreSQL, Redis, Cloudflare R2, SMTP provider, Google OAuth, Cloudflare Turnstile.
- Deploy frontend and API on the same parent domain; allow credentialed CORS only from the Angular origin.

### Spring stack

- Use Spring MVC, not WebFlux.
- Use Spring Security 6.5 with session cookies and CSRF cookie/header protection for mutating requests.
- Use Spring Session backed by Redis for host sessions.
- Use Actuator health and Prometheus endpoints from day one.
- Generate OpenAPI from controller DTOs.

### Internal code organization

- Use package-by-feature.
- Top-level features: `auth`, `host`, `event`, `guest`, `media`, `gallery`, `moderation`, `export`, `jobs`, `infra`.
- Each feature owns its controller, service, repository, DTOs, entities or value objects, and mapper code.
- Keep shared cross-cutting code limited to `infra` and `common` utilities.
- Stay in one Gradle module for v1; do not split into multiple build modules yet.

## Data Model

### Core tables

- `hosts`: account record, primary email, display name, created and updated timestamps.
- `host_identities`: host-to-auth-provider links for `magic_link` and `google`.
- `magic_link_tokens`: hashed one-time tokens, email, host reference, expires-at, consumed-at, requester metadata.
- `events`: host reference, title, slug, share-token lookup hash, encrypted recoverable token, optional scheduled upload open time, mandatory close time, manual override state, closure/applied-retention snapshot, retention expiry, and gallery enabled flag. Theme and cover fields wait for design approval.
- `guest_sessions`: event reference, display name, hashed session token, cookie id, expires-at, last-seen-at, lightweight risk metadata.
- `upload_intents`: event reference, guest session reference, selected upload mode, storage key prefix, content type, size, multipart upload id if used, status, expires-at.
- `photos`: event reference, guest session reference, original key, original filename, mime type, byte size, processing status, visibility state, deleted-at, failure reason, created and ready timestamps.
- `photo_variants`: photo reference, variant kind, storage key, width, height, mime type, byte size, public URL path token.
- `moderation_actions`: event reference, photo reference, host reference, action type, reason nullable, timestamp.
- `export_jobs`: event reference, requested-by host, status, archive key, archive expires-at, requested and completed timestamps, failure reason nullable.

### ID and indexing strategy

- Use UUIDv7 or another ordered UUID variant for all primary keys.
- Make `events.slug` unique and `share_token_hash` indexed.
- Index `guest_sessions` by event and cookie token hash.
- Index `photos` by event, readiness, visibility, and created-at for feed queries.
- Index `upload_intents` by expiry and status for cleanup.
- Index `export_jobs` by event and status.

### Persistence rules

- Use JPA entities for aggregates and standard CRUD.
- Use targeted custom SQL or native queries for cursor-based photo feeds and admin gallery screens where JPA pagination becomes awkward.
- Order host and public feeds by `(createdAt DESC, id DESC)` and use opaque, versioned compound keyset cursors.
- Keep all schema changes as Flyway SQL migrations; do not rely on Hibernate schema auto-update.

## Storage and Media Pipeline

### R2 layout

- Use one R2 bucket with prefixes.
- Originals: `originals/{eventId}/{photoId}/original`
- Variants: `variants/{eventId}/{photoId}/{randomToken}-{variantKind}.{ext}`
- Exports: `exports/{eventId}/{exportId}.zip`
- Originals and exports stay private.
- Production variants remain private in R2 and are streamed through backend-authorized opaque asset routes so hide/delete/disable/expiry revocation cannot be bypassed. A CDN/custom-domain path remains disabled until it has an equivalent revocation-safe edge design.

### R2 integration details

- Use AWS SDK for Java v2 against R2.
- Configure endpoint override to the account R2 endpoint.
- Set region to `auto`.
- Enable path-style access.
- Keep R2 signing behavior inside the storage adapter. Presigned single and multipart PUT responses include all required signed headers, and AWS SDK checksum calculation remains `WHEN_REQUIRED` for compatibility.
- Presign PUTs for direct uploads and presign export GETs for host downloads.
- Treat `APP_STORAGE_R2_PRESIGN_TTL` as a maximum: export GET signatures are shortened by remaining archive and event-retention lifetime.

### Upload policy

- Accept `image/jpeg`, `image/png`, `image/webp`, `image/heic`, `image/heif`.
- Enforce a 25 MB per-photo cap.
- Use single-part presigned PUT for files up to 8 MB.
- Use multipart upload for files above 8 MB.
- Backend generates all object keys; clients never choose final storage paths.
- New photos become visible only after processing completes successfully.

### Worker media processing

- Use native image tools inside the worker container for HEIC support and reliable variant generation.
- Generate at least one gallery-sized variant and one thumbnail variant.
- Strip EXIF metadata from public variants only.
- Preserve original files for export until retention or deletion cleanup removes them.
- Mark failed processing explicitly and keep failures visible to the host dashboard only.

### Phase 6 privacy and export policy

- Serialize moderation, media processing, and deleted-photo purge through a shared pessimistic photo lock.
- Permit only `VISIBLE -> HIDDEN`, `HIDDEN -> VISIBLE`, and `VISIBLE|HIDDEN -> DELETED`; identical actions are no-ops and deletion is terminal.
- Keep the first `deletedAt` immutable and enforce deleted/timestamp consistency with Flyway V8.
- Apply strict no-store/no-cache/zero-age/`nosniff` headers to all public asset GET/HEAD outcomes while preserving indistinguishable `404` denials.
- Include every non-deleted finalized original in an export, including hidden, processing, and failed photos; use `(createdAt, id)` ordering.
- Reject export creation after retention expiry and set archive expiry to the earlier of completion plus 24 hours or event retention.
- Keep `QUEUED -> PROCESSING -> READY` and terminal `FAILED`; duplicate delivery cannot downgrade `READY` or `FAILED`.
- Treat retention expiry, missing originals, and invalid targets as permanent; retry provider/network/5xx failures with five total attempts.
- Abort every incomplete multipart upload before retained-event object deletion.
- Clean expired archives and upload intents one locked item per transaction, retaining failed rows and continuing unrelated due items.
- Export downloads are ZIP attachments with private/no-store caching and `nosniff`.
- See `.agents/docs/PHASE6_PRIVACY.md` for evidence, alert names, and recovery steps.

## API and Interface Contract

### Auth endpoints

- `POST /api/v1/auth/magic-link/request`
- `GET /api/v1/auth/magic-link/consume`
- `GET /api/v1/auth/magic-link/complete`
- `GET /api/v1/auth/oauth2/authorization/google`
- `GET /login/oauth2/code/google`
- `POST /api/v1/auth/logout`
- `GET /api/v1/auth/me`
- `GET /api/v1/csrf`

### Host endpoints

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

### Public guest endpoints

- `GET /api/v1/public/events/{slug}/{shareToken}`
- `POST /api/v1/public/events/{slug}/{shareToken}/guest-session`
- `GET /api/v1/public/events/{slug}/{shareToken}/photos`
- `GET /api/v1/public/events/{slug}/{shareToken}/stream`
- `POST /api/v1/public/events/{slug}/{shareToken}/uploads/init`
- `POST /api/v1/public/events/{slug}/{shareToken}/uploads/{uploadId}/parts`
- `POST /api/v1/public/events/{slug}/{shareToken}/uploads/{uploadId}/complete`
- `POST /api/v1/public/events/{slug}/{shareToken}/uploads/{uploadId}/finalize`

### Key DTOs

- `ProblemDetail` for all API errors.
- `GuestSessionRequest { displayName }`
- `UploadInitRequest { fileName, contentType, sizeBytes }`
- `UploadInitResponse { uploadId, mode, expiresAt, singlePartUrl?, multipartUploadId?, partSizeBytes? }`
- `UploadPartUrlResponse { partNumber, url, requiredHeaders }`
- `CompleteMultipartRequest { parts[] }`
- `FinalizeUploadRequest { clientFileName }`
- `PhotoFeedResponse { items[], nextCursor }`
- `EventResponse`, `EventSummaryResponse`, `ExportJobResponse`

## Security, Sessions, and Realtime

- Host auth uses one-time DB-backed magic-link tokens plus Google OAuth.
- Magic-link tokens are stored hashed, expire in 15 minutes, are pessimistically single-use, and carry allowlisted frontend return paths. Browser email links complete through a token-free `303` redirect while the JSON consume contract remains available.
- Host sessions are Redis-backed, HttpOnly, Secure, rolling 30-day sessions; controller-managed authentication explicitly rotates the pre-authentication session ID and persists the security context.
- Guest sessions are event-scoped cookies lasting until event close or 30 days, whichever comes first.
- Use CSRF cookie/header protection for all mutating cookie-authenticated requests.
- Use `SameSite=Lax` unless deployment constraints force a stricter change.
- Apply operation-aware rolling-window abuse policy to magic request/consume, OAuth start, guest join, upload init, and upload finalize. HMAC every stored subject, use atomic Redis counters/clearance in production, and keep behaviorally equivalent local counters.
- Use Cloudflare Turnstile only after suspicious magic-request, guest-join, or upload-init thresholds; grant bounded server-side clearance, preserve hard caps, and fail closed when verification is unavailable.
- Use Redis pub/sub to fan out photo-ready and moderation events to SSE connections across API instances.
- SSE events should include `photo_ready`, `photo_hidden`, `photo_unhidden`, and `photo_deleted`.

## Background Jobs

### Queue and delivery

- Use Redis Streams with consumer groups for job delivery.
- Job types: `PROCESS_UPLOAD`, `BUILD_EXPORT`, `PURGE_DELETED_PHOTO`, `PURGE_RETAINED_EVENT`.
- Worker acknowledges jobs only after side effects and DB state are committed.
- Retry failed jobs with bounded retry count and exponential backoff.
- Move exhausted failures to a dead-letter stream and surface them in logs and alerts.

### Scheduled cleanup

- Use scheduled worker scans to enqueue due cleanup and retention jobs.
- Exports are built asynchronously, written to R2, and exposed until the earlier of their 24-hour archive lifetime or event-retention expiry; each signed URL is bounded again by the configured presign maximum.
- Soft-deleted photos disappear immediately from feeds and exports, then storage is purged after 7 days.

## Test Plan

- Unit-test security rules, token lifecycles, upload validation, cursor generation, and job handlers.
- Run integration tests with Testcontainers for PostgreSQL and Redis.
- Use an S3-compatible local test target for storage integration and keep one environment-level smoke test against real R2.
- Verify host login, logout, session renewal, and Google OAuth callback handling.
- Verify guest session creation, cookie persistence, and blocked uploads after event closure.
- Verify single-part and multipart upload flows, finalize validation, and media processing success or failure states.
- Verify cursor pagination stability under concurrent uploads.
- Verify SSE delivery across multiple API instances using Redis pub/sub.
- Verify moderation transitions and that hidden or deleted photos disappear from public feeds.
- Verify export creation, download expiry, and retention cleanup.
- Verify PostgreSQL moderation races, MinIO signed GET response overrides/duration, partial-provider cleanup continuation, and Prometheus export/cleanup alerts.
- Verify CSRF enforcement on writes and CORS behavior for the Angular origin only.

## Assumptions and Defaults

- Target Spring Boot 3.5.x and Spring Security 6.5 unless deployment constraints force a downgrade.
- The backend remains a modular monolith in one repo and one deployable artifact, with role-based runtime behavior.
- Link privacy is the intended privacy model; public variant URLs are opaque but not individually signed.
- Email delivery is implemented through SMTP abstraction so the provider can be swapped later.
- No collaborator-host roles, no guest accounts, no video, and no approval queue in v1.
