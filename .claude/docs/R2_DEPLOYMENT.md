# Cloudflare R2 Deployment Contract

## Delivery model

- Keep originals and processed variants in a private R2 bucket.
- Guests upload directly to presigned R2 S3 API `PUT` URLs.
- Production reads public variants through `GET /api/v1/public/assets/{publicToken}` so database visibility, event enablement, deletion, and retention checks enforce strict revocation.
- Leave `APP_STORAGE_PUBLIC_BASE_URL` empty in production. Startup rejects a non-empty value until a revocation-safe signed-edge or purge design is implemented.

## Required production configuration

- `APP_STORAGE_PROVIDER=r2`
- `APP_STORAGE_R2_BUCKET`
- `APP_STORAGE_R2_ACCESS_KEY`
- `APP_STORAGE_R2_SECRET_KEY`
- Either `APP_STORAGE_R2_ACCOUNT_ID` or an HTTPS `APP_STORAGE_R2_ENDPOINT`
- `APP_STORAGE_R2_PRESIGN_TTL` greater than zero and no longer than seven days
- `APP_MEDIA_PROCESSOR=libvips`
- Multipart part size of at least 5 MiB; the repository default is 5 MiB

Cloudflare R2 S3 access-key IDs are 32 characters and secret access keys are 64 characters. Never log either value or a presigned URL. Load each configured field directly; the opt-in live smoke workflow passes with the deployment-equivalent ignored `.env` configuration.

## Presigning compatibility

AWS SDK for Java v2 is configured with request checksum calculation and response validation set to `WHEN_REQUIRED`. This prevents an automatic full-object CRC32 upload checksum from being added to presigned R2 PUT requests. Upload finalize computes SHA-256 by streaming the stored object and compares it with the optional client checksum.

## Restrictive upload CORS

Use `backend/r2-cors.example.json` as the bucket CORS template. Before applying it:

1. Replace `https://app.example.com` with the exact `APP_FRONTEND_ORIGIN`.
2. Keep only `PUT` in `AllowedMethods`.
3. Keep `Content-Type`, `x-amz-content-sha256`, and `x-amz-security-token` as the only allowed headers unless a generated `requiredHeaders` response proves another signed header is required.
4. Keep `ETag` exposed because multipart completion needs each uploaded part's ETag.
5. Do not add public `GET` CORS for the R2 bucket; reads go through the backend authorization endpoint.

## Verification

Run the portable storage and full backend contracts:

```text
cd backend
./gradlew test --tests "com.eventcapture.backend.integration.S3CompatibleStorageIntegrationTest"
./gradlew spotlessCheck test
```

With deployment-equivalent R2 configuration loaded, run:

```text
EVENT_CAPTURE_LIVE_R2_SMOKE=true ./gradlew test --tests "com.eventcapture.backend.integration.LiveR2SmokeIntegrationTest"
```

The live test covers presigned single-part upload, multipart completion, asynchronous processing, export creation/read, multipart-intent cleanup, and retention cleanup. Its HTTP diagnostics expose only sanitized status, provider code, and provider message.