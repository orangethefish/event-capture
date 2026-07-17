# Wedding Event Capture App Plan

## Summary

- Build a mobile-first web app for weddings where hosts create events, share a QR code or link, guests enter a display name, upload photos directly to Cloudflare R2, and view a live gallery during the event.
- Use modern Angular for the frontend, Spring Boot for the backend, PostgreSQL for relational data, Cloudflare R2 for object storage, and Server-Sent Events for live gallery updates.
- Ship only the core product surfaces in v1: guest event page and host dashboard. Do not build a full marketing site or a separate post-event gallery product in v1.
- Apply the Claude-inspired warm editorial design language to guest-facing event surfaces; keep the host dashboard more restrained and operational. Use open-source font approximations rather than licensed commercial fonts.

## Implementation Changes

### Frontend architecture

- Build a separate Angular app that talks to a Spring Boot JSON API.
- Optimize the guest event page for mobile camera uploads and fast gallery browsing.
- Make the first screen upload-first, with the live gallery directly below the primary upload controls.
- Support host dashboard flows for multiple events per account, event creation and editing, live moderation, download and export, and upload-window settings. Retention is a global operations-managed policy.

### Backend architecture

- Use one Spring Boot codebase with two deployment roles: `api` and `worker`.
- The `api` role handles auth, event CRUD, guest sessions, upload init and finalize, gallery reads, SSE streams, moderation, and export requests.
- The `worker` role handles thumbnail and web-variant generation, EXIF stripping for public variants, and archive export jobs.
- Use PostgreSQL for hosts, events, guest sessions, photos, photo variants, moderation actions, and export jobs.

### Auth and session model

- Support host auth with email magic link plus Google OAuth.
- Use HttpOnly secure session cookies for host API authentication.
- Let guests join without accounts using a display name only, then persist that event-scoped guest session with a cookie on the same device.
- Deploy frontend and API under the same parent domain so cookie auth and SSE remain straightforward.

### Upload and storage flow

- Upload from the browser directly to R2 using short-lived presigned PUT URLs issued by Spring Boot.
- Generate storage keys on the backend; clients must never choose final object keys.
- Use a two-step upload flow:
  - `init` returns signed upload details.
  - `finalize` verifies the uploaded object and creates the photo record.
- Store originals privately in R2 and serve only processed variants to the public gallery.

### Security controls

- Enforce an image-only MIME allowlist and file-size caps at upload init and finalize.
- Rate-limit guest join and upload actions per event, session, and IP.
- Trigger an extra challenge only when behavior looks suspicious.
- Restrict R2 CORS to the frontend origin and the required methods and headers.
- Strip EXIF metadata from public variants only; keep originals intact for host export.
- Support only basic moderation in v1: hide, unhide, and delete.

### Event lifecycle and privacy

- Give events scheduled upload open and close times plus manual host override.
- Default to link-based privacy: anyone with the event link or QR can view and upload.
- Require every new event to have a scheduled upload close time. Persist the global, effective-dated retention policy applied when uploads close; seed 365 days and do not expose a host override.
- After uploads close, keep viewing available until retention expiry unless the host disables it.

## Public APIs and Interfaces

### Host routes and API

- Magic link sign-in flow.
- Google OAuth sign-in and callback flow.
- Event list, create, update, and settings endpoints.
- Photo moderation endpoints for hide, unhide, and delete.
- Export job create and status endpoints.

### Guest routes and API

- Public event route by share slug.
- Guest session create or resume endpoint for display name capture.
- Upload init endpoint returning presigned R2 upload details.
- Upload finalize endpoint that validates the stored object and creates the photo record.
- Public gallery read endpoint returning visible processed variants only.
- SSE endpoint streaming new-photo and moderation-change events for the event.

### Core domain types

- `Host`
- `Event`
- `GuestSession`
- `Photo`
- `PhotoVariant`
- `ModerationAction`
- `ExportJob`

## Test Plan

### Host auth

- Magic link login works end to end.
- Google OAuth login works end to end.
- Host session cookie persists and protects dashboard and API routes.

### Guest flow

- QR or link entry creates or resumes an event-scoped guest session.
- Guest can upload from camera and device library on mobile browsers.
- Guest session survives a page revisit on the same device.

### Upload pipeline

- Signed R2 upload works with valid image types and fails for invalid MIME or oversize files.
- Finalize rejects missing, mismatched, or tampered uploads.
- Worker generates gallery variants and strips EXIF from public images.

### Live gallery

- New uploads appear via SSE for guests and hosts without refresh.
- Hidden or deleted photos disappear from guest responses and live updates.

### Host operations

- Host can create multiple events.
- Host can open or close uploads manually and schedule upload windows.
- Host can request a download-all export and retrieve the completed archive.

### Security and privacy

- Guests cannot access host endpoints.
- Hosts cannot access other hosts' events.
- R2 objects are not publicly writable or listable.
- Suspicious upload behavior triggers the extra challenge flow.

## Assumptions and Defaults

- The first target is weddings, but the data model stays generic enough for other event types later.
- v1 supports photos only, not video, comments, reactions, guest-original downloads, or collaborator hosts.
- There is no separate marketing site requirement in v1 beyond minimal entry and sign-in pages.
- Design artifacts, including typography, theme, and cover-photo contracts, remain pending product-owner approval; do not infer them from deleted drafts.
- Use a dense masonry-style gallery for browsing, but keep upload controls visually dominant on the guest page.
- Keep one Spring Boot repository and codebase for API and worker roles; do not split into separate services in v1.
