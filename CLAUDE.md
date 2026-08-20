# Event Capture Repo Guide

## Product Direction

- Build a mobile-first wedding event capture app where hosts create events, share a QR code or link, guests join with a display name, upload photos, and watch a live gallery update during the event.
- Frontend target remains Angular. Backend target remains Spring Boot. The intended production storage path is Cloudflare R2, with PostgreSQL for app data and Redis for sessions, fan-out, and background jobs.
- v1 scope is still guest event pages plus a host dashboard. Do not expand into video, guest accounts, collaborator hosts, comments, reactions, or a marketing site unless requirements change.

## Current Repo State

- `backend` is now a working Spring Boot 3.5.x Gradle project.
- `frontend` is now a working Angular 19 application (standalone components, signals). The wireframe/design pause has been lifted and Phase 7 is implemented.
- `backend/` and `frontend/` are git submodules; both plus this `AGENTS.md` are the source of truth for what runs today. The planning docs remain target-state references.
- Root planning docs are in `.agents/docs/IMPLEMENTATION_PLAN.md` and `.agents/docs/BACKEND_IMPLEMENTATION_PLAN.md`.
- The dependency-ordered work needed to close the audited gaps and complete the v1 application is in `.agents/docs/APPLICATION_COMPLETION_PLAN.md`.
- Deployment is documented in `.agents/docs/DEPLOYMENT.md`, with `docker-compose.yml` at the repo root.
- Production-oriented environment variables are documented in `env.example`.

## Deployment Topology

- The SPA and the API are served from **one public origin**. The frontend nginx container proxies `/api/v1`, `/login/oauth2`, and `/actuator` to the API container.
- This is load-bearing, not stylistic:
  - host and guest session cookies are `SameSite=Lax`, which browsers will not send cross-site, so split `api.`/`app.` origins break authentication outright
  - `PublicAssetUrlBuilder` emits relative `/api/v1/public/assets/...` URLs whenever `APP_STORAGE_PUBLIC_BASE_URL` is empty, which production requires for strict revocation
  - same-origin means no production CORS
