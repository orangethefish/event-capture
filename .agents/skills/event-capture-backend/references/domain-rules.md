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
  - `init`
  - backend `PUT` binary upload or multipart part uploads
  - multipart `complete` if needed
  - `finalize`
- Finalize behavior today:
  - verifies upload object exists
  - creates `Photo`
  - copies original to gallery and thumbnail variant paths
  - probes dimensions if `ImageIO` can read them
  - marks photo `READY`
  - publishes SSE `photo_ready`

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
- Export jobs exist as DB records only for now
- Export job statuses:
  - `QUEUED`
  - `PROCESSING`
  - `COMPLETED`
  - `FAILED`
