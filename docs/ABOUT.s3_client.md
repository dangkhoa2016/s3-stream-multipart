# S3Client — Resumable Multipart Upload & Streaming Download

> 🌐 Language / Ngôn ngữ: **English** | [Tiếng Việt](ABOUT.s3_client.vi.md)

A pure Ruby library (no AWS SDK dependency) for uploading/downloading large files to S3-compatible storage (AWS S3, MinIO, Cloudflare R2, Backblaze B2, …).

**Key features:**

- **Ruby >= 2.7.8 required** — uses `Data.define` for result objects
- **Low & stable RAM usage** — upload: ~`part_size × concurrency`, download: a few tens of KB
- **Resumable** — state is persisted to JSON after each part; Ctrl+C then re-run to resume (both upload & download)
- **Unified API** — `upload_file` auto-selects between EmptyUpload / SinglePartUpload / MultipartUpload based on file size
- **SSE encryption** — supports SSE-S3, SSE-KMS, SSE-C
- **21 event callbacks** — hook into every point in the lifecycle (progress bar, alerts, monitoring)
- **Thread-safe logging** — worker threads use `thread_log_*`
- **Debug mode** — detailed HTTP request/response logging when `debug: true`
- **Structured logging** — choose `log_format: :text` (default) or `:json`; color output with `log_color: true`

> **Detailed documentation:** see [USAGE_GUIDE.s3_client.md](USAGE_GUIDE.s3_client.md) for the full API, examples, state file format, cookbook, and troubleshooting.

---

## Installation

```bash
gem install aws-sigv4
```

```ruby
require_relative "path/to/src/s3_client"
```

## Quick usage

```ruby
client = S3Client.new(
  region:           "us-east-1",
  bucket:           "my-bucket",
  access_key_id:    ENV["S3_ACCESS_KEY_ID"],
  secret_access_key: ENV["S3_SECRET_ACCESS_KEY"],
  # endpoint:       "https://minio.local:9000",  # MinIO / R2
  # endpoint_style: :path,                        # required for MinIO/R2
  # log_file:       "s3_upload.log",              # write logs to file
  # log_format:     :json,                        # structured JSON output
  # debug:          true,                          # detailed HTTP logging
)

# Upload — auto-selects single PUT or multipart
result = client.upload_file(
  local_path:  "huge.bin",
  key:         "/data/huge.bin",
  state_file:  "huge.upload.json",
  on_progress: ->(written, total) { puts "#{written * 100 / total}%" }
)
puts "Uploaded #{result.key}: #{result.size} bytes in #{'%.2f' % result.elapsed}s"

# Download — streaming, never loads the whole file into RAM
client.download_file(key: "/data/huge.bin", destination_path: "huge_copy.bin")

# HEAD metadata
info = client.head_object("/data/huge.bin")
puts "Size: #{info[:content_length]}, Type: #{info[:content_type]}"

# Presigned URL
url = client.presigned_url(key: "/data/huge.bin", expires_in: 3600)
```

## Resuming uploads

```ruby
# Add state_file: to upload_file — state is persisted after each part automatically
client.upload_file(local_path: "huge.bin", key: "/data/huge.bin", state_file: "upload.json")

# Ctrl+C → re-run the same command → resumes automatically from missing parts
# State file is deleted automatically once upload completes
```

## Event callbacks

```ruby
S3Client.on(:part_complete) { |pn, total, tid, etag, bytes, ms, speed|
  puts "#{tid} part #{pn}/#{total} @ #{speed} MB/s"
}

S3Client.on(:upload_complete) { |result, elapsed, throughput|
  puts "Done: #{result.key} (#{'%.1f' % throughput} MB/s)"
}
```

21 events: `:upload_start`, `:upload_resume`, `:part_start`, `:part_complete`, `:part_retry`, `:part_failed`, `:state_save`, `:state_load`, `:state_mismatch`, `:upload_complete`, `:upload_failed`, `:thread_start`, `:thread_finish`, `:log`, `:download_start`, `:download_part_start`, `:download_part_complete`, `:download_part_retry`, `:download_part_failed`, `:download_complete`, `:download_failed`.

