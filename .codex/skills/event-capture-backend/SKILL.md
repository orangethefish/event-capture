---
name: event-capture-backend
description: Backend implementation, extension, debugging, and review guidance for the Event Capture Spring Boot repo. Use when working in this repository's `backend/` code on auth, sessions, events, guest flows, uploads, gallery, moderation, exports, Flyway/JPA, security, or the project-specific gap between the current local inline implementation and the planned R2/Redis/worker architecture.
---

# Event Capture Backend

Use this skill when the task is about the Event Capture backend in this repository, not generic Spring Boot work. It adds repo-specific architecture, invariants, file locations, and known traps that are easy to miss when reading the code cold.

## Workflow

1. Read `AGENTS.md` first for the repo's current backend status and commands.
2. Read `.codex/docs/BACKEND_IMPLEMENTATION_PLAN.md` only when the task touches planned but not yet implemented behavior.
3. Use Context7 before making library-specific changes involving Spring Boot, Spring Security, Spring Data JPA, Redis, OAuth, Flyway, or cloud/storage SDKs.
4. Load only the relevant reference file:
   - `references/backend-state.md` for current implementation status, environment details, and known traps.
   - `references/domain-rules.md` for event, auth, upload, gallery, moderation, and privacy invariants.
   - `references/code-map.md` for the fastest path to the relevant files.
5. Keep changes aligned with the current inline/local implementation unless the user explicitly asks to move the code toward the planned R2/Redis/worker target.
6. Validate with `cd backend && ./gradlew test` after meaningful backend changes. Run at least `./gradlew compileJava` if the task is too narrow for the full test suite.

## Project-Specific Rules

- Treat `.codex/docs/BACKEND_IMPLEMENTATION_PLAN.md` as the target architecture, not the current implementation.
- Treat `backend/` as the source of truth for what actually runs today.
- Preserve the distinction between:
  - Host auth: session-backed `ROLE_HOST` access.
  - Guest auth: event-scoped cookie session with no account.
- Preserve the share-link model:
  - Host-facing `sharePath` is `/events/{slug}/{shareToken}`.
  - Public APIs live under `/api/v1/public/events/{slug}/{shareToken}/...`.
- Do not assume direct browser-to-R2 uploads exist yet. Current upload binaries pass through backend `PUT` endpoints and land in local filesystem storage.
- When changing gallery or asset behavior, preserve moderation, readiness, retention, and gallery-enabled checks together.
- When changing auth/security routes, check `references/backend-state.md` for known route mismatches and conditional OAuth wiring.