- `APP_BASE_URL` and `APP_FRONTEND_ORIGIN` must be the same origin.
- The `/api/v1/` proxy location must keep `proxy_buffering off` and `chunked_transfer_encoding on`, or the SSE gallery stream is buffered and the live gallery appears broken.
- `APP_HTTP_TRUSTED_PROXY_CIDRS` must include the nginx network, or `ClientIpResolver` attributes every request to the proxy and all per-IP abuse limits collapse into one bucket.

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
- Host magic-link auth with JSON consume compatibility, a browser-oriented token-free `303` completion flow, persisted allowlisted return paths, exact expiry, pessimistic replay protection, normalized `MAGIC_LINK` identities, and centralized session-fixation rotation.
- Conditional Google OAuth uses Spring Security authorization-code/state processing, shared-session state-bound return paths, verified `sub`/email claims, first-login verified-email linking, safe failure codes, and centralized session establishment. OAuth wiring activates only for a complete Google client configuration.
- CSRF cookie/header support for host endpoints, with both `GET /api/v1/auth/csrf` and canonical `GET /api/v1/csrf`.
- Credentialed CORS is restricted to `APP_FRONTEND_ORIGIN`, allows `X-XSRF-TOKEN` and `X-Challenge-Token`, and exposes `Retry-After` and `X-Correlation-ID`.
- Security-filter and controller-advice failures use standardized `application/problem+json` responses.
- Magic-link delivery logs never include the live URL or token; SMTP failures return a safe `502` error.
- Export archive entry names are normalized to traversal-safe basenames with deterministic duplicate suffixes.
- Actuator liveness remains process-focused, while readiness includes the database and the mode-aware Redis health contributor.
- Host APIs for event list/create/get/update, host photo feed, moderation, export-job creation/status, and export download with expiry enforcement.
- Host event counts are served by `com.eventcapture.backend.stats.EventStatsService`, which lives outside `event` because it reads the `media` and `guest` repositories and both of those already depend on `event`. The batched list path uses one grouped query per repository rather than one per event.
- Public APIs for event lookup, guest session create/resume, read-only cookie-based guest session resume, gallery feed, SSE stream subscription, upload init, multipart part URL issuance, binary upload endpoints, multipart complete, finalize, and public asset fetch.
- OpenAPI is exposed through Springdoc on the API role.
- Phase 3 lifecycle behavior is implemented: mandatory close times for new events, closure-time retention snapshots, tri-state PATCH semantics, and compound opaque feed cursors.
- Share tokens are persisted only as a SHA-256 lookup hash plus AES-256-GCM ciphertext and key ID. Host share paths decrypt the original token; public lookup remains hash-based and existing API paths/shapes are unchanged.
- The optional Release B preflight scans events in bounded UUID-keyset batches and safely reports missing encryption data, unknown keys, decryption/hash failures, missing closes, and invalid windows. Backfill and preflight cannot run together.
- Post-B backfill performs ciphertext-only key rotation, and normal startup rejects any database key ID absent from the configured API/worker keyring.
- Flyway V6 enforces non-null close/ciphertext/key ID fields, nonblank encrypted fields, ordered upload windows, and physical removal of `share_token_value`. Flyway V7 adds the validated magic-link return path, and V8 requires `deletedAt` exactly for `DELETED` photos. No release or application data has been deployed, so the greenfield first deployment migrates directly through V8; the coordinated V6 cutover applies only to a future upgrade from a pre-V6 environment.
- SSE fan-out uses local in-process delivery in explicit `local` infrastructure mode and Redis pub/sub propagation in explicit `redis` mode.
- Upload validation for allowed content types and size limits.
- Storage abstraction with:
  - local filesystem-backed storage for tests and lightweight local development
  - Cloudflare R2-backed storage using AWS SDK for Java v2
