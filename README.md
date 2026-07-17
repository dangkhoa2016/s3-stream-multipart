# s3-stream-multipart

[![CI](https://github.com/dangkhoa2016/s3-stream-multipart/actions/workflows/ci.yml/badge.svg)](https://github.com/dangkhoa2016/s3-stream-multipart/actions/workflows/ci.yml)
[![Gem Version](https://img.shields.io/gem/v/s3-stream-multipart)](https://rubygems.org/gems/s3-stream-multipart)

> 🌐 Language / Ngôn ngữ: **English** | [Tiếng Việt](README.vi.md)

A lightweight, memory-efficient Ruby client for S3-compatible storage. Supports AWS S3, MinIO, Cloudflare R2, Backblaze B2, and any S3-compatible provider.

Features parallel multipart upload/download with resume support, event callbacks, presigned URLs, and SSE encryption — all without the `aws-sdk-s3` gem (uses `aws-sigv4` + `Net::HTTP`).

## Features

- Parallel multipart upload (resumable via state files)
- Streaming chunked download (multi-thread, resumable)
- Presigned URL generation (upload, download, delete)
- Server-Side Encryption (SSE-S3, SSE-KMS, SSE-C)
- Automatic retry with exponential backoff + jitter
- Event callbacks (21+ events for logging/progress/alerting)
- Atomic state persistence (resume safe after crash)
- Bulk directory upload with progress
- Single-bucket (`S3Client`) and multi-bucket (`S3MultiBucketClient`) variants
- Factory method `S3Client.build` auto-selects the right client

## Requirements

Ruby **>= 2.7.8** (uses `Data.define`, endless methods, and other modern features).

## Installation

```ruby
# Gemfile
gem "s3-stream-multipart"
```

Or build locally:

```bash
gem build s3-stream-multipart.gemspec
gem install s3-stream-multipart-1.0.0.gem
```

## Quick Start

### Using the factory (recommended)

```ruby
require "s3-stream-multipart"

# Single-bucket client (pass bucket:) → returns S3Client
client = S3Client.build(
  region:            "us-east-1",
  bucket:            "my-bucket",
  access_key_id:     ENV["S3_ACCESS_KEY_ID"],
  secret_access_key: ENV["S3_SECRET_ACCESS_KEY"]
)

client.upload_file(local_path: "photo.jpg", key: "photos/photo.jpg")

# Multi-bucket client (omit bucket:, include endpoint:) → returns S3MultiBucketClient
client = S3Client.build(
  region:            "us-east-1",
  endpoint:          "https://minio.local:9000",
  access_key_id:     "minioadmin",
  secret_access_key: "minioadmin"
)

client.upload_file(bucket: "my-bucket", local_path: "photo.jpg", key: "photos/photo.jpg")
```

`S3Client.build(bucket: "b", ...)` → `S3Client` (single fixed bucket).
`S3Client.build(endpoint: "...", ...)` → `S3MultiBucketClient` (explicit bucket per call).
Raises `ArgumentError` if neither `bucket:` nor `endpoint:` is provided.

### Direct S3Client (single bucket)

```ruby
require "s3-stream-multipart"

client = S3Client.new(
  region:            "us-east-1",
  bucket:            "my-bucket",
  access_key_id:     ENV["S3_ACCESS_KEY_ID"],
  secret_access_key: ENV["S3_SECRET_ACCESS_KEY"]
)

# Upload a small file (single PUT)
client.upload_file(local_path: "report.pdf", key: "documents/report.pdf")

# Resumable multipart upload
client.upload_file(
  local_path: "large_video.mp4",
  key:        "videos/large_video.mp4",
  state_file: "uploads/large_video.state.json"
)
```

### Direct S3MultiBucketClient (multiple buckets)

```ruby
require "s3-stream-multipart"

client = S3MultiBucketClient.new(
  endpoint:          "https://s3.us-east-1.amazonaws.com",
  region:            "us-east-1",
  access_key_id:     ENV["S3_ACCESS_KEY_ID"],
  secret_access_key: ENV["S3_SECRET_ACCESS_KEY"]
)

client.upload_file(bucket: "my-bucket", local_path: "photo.jpg", key: "photos/photo.jpg")
```

### Download

```ruby
# S3Client (returns DownloadResult with .path, .size, .elapsed, .throughput)
result = client.download_file(key: "videos/large.mp4", destination_path: "large.mp4")
puts "Downloaded #{result.size} bytes in #{result.elapsed}s"

# S3MultiBucketClient (requires bucket:)
result = client.download_file(bucket: "my-bucket", key: "videos/large.mp4",
                               destination_path: "large.mp4")
```

### Presigned URLs

```ruby
url = client.presigned_url(bucket: "my-bucket", key: "private/doc.pdf",
                           method: :get, expires_in: 3600)
```

### Event callbacks

```ruby
client = S3MultiBucketClient.new(
  endpoint: "...", region: "us-east-1",
  access_key_id: "...", secret_access_key: "...",
  on_event: ->(event, *args) {
    puts "[#{event}] #{args.inspect}" if %i[part_complete state_save state_mismatch].include?(event)
  }
)
```

## Thread Safety

Client instances are **not** thread-safe for concurrent public API calls (e.g. calling
`upload_file` from multiple threads on the same client). Internally, each multipart
upload/download manages its own worker threads safely.

**Good:** Reuse a single client sequentially across requests.
**Bad:** Share a single client across threads without external synchronization.

Ruby's `Logger` and `aws-sigv4::Signer` are thread-safe; all internal mutable state
uses mutex protection or is read-only after initialization.

## Performance & Memory

- **Upload** (N GB file): peak RSS ≈ `part_size × max_concurrency` — each thread reads
  exactly one part, sends it, then discards it.
- **Download** (N GB file): peak RSS ≈ chunk buffer (default 64 KB).
  `Net::HTTP#read_body` pipes chunks directly to `File#write` — zero buffering.

## CLI

A command-line interface is available after installing the gem:

```bash
# Upload a file
s3sm upload photo.jpg --bucket my-bucket --key photos/photo.jpg

# Download a file
s3sm download photos/photo.jpg /tmp/photo.jpg --bucket my-bucket

# Generate a presigned URL (expires in 1 hour)
s3sm presign photos/photo.jpg --bucket my-bucket --expires 3600

# Delete an object
s3sm delete photos/photo.jpg --bucket my-bucket

# Upload a directory
s3sm upload-dir ./build --bucket my-bucket --prefix site/

# List active multipart uploads
s3sm list-uploads --bucket my-bucket

# Use environment variables for credentials
export AWS_ACCESS_KEY_ID=...
export AWS_SECRET_ACCESS_KEY=...
export AWS_REGION=us-east-1
export AWS_BUCKET=my-bucket
s3sm upload photo.jpg --key photos/photo.jpg

# Custom endpoint (MinIO, R2, etc.)
s3sm --endpoint https://minio.local:9000 upload photo.jpg \
  --bucket my-bucket --key photos/photo.jpg
```

Run `s3sm --help` for all commands and options.

## Full API Reference

### Return types

All upload/download return `Data` objects (`.key`, `result[:key]`, or `result.to_h`):

```ruby
UploadResult   = Data.define(:key, :size, :etag, :elapsed, :throughput, :extra)
DownloadResult = Data.define(:path, :size, :elapsed, :throughput, :extra)
```

| Field | Type | UploadResult | DownloadResult | Notes |
|-------|------|-------------|---------------|-------|
| `.key` | String | ✓ | — | S3 object key |
| `.path` | String | — | ✓ | Local file path |
| `.size` | Integer | ✓ | ✓ | Bytes |
| `.etag` | String | ✓ | — | S3 ETag (MD5 or multipart hash) |
| `.elapsed` | Float | ✓ | ✓ | Wall-clock seconds |
| `.throughput` | Float | ✓ | ✓ | Effective MB/s |
| `.extra` | Hash | ✓ | ✓ | Upload ID, parts, bucket, destination, etc. |

`.to_h` merges `extra` keys at the top level so you can destructure directly:

```ruby
result = client.upload_file(local_path: "f.bin", key: "f.bin")
result.key          # "f.bin"
result[:key]        # "f.bin"
result.to_h         # { key: "f.bin", size: 100, etag: "...", elapsed: 0.5, throughput: 0.2, extra: {...} }
# extra keys (upload_id, parts, etc.) are merged into to_h:
result[:upload_id]  # "abc123"  (from extra)
```

### S3Client

| Method | Description |
|--------|-------------|
| `upload_file(key:, local_path:, content_type:, metadata:, cache_control:, part_size:, state_file:, skip_existing:, on_progress:, max_threads:, max_retries:, retry_delay:)` | Upload a file (auto-dispatches: 0-byte PUT, streaming PUT, or multipart) |
| `download_file(key:, destination_path:, range:, on_progress:)` | Download a file (streaming) |
| `download_stream(key:, &)` | Stream body chunks without buffering |
| `resume_upload(state_file:, key:, on_progress:, bucket:, local_path:)` | Resume interrupted upload from state file |
| `upload_directory(directory:, prefix:, pattern:, exclude:, max_files:, multipart_threshold:, on_file_start:, on_file_complete:, on_file_error:, content_type:, metadata:, cache_control:, skip_existing:, state_dir:)` | Upload every file in a directory |
| `head_object(key:)` → Hash | Get object metadata |
| `delete_object(key:)` → `204` (Integer) S3Client / `{key:, status: 'deleted'}` (Hash) MBC | Delete an object |
| `presigned_url(key:, method:, expires_in:, query:)` → String | Generate a presigned URL |
| `list_multipart_uploads(key_prefix:, max_uploads:)` → Array | List in-progress multipart uploads |
| `list_parts(key:, upload_id:, max_parts:)` → Array | List parts for an upload |
| `abort_multipart_upload(key:, upload_id:)` → Hash `{key:, upload_id:, status: "aborted"}` | Abort and clean up parts |

### S3MultiBucketClient

Same as S3Client, plus:

| Extra parameter | Applies to |
|----------------|-----------|
| `bucket:` (required) | `upload_file`, `download_file`, `upload_directory`, `head_object`, `delete_object`, `presigned_url` |

```ruby
client.upload_file(bucket: "my-bucket", local_path: "f.txt", key: "f.txt")
client.download_file(bucket: "my-bucket", key: "f.txt", destination_path: "f.txt")
```

### S3Helper

```ruby
# Quick one-shot upload (auto-detects S3Client vs S3MultiBucketClient)
S3Helper.upload(client:, key:, local_path:, bucket:, ...)

# Quick one-shot download (with optional progress bar)
S3Helper.download(client:, key:, local_path:, destination:, bucket:, ...)

# Bulk upload directory
S3Helper.upload_bulk(client:, directory:, prefix:, bucket:, max_files:, ...)
```

### Error handling

Methods raise typed exceptions on failure:

| Exception | When |
|-----------|------|
| `S3BaseClient::S3Error` | Server returned an error (status 4xx/5xx) |
| `S3BaseClient::UploadError` | Upload-specific failure (part failed, etag mismatch) |
| `S3BaseClient::DownloadError` | Download-specific failure (connection reset, partial content) |

All inherit from `RuntimeError`. Rescue from most specific to most general:

```ruby
begin
  client.upload_file(local_path: "data.bin", key: "data.bin")
rescue S3BaseClient::UploadError => e
  retry if e.message.include?("part")  # retry on part failure
rescue S3BaseClient::S3Error => e
  puts "S3 returned #{e.code}: #{e.message}"
rescue Net::ReadTimeout, Net::OpenTimeout => e
  puts "Network issue — consider increasing read_timeout:"
end
```

### Constructor options

Both clients accept:

| Option | Default | Description |
|--------|---------|-------------|
| `access_key_id:` | — | AWS-style access key |
| `secret_access_key:` | — | AWS-style secret key |
| `region:` | — | AWS region (e.g. `us-east-1`) |
| `bucket:` | — | Default bucket (S3Client: required; MBC: optional) |
| `endpoint:` | — | Custom S3-compatible endpoint |
| `endpoint_style:` | `:auto` | `:path` or `:virtual_host` style URLs |
| `part_size:` | `10_485_760` (10 MiB) S3Client / `8_388_608` (8 MiB) MBC | Multipart chunk size (min 5 MiB) |
| `max_concurrency:` | `4` | Max parallel parts (clamped 1–32) |
| `max_retries:` | `3` | Retry count for transient failures |
| `retry_delay:` | `0.25` | Base retry delay in seconds (exponential + jitter) |
| `open_timeout:` | `30` | HTTP open / connect timeout (seconds) |
| `read_timeout:` | `600` | HTTP read timeout (seconds) |
| `session_token:` | — | STS session token for temporary credentials |
| `sse:` | — | Server-side encryption config (see below) |
| `debug:` | `false` | Enable verbose HTTP request/response logging |
| `logger:` | — | Custom `Logger` instance |
| `log_file:` | — | Path to log file (ignored if `logger:` is set) |
| `log_color:` | `false` | ANSI color highlighting in log output |
| `log_format:` | `:text` | `:text` or `:json` |

#### Server-Side Encryption (`sse:`)

The `sse:` option accepts a Hash with a `:type` key:

| Type | Hash format | Description |
|------|-------------|-------------|
| SSE-S3 | `{ type: "AES256" }` | Amazon S3-managed keys |
| SSE-KMS | `{ type: "aws:kms", kms_key_id: "..." }` | AWS KMS (optional key ID) |
| SSE-C | `{ type: "customer", key: "base64...", key_md5: "base64..." }` | Customer-provided key |

```ruby
# SSE-C example
client = S3Client.new(region: "us-east-1", bucket: "my-bucket",
                       access_key_id: "...", secret_access_key: "...",
                       sse: { type: "customer", key: "base64key==", key_md5: "base64md5==" })
```

## Documentation

### Guides

- [S3Client Usage Guide](docs/USAGE_GUIDE.s3_client.md) — full API, examples, state file format
- [S3MultiBucketClient Usage Guide](docs/USAGE_GUIDE.s3_multi_bucket_client.md) — multi-bucket examples with SSE, retry, bulk upload
- [CLI Usage Guide](docs/USAGE_GUIDE.cli.md) — `s3sm` command-line tool reference

### Overviews

- [S3Client Overview](docs/ABOUT.s3_client.md) — feature summary
- [S3MultiBucketClient Overview](docs/ABOUT.s3_multi_bucket_client.md) — feature summary

### Scripts & Manual Usage

- [Upload script usage](manually/upload-USAGE.md) — `upload.sh` reference with S3Client & S3MultiBucketClient
- [Folder upload script usage](manually/folder-upload-USAGE.md) — `folder-upload.sh` reference for batch uploads
- [Upload script usage (Vietnamese)](manually/upload-USAGE.vi.md)
- [Folder upload script usage (Vietnamese)](manually/folder-upload-USAGE.vi.md)

## Development

```bash
git clone https://github.com/dangkhoa2016/s3-stream-multipart.git
cd s3-stream-multipart
bundle install
bundle exec rake test    # run all tests
bundle exec rake test:quick  # skip memory/race tests
```

## License

[MIT](LICENSE)
