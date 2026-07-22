# Phase 6 Privacy, Moderation, Delivery, and Export Evidence

## Status

Runtime implementation and focused non-container verification are complete. Phase 6 remains pending final closure because Docker is unavailable on the current workstation, so PostgreSQL/Redis/MinIO suites, the Phase 4 child-process test, and containerized `promtool` checks have not run locally. Do not relabel the phase complete until every exit gate below passes.

No API route or public DTO shape changed.

## Moderation state machine

All moderation, media-processing, and deleted-photo-purge paths acquire a pessimistic lock through `PhotoRepository` before changing the photo row.

| Current state | Hide | Unhide | Delete |
| --- | --- | --- | --- |
| `VISIBLE` | `HIDDEN`, audit + `photo_hidden` | no-op `204` | `DELETED`, set first `deletedAt`, audit + `photo_deleted` |
| `HIDDEN` | no-op `204` | `VISIBLE`, audit + `photo_unhidden` | `DELETED`, set first `deletedAt`, audit + `photo_deleted` |
| `DELETED` | `409 Conflict` | `409 Conflict` | no-op `204` |

No-op actions create no moderation row and no gallery outbox event. The outbox row is stored in the same transaction as the state change, so a rollback cannot publish a moderation transition. Repeated deletion never changes `deletedAt`; the seven-day purge deadline cannot be postponed.

Flyway V8 enforces the database invariant that `deleted_at` is non-null exactly when visibility is `DELETED`.

## Public asset privacy policy

`PublicAssetPrivacyFilter` runs only on the API role for `/api/v1/public/assets/**`. GET and HEAD responses receive the same headers before controller/security outcome handling:

- `Cache-Control: no-store, no-cache, max-age=0, must-revalidate`
- `Pragma: no-cache`
- `Expires: 0`
- `X-Content-Type-Options: nosniff`

The backend-authorized opaque URL remains stable. Hide and gallery disablement revoke it immediately; unhide and gallery re-enablement restore access through that URL. Deleted, non-ready, retention-expired, purged, and unknown assets all return the same `404`. Production public-base/CDN delivery remains prohibited.

## Export contents and deadlines

Each export request creates a distinct job. Creation returns RFC 9457 `410 Gone` when event retention is already expired.

Archive selection is scoped to the job's event and includes every non-deleted photo row. Because photo rows are created only after finalize, this preserves finalized originals that are visible, hidden, uploaded/processing, ready, or failed. Deleted and foreign-event rows are excluded. Database ordering is deterministic by `(createdAt, id)`; ZIP names retain traversal-safe basenames and deterministic duplicate suffixes.

On successful build:

`archiveExpiresAt = min(buildCompletedAt + 24 hours, event.retentionExpiresAt)`

A signed R2 GET duration is:

`min(APP_STORAGE_R2_PRESIGN_TTL, remaining archive lifetime, remaining event-retention lifetime)`

Polling a ready job generates a refreshed URL until the effective deadline. Expired status responses omit `downloadUrl`; backend downloads return `410 Gone`.

Presigned and backend ZIP responses use:

- `Content-Type: application/zip`
- attachment content disposition with identifier-only filename
- `Cache-Control: private, no-store, max-age=0`
- `X-Content-Type-Options: nosniff`

## Export retry taxonomy

| Failure | Classification |
| --- | --- |
| Event retention expired before/during build | Permanent |
| Source original missing or other storage `4xx` | Permanent |
| Invalid job/target arguments | Permanent |
| Storage/network/provider `5xx` | Transient |
| Other provider/dependency failure | Transient |

Transient jobs use the existing exponential backoff with five total attempts. Permanent or exhausted work becomes `FAILED`. `READY` and `FAILED` are terminal under duplicate delivery. Missing jobs after retention purge are no-ops. `markFailed` locks the job and never deletes or downgrades an archive already committed as `READY`.

Transition-only Micrometer counters record requested, completed, and failed exports.

## Cleanup recovery model

Retained-event purge locks the event and lists its uploads/photos/variants/exports. It aborts every incomplete multipart upload before the first delete operation. Only after all provider cleanup succeeds are moderation, variant, photo, export, upload, guest-session, and event rows removed.

Deleted-photo purge locks the photo. Expired archive and upload-intent scans select identifiers, then each identifier is reloaded with a pessimistic lock in a `REQUIRES_NEW` transaction and eligibility is rechecked. A failed item rolls back and remains eligible; the coordinator records the cleanup type and continues with later identifiers.

Provider operations use deterministic object keys/prefixes, so a retry safely repeats operations already completed before a later provider failure. R2 `NoSuchUpload` abort is an idempotent success.

Recovery procedure:

1. Restore R2/S3 connectivity or credentials; do not manually delete retained database rows.
2. Inspect the identifier-safe warning and `eventcapture_cleanup_provider_failures_total{cleanup_type=...}`.
3. Allow the next maintenance scan to reacquire the item lock and retry.
4. Confirm the due row/path clears and the alert resolves.
5. Replay dead-lettered export work only after confirming source retention and handler idempotency.

Logs must not include filenames, tokens, URLs, cookies, ciphertext, provider diagnostics containing signed material, or credentials.

## Evidence and exit gates

Focused evidence includes moderation transition/idempotency tests, asset filter GET/HEAD/error tests, export deadline/presign/archive tests, cleanup item/coordinator tests, H2 V8 migration coverage, R2 presigner request assertions, and PostgreSQL moderation race tests for delete/delete, delete/unhide, and moderation/media processing.

Required closure gates:

- `./gradlew spotlessCheck test`
- `./gradlew openApiCheck`
- `./gradlew phase4ProcessTest`
- `promtool check rules event-capture-alerts.yml`
- `promtool test rules event-capture-alerts.test.yml`
- API and worker production-configuration tests
- canonical/mirror byte comparisons
- opt-in live R2 smoke remains the provider proof when credentials are available

After all gates pass, Phase 6 may be marked complete and backend-only Phase 8/9 delivery-confidence work becomes next. Angular Phase 7 remains paused pending approved wireframes and design.