- UUID generation uses UUIDv7-style ordered IDs through `uuid-creator`.
- Host sessions use an in-memory `MapSessionRepository` in explicit `local` mode and `RedisSessionRepository` in explicit `redis` mode. Spring Session auto-configuration is disabled so selection is deterministic.
- Operation-aware abuse enforcement uses exact in-memory rolling windows in `local` mode and atomic Redis rolling windows in `redis` mode. Counter and clearance subjects are HMACed; hard caps, risk challenges, 15-minute Turnstile clearance, and safe retry metadata are enforced consistently across modes.
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
- The media variant pipeline is selected through `APP_MEDIA_PROCESSOR=java|libvips`: Java remains the portable local/test fallback, while the root `docker-compose.yml` selects libvips for bounded auto-rotating, metadata-stripping re-encoding. Production images include `libvips-tools`, HEIF, and WEBP helpers.
- Export jobs are now executed asynchronously and can return a signed or local download URL once `READY`. Duplicate builds take a pessimistic export-job lock, use a deterministic archive key, and remove that key on terminal failure even if its database path did not commit.
- Phase 6 moderation uses one pessimistic photo lock across moderation, media processing, and deleted-photo purge. Only `VISIBLE -> HIDDEN`, `HIDDEN -> VISIBLE`, and `VISIBLE|HIDDEN -> DELETED` change state; repeated actions are no-op `204` responses, deletion is terminal, and the first `deletedAt` remains immutable.
- Public asset delivery applies `no-store`, `no-cache`, zero-age, `Pragma`, `Expires`, and `nosniff` headers through an API-role filter for every GET/HEAD success or error. Hidden, deleted, non-ready, gallery-disabled, retention-expired, purged, and unknown assets remain indistinguishable `404` responses.
- Phase 6 exports include every non-deleted finalized original regardless of visibility or processing outcome, order entries by `(createdAt, id)`, retain safe deterministic ZIP names, reject creation after retention expiry, and cap archive/presign lifetime by both archive and event-retention deadlines. ZIP reads use attachment, private/no-store, and `nosniff` response controls.
- Phase 6 cleanup locks eligible rows, aborts all incomplete multipart uploads before retained-event object deletion, preserves database state on provider failure, and cleans expired export archives/upload intents one locked item per transaction while later items continue.
- Public feeds can build asset URLs from `APP_STORAGE_PUBLIC_BASE_URL` outside production. Production rejects a non-empty public base URL and uses backend-authorized asset reads so strict hide/delete/disable/expiry revocation cannot be bypassed by an old CDN object URL.
- Public asset reads and export reads stream through the storage abstraction instead of reading directly from the filesystem.
- Unit tests covering `EventService`, `AuthService`, `GuestSessionService`, `SimpleRateLimiter`, `UploadService`, and `R2ObjectStorageService`.
- Integration tests now run against PostgreSQL and Redis Testcontainers for the main backend behavior path, including Redis-backed host sessions, while keeping local storage for binary assets.
- Split-runtime integration coverage now uses command-line overrides to guarantee separate `api` and `worker` boot paths share PostgreSQL and Redis. A real HTTP SSE client on API A observes API B changes, disconnects across a state transition, resynchronizes from REST, reconnects, and observes the next live event.
- `GalleryEventBrokerTest` covers `photo_ready`, `photo_hidden`, `photo_unhidden`, and `photo_deleted` emitter payload delivery.
- `phase4ProcessTest` launches child API/worker JVMs against PostgreSQL and AOF-backed Redis, proving outbox replay after publish-before-commit termination, pending reclaim after handler-commit-before-ack termination, and recovery of readiness/publication/consumption across Redis stop/start.
- The storage-side-effect audit covers deterministic media/export keys, pessimistic handler locks, orphan-prefix cleanup, and uncertain multipart-completion recovery.
- Deployment-owned Prometheus rules and executable `promtool` tests cover outbox stall/backlog, pending work, retries, DLQ depth, terminal/publish failures, p95 handler latency, missing queue metrics, terminal exports, and provider cleanup failures by cleanup type. Bitbucket and Jenkins validate them with pinned Prometheus `v3.5.0`.
- A MinIO Testcontainers suite exercises the R2 adapter contract through real S3-compatible HTTP for presigned single-part upload, multipart completion, abort, head/read/write, retention-aware signed export GET duration/response overrides, export reads, and prefix cleanup.
- Phase 5 tests include browser magic-link/session behavior, PostgreSQL concurrent replay, an embedded signed OIDC provider, every balanced abuse threshold, Redis cross-instance counters/clearance, Turnstile classification, trusted proxy chains, CORS, and production configuration validation.
- Phase 6 has a green 39-test focused non-container suite plus successful compilation and formatting. The full PostgreSQL/Redis/MinIO suite, Phase 4 child-process recovery, `promtool`, OpenAPI, and production-configuration exit gates remain mandatory before Phase 6 may be marked complete. Docker is available locally again, so these can now be run.
- The live R2 test verifies direct single-part and multipart upload, asynchronous processing, export generation/read, incomplete-upload cleanup, and retention cleanup without exposing signed URLs or credentials. Provider-issued multipart upload IDs are stored as opaque text, and quoted provider ETags are JSON-encoded as opaque values.

### Intentionally Temporary

- The Java media variant processor remains available for portable local/test use; production selects the libvips processor. Both paths re-encode public variants, and libvips is validated in the production image rather than required on the host machine.
- Metadata stripping is achieved through public-variant re-encoding (`strip` in libvips) rather than a separate metadata service.
- Production deliberately serves media through authorized backend asset endpoints for strict revocation. Direct CDN/custom-domain delivery remains disabled until a revocation-safe edge strategy is implemented.
- Cleanup scheduling is simple and currently relies on periodic scans plus idempotent job handlers rather than explicit deduplication state.
- Local infrastructure is intentionally process-local and non-durable: sessions, abuse counters/clearance, gallery events, and background jobs are lost on restart and cannot coordinate multiple instances.
- Backend `PUT` upload binary endpoints still exist for `local` storage mode. The intended production path is presigned direct upload to R2.
- Phase 4 is complete for the approved backend scope: transactional outbox/delays, reclaim/retries/DLQ, child-process crash/restart and Redis-interruption proof, live multi-API SSE disconnect/resync proof, storage-side-effect idempotency auditing, and deployment-owned alerts are implemented. Broader dashboards remain later observability work.


