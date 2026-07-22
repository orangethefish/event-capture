# Domain Rules

## Auth and Sessions

- Host auth model:
  - magic-link tokens are stored hashed, expire at `expiresAt <= now`, and are locked pessimistically so one token authenticates once
  - each issued token remains independently valid until consumed/expired and carries an allowlisted `/host` return path
  - both JSON consume and browser completion rotate any pre-authentication session ID and save `ROLE_HOST` through `HttpSessionSecurityContextRepository`
  - browser completion returns token-free `303` success/fixed-failure destinations with `no-store` and `no-referrer`
  - Google identity is anchored to verified nonblank `sub`; only first login may link an existing host through verified normalized email
- Abuse model:
  - every email/IP/session/event/guest counter and clearance subject is HMACed before storage
  - any hard cap wins and returns the longest safe retry; challenges apply only to magic request, guest join, and upload init
  - valid Turnstile grants a 15-minute server-side operation-family clearance; provider unavailability fails closed with retryable `503`
- Guest auth model:
  - no account
  - event-scoped cookie
  - cookie name: `event_capture_guest`
  - cookie value is the raw guest session token
- Guest session expiry:
  - default `P30D`
  - shortened to event scheduled close if that is earlier

## Event Lifecycle

- `EventManualOverrideState`:
  - `DEFAULT`
  - `FORCE_OPEN`
  - `FORCE_CLOSED`
- Uploads are open when:
  - `FORCE_OPEN`, or
  - `DEFAULT` and current time is after `scheduledUploadOpenAt` if present, and before the mandatory `scheduledUploadCloseAt`
- Uploads are closed when:
  - `FORCE_CLOSED`, or
  - current time is before scheduled open, or at/after scheduled close
- Scheduled open is optional but, when present, must be strictly before the mandatory close time.
- The first effective closure snapshots `uploadsClosedAt`, the effective retention duration, and `retentionExpiresAt`; expiry is terminal.
- `FORCE_OPEN` may explicitly reopen a scheduled closure. Returning to `DEFAULT` re-applies the schedule without discarding closure/retention history.
- Gallery is available when:
  - `galleryEnabled == true`
  - retention has not expired

## Share Link Model

- Hosts receive a `sharePath` in the form:
  - `/events/{slug}/{shareToken}`
- Public backend APIs use:
  - `/api/v1/public/events/{slug}/{shareToken}/...`
- `requirePublicEvent` validates the slug lookup plus SHA-256 of the raw share token
- The database stores only `share_token_hash`, AES-256-GCM ciphertext, and its key ID after V6.
- Encryption binds ciphertext to the event UUID as AAD; host `sharePath` decrypts it unconditionally.
- Existing raw tokens and public paths remain unchanged through Release B. Missing referenced key IDs fail startup.

## Upload Rules

- Allowed MIME types:
  - `image/jpeg`
  - `image/png`
  - `image/webp`
  - `image/heic`
  - `image/heif`
- Max size:
  - `25 MB`
- Multipart threshold:
  - above `8 MB`
- Multipart part size:
  - `5 MB`
- Upload intent TTL:
  - currently `20 minutes`
- Current flow:
  - `init` accepts an optional SHA-256 checksum and returns a presigned single-part upload plus its `requiredHeaders` for R2, or a local backend `PUT` URL
  - multipart R2 uploads request presigned part URLs and call `complete`; local mode retains backend multipart part `PUT` endpoints
  - multipart part plans are contiguous and exact; `complete` and `finalize` are idempotent
  - `finalize` verifies stored size, computes SHA-256, rejects and removes checksum mismatches, creates a `Photo` in `UPLOADED` state, returns `202 Accepted`, and enqueues processing
- Worker processing behavior today:
  - verifies JPEG, PNG, WEBP, HEIC, and HEIF signatures against the declared MIME type before decoding
  - validates encoded and decoded dimensions and pixel limits
  - uses Java/ImageIO as the portable fallback and libvips in production for orientation normalization, resizing, metadata stripping, and public-variant re-encoding
  - records dimensions and marks the photo `READY`, or marks invalid/corrupt media `FAILED`
  - publishes SSE `photo_ready` only after processing succeeds
  - serializes duplicate processing with a pessimistic photo lock and writes public variants to deterministic per-photo keys so replay overwrites rather than orphans objects
  - terminal processing failure deletes the complete per-photo variant prefix before persisting `FAILED`
- Retry classification:
  - invalid/corrupt media, missing photo targets, and invalid job input are permanent
  - storage, native-command, and dependency failures retry with bounded exponential backoff before terminal failure and DLQ publication

## Photo and Gallery Rules

- `PhotoProcessingStatus` currently used:
  - `PENDING_UPLOAD`
  - `UPLOADED`
  - `READY`
  - `FAILED`
- `PhotoVisibility`:
  - `VISIBLE`
  - `HIDDEN`
  - `DELETED`
- Public feed includes only:
  - `READY`
  - `VISIBLE`
- Public asset reads additionally require:
  - event gallery enabled
  - retention not expired
- SSE event names:
  - `photo_ready`
  - `photo_hidden`
  - `photo_unhidden`
  - `photo_deleted`
- SSE events are transient hints; every reconnect must resynchronize from the authoritative paginated REST feed before applying later live events.

## Export and Multipart Idempotency

- Export handlers serialize duplicate builds with a pessimistic export-job lock and always address `exports/{eventId}/{exportId}.zip`; terminal failure removes that deterministic key even when the archive path did not commit.
- A repeated remote multipart completion may treat `NoSuchUpload`/404 as prior success only when `HEAD` confirms the intended final object exists. Missing final objects remain failures.
- Retention and deleted-photo cleanup remove deterministic storage prefixes as well as database-recorded paths so storage writes that preceded a rolled-back database commit remain recoverable.
## Moderation and Export

- Moderation, media processing, and deleted-photo purge acquire the same pessimistic photo lock.
- Allowed moderation transitions are `VISIBLE -> HIDDEN`, `HIDDEN -> VISIBLE`, and `VISIBLE|HIDDEN -> DELETED`.
- Repeating the current action is an idempotent no-op with no audit/outbox row. `DELETED` is terminal for hide/unhide.
- The first delete sets `deletedAt`; later deletes never change it. Flyway V8 requires `deletedAt` exactly for `DELETED` rows.
- Public assets require visible/ready media, enabled gallery, and unexpired retention. Every GET/HEAD outcome carries strict no-store/no-cache/zero-age/`nosniff` headers; denials are indistinguishable `404` responses.
- Export requests after event retention expiry return `410 Gone`.
- Export jobs run asynchronously and include every non-deleted finalized original, including hidden, processing, and failed photos, ordered by `(createdAt, id)`.
- Archive expiry is the earlier of completion plus 24 hours or event retention. R2 GET signatures are capped again by configured presign TTL and remaining archive/retention lifetime.
- Ready exports expose a refreshed signed R2 or local backend download URL until the effective deadline; expired status omits the URL and downloads return `410 Gone`.
- The canonical download route is `GET /api/v1/host/events/{eventId}/exports/{exportId}/download`.
- ZIP responses use `application/zip`, attachment disposition, private/no-store caching, and `nosniff`.
- Guest-controlled client filenames are normalized to traversal-safe ZIP basenames; duplicate normalized names receive deterministic numeric suffixes.
- Export job statuses:
  - `QUEUED -> PROCESSING -> READY`
  - exhausted or permanent failure -> `FAILED`
  - `READY` and `FAILED` are terminal under duplicate delivery
- Missing jobs after retention purge are no-ops. `markFailed` never deletes/downgrades an already-ready archive.
- Retention expiry, missing originals, and invalid targets are permanent. Provider/network/5xx failures use five total attempts with existing backoff.
- Retained-event cleanup aborts every incomplete multipart upload before deletion. Expired archives/uploads are locked and rechecked one transaction per item so failures retain recovery state and later items continue.
