# Phase 5 Authentication and Abuse-Control Evidence

## Delivered behavior

- Email links now target `GET /api/v1/auth/magic-link/complete`; the original JSON/session
  `consume` endpoint remains compatible. Browser completion always returns a token-free `303`
  success or fixed failure destination with `Cache-Control: no-store` and
  `Referrer-Policy: no-referrer`.
- Magic-link return paths are allowlisted, persisted by Flyway V7, and consumed under a
  pessimistic token-row lock. Expiry is inclusive, replay is rejected, successful consume
  creates the normalized `MAGIC_LINK` identity if needed, and controller-managed login rotates
  a pre-authentication session ID before saving `ROLE_HOST`.
- Google login remains conditional. It uses Spring Security's authorization-code/state flow,
  keeps a bounded state-to-return-path map in the Redis-backed HTTP session, and clears pending
  state on terminal success/failure. Only registration `google` with nonblank `sub`, normalized
  email, and `email_verified=true` is accepted. Provider identity resolution remains anchored to
  `sub` after first login.
- The old direct service-level rate-limit calls and placeholder risk policy are removed. A single
  operation-aware abuse service now uses exact rolling windows in local mode and atomic Redis
  sorted-set scripts in redis mode. Every subject is HMACed before it enters a counter or
  clearance key.
- Challenge clearance lasts 15 minutes and is bound to operation family, client IP, event, and
  guest/email subject. Hard caps are always evaluated first and the longest blocking retry is
  returned in `Retry-After` and `retryAfterSeconds`.
- Turnstile verification distinguishes valid, invalid, and dependency-unavailable outcomes,
  validates hostname and action with bounded HTTP timeouts, and fails closed with a retryable
  `503` when the provider cannot be reached.
- Client IP resolution trusts `X-Forwarded-For` only from configured IPv4/IPv6 CIDRs and walks
  the chain from right to left. Malformed, oversized, or overlong chains fall back to the socket
  peer.

## Balanced abuse thresholds

| Operation / dimension | Window | Challenge after | Hard deny after |
| --- | ---: | ---: | ---: |
| Magic request / normalized email | 15 minutes | 2 | 5 |
| Magic request / client IP | 1 hour | 10 | 20 |
| Magic consume / client IP | 10 minutes | - | 30 |
| OAuth start / browser session | 10 minutes | - | 20 |
| OAuth start / client IP | 1 hour | - | 60 |
| Guest join / event + IP | 10 minutes | 10 | 30 |
| Guest join / global IP | 1 hour | 30 | 100 |
| Upload init / event + guest | 10 minutes | 30 | 60 |
| Upload init / event + IP | 10 minutes | 100 | 300 |
| Upload init / event aggregate | 1 hour | - | 10,000 |
| Upload finalize / event + guest | 10 minutes | - | 120 |
| Upload finalize / event + IP | 10 minutes | - | 500 |
| Upload finalize / event aggregate | 1 hour | - | 10,000 |

## Production invariants

- `APP_BASE_URL` and `APP_FRONTEND_ORIGIN` are explicit HTTPS values; forwarded host/protocol
  never construct canonical URLs.
- Host, guest, and XSRF cookies use `Path=/`, `SameSite=Lax`, and secure production delivery.
  Host/guest cookies are HttpOnly; XSRF remains JavaScript-readable.
- SMTP, mail-from, Turnstile, trusted-proxy, and a deployment-specific abuse HMAC secret are
  mandatory on production API nodes. Google is optional, but ID, secret, and an explicit HTTPS
  callback URI form an all-or-nothing configuration.
- Provider credentials are passed only to the API service in production Compose. Worker nodes do
  not receive SMTP, Google, Turnstile, redirect, proxy, or abuse-control secrets.
- Startup validates syntax and invariants without contacting external providers. Staging owns
  live SMTP, Google, and Turnstile smoke checks.

## Verification evidence

- Focused unit/application tests cover redirect validation, exact expiry, identity linking,
  session rotation, public problem metadata, every balanced threshold, local rolling windows,
  trusted proxy chains, Turnstile classification, production configuration, CORS, and browser
  completion.
- An embedded signed OIDC provider exercises authorization redirect, state, token, JWKS,
  user-info, verified identity, denied consent, invalid claims, and safe redirects.
- PostgreSQL Testcontainers proves two concurrent consumes authenticate exactly once. Redis
  Testcontainers proves shared atomic counters, shared clearance, and identifier-free keys.
- Production Compose renders successfully with non-secret fixtures and rejects absent required
  public/auth settings.
- The canonical OpenAPI snapshot intentionally adds `MagicLinkRequest.returnPath` and
  `/api/v1/auth/magic-link/complete` while preserving existing route shapes.

The full Gradle, OpenAPI, Phase 4 recovery, formatting, and mirror-verification results are
recorded in the Phase 5 completion change and must remain green for subsequent phases.