## Approved Completion Decisions

- Support an explicit Redis-free single-process local mode. Require Redis for production and separate API/worker deployments.
- Persist share tokens as a lookup hash plus an encrypted recoverable value for the host-facing share link; do not store the recoverable token as plaintext.
- Enforce strict public-asset revocation: hidden, deleted, disabled, or expired media must stop being retrievable even through a previously known URL.
- Evaluate libvips first for the native media pipeline and require parity tests before replacing the current Java implementation.
- Use npm and the Angular CLI for frontend work. The wireframe/design pause has been lifted.
- Serve the SPA and the API from a single origin; do not reintroduce a split `api.`/`app.` topology while session cookies remain `SameSite=Lax`.
- Backend DTOs are authoritative for every wire shape. The frontend adapts; do not change a backend record to match a hand-authored TypeScript model.

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
- Frontend:
  - `cd frontend && npm ci`
  - `npm start` (dev server on 4200; proxies `/api`, `/login/oauth2`, `/actuator` to 8080)
  - `npm run lint`
  - `npm test -- --watch=false --browsers=ChromeHeadless`
  - `npm run build -- --configuration production`
  - `npm run e2e` (builds the backend jar, then Playwright boots API + SPA itself)
- Full stack:
  - `docker compose up -d` from the repo root after building both artifacts

## Frontend Status

### Implemented

- Angular 19 standalone-component application with signals, lazy-loaded host and guest feature routes, a shared component library under `src/app/shared/components`, and guest-only screen components under `src/app/features/guest/components`.
- Host surface: magic-link and Google sign-in, event list/create/edit, event overview, QR/share dialog, moderation grid, and export create/poll/download.
- Guest surface: share-link resolution, display-name join, camera-roll upload with progress and retry, live gallery, and photo viewer.
- Typed API models in `src/app/core/models` mirroring the backend records exactly, with shared typed fixtures in `src/testing/fixtures.ts`.
- Interceptor chain `credentials -> csrf -> challenge`:
  - CSRF sends the raw `XSRF-TOKEN` cookie value; `GET /api/v1/csrf` is only a cookie bootstrap because `SpaCsrfTokenRequestHandler` resolves a header-borne token with the plain handler while the body token is XOR-masked
  - the challenge interceptor renders Turnstile from the `siteKey` in the backend's 403 problem body and retries once with `X-Challenge-Token`
