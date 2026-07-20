# Phase 4 Resilience and Realtime Proof

## Completion scope

Phase 4 is complete for the backend scope approved on 2026-07-20: process-level crash/restart and Redis-interruption testing, live SSE disconnect/resync proof, storage-side-effect idempotency auditing, and deployment-owned alerts. Broader dashboards and browser/client implementation remain later-phase work.

## Process crash and Redis interruption proof

Run from `backend/`:

```text
./gradlew phase4ProcessTest
```

`Phase4ProcessRecoveryIntegrationTest` starts PostgreSQL and AOF-backed Redis containers, then launches API and worker roles as child operating-system JVM processes. A test-only primary `JobCrashCheckpoint` halts a child with no shutdown hooks at explicit boundaries; the production bean is a no-op.

The suite proves these externally ambiguous boundaries:

- Redis `XADD` succeeds and the API process halts before the PostgreSQL outbox row is marked published. Restart republishes the row, demonstrating at-least-once delivery without losing committed work.
- A worker handler commits and the worker process halts before `XACK`. A fresh worker reclaims the pending records after the configured idle interval and drains duplicate work safely.
- Redis is stopped while API and worker JVMs remain running. Readiness becomes unhealthy, a new outbox row remains recoverable in PostgreSQL, Redis restarts at the same endpoint with AOF state, readiness recovers, and the held row is published and consumed.

Checkpoint seams also exist immediately after stream delivery, retry-outbox persistence, and dead-letter publication so later handler-specific fixtures can halt at those exact boundaries without adding production crash behavior.

The test discovered and now prevents a restart defect: an existing consumer group previously left its bootstrap record in the stream after `BUSYGROUP`, creating a malformed permanently pending message. Bootstrap deletion now runs in `finally`, and worker-loop failures are logged while unacknowledged records remain recoverable.

## Live SSE disconnect and resync proof

`DistributedRuntimeIntegrationTest` now uses command-line property overrides so its separate API and worker contexts genuinely share Testcontainers PostgreSQL and Redis rather than silently falling back to H2/local mode.

The test opens a real HTTP `text/event-stream` connection on API A while API B performs uploads and moderation. It proves cross-instance Redis pub/sub delivery of `photo_ready` and `photo_hidden`, closes the stream, performs `photo_unhidden` while disconnected, restores current state from the public REST photo feed, reconnects to API A, and observes `photo_deleted`. SSE remains a state-change hint; REST is authoritative after every reconnect.

## Storage-side-effect idempotency audit

| Boundary | Stable identity or recovery action | Proof |
| --- | --- | --- |
| Media variant write before photo/variant commit | Per-photo deterministic gallery and thumbnail object keys; pessimistic photo lock serializes duplicate delivery | `MediaProcessingServiceTest` replays after a partial write and verifies identical keys |
| Terminal media failure after an uncommitted write | Delete the complete `variants/{eventId}/{photoId}/` prefix before marking failed | Focused terminal-failure unit test |
| Deleted-photo or retained-event purge with an orphan object absent from database rows | Delete deterministic photo/event variant and export prefixes, not only paths recorded in rows | Retention cleanup unit/integration coverage |
| Export archive write before export-row commit | Deterministic `exports/{eventId}/{exportId}.zip` key, pessimistic export lock, and deterministic-key cleanup on terminal failure | `ExportArchiveServiceTest` |
| Multipart completion response lost after provider commit | Treat `NoSuchUpload`/404 as already completed only when `HEAD` confirms the final object | `R2ObjectStorageServiceTest` plus S3-compatible coverage |
| Outbox publish, handler commit, retry persistence, or DLQ write before acknowledgement | PostgreSQL outbox and Redis pending entries are replay sources; handlers and storage keys are duplicate-safe | Unit relay coverage and child-process recovery suite |

DLQ entries may duplicate if a process dies after DLQ publication and before acknowledgement. Operators should deduplicate investigation by job type, target ID, and attempt; they must not delete pending/outbox state merely to clear an alert.

## Deployment-owned alerts

Prometheus rules and executable rule tests live in:

- `backend/deploy/prometheus/event-capture-alerts.yml`
- `backend/deploy/prometheus/event-capture-alerts.test.yml`

They cover stalled/high outbox backlog, pending jobs, DLQ depth, retry storms, terminal failures, outbox publication failures, slow handler p95 latency, and missing queue metrics. CI runs pinned Prometheus `v3.5.0` `promtool check rules` and `promtool test rules`; the rules are imported by the deployment monitoring stack rather than embedded in application code.

Queue recovery timings are deployment-configurable through `APP_JOBS_OUTBOX_RELAY_DELAY`, `APP_JOBS_RECLAIM_IDLE`, and `APP_JOBS_QUEUE_MONITOR_DELAY`. Keep reclaim idle above normal healthy handoff time; the one-second value is reserved for deterministic recovery tests.