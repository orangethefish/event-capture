# Code Map

## Fast Entry Points

- App boot and config:
  - `backend/src/main/java/com/eventcapture/backend/EventCaptureBackendApplication.java`
  - `backend/src/main/java/com/eventcapture/backend/infra/config/AppProperties.java`
  - `backend/src/main/java/com/eventcapture/backend/infra/config/ApiSecurityConfig.java`
  - `backend/src/main/java/com/eventcapture/backend/infra/config/WorkerSecurityConfig.java`
  - `backend/src/main/java/com/eventcapture/backend/infra/config/SessionConfig.java`
  - `backend/src/main/java/com/eventcapture/backend/infra/config/LocalSessionConfig.java`
  - `backend/src/main/java/com/eventcapture/backend/infra/config/RedisSessionConfig.java`
  - `backend/src/main/java/com/eventcapture/backend/infra/config/RuntimeInfrastructureValidator.java`
  - `backend/src/main/java/com/eventcapture/backend/infra/config/InfrastructureHealthConfig.java`
  - `backend/src/main/resources/application.yml`
- Error handling:
  - `backend/src/main/java/com/eventcapture/backend/common/error/ApiException.java`
  - `backend/src/main/java/com/eventcapture/backend/common/error/ApiExceptionHandler.java`

## Feature Map

- Auth:
  - `backend/src/main/java/com/eventcapture/backend/auth/AuthController.java`
  - `backend/src/main/java/com/eventcapture/backend/auth/AuthService.java`
  - `backend/src/main/java/com/eventcapture/backend/auth/OAuth2LoginSuccessHandler.java`
- Host event APIs:
  - `backend/src/main/java/com/eventcapture/backend/host/HostController.java`
  - `backend/src/main/java/com/eventcapture/backend/event/EventService.java`
- Guest/public APIs:
  - `backend/src/main/java/com/eventcapture/backend/guest/PublicEventController.java`
  - `backend/src/main/java/com/eventcapture/backend/guest/GuestSessionService.java`
- Uploads and media:
  - `backend/src/main/java/com/eventcapture/backend/media/UploadService.java`
  - `backend/src/main/java/com/eventcapture/backend/media/MediaProcessingService.java`
  - `backend/src/main/java/com/eventcapture/backend/media/NativeSourceImageDecoder.java`
  - `backend/src/main/java/com/eventcapture/backend/infra/storage/LocalStorageService.java`
  - `backend/src/main/java/com/eventcapture/backend/infra/storage/R2ObjectStorageService.java`
- Gallery and SSE:
  - `backend/src/main/java/com/eventcapture/backend/gallery/GalleryService.java`
  - `backend/src/main/java/com/eventcapture/backend/gallery/GalleryEventBroker.java`
  - `backend/src/main/java/com/eventcapture/backend/gallery/GalleryEventRedisConfig.java`
- Moderation:
  - `backend/src/main/java/com/eventcapture/backend/moderation/ModerationService.java`
- Export:
  - `backend/src/main/java/com/eventcapture/backend/export/ExportService.java`

## Persistence

- Domain enums and shared base entity:
  - `backend/src/main/java/com/eventcapture/backend/domain/`
- JPA entities and repositories by feature:
  - `backend/src/main/java/com/eventcapture/backend/auth/`
  - `backend/src/main/java/com/eventcapture/backend/event/`
  - `backend/src/main/java/com/eventcapture/backend/guest/`
  - `backend/src/main/java/com/eventcapture/backend/media/`
  - `backend/src/main/java/com/eventcapture/backend/moderation/`
  - `backend/src/main/java/com/eventcapture/backend/export/`
- Migrations:
  - `backend/src/main/resources/db/migration/V1__initial_schema.sql`
  - `backend/src/main/resources/db/migration/V2__upload_media_integrity.sql`
  - `backend/src/main/resources/db/migration/V3__widen_multipart_upload_id.sql`

## Tests

- Main integration coverage:
  - `backend/src/test/java/com/eventcapture/backend/integration/BackendIntegrationTest.java`
  - `backend/src/test/java/com/eventcapture/backend/integration/DistributedRuntimeIntegrationTest.java`
  - `backend/src/test/java/com/eventcapture/backend/integration/WorkerRoleIntegrationTest.java`
  - `backend/src/test/java/com/eventcapture/backend/integration/LocalRuntimeIntegrationTest.java`
  - `backend/src/test/java/com/eventcapture/backend/integration/RuntimeConfigurationIntegrationTest.java`
  - `backend/src/test/java/com/eventcapture/backend/integration/S3CompatibleStorageIntegrationTest.java`
  - `backend/src/test/java/com/eventcapture/backend/integration/LiveR2SmokeIntegrationTest.java`
- Unit coverage:
  - `backend/src/test/java/com/eventcapture/backend/event/EventServiceTest.java`
  - `backend/src/test/java/com/eventcapture/backend/auth/AuthServiceTest.java`
  - `backend/src/test/java/com/eventcapture/backend/guest/GuestSessionServiceTest.java`
  - `backend/src/test/java/com/eventcapture/backend/common/security/SimpleRateLimiterTest.java`
  - `backend/src/test/java/com/eventcapture/backend/gallery/GalleryEventBrokerTest.java`
  - `backend/src/test/java/com/eventcapture/backend/media/NativeSourceImageDecoderTest.java`
  - `backend/src/test/java/com/eventcapture/backend/media/MediaInspectionServiceTest.java`
  - `backend/src/test/java/com/eventcapture/backend/media/LibvipsMediaVariantProcessorTest.java`
  - `backend/src/test/java/com/eventcapture/backend/media/UploadServicePhase2Test.java`
  - `backend/src/test/java/com/eventcapture/backend/gallery/PublicAssetUrlBuilderTest.java`
- Test profile:
  - `backend/src/test/resources/application-test.yml`

## Grep Shortcuts

- Controllers and routes:
  - `rg -n "@RestController|@RequestMapping|/api/v1/" backend/src/main/java`
- Services:
  - `rg -n "@Service|class .*Service" backend/src/main/java`
- Entities:
  - `rg -n "@Entity|enum " backend/src/main/java/com/eventcapture/backend`
- Current public route surface:
  - `rg -n "/api/v1/public|/api/v1/host|/api/v1/auth" backend/src/main/java`
