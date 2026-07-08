# S3MultiBucketClient — Resumable Multipart Upload & Parallel Download (Ruby)

A pure Ruby library (no AWS SDK dependency) for uploading/downloading large files to S3-compatible storage (AWS S3, MinIO, Cloudflare R2, Backblaze B2, …).

**Key features:**

- **Low & stable RAM usage** — upload: ~`part_size × threads`, download: a few tens of KB
- **Parallel download** — download large files in parallel across multiple threads via Range requests, resumable
- **Resumable** — state is persisted to JSON after each part; Ctrl+C then re-run to resume (both upload & download)
- **Multi-bucket** — a single client instance can operate on multiple different buckets
- **SSE encryption** — supports SSE-S3, SSE-KMS, SSE-C
- **21 event callbacks** — hook into every point in the lifecycle (progress bar, alerts, monitoring)
- **Thread-safe logging** — worker threads use `thread_log_*`, main thread drains
- **Debug mode** — detailed HTTP request/response logging when `debug: true`

> **Detailed documentation:** see [USAGE_GUIDE.s3_multi_bucket_client.md](USAGE_GUIDE.s3_multi_bucket_client.md) for the full API, examples, state file format, cookbook, and troubleshooting.

---

## Installation

```bash
gem install aws-sigv4
```

Requires Ruby >= 3.2.

```ruby
require_relative "path/to/src/s3_multi_bucket_client"
```

## Quick usage

```ruby
client = S3MultiBucketClient.new(
  endpoint:          "https://s3.ap-southeast-1.amazonaws.com",
  region:            "ap-southeast-1",
  access_key_id:     ENV["S3_ACCESS_KEY_ID"],
  secret_access_key: ENV["S3_SECRET_ACCESS_KEY"],
  # log_file: "s3_upload.log",   # write logs to file
  # debug:    true,               # detailed HTTP logging
)

# Upload — auto-dispatches to EmptyUpload / SinglePartUpload / MultipartUpload
# based on file size relative to part_size (default 8 MB for MBC).
result = client.upload_file(
  bucket:     "my-bucket",
  key:        "videos/movie.mp4",
  local_path: "/path/to/large-movie.mp4",
  part_size:  8 * 1024 * 1024,
  max_threads: 4,
  state_file: "upload-state.json",
  on_progress: ->(uploaded, total) { puts "#{uploaded}/#{total}" }
)

# Download — streaming, never loads the whole file into RAM
client.download_file(
  bucket:           "my-bucket",
  key:              "videos/movie.mp4",
  destination_path: "/path/to/downloaded.mp4"
)

# Download — Range (partial file download)
client.download_file(
  bucket:           "my-bucket",
  key:              "videos/movie.mp4",
  destination_path: "/path/to/partial.mp4",
  range:            [0, 1024 * 1024 - 1]  # first 1MB
)

# Download — block streaming
client.download_stream(key: "videos/movie.mp4", bucket: "my-bucket") do |chunk|
  process_chunk(chunk)
end

# HEAD metadata
info = client.head_object(bucket: "my-bucket", key: "documents/report.pdf")
puts "Size: #{info[:content_length]}, Type: #{info[:content_type]}"

# Presigned URL
url = client.presigned_url(bucket: "my-bucket", key: "documents/report.pdf", expires_in: 3600)

# Delete
client.delete_object(bucket: "my-bucket", key: "old-file.txt")
# => { key: "old-file.txt", status: "deleted" }
```

## Resuming uploads

```ruby
# Pass state_file: — state is persisted after each part automatically
client.upload_file(
  bucket: "my-bucket", key: "data/huge.bin",
  local_path: "/path/to/huge.bin", state_file: "upload.json"
)

# Ctrl+C → re-run the same command → resumes automatically
# Or resume explicitly:
client.resume_upload(state_file: "upload.json", bucket: "my-bucket")
```

## Event callbacks

```ruby
S3MultiBucketClient.on(:part_complete) { |pn, total, tid, etag, bytes, ms, speed|
  puts "#{tid} ✓ part #{pn}/#{total} @ #{speed} MB/s"
}

S3MultiBucketClient.on(:upload_complete) { |result, elapsed, throughput|
  puts "Done: #{result.key} (#{'%.1f' % throughput} MB/s)"
}
```

21 events: `:upload_start`, `:upload_resume`, `:part_start`, `:part_complete`, `:part_retry`, `:part_failed`, `:state_save`, `:state_load`, `:state_mismatch`, `:upload_complete`, `:upload_failed`, `:thread_start`, `:thread_finish`, `:log`, `:download_start`, `:download_part_start`, `:download_part_complete`, `:download_part_retry`, `:download_part_failed`, `:download_complete`, `:download_failed`.

## API summary

| Group | Methods |
|---|---|
| **Upload** | `upload_file` (auto‑dispatch: empty/single/multipart), `resume_upload` |
| **Download** | `download_file` (streaming + Range), `download_stream` (block + Range) |
| **Bulk** | `upload_directory` (pattern, exclude, concurrency, state) |
| **Object ops** | `head_object`, `delete_object`, `presigned_url` |
| **Multipart** | `multipart_start`, `multipart_upload_part`, `multipart_complete`, `multipart_abort`, `abort_multipart_upload` |
| **List** | `list_multipart_uploads`, `list_parts` |
| **Logging** | `log_info/debug/warn/error`, `thread_log_*`, `emit_event`, `setup_logger` |
| **Class** | `S3MultiBucketClient.on/off/clear_callbacks!`, `S3MultiBucketClient.drain_logs` |
| **Nested** | `S3MultiBucketClient::UploadState`, `S3MultiBucketClient::DownloadState`, `S3MultiBucketClient::PartUploader`, `S3MultiBucketClient::PartDownloader` |
| **Results** | `UploadResult` (Data — `.key`, `[:key]`, `.to_h`), `DownloadResult` (Data — `.path`, `[:path]`, `.to_h`) |
| **Error** | `S3Error`, `UploadError`, `DownloadError` |
| **Helper** | `S3Helper.upload`, `S3Helper.download`, `human_readable_size` |

## Running tests

```bash
rake test:s3_multi_bucket_client                  # MBC tests only
rake test:quick                                   # skip memory/race tests
ruby tests/s3_multi_bucket_client/test_smoke.rb          # single file
ruby tests/s3_multi_bucket_client/test_client.rb -n test_human_readable_size  # single test
ruby tests/interactive/upload_resume_s3_multi_bucket_client.rb  # Ctrl+C resume demo
```

| File | Contents |
|---|---|
| `tests/s3_multi_bucket_client/test_upload_state.rb` | Unit tests (no server required) |
| `tests/s3_multi_bucket_client/test_download_state.rb` | Download state unit tests |
| `tests/s3_multi_bucket_client/test_client.rb` | Unit tests (init, utilities, errors) |
| `tests/s3_multi_bucket_client/test_smoke.rb` | Functional tests |
| `tests/s3_multi_bucket_client/test_state.rb` | Resumable upload tests |
| `tests/s3_multi_bucket_client/test_race.rb` | Stress test: 8 threads, monotonic state |
| `tests/s3_multi_bucket_client/test_memory.rb` | RAM measurement |
| `tests/s3_multi_bucket_client/test_features.rb` | Presigned, list, events, logging, S3Helper |
| `tests/s3_multi_bucket_client/test_bulk_upload.rb` | Bulk upload tests |
| `tests/s3_multi_bucket_client/test_coverage.rb` | Coverage test |

## Project structure

```
s3-upload/
├── src/                      # Source code
│   ├── s3_multi_bucket_client.rb # S3MultiBucketClient (entry point)
│   ├── s3_client.rb              # S3Client (single-bucket variant)
│   ├── s3-upload.rb              # Top-level require
│   ├── core/                     # Shared base class, errors, logging, signing
│   │   ├── base_client.rb
│   │   ├── result.rb             # UploadResult / DownloadResult Data objects
│   │   ├── errors.rb
│   │   ├── logging.rb
│   │   ├── constants.rb
│   │   ├── utils.rb
│   │   ├── validator.rb
│   │   ├── event_registry.rb
│   │   ├── request_executor.rb
│   │   ├── http_signer.rb
│   │   ├── xml_helpers.rb
│   │   ├── session_metadata.rb
│   │   ├── upload_state_manager.rb
│   │   ├── upload_logic.rb
│   │   ├── download_logic.rb
│   │   ├── download_helpers.rb
│   │   ├── upload_completion.rb
│   │   ├── upload_transport.rb
│   │   └── download_transport.rb
│   ├── concurrent/               # Parallel upload/download runners
│   │   ├── parallel_uploader.rb
│   │   ├── parallel_downloader.rb
│   │   ├── parallel_transfer.rb
│   │   ├── thread_tracking.rb
│   │   ├── thread_pool.rb
│   │   ├── progress_tracker.rb
│   │   └── part_geometry.rb
│   ├── upload/                   # Upload strategy objects
│   │   ├── upload_service.rb     # Auto-dispatch to empty/single/multipart
│   │   ├── empty_upload.rb
│   │   ├── single_part_upload.rb
│   │   ├── multipart_upload.rb
│   │   ├── part_uploader.rb
│   │   └── resume_upload.rb
│   ├── download/                 # Download strategy objects
│   │   ├── download_service.rb
│   │   ├── single_part_download.rb
│   │   └── part_downloader.rb
│   ├── extras/                   # Helpers
│   │   ├── helper.rb
│   │   ├── bulk_uploader.rb
│   │   ├── bulk_upload_worker.rb
│   │   ├── directory_scanner.rb
│   │   └── retry_helper.rb
│   ├── states/                   # UploadState, DownloadState
│   │   ├── upload_state.rb
│   │   ├── download_state.rb
│   │   └── state_base.rb
│   └── s3_multi_bucket_client/   # MBC-specific overrides
│   │   ├── upload.rb
│   │   ├── download.rb
│   │   └── networking.rb
│   └── s3_client/                # S3Client-specific overrides
│       ├── upload.rb
│       ├── download.rb
│       └── networking.rb
├── usage/                    # Usage examples
├── docs/                     # Guides (EN + VI) and comparison
├── manually/                 # Manual upload scripts
├── tests/                    # Shared test suite (Minitest)
│   ├── support/              # Fake S3 server + helpers (shared)
│   ├── s3_client/            # S3Client test files
│   ├── s3_multi_bucket_client/  # 10 test files
│   └── interactive/          # Ctrl+C resume demos
├── Gemfile
└── Rakefile
```

## Differences from S3Client

| | S3MultiBucketClient | S3Client |
|---|---|---|
| **Bucket** | Passed per method (`bucket:`) | Fixed in the constructor |
| **Upload API** | Same `upload_file` (auto‑dispatch) | Same `upload_file` (auto‑dispatch) |
| **Default part_size** | 8 MB | 10 MB |
| **Error behavior** | Raises `S3Error`/`UploadError`/`DownloadError` | Same (inherited) |
| **`delete_object`** | Returns `{key:, status: 'deleted'}` (Hash) | Returns `204` (Integer) |
| **`presigned_url`** | Requires `bucket:` | No `bucket:` param needed |
| **`head_object`** | Requires `bucket:` | No `bucket:` param needed |

## Limitations

1. **MD5 hashing is NOT available** — uses mtime + size as the fingerprint (instant).
2. **SSE-S3 / SSE-KMS / SSE-C** — pass `sse:` when constructing the client. SSE-C sends the key on every part request (never logged).
3. **Configurable retries** — `max_retries:` / `retry_delay:` in the constructor. Retries 5xx + 429 + transient errors. 2× backoff with jitter.
4. **Log format** — `log_format: :text` (default) or `:json`. `log_color:` enables ANSI coloring.
5. **`download_file` supports Range** — pass `range: [start, end]` or `range: start..end`.
6. **Upload raises on failure** — both `S3Client` and `S3MultiBucketClient` raise `S3Error`/`UploadError`/`DownloadError`. No silent `{error:, state:}` return.

## License

Up to you — this code was written for learning / demo purposes. Use it freely.
