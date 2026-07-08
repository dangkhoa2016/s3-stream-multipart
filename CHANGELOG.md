# Changelog

## [1.0.0] — 2026-07-10

### Added
- **Core:** Base client with shared S3 operations (presign, list, delete)
- **Core:** Errors, events, logging, HTTP signing, XML helpers, threading utilities
- **Core:** Upload/download state management with persistence and resume support
- **Upload:** Pipeline with empty upload, single-part, multipart, and part uploader
- **Download:** Pipeline with single-part and streaming part downloader
- **Upload:** Concurrent infrastructure — thread pool, progress tracking, parallel helpers
- **Upload:** Bulk directory upload with scanner and retry helpers
- **S3Client:** Single-bucket S3 operations
- **S3MultiBucketClient:** Multi-endpoint S3 operations
- **Infrastructure:** Thread pool, progress tracking, parallel transfer helpers
- **CLI:** `s3sm` command-line tool with upload, download, presign, delete, list-parts, list-uploads, upload-dir commands
- **CI:** GitHub Actions pipeline with RuboCop, Steep, RBS validation, tests, and coverage enforcement
- **Release:** Automated publish to RubyGems on tag push
- **Types:** Complete RBS type signatures
- **Test:** Minitest test suite with helpers, fake S3 server, SimpleCov coverage (100% threshold)
- **Docs:** About guides for S3Client and S3MultiBucketClient
- **Docs:** Detailed usage guides with configuration examples
- **Docs:** Usage examples with code samples
- **Docs:** All documentation available in English and Vietnamese
- **Docs:** README with full API reference and bilingual support

### Dependencies
- Runtime: `aws-sigv4 ~> 1.0`, `rexml ~> 3.0`
- Development: minitest, rake, rbs, rubocop, simplecov, steep, yard, webrick
- Ruby >= 3.2 required
