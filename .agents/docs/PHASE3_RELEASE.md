# Phase 3 Rolling Release Runbook

## Release A

Release A is additive and is represented by Flyway V4. It creates the effective-dated global retention settings table, seeds the 365-day default, adds lifecycle/token-encryption columns, and creates compound feed and maintenance indexes. Application nodes dual-write encrypted and legacy recoverable share tokens, read ciphertext first, and fall back to plaintext for rolling compatibility.

Configure every node with:

- `APP_SHARE_TOKEN_ACTIVE_KEY_ID`
- `APP_SHARE_TOKEN_KEYRING` containing the active AES-256 key and every older key ID still referenced by rows
- `APP_SHARE_TOKEN_BACKFILL_ENABLED=false` during normal service startup

Deploy Release A to API and worker roles, run the complete backend/OpenAPI checks, then run one controlled node with `APP_SHARE_TOKEN_BACKFILL_ENABLED=true`. The runner encrypts missing rows and re-encrypts old-key rows in bounded, idempotent batches. It logs counts only.

Retention is database-managed. Operations change the policy by inserting a new positive-duration row with a unique future/effective timestamp. Never update a historical row: closure chooses the version effective at that instant and snapshots the applied days and expiry on the event.

## Legacy close-time assignment

Run `backend/scripts/phase3-release-b-preflight.sql`. The null-close query is an operations work queue, not permission to infer dates. Assign an explicit `scheduled_upload_close_at` to every row using authoritative operational/product data. Do not automatically close or guess legacy events.

## Release B gate

Release B must not be created or deployed until all of these are true in the target database:

1. Zero events have a null scheduled close time.
2. Zero events lack ciphertext or key ID.
3. Every distinct stored key ID is present in the deployed keyring.
4. API and worker nodes in the fleet can read every encrypted share token.
5. A current backup and restore point have been verified.

After the gate, create the next Flyway migration from the reviewed statements in the preflight script: make close/ciphertext/key-ID columns non-null and drop `share_token_value`. Deploy code that removes dual-write/plaintext fallback in the same coordinated release. Regenerate OpenAPI and current-state guidance only after that deployment succeeds.

## Key rotation

Add the new key while retaining all old keys, switch the active ID, deploy all nodes, and run the same bounded backfill. Remove an old key only after its database count is zero and all nodes have the replacement keyring. Ciphertext, plaintext tokens, keys, and complete share URLs must never enter logs, tickets, or command output.

## Rollback

Before Release B, rolling back application nodes is safe because Release A retains plaintext and additive columns. After Release B, old nodes are schema-incompatible; roll back by restoring the coordinated application/database release according to the migration runbook, not by reintroducing token plaintext ad hoc.