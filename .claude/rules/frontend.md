# Event Capture Frontend Rules

- Treat `frontend/` as the source of truth for the current implementation, and the Spring Boot
  records under `backend/src/main/java/com/eventcapture/backend/**` as the source of truth for
  every request and response shape.

## The contract is not negotiable from this side

- **Never hand-author a model against a plan document or a guess.** Every field name and enum
  value in `src/app/core/models/` must match a backend record. This rule exists because the
  first implementation did exactly that and produced ten mismatches, including two that fail
  hard: `spring.jackson.deserialization.fail-on-unknown-properties` is `true`, so an extra
  field in a request body is a 400, not a warning.
- Backend values that are easy to get wrong: `AuthMeResponse.hostId` (not `id`),
  `GuestSessionResponse.guestSessionId` (not `id`), `EventManualOverrideState.DEFAULT` (not
  `NONE`), `ExportJobStatus.QUEUED` (not `PENDING`), `FinalizeUploadRequest.clientFileName`
  (the checksum belongs to upload *init*), and `CompletedPart` being exactly
  `{partNumber, etag}`.
- Mock payloads in specs belong in `src/testing/fixtures.ts`, typed against the models. Do not
  inline object literals in a spec: self-consistent mocks are how the original drift went
  undetected by a green suite.
- `e2e/api-contract.spec.ts` asserts these shapes against a running backend. Extend it when
  you consume a new endpoint.

## Security contract

- The CSRF header must carry the **raw `XSRF-TOKEN` cookie value**. `GET /api/v1/csrf` returns
  an XOR-masked token for BREACH protection and only exists to make the backend issue the
  cookie; `SpaCsrfTokenRequestHandler` resolves a header-borne token with the *plain* handler,
  so sending the body token 403s every write.
- Interceptor order is `credentials -> csrf -> challenge`. The challenge interceptor replays a
  request after a solved challenge and must replay one that already carries its CSRF header.
- Abuse responses are part of the UI contract: 403 with a `challenge-required` problem body
  means render the Turnstile widget and retry once with `X-Challenge-Token`; 429 carries
  `retryAfterSeconds` and should be shown to the user, not swallowed into a generic failure.
- Never attach credentials or interceptor headers to presigned storage URLs. `uploadToPresignedUrl`
  deliberately uses raw `XMLHttpRequest` for this reason.

## Uploads

- Branch on `UploadInitResponse.mode`, never on a client-side size threshold. The backend owns
  the decision via `app.upload.multipart-threshold-bytes`, and a client-side copy will drift.
- Multipart part numbers are 1-based and contiguous, and the backend rejects any part number
  beyond the count implied by `partSizeBytes`. Send ETags verbatim, quotes included.

## Live gallery

- The backend emits **named** SSE events (`photo_ready`, `photo_hidden`, `photo_unhidden`,
  `photo_deleted`), so `EventSource.onmessage` never fires - register a listener per name.
- The event payload is a bare photo UUID, not JSON. Removals can be applied locally; additions
  require refetching the feed head, because the event carries no URLs and there is no
  single-photo endpoint.
- Coalesce bursts, and resync from REST after a reconnect - anything published while
  disconnected is not replayed.

## Rendering

- `PhotoFeedItem.imageUrl` and `thumbnailUrl` are `null` until the worker has produced the
  variants, and stay null for `FAILED` photos. The host feed includes non-`READY` photos, so
  always guard before binding to `src`.
- The product is mobile-first. Check narrow viewports; the Playwright suite runs a `mobile`
  project for this reason.
- Do not ship placeholder content that misrepresents real data (stock cover photos, fake
  counters, non-functional buttons).

## Testing

- Write or update tests before changing runtime code.
- Component tests for pages, `src/app/core/integration/` for router + guard + interceptor
  seams, and Playwright `e2e/` against a **real** backend.
- The e2e backend runs in the documented Redis-free local mode with
  `app.auth.debug-token-exposure=true`, which is what makes host sign-in testable without SMTP.
  Never enable that flag outside tests.
- A change is incomplete until `npm run lint`, `npm test`, `npm run build` and `npx playwright
  test` pass.
