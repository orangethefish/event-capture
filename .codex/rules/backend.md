# Event Capture Backend Rules

- Treat `backend/` as the source of truth for the current implementation.
- Treat `.codex/docs/BACKEND_IMPLEMENTATION_PLAN.md` as the target architecture, not the current runtime behavior.
- Keep the distinction between host and guest access intact:
  - Hosts authenticate with session-backed `ROLE_HOST` access.
  - Guests use an event-scoped cookie session and do not have accounts.
- Preserve the share-link contract:
  - Host responses expose `/events/{slug}/{shareToken}` via `sharePath`.
  - Public APIs live under `/api/v1/public/events/{slug}/{shareToken}/...`.
- Do not assume direct browser-to-R2 uploads exist yet. The current implementation uses backend `PUT` upload endpoints plus local filesystem storage.
- When changing gallery or asset behavior, preserve all of these checks together:
  - photo readiness
  - photo visibility
  - gallery enabled
  - retention not expired
- Check auth and security routes carefully before editing them. There is a current CSRF route mismatch between controller and security config that should not be widened accidentally.
- Use Context7 for library-specific changes involving Spring Boot, Spring Security, Spring Data JPA, Flyway, Redis, OAuth, or storage SDKs.
- Validate meaningful backend changes with `cd backend && ./gradlew test`. Use at least `./gradlew compileJava` for narrow changes when full tests are unnecessary.
