# Phase 3 Greenfield Status and Conditional Pre-V6 Upgrade Runbook

## Applicability and current status

No release or application database has been deployed for the current target. Phase 3 is complete for this greenfield path: configure the same approved keyring on API and worker roles, keep both maintenance flags disabled, and let Flyway migrate the fresh database directly through V6 on the first deployment. No legacy preflight, backfill, maintenance window, or A-to-B cutover is pending.

The remainder of this document is conditional. Use it only if a future environment already contains pre-V6 Release A data. In that case, Release A is rolling-compatible but Release B is intentionally non-rolling: Release A binaries cannot run after V6 drops `share_token_value`, and Release B binaries cannot create events before V6 because the legacy plaintext column is still non-null.

## Required configuration

Configure API and worker roles with the same deployment-approved keyring:

- `APP_SHARE_TOKEN_ACTIVE_KEY_ID`
- `APP_SHARE_TOKEN_KEYRING`, loaded from the deployment secret store and containing every key ID still referenced by an event
- `APP_SHARE_TOKEN_BACKFILL_ENABLED=false` during normal startup
- `APP_SHARE_TOKEN_RELEASE_B_PREFLIGHT_ENABLED=false` during normal startup
- `APP_SHARE_TOKEN_BACKFILL_BATCH_SIZE=100` or another reviewed value from 1 through 1000

Backfill and preflight are mutually exclusive; startup fails if both flags are enabled. Logs, evidence, tickets, and command output may contain aggregate counts and key IDs only. Never include raw tokens, ciphertext, share URLs, key bytes, or provider exception text.

## Existing pre-V6 data only: Stage A readiness patch and data gate

1. Deploy the readiness patch to every Release A API and worker node.
2. Start one controlled node with backfill enabled. It validates `SHA-256(recoveredToken) == share_token_hash` before encrypting or rotating each bounded batch. A mismatch, unknown key, missing material, or decryption failure aborts the transaction with a token-safe error.
3. Stop that node or disable backfill after it reports zero remaining rows.
4. Run `backend/scripts/phase3-release-b-preflight.sql`. The script is read-only and returns only safe operational fields, counts, and referenced key IDs.
5. Run a separate controlled node with `APP_SHARE_TOKEN_RELEASE_B_PREFLIGHT_ENABLED=true` and the deployment-equivalent API keyring. Repeat with the worker keyring. The application scans in bounded UUID keyset batches, decrypts every token, verifies its lookup hash, and fails startup unless every error count is zero.
6. Assign every missing `scheduled_upload_close_at` from authoritative product or operations data. Never infer, regenerate, or automatically update a close time or share token.
7. Let lifecycle maintenance snapshot already-due non-`FORCE_OPEN` closures. Rerun the SQL and both application preflights.
8. Verify a current PostgreSQL snapshot and an isolated restore.
9. Record the zero-count outputs, configured key IDs, application version, and backup identifier as Release B approval evidence.

Any corrupt, undecryptable, hash-mismatched, or unknown-key row blocks the cutover. Recover it from authoritative data or the verified backup; never rotate it to a new raw token automatically.

## Existing pre-V6 data only: Stage B coordinated V6 cutover

1. Enable maintenance mode and stop every Release A API and worker node.
2. Rerun the final SQL and application preflight against the frozen database.
3. Take and identify the final encrypted backup or restore point.
4. Start one Release B worker so it acquires Flyway's migration lock and applies `V6__phase3_release_b.sql`.
5. Verify migration success and worker readiness before starting additional workers.
6. Start API instances, verify readiness, and then restore traffic.
7. Smoke-test an existing share link, host event retrieval, public event lookup, guest join, new event creation, and physical absence of `events.share_token_value`.
8. Monitor decryption failures, host-event 5xx responses, readiness, and Flyway logs.

V6 makes scheduled close time, ciphertext, and key ID non-null; rejects blank encrypted fields and invalid upload windows; and drops plaintext storage. Public paths and response shapes do not change. Existing links continue to resolve through `share_token_hash`, and host `sharePath` decrypts the original token.

## Key rotation after Release B

Add the replacement key while retaining every old referenced key, switch the active ID, deploy all nodes, and run the bounded backfill. Post-B backfill selects only rows whose key ID differs from the active key and decrypts ciphertext only. Remove an old key only after its database row count is zero. Normal startup fails if any event references an absent key.

## Existing pre-V6 data only: rollback

Before V6, roll back to the Release A readiness binary while retaining the full keyring. After V6 or the Release B binary fails, stop Release B, restore the identified pre-cutover database snapshot, and start the Release A binary with the full old keyring. Do not create a down migration, re-add `share_token_value`, or reconstruct plaintext manually.