- Uploads branch on `UploadInitResponse.mode`; multipart slices the file by `partSizeBytes`, uploads contiguous 1-based parts with bounded concurrency, and preserves provider ETags verbatim.
- SSE registers a listener per named backend event and treats the payload as a bare photo UUID: removals apply locally, additions and unhides resync the feed head, bursts are coalesced, and reconnects resync from REST.
- Self-contained QR rendering via bundled `qrcode-generator`; nothing is fetched from a CDN.
- Media bindings guard the null `imageUrl`/`thumbnailUrl` the backend returns for unprocessed and failed photos.
- `IconComponent` wraps its geometry in `bypassSecurityTrustHtml`. This is load-bearing, not a shortcut: Angular's HTML sanitizer allowlists HTML elements only, so an unwrapped `[innerHTML]` binding strips every `path`/`circle`/`rect` and renders empty `<svg>` boxes app-wide. The bypass is safe because `name` is only a lookup key into a fixed constant map and an unknown key yields an empty string. `icon.component.spec.ts` asserts on the rendered DOM, not on the string map, because a map-only assertion is what let the original bug ship green.
- Guest upload availability is a rendered state, never an absence. When `uploadsOpen` is false the guest page explains why (scheduled, closed, expired) and, for a scheduled window, when uploads open; it also re-reads the event at the next lifecycle boundary within a two-hour horizon so the CTA appears without a reload.
- Every rendered control does something. The host uploads switch PATCHes `manualOverrideState` (`FORCE_OPEN`/`FORCE_CLOSED`) and takes its state from the response; Preview opens the real guest URL; the guest top bar shares via `navigator.share` with a clipboard fallback and opens the QR dialog; the photo viewer offers only Save, because reactions have no backend contract.
- The host surface renders real counts. Event detail reads `GET /api/v1/host/events/{eventId}/stats`, the event list reads the batched `GET /api/v1/host/events/stats` and keys it by `eventId`, and a failed counts request degrades to zeros without taking the page down. The "Today" tile is now "Last 24h" to match the backend's rolling window, and the "Viewing now" tile is gone: no endpoint exposes SSE subscriber counts.
- A returning guest is resumed, not re-asked. `guest-event` calls `GuestSessionService.resume()` on load, which reads the `event_capture_guest` cookie through the read-only `GET .../guest-session`; a `204` is the ordinary first-visit answer and falls through to the join screen.
- Component inputs that drive layout must be asserted on the measured box. `app-button`'s `fullWidth` was styled with `:host([fullWidth])`, an *attribute* selector, while all twelve call sites bind the *property* `[fullWidth]="true"` - Angular never reflects that to an attribute, so every "full width" button silently shrink-to-fit, including the login and guest-join CTAs. It is now a host class binding (`[class.full-width]`), and `button.component.spec.ts` asserts the rendered width against a fixed-width parent.
- Responsive rules for a page belong in one `@media` block at the bottom of its stylesheet, not nested per rule: each nested `@media` re-emits its whole selector chain, and `event-detail.component.scss` (5.29 kB) is the largest component stylesheet and the closest to the 6 kB component-style warning. The host top bar has the same responsive treatment on all five host pages (shrinkable left side, truncated breadcrumb with the trail hidden, tightened padding); it is copy-pasted rather than shared, so a change to one belongs in all five.
- Component styles must not use bare element selectors when the same tag is nested in the template. Emulated encapsulation rewrites `span { … }` to `span[_ngcontent-x]`, which still matches every descendant `span` in the component - it is scoped to the component, not to one element. `badge.component.ts` hit this: the badge's `padding: 4px 10px` landed on the nested status dot, whose `width: 7px` then floored at the padding under border-box sizing and rendered a 20x8 pill instead of a 7px circle. Use `:host > span`. The badge spec asserts the dot's measured box, because class-presence assertions cannot see this class of bug.
- Every grid track is `minmax(0, …)` and every element rendering user input has `overflow-wrap: anywhere`. A bare `fr` floors at min-content, so one unbreakable string drags the track past the viewport - the measured cause of event detail's 553px horizontal scroll at 412px wide. `event-list`, `event-form` and `event-settings` now use `minmax(0, …)` throughout, and the guest event title (rendered twice, at 36px and 27px) plus the photo viewer's contributor name wrap rather than overflow. Prefer `overflow-wrap: anywhere` over `break-word`: only `anywhere` also zeroes the intrinsic min-content width, which is what lets a flex chain shrink without a `min-width: 0` on every ancestor.
- The `event-list` grid was **not** in fact broken, contrary to an earlier note here. `.event-card`'s `overflow: hidden` already zeroes the card's automatic minimum size, and the page was measured at zero overflow with a bare `1fr`. But that rule exists to clip the cover's rounded corners, not to hold the layout together: flipping it to `overflow: visible` puts the page at a measured 129px of horizontal scroll. The `minmax(0, …)` there is deliberate hardening against that coupling, not a bug fix.
- The `anyComponentStyle` budget is `6 kB` warning / `10 kB` error, raised from `4 kB`/`8 kB`. The old 4 kB warning had been permanently exceeded by two ordinary page stylesheets, so it had stopped being signal. After the guest-page split (below) the production build is clean with zero budget warnings; the largest remaining stylesheet is `event-detail` at 5.29 kB, ~0.7 kB under the warning, so the next file to cross 6 kB is the one the warning is there to catch. Do not restore the 4 kB warning: it flagged files that were fine and trained everyone to ignore it.
- The guest event page was split before the budget was raised, not instead of it. `guest-event.component.ts` was one component rendering five distinct screens, and its stylesheet was 7.99 kB - 2.1x the median page and one declaration from failing the build. The join screen, upload sheet and photo viewer are now standalone components under `features/guest/components/` with inline styles, each well under 3 kB, and the parent keeps only the gallery/home shell (3.62 kB). The split conserves total bytes exactly; it buys a maintainable ceiling, and the raised budget buys ordinary working room on top.

### Testing

- 375 Karma/Jasmine specs: services, interceptors, guard, all shared components, all nine feature pages, the three extracted guest components (`guest-join`, `guest-upload-sheet`, `guest-photo-viewer`), plus `src/app/core/integration/` covering router + guard + interceptor seams together.
- 46 Playwright end-to-end runs (23 specs across the desktop and mobile projects; 43 pass and the 3 phone-viewport specs are skipped on desktop), run against a real backend in the documented Redis-free local mode (H2, in-process jobs, local storage, `challenge.mode=off`, `auth.debug-token-exposure=true` so a host can sign in without SMTP).
- Horizontal-scroll coverage is `expectNoHorizontalScroll(page, label)` in `e2e/support/api.ts`, asserted on the `mobile` project for event detail, the event list, the create form, the guest join screen and the guest gallery. All five seed `UNBREAKABLE_TITLE`, a title with **no spaces and no hyphens** - a browser breaks after either one unprompted, so a friendlier-looking title passes against broken CSS and proves nothing. This is the guard for a whole class of bug the component specs cannot see: a Karma fixture root is not viewport-constrained and media queries key off the real window width.
- Every `signInHost` both requests **and consumes** a magic link, and the two are separate abuse operations. `playwright.config.ts` has to raise `magic-consume.ip.hard-deny-after` as well as the `magic-request` limits; without it the suite silently runs out of sign-ins partway through the second project and every later host test bounces to `/host/login` with no 429 anywhere to explain it.
- `signInHost` therefore asserts **both** the consume response status and a follow-up `GET /api/v1/auth/me`, and neither replaces the other. `AuthController.completeMagicLink` enforces abuse before its try/catch, so a denial answers 429 `problem+json` instead of redirecting (caught by the status); an invalid or expired token redirects to an ordinary 200 failure page (caught only by the session check). Both were verified by temporarily lowering `magic-consume.ip.hard-deny-after` to 3 and confirming the suite fails *inside* `signInHost` naming `abuse-limit-exceeded` and `retryAfterSeconds`, rather than bouncing a later test to `/host/login`. Any newly added per-IP abuse operation will now surface here instead of hiding.
- `npm run e2e` does not run on Windows (`e2e:backend` is `cd ../backend && ./gradlew bootJar -q`, which cmd.exe rejects). Build the jar from a POSIX shell and run `npx playwright test`.
- Playwright's `reuseExistingServer` is on whenever `CI` is unset, so a `docker compose` stack holding port 8080 will silently absorb the whole suite. Stop it before running e2e locally.
- `e2e/api-contract.spec.ts` asserts backend field names, enum values, unknown-field rejection, and the raw-versus-masked CSRF token behavior against the live API. Extend it whenever a new endpoint is consumed.

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
  - `APP_AUTH_SUCCESS_PATH` with deprecated `APP_OAUTH_SUCCESS_PATH` fallback, `APP_AUTH_FAILURE_PATH`, and `APP_AUTH_ALLOWED_RETURN_PATH_PREFIXES`
  - `APP_AUTH_DEBUG_TOKEN_EXPOSURE=false` by default
  - `APP_HTTP_TRUSTED_PROXY_CIDRS`
  - `APP_ABUSE_KEY_SECRET` and typed `APP_ABUSE_OPERATIONS_*` thresholds
  - `APP_TURNSTILE_SITE_KEY`, `APP_TURNSTILE_SECRET`, `APP_TURNSTILE_EXPECTED_HOSTNAME`, verification URL, and timeout
  - `APP_MAIL_FROM`, `APP_SMTP_*` transport settings/timeouts, and optional complete `APP_GOOGLE_*` OAuth settings
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
- `APP_STORAGE_R2_PRESIGN_TTL` is the maximum for upload presigns and export download presigns; export URLs may be shorter when archive or event-retention lifetime is lower.
- The opt-in live R2 smoke test is enabled with `EVENT_CAPTURE_LIVE_R2_SMOKE=true` and reuses the existing `APP_STORAGE_*` R2 variables.

## Next Likely Work

- Finish the Docker-backed Phase 6 exit gates: full PostgreSQL/Redis/MinIO tests, Phase 4 process recovery, OpenAPI, production configuration, and Prometheus rule checks. Do not mark Phase 6 complete before those gates pass.
- After Phase 6 verification closes, the next backend work is the Phase 8/9 delivery-confidence gap set.
- Use `.agents/docs/PHASE3_RELEASE.md` only if a future environment must upgrade existing pre-V6 data. The current undeployed greenfield environment migrates directly through V8 with the configured keyring and both maintenance flags disabled.
- Preserve the completed Phase 1 through Phase 5 runtime, security, resilience, auth, and abuse gates; keep the full backend, OpenAPI, and Phase 4 process checks passing after every backend phase.
- Queued work, in the order it is most likely to be picked up:
  - **Add an event cover contract to the backend.** `Event` has no cover field, so `CreateEventRequest`/`UpdateEventRequest`/`EventResponse`/`EventSummaryResponse`/`PublicEventResponse` carry nothing to render, and both the host event cards and the guest join hero fall back to a deterministic decorative wash. Decide first whether a cover is a host-uploaded image (which needs an upload intent, a variant kind, storage keys, and the same hide/delete/expiry revocation rules as guest photos) or a chosen theme/palette token (a single enum column, no storage, no revocation surface). The theme route is far cheaper and covers the actual product need; only take the image route if hosts must supply their own photo.
  - **Make the top-left wordmark a real home link.** `wordmark.component.ts` renders a bare `<span>OurRoll</span>` with no anchor, no route, and no logo mark, and it sits in the top bar of every host page plus the guest header. There is no affordance to get back: the host event-detail and moderation pages rely entirely on the small breadcrumb, and event-settings only has a back-link to its own event. Give the wordmark an optional `routerLink` (host pages to `/host/events`; the guest header should stay inert, since a guest has nowhere to navigate to) with focus-visible styling and a real hit area, and consider pairing the text with an actual logo mark.
  - The `anyComponentStyle` budget question is **resolved**: the guest page was split into `guest-join`, `guest-upload-sheet` and `guest-photo-viewer` under `features/guest/components/`, and the budget was raised to `6 kB` warning / `10 kB` error. `event-detail.component.scss` (5.29 kB) is the only remaining warning and is deliberately left as the watch line. No further action is queued here.
  - **`npm run e2e` does not work on Windows.** The `e2e:backend` script is `cd ../backend && ./gradlew bootJar -q`, which cmd.exe cannot run, so the command fails before Playwright starts. Run `./gradlew bootJar` from a POSIX shell and then `npx playwright test`, or make the script cross-platform.
  - the compose stack has not been exercised against real R2, SMTP, Turnstile, or Google OAuth credentials; only the local-mode stack has been run end to end
  - accessibility review (focus order, reduced motion, screen-reader labelling) has not been completed