## API summary

| Group | Methods |
|---|---|
| **Upload** | `upload_file` (auto-dispatch), `resume_upload`, `upload_directory` |
| **Download** | `download_file` (Range support), `download_stream` (block-based) |
| **Object ops** | `head_object`, `delete_object`, `presigned_url` |
| **Multipart** | `multipart_start`, `multipart_upload_part`, `multipart_complete`, `multipart_abort`, `abort_multipart_upload` |
| **List** | `list_multipart_uploads`, `list_parts` |
| **Logging** | `log_info/debug/warn/error`, `thread_log_*`, `emit_event`, `setup_logger` |
| **Class** | `S3Client.on/off/clear_callbacks!` |
| **Nested** | `S3Client::UploadState`, `S3Client::DownloadState`, `S3Client::S3Error` (with `s3_code`, `s3_message`, `s3_bucket` attributes), `S3Client::UploadError`, `S3Client::DownloadError` |
| **Helper** | `S3Helper.upload`, `S3Helper.download`, `S3Helper.upload_bulk`, `human_readable_size` |

## Running tests

```bash
rake test:s3_client                    # s3_client tests only
ruby tests/s3_client/test_smoke.rb     # single file
ruby tests/s3_client/test_smoke.rb -n test_multipart_upload_20mb  # single test
ruby tests/interactive/upload_resume_s3_client.rb  # Ctrl+C resume demo
```

| File | Contents |
|---|---|
| `tests/s3_client/test_smoke.rb` | Functional tests |
| `tests/s3_client/test_state.rb` | Resumable upload tests |
| `tests/s3_client/test_race.rb` | Stress test: 8 threads, monotonic state |
| `tests/s3_client/test_memory.rb` | RAM measurement (200 MB) |
| `tests/s3_client/test_features.rb` | Presigned, list, download, events, S3Helper |
| `tests/s3_client/test_concurrent.rb` | Thread pool & parallel transfer tests |
| `tests/s3_client/test_request_executor.rb` | HTTP request executor tests |
| `tests/s3_client/test_event_registry.rb` | Callback registry tests |
| `tests/s3_client/test_upload_state_manager.rb` | Upload state persistence tests |
| `tests/s3_client/test_parallel_download.rb` | Multi-thread download tests |

## Project structure

```
s3-stream-multipart/
├── src/                      # Source code
│   ├── s3_client.rb              # S3Client (single-bucket)
│   ├── s3_multi_bucket_client.rb # S3MultiBucketClient
│   ├── s3-stream-multipart.rb              # Entry point
│   ├── core/                     # Base client, errors, logging, signing, events, XML, utils, transports
│   ├── concurrent/               # Thread pool, parallel uploader/downloader, progress tracker
│   ├── upload/                   # EmptyUpload, SinglePartUpload, MultipartUpload, ResumeUpload, UploadService
│   ├── download/                 # DownloadService, PartDownloader, SinglePartDownload
│   ├── states/                   # UploadState, DownloadState, StateBase
│   ├── extras/                   # S3Helper, BulkUploader, DirectoryScanner, RetryHelper
│   ├── s3_client/                # S3Client-specific networking, upload, download
│   └── s3_multi_bucket_client/   # Multi-bucket networking, upload, download
├── usage/                    # Usage examples
├── docs/                     # Guides (EN + VI) and comparison
├── tests/                    # Shared test suite (Minitest)
│   ├── support/              # Fake S3 server + helpers (shared)
│   ├── s3_client/            # 20 test files
│   ├── s3_multi_bucket_client/  # 7 test files
│   └── interactive/          # Ctrl+C resume demos
├── Gemfile
├── s3-stream-multipart.gemspec
└── Rakefile
```

## Limitations

1. **SSE-S3 / SSE-KMS / SSE-C** — pass `sse:` when constructing the client. SSE-C sends the key on every part request (never logged).
2. **Configurable retries** — `max_retries:` / `retry_delay:` in the constructor. Retries 5xx + 429 + transient errors. 2x backoff with jitter.
3. **MinIO / R2 / non-AWS endpoints** — must pass `endpoint:` and typically `endpoint_style: :path`.
