# Changelog

## [3.0.0] — 2026-07-07

### Breaking Changes
- Removed deprecated `file_path:` parameter (use `local_path:`)
- Removed deprecated `progress_callback:` parameter (use `on_progress:`)
- Removed deprecated `concurrency:` parameter (use `max_threads:`)
- Removed deprecated `retries:` parameter (use `max_retries:`)
- Removed `upload_file_multipart` in favor of auto-dispatching `upload_file`
- Removed `download_file_parallel` in favor of auto-dispatching `download_file`
- Removed `download_file_resume` method
- Upload methods now return `UploadResult` Data objects instead of Hash
- Download methods now return `DownloadResult` Data objects instead of Hash

### Features
- Service-object architecture: UploadService dispatches to EmptyUpload, SinglePartUpload, MultipartUpload, ResumeUpload
- Service-object architecture: DownloadService dispatches to SinglePartDownload
- Auto-dispatch for upload (0-byte → PUT, ≤part_size → streaming PUT, >part_size → multipart)
- Consistent UploadResult/DownloadResult return types with `to_h` support

### Internal Refactoring
- Extracted `Result`, `SessionMetadata`, `UploadCompletion` modules
- Removed 200+ lines of dead code from `upload_logic.rb`
- Clients delegate to services with `(...)` forwarder
- Services use `Process.clock_gettime` instead of `now_mono` for timing

## [2.0.0] - 2026-07-03

### Added
- Shared test modules (`SharedSmokeTests`, `SharedStateTests`, `SharedConcurrentTests`)
- `max_concurrency` and `max_retries` parameter aliases on both clients (replaces `max_threads`/`retries`)
- `access_key`/`secret_key` parameter aliases (replaces `access_key_id`/`secret_access_key`)
- `build_uri` public method on `S3MultiBucketClient`
- `UploadStateManager` extracted helper methods: `parse_state_data`, `atomic_write_state`, `write_and_rename`, `sync_dir`, `state_mismatched?`, `file_changed?`

### Changed
- **Architecture**: Parallel download path unified into `S3BaseClient` — both clients now share `run_parallel_download`
- **Architecture**: Class-reopening for constants, errors, logging, XML helpers replaced with proper module composition (`S3Constants`, `S3Errors`, `S3Logging`, `S3XmlHelpers`)
- **Refactor**: All `S3Client` upload methods reduced to < 31 code lines each (`upload_file`, `upload_file_multipart`, `resume_upload`, `execute_multipart_upload`, `setup_multipart_upload_state`)
- **Refactor**: `S3MultiBucketClient#upload_file_multipart` 59→30 lines, `resume_upload` 70→14 lines
- **Refactor**: `BulkUploader#scan_files` renamed to `build_file_list`; extracted `process_one_file` and `pop_from_queue`
- **Refactor**: `Networking#perform_request` unified `max_attempts` calculation across streaming/non-streaming branches
- **RuboCop**: MethodLength tightened 60→40, AbcSize 50→35, CyclomaticComplexity 20→12
- `@max_retries` replaces `@retries` internally (backward-compatible alias preserved)
- Instance variable `@_upload_multipart_t0` replaced with explicit `t0` parameter through call chain

### Fixed
- Private test methods bug in shared examples (misplaced `private` keyword in `class_eval` block)
- Bare `rescue` in `sync_dir` replaced with explicit `rescue SystemCallError`
- S3MultiBucketClient `upload_file` now correctly delegates to multipart when appropriate

### Deprecated
- `max_threads:` parameter — use `max_concurrency:` instead
- `access_key:`/`secret_key:` — use `access_key_id:`/`secret_access_key:` instead
- `ParallelUploadRunner` and `ParallelDownloadRunner` — use shared `PartUploader`/`PartDownloader` instead

### Removed
- `@_upload_multipart_t0` instance variable (was used in S3MultiBucketClient upload)

## [1.0.0] - 2026-06-24

### Added
- Parallel multipart upload with automatic retry and exponential backoff
- Parallel multipart download with resume support
- Streaming single-PUT upload (memory-efficient for large files)
- Streaming chunked download (no full-file buffering)
- Resumable upload via state file (JSON-based, atomic writes with fsync)
- Resumable download via `.part` file
- Cooperative thread shutdown (replaces unsafe `Thread#raise(Interrupt)`)
- Event callback system (`S3EventRegistry`) with 20+ event types
- Session metadata tracking (upload session ID, file fingerprint, MD5)
- `S3Helper` convenience module (auto-detects single/multi-bucket client)
- `S3BulkUploader` for parallel directory upload
- Presigned URL generation
- SSE support (SSE-S3, SSE-KMS, SSE-C)
- JSON and colorized log formatters
- Thread state tracking and diagnostics
- Human-readable size formatting
- `skip_existing` support for upload and bulk upload
- Support for AWS S3, MinIO, Cloudflare R2, and other S3-compatible providers
- Optional MD5-based file integrity checking
- Instance-level `@max_concurrency` on `S3MultiBucketClient`
- Structured error classes: `S3NotFoundError`, `S3PermissionError`,
  `S3BucketError`, `S3TimeoutError`, `S3ConnectionError`, `S3StateError`
- Full YARD documentation on all public API methods
- RBS type signatures in `sig/` directory
- GitHub Actions CI workflow (test, RuboCop, coverage)
- 100% test coverage with Minitest + SimpleCov

### Changed
- **Thread safety**: session metadata is now passed as a local variable
  through the execution chain instead of stored in an instance variable,
  preventing data corruption from concurrent API calls
- **Error handling**: `rescue => e` replaced with `rescue StandardError => e`
  in all 20 locations across 8 source files
- **Thread interrupt**: `Thread.raise(Interrupt)` replaced with cooperative
  shutdown via `Thread#run` in both parallel uploader and downloader —
  prevents mutex corruption from forced interrupts during `Mutex#synchronize`
- **Error propagation**: `head_object` non-404 errors now re-raise instead
  of being silently swallowed in `skip_existing` code paths
- **Concurrency cap**: `S3MultiBucketClient` now enforces `MAXIMUM_CONCURRENCY`
  (32) cap, matching `S3Client` behavior
- **RuboCop todo**: regenerated from stale 45+ entries down to 5

### Fixed
- `README.md` download example: `local_path:` → `destination_path:`,
  `resume:` string → `resume: true`
- `S3MultiBucketClient` `upload_file` and `resume_upload` now use
  `@max_concurrency` as default for `max_threads:`

### Removed
- All `Thread#raise` calls from source code
- All `rescue => e` bare exception rescues
- Obsolete `(removed compat alias:)` comments (6 locations)
- Dead `@debug` instance variable
- Stale `.rubocop_todo.yml` file references (8 deleted files)

### Technical Debt
- Minor duplication remains between `S3Client` and `S3MultiBucketClient`
  nested `PartUploader`/`PartDownloader` classes — a future refactoring
  could extract a shared `save_state_after_part` implementation
