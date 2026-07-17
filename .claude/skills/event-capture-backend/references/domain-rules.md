# Domain Rules

## Auth and Sessions

- Host auth model:
  - magic link token stored hashed in DB
  - token TTL from config: `PT15M`
  - successful consume stores a host principal in servlet session via `HttpSessionSecurityContextRepository`
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
  - `DEFAULT` and current time is after `scheduledUploadOpenAt` if present, and before `scheduledUploadCloseAt` if present
- Uploads are closed when:
  - `FORCE_CLOSED`, or
  - current time is before scheduled open, or at/after scheduled close
- Gallery is available when:
  - `galleryEnabled == true`
  - retention has not expired

## Share Link Model

- Hosts receive a `sharePath` in the form:
  - `/events/{slug}/{shareToken}`
- Public backend APIs use:
  - `/api/v1/public/events/{slug}/{shareToken}/...`
- `requirePublicEvent` validates the slug lookup plus SHA-256 of the raw share token

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
- Current retry limitation:
  - every `PROCESS_UPLOAD` failure is currently non-retryable; Phase 4 must classify invalid/corrupt media as permanent and retry transient storage, command, and dependency failures

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

## Moderation and Export

- Moderation actions supported:
  - hide
  - unhide
  - delete
- Delete is soft at application level:
  - sets visibility to `DELETED`
  - sets `deletedAt`
- Export jobs run asynchronously and build archives through the storage abstraction.
- Ready exports expose a signed R2 or local backend download URL until `archiveExpiresAt`; expired downloads return `410 Gone`.
- The canonical download route is `GET /api/v1/host/events/{eventId}/exports/{exportId}/download`.
- Guest-controlled client filenames are normalized to traversal-safe ZIP basenames; duplicate normalized names receive deterministic numeric suffixes.
- Export job statuses:
  - `QUEUED`
  - `PROCESSING`
  - `READY`
  - `FAILED`
