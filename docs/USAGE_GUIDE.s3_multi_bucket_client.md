# S3MultiBucketClient - Detailed Usage Guide

A pure Ruby library (no AWS SDK dependency) for uploading/downloading large files to S3-compatible storage (AWS S3, MinIO, Cloudflare R2, Backblaze B2, …) with the following features:

- **Memory-efficient** — streaming upload/download, never loads the whole file into RAM
- **Resumable** — persists state to a JSON file; Ctrl+C then re-run to resume (both upload & download)
- **Parallel** — thread pool uploads multiple parts in parallel
- **SSE encryption** — supports SSE-S3, SSE-KMS, SSE-C
- **Retry** — automatic retry with exponential backoff + jitter for transient errors and 429
- **Observable** — structured logging, debug mode, event callbacks, thread-safe logging
- **Auto-dispatch** — `upload_file` automatically chooses single PUT or multipart based on file size

---

## Table of contents

- [Requirements](#requirements)
- [Installation](#installation)
- [Initializing the client](#initializing-the-client)
  - [SSE encryption](#sse-encryption)
- [Uploading files](#uploading-files)
  - [Auto-dispatch upload](#auto-dispatch-upload)
  - [Resumable upload with state file](#resumable-upload-with-state-file)
  - [Explicit resume with resume_upload](#explicit-resume-with-resume_upload)
- [Downloading files](#downloading-files)
  - [Streaming download](#streaming-download)
  - [Download with Range](#download-with-range)
  - [Block-based streaming (no disk write)](#block-based-streaming-no-disk-write)
- [HEAD / DELETE object](#head--delete-object)
- [Low-level multipart API](#low-level-multipart-api)
- [Presigned URL](#presigned-url)
- [UploadState class](#uploadstate-class)
- [DownloadState class](#downloadstate-class)
- [PartUploader class](#partuploader-class)
- [S3Helper convenience module](#s3helper-convenience-module)
- [Logging & Observability](#logging--observability)
  - [Structured Logging](#structured-logging)
  - [Debug Mode](#debug-mode)
  - [Event Callbacks — 17 lifecycle events](#event-callbacks--17-lifecycle-events)
  - [Thread-safe Logging](#thread-safe-logging)
  - [Debugging the state file after a crash](#debugging-the-state-file-after-a-crash)
- [Manual testing against real S3](#manual-testing-against-real-s3)
- [Running the automated test suite](#running-the-automated-test-suite)
- [Troubleshooting common errors](#troubleshooting-common-errors)

---

## Requirements

- Ruby 3.2+
- Gem: `aws-sigv4`

```bash
gem install aws-sigv4
```

## Installation

Copy `s3_multi_bucket_client.rb` into your project and require it:

```ruby
require_relative 'path/to/src/s3_multi_bucket_client'
```

---

## Initializing the client

### Basic

```ruby
require 'logger'

client = S3MultiBucketClient.new(
  endpoint:          'https://s3.ap-southeast-1.amazonaws.com',
  region:            'ap-southeast-1',
  access_key_id:     ENV['S3_ACCESS_KEY_ID'],
  secret_access_key: ENV['S3_SECRET_ACCESS_KEY'],
  logger:            Logger.new($stdout, level: Logger::INFO)
)
```

### With MinIO / Cloudflare R2 (path-style endpoint)

```ruby
client = S3MultiBucketClient.new(
  endpoint:          'https://minio.local:9000',
  region:            'us-east-1',
  access_key_id:     'minioadmin',
  secret_access_key: 'minioadmin',
  logger:            Logger.new($stdout)
)
```

### With a session token (STS temporary credentials)

```ruby
client = S3MultiBucketClient.new(
  endpoint:          'https://s3.amazonaws.com',
  region:            'us-east-1',
  access_key_id:     'ASIA...',
  secret_access_key: '...',
  session_token:     'FwoGZXIvYXdzE...',
  open_timeout:      10,
  read_timeout:      600
)
```

### Initialization parameters

| Parameter | Type | Default | Description |
|---|---|---|---|
| `endpoint` | String | (required unless `bucket:`) | S3 endpoint |
| `region` | String | (required) | AWS region |
| `access_key_id` | String | (required) | AWS Access Key |
| `secret_access_key` | String | (required) | AWS Secret Key |
| `bucket` | String | `nil` | Optional default bucket |
| `session_token` | String | `nil` | STS token |
| `part_size` | Integer | `8 * 1024 * 1024` | Part size (8 MB) |
| `max_concurrency` | Integer | `4` | Parallel threads (1–32) |
| `max_retries` | Integer | `3` | Retry count |
| `retry_delay` | Float | `0.25` | Backoff base delay |
| `open_timeout` | Integer | `30` | Connection timeout |
| `read_timeout` | Integer | `600` | Read timeout |
| `endpoint_style` | Symbol | `:auto` | `:auto` / `:virtual_hosted` / `:path` |
| `logger` | Logger | `nil` | Custom Logger |
| `log_file` | String | `nil` | Log file path |
| `log_format` | Symbol | `:text` | `:text` or `:json` |
| `log_color` | Boolean | `false` | ANSI color |
| `debug` | Boolean | `false` | Detailed HTTP logging |
| `sse` | Hash | `nil` | SSE config |

### SSE encryption

```ruby
# SSE-S3 (AWS-managed key)
client = S3MultiBucketClient.new(
  ...,
  sse: { type: 'AES256' }
)

# SSE-KMS (AWS KMS key)
client = S3MultiBucketClient.new(
  ...,
  sse: { type: 'aws:kms', kms_key_id: 'arn:aws:kms:us-east-1:123456:key/abc-...' }
)

# SSE-C (Customer-provided key — key sent on every request, NEVER logged)
require 'base64'
require 'digest'
raw_key = SecureRandom.bytes(32)
client = S3MultiBucketClient.new(
  ...,
  sse: {
    type:    'customer',
    key:     Base64.strict_encode64(raw_key),
    key_md5: Base64.strict_encode64(Digest::MD5.digest(raw_key))
  }
)
```

---

## Uploading files

### Auto-dispatch upload

`upload_file` automatically dispatches based on file size:
- **0 bytes** → EmptyUpload (no HTTP request)
- **≤ part_size** → SinglePartUpload (single PUT)
- **> part_size** → MultipartUpload (parallel, resumable)

```ruby
# Small file → single PUT
result = client.upload_file(
  bucket:       'my-bucket',
  key:          'data/report.csv',
  local_path:   '/tmp/report.csv',
  content_type: 'text/csv',
  metadata:     { 'author' => 'alice', 'version' => '2' },
  cache_control: 'max-age=3600'
)
# => #<data UploadResult key="data/report.csv", size=1048576, etag="\"a1b2c3...\"", elapsed=0.42, throughput=2.38, extra={}>

puts result.key    # "data/report.csv"
puts result[:size] # 1048576
puts result.to_h   # { key: "data/report.csv", size: 1048576, ... }
```

```ruby
# Large file → multipart (parallel, resumable)
result = client.upload_file(
  bucket:       'my-bucket',
  key:          'data/huge.bin',
  local_path:   '/tmp/huge.bin',
  part_size:    8 * 1024 * 1024,
  max_threads:  4,
  content_type: 'application/octet-stream',
  metadata:     { 'project' => 'alpha' },
  state_file:   '/tmp/huge.upload.json',
  on_progress:  ->(completed, total, pct) {
    puts "Part #{completed}/#{total} (#{pct}%)"
  }
)
# => #<data UploadResult key="data/huge.bin", size=209715200, etag="\"abc-...\"", elapsed=35.2, throughput=5.68, extra={upload_id: "abc-123-...", parts_uploaded: 25}>
```

**RAM consumption:** `~part_size × max_threads` (each thread reads one part into a buffer before sending).

> **S3 constraints:** `5MB ≤ part_size ≤ 5GB`, maximum **10,000 parts**/file. The library auto-adjusts `part_size` if the limit would be exceeded.

**On failure:** raises `S3BaseClient::UploadError` or `S3BaseClient::S3Error`.

### Resumable upload with state file

When uploading large files over an unreliable network:

```ruby
# First run: pass state_file
client.upload_file(
  bucket:     'my-bucket',
  key:        'data/huge.bin',
  local_path: '/tmp/huge.bin',
  state_file: '/tmp/huge.upload.json'
)

# If Ctrl+C or crash occurs, re-run the same command → auto-resumes
# State file is automatically deleted when the upload completes
```

### Explicit resume with `resume_upload`

```ruby
result = client.resume_upload(
  bucket:     'my-bucket',
  key:        'data/huge.bin',
  local_path: '/tmp/huge.bin',
  state_file: '/tmp/huge.upload.json',
  on_progress: ->(completed, total, pct) {
    puts "#{completed}/#{total} (#{pct}%)"
  }
)
# => #<data UploadResult key="data/huge.bin", ...>
```

---

## Downloading files

### Streaming download

Streams chunks from the server to disk, RAM never grows with file size.

```ruby
result = client.download_file(
  bucket:     'my-bucket',
  key:        'data/huge.bin',
  local_path: '/tmp/huge_copy.bin',
  on_progress: ->(current, total, pct) {
    puts "#{current}/#{total} bytes (#{pct}%)"
  }
)
# => #<data DownloadResult path="/tmp/huge_copy.bin", size=209715200, elapsed=20.1, throughput=9.94, extra={}>

puts result.path   # "/tmp/huge_copy.bin"
puts result[:size] # 209715200
```

### Download with Range

`download_file` supports the `range:` parameter for partial downloads:

```ruby
# Download bytes 0 → 1MB-1 (first 1MB) — using an Array
client.download_file(
  bucket:           'my-bucket',
  key:              'data/huge.bin',
  destination_path: '/tmp/chunk.bin',
  range:            [0, 1024 * 1024 - 1]
)

# Or using a Ruby Range
client.download_file(
  bucket:           'my-bucket',
  key:              'data/huge.bin',
  destination_path: '/tmp/chunk.bin',
  range:            0..(1024 * 1024 - 1)
)

# Exclusive range
client.download_file(
  bucket:           'my-bucket',
  key:              'data/huge.bin',
  destination_path: '/tmp/chunk.bin',
  range:            0...1024
)
```

### Block-based streaming (no disk write)

Pipe directly into a parser / upstream proxy / unzip:

```ruby
client.download_stream(bucket: 'my-bucket', key: 'data/huge.bin') do |chunk|
  $stdout.write(chunk)
end

# With Range
written = client.download_stream(
  bucket: 'my-bucket',
  key:    'data/huge.bin',
  range:  (1_000_000..2_000_000)
) { |chunk| process(chunk) }
```

---

## HEAD / DELETE object

### HEAD — get metadata

```ruby
info = client.head_object(bucket: 'my-bucket', key: 'data/file.txt')
# => {
#   content_length: 1048576,
#   content_type: "text/plain",
#   etag: "\"abc123...\"",
#   last_modified: "Mon, 02 Jun 2025 10:00:00 GMT",
#   storage_class: "STANDARD",
#   metadata: { "author" => "alice", "version" => "2" }
# }

puts info[:content_length]       # 1048576
puts info[:metadata]['author']   # "alice"
puts info[:storage_class]        # "STANDARD"
```

### DELETE — delete an object

```ruby
result = client.delete_object(bucket: 'my-bucket', key: 'data/file.txt')
# => { key: "data/file.txt", status: "deleted" }
```

---

## Low-level multipart API

For use cases that manage the multipart lifecycle manually (e.g., resuming across processes/machines):

```ruby
# 1. Start a multipart upload
upload_id = client.multipart_start(
  bucket:       'my-bucket',
  key:          'data/file.bin',
  content_type: 'application/octet-stream',
  metadata:     { 'source' => 'manual' },
  cache_control: 'max-age=86400'
)

# 2. Upload each part
etag1 = client.multipart_upload_part(
  bucket:      'my-bucket',
  key:         'data/file.bin',
  upload_id:   upload_id,
  part_number: 1,
  body:        File.binread('/tmp/part1.bin')
)

# Or with IO
File.open('/tmp/part2.bin', 'rb') do |f|
  etag2 = client.multipart_upload_part(
    bucket:      'my-bucket',
    key:         'data/file.bin',
    upload_id:   upload_id,
    part_number: 2,
    body:        f,
    length:      File.size('/tmp/part2.bin'),
    io_offset:   0
  )
end

# 3. Complete
final_etag = client.multipart_complete(
  bucket:    'my-bucket',
  key:       'data/file.bin',
  upload_id: upload_id,
  parts:     [
    { part_number: 1, etag: etag1 },
    { part_number: 2, etag: etag2 }
  ]
)

# Or abort
client.multipart_abort(
  bucket:    'my-bucket',
  key:       'data/file.bin',
  upload_id: upload_id
)
```

---

## Presigned URL

Generate temporary signed URLs, no credentials needed:

```ruby
# GET URL (read file)
url = client.presigned_url(
  bucket:     'my-bucket',
  key:        'data/file.txt',
  method:     :get,
  expires_in: 3600
)

# PUT URL (upload file)
url = client.presigned_url(
  bucket:     'my-bucket',
  key:        'uploads/new.bin',
  method:     :put,
  expires_in: 600
)

# With additional query params
url = client.presigned_url(
  bucket:     'my-bucket',
  key:        'data/file.txt',
  method:     :get,
  expires_in: 3600,
  query:      { 'response-content-disposition' => 'attachment; filename="download.txt"' }
)
```

---

## UploadState class

OOP wrapper for resumable upload state:

```ruby
# Create new
state = S3MultiBucketClient::UploadState.new(
  upload_id:  'abc-123',
  key:        'data/file.bin',
  local_path: '/tmp/file.bin',
  part_size:  8 * 1024 * 1024,
  total_size: 200 * 1024 * 1024,
  parts:      [
    { part_number: 1, etag: '"e1"', size: 8 * 1024 * 1024 },
    { part_number: 2, etag: '"e2"', size: 8 * 1024 * 1024 }
  ]
)

# Serialize
json = state.to_json
hash = state.to_h
state.save_to_file('/tmp/state.json')

# Deserialize
state = S3MultiBucketClient::UploadState.from_json(json_string)
state = S3MultiBucketClient::UploadState.from_file('/tmp/state.json')

# Tracking methods
state.upload_id               # "abc-123"
state.completed_parts_count   # 2
state.total_parts             # 25
state.progress_percentage     # 8.0
state.bytes_uploaded          # 16777216
state.pending_part_numbers    # [3, 4, 5, ... 25]
state.next_part_number        # 3
state.part_list               # [{part_number: 1, etag: '"e1"'}, ...]
state.completed?              # false

# Session & tracking
state.upload_session_id       # "a5f8bf53ebadba22" (16-char hex, unchanged on resume)
state.file_fingerprint        # "mtime_float-size" fast fingerprint (always present)
state.file_mtime              # mtime of the local file
state.file_md5                # MD5 of the file (nil unless set externally)
state.last_part_completed_at  # "2026-06-03T08:05:12Z"
state.resumed_at              # "2026-06-03T08:06:00Z" (if resumed)
state.resume_count            # 2 (number of resumes)
state.started_at              # "2026-06-03T08:00:00Z"
state.last_updated_at         # "2026-06-03T08:05:12Z"

# Thread & in-progress tracking
state.in_progress_part_numbers  # [14, 15] — parts currently uploading
state.in_progress_parts         # {14 => "t2", 15 => "t0"}
state.thread_states             # {"t0" => {status:, current_part:, parts_done:, ...}, ...}

# Concise summary for logs
state.summary  # "parts=2/25 (8.0%) bytes=16777216/209715200 in_progress=[14, 15] threads=4"
```

---

## DownloadState class

OOP wrapper for resumable download state:

```ruby
# Create new
state = S3MultiBucketClient::DownloadState.new(
  key:              'data/file.bin',
  bucket:           'my-bucket',
  destination_path: '/tmp/file.bin',
  total_size:       200 * 1024 * 1024,
  part_size:        8 * 1024 * 1024,
  parts:            [
    { part_number: 1, size: 8 * 1024 * 1024 },
    { part_number: 2, size: 8 * 1024 * 1024 }
  ]
)

# Serialize
json = state.to_json
hash = state.to_h
state.save_to_file('/tmp/dl-state.json')

# Deserialize
state = S3MultiBucketClient::DownloadState.from_json(json_string)
state = S3MultiBucketClient::DownloadState.from_file('/tmp/dl-state.json')

# Tracking methods
state.completed_parts_count   # 2
state.total_parts             # 25
state.progress_percentage     # 8.0
state.bytes_downloaded        # 16777216
state.pending_part_numbers    # [3, 4, 5, ... 25]
state.completed?              # false

# Session & tracking
state.download_session_id     # "a5f8bf53..."
state.resumed_at              # "2026-06-06T10:00:00Z"
state.resume_count            # 1
state.started_at              # "2026-06-06T09:50:00Z"
state.last_updated_at         # "2026-06-06T09:55:00Z"

state.summary  # "parts=2/25 (8.0%) bytes=16777216/209715200"
```

---

## PartUploader class

Standalone parallel uploader, works with UploadState:

```ruby
# Build an UploadState
state = S3MultiBucketClient::UploadState.new(
  upload_id:  upload_id,
  key:        'data/file.bin',
  local_path: '/tmp/file.bin',
  part_size:  8 * 1024 * 1024,
  total_size: File.size('/tmp/file.bin'),
  parts:      { 1 => '"etag1"' }
)

# Upload the missing parts
uploader = S3MultiBucketClient::PartUploader.new(
  client, state,
  max_threads:       4,
  max_retries:       3,
  retry_delay:       0.25,
  on_progress:       ->(completed, total, pct) { puts "#{pct}%" },
  state_file:        '/tmp/state.json'
)

parts = uploader.upload_all!

# Complete
client.multipart_complete(
  bucket:    state.bucket,
  key:       state.key,
  upload_id: state.upload_id,
  parts:     state.part_list
)
```

---

## S3Helper convenience module

```ruby
# Auto-detect single/multipart
S3Helper.upload(
  client:    client,
  bucket:    'my-bucket',
  key:       'data/file.bin',
  local_path: '/tmp/file.bin'
)

# Download with a progress bar
S3Helper.download(
  client:        client,
  bucket:        'my-bucket',
  key:           'data/file.bin',
  destination:   '/tmp/file.bin',
  show_progress: true
)

# Bulk upload a directory
S3Helper.upload_bulk(
  client:      client,
  directory:   './public/',
  bucket:      'my-bucket',
  prefix:      'assets/',
  pattern:     '**/*',
  exclude:     ['*.log', '*.tmp'],
  max_files:   4,
  on_file_start:   ->(key) { puts "Starting #{key}" },
  on_file_complete: ->(result) { puts "Done: #{result.key}" },
  on_file_error:   ->(key, error) { puts "Failed: #{key}: #{error}" }
)
```

---

## Logging & Observability

`S3MultiBucketClient` has a 4-layer observability system: structured logging, debug mode, event callbacks, and thread-safe logging.

### Structured Logging

3 ways to pass a logger:

```ruby
# 1. Custom logger
client = S3MultiBucketClient.new(..., logger: Logger.new($stdout, level: Logger::INFO))

# 2. Write to a file
client = S3MultiBucketClient.new(..., log_file: 'upload.log')

# 3. Default STDOUT
client = S3MultiBucketClient.new(...)
```

Custom formatter with millisecond timestamps:
```
[2026-06-03 16:39:32.901] INFO -- [S3] upload_file start: "huge.bin" -> key="data/huge.bin" ...
```

4 log levels: `DEBUG` (detailed HTTP), `INFO` (lifecycle), `WARN` (retries, mismatches), `ERROR` (failures).

### Debug Mode

When `debug: true`, log every HTTP request/response in detail:

```ruby
client = S3MultiBucketClient.new(
  ...,
  log_file: 'debug.log',
  debug:    true
)
```

Sample output:
```
[2026-06-03 16:39:32.901] DEBUG -- [S3] [DETAILED REQUEST] PUT http://...
[2026-06-03 16:39:32.901] DEBUG -- [S3]   Body size: 8388608 bytes
[2026-06-03 16:39:33.100] DEBUG -- [S3] [DETAILED RESPONSE] 200 OK
[2026-06-03 16:39:33.100] DEBUG -- [S3]   Header: ETag: "abc123..."
```

### Event Callbacks — 17 lifecycle events

Register callbacks at the **class level** (applies to every instance):

**Upload events:**

| Event | Parameters | When it fires |
|---|---|---|
| `:upload_start` | `(local_path, key, size, total_parts, part_size, resumed)` | Upload starts |
| `:upload_resume` | `(state)` | Resuming from a state file |
| `:part_start` | `(part_number, total_parts, thread_id, offset, length)` | Thread starts a part |
| `:part_complete` | `(part_number, total_parts, thread_id, etag, bytes, elapsed_ms, throughput)` | Part completes |
| `:part_retry` | `(part_number, thread_id, attempt, max_retries, backoff, error)` | Retrying a part |
| `:part_failed` | `(part_number, thread_id, error, exhausted)` | Part fails |
| `:state_save` | `(state_snapshot, completed_count, total_parts, thread_id)` | State written to disk |
| `:state_load` | `(state, path)` | State loaded on resume |
| `:state_mismatch` | `(old_state, new_key, new_size)` | State doesn't match |
| `:upload_complete` | `(result, elapsed, throughput)` | Upload succeeds |
| `:upload_failed` | `(error, state_preserved_path)` | Upload fails |

**Download events:**

| Event | Parameters | When it fires |
|---|---|---|
| `:download_start` | `(key, bucket, total_size)` | Download starts |
| `:download_complete` | `(result, elapsed, throughput)` | Download succeeds |
| `:download_failed` | `(error)` | Download fails |

**Common events:**

| Event | Parameters | When it fires |
|---|---|---|
| `:thread_start` | `(thread_id, thread_object_id)` | Worker thread starts |
| `:thread_finish` | `(thread_id, thread_object_id, parts_processed)` | Worker thread ends |
| `:log` | `(level, message, thread_id, timestamp)` | Custom log from a worker thread |

```ruby
# Register a callback
cb = S3MultiBucketClient.on(:part_complete) do |pn, total, tid, etag, bytes, ms, speed|
  puts "#{tid} ✓ part #{pn}/#{total} #{bytes / 1024 / 1024} MB @ #{speed} MB/s"
end

S3MultiBucketClient.on(:upload_complete) do |result, elapsed, throughput|
  notify_slack("Upload done: #{result.key} (#{'%.1f' % throughput} MB/s)")
end

# Unregister a callback
S3MultiBucketClient.off(:part_complete, cb)

# Clear all
S3MultiBucketClient.clear_callbacks!
```

**Use cases:** progress bar UI, retry/failure alerts, centralized logging, monitoring dashboard. Callback errors do not fail the upload.

### Thread-safe Logging

Inside worker threads, **don't use `puts`** (output gets interleaved). Use:

```ruby
# From a worker thread
client.thread_log_info("custom message", "t0")
client.thread_log_warn("warning", "t0")
client.thread_log_error("error", "t0")
```

Output format:
```
[2026-06-03 16:38:50.914] INFO -- [thread:t0] [S3] part 5/35 done
```

### Debugging the state file after a crash

```ruby
state = S3MultiBucketClient::UploadState.from_file('upload-state.json')
puts "Session:    #{state.upload_session_id}"
puts "Progress:   #{state.summary}"
puts "Completed:  #{state.part_list.map { |p| p[:part_number] }.inspect}"
puts "In-progress:#{state.in_progress_part_numbers.inspect}"
puts "Pending:    #{state.pending_part_numbers.inspect}"
puts "Threads:    #{state.thread_states.keys.inspect}"
```

---

## Manual testing against real S3

### 1. Upload a file

```ruby
require_relative 's3_multi_bucket_client'
require 'logger'

client = S3MultiBucketClient.new(
  endpoint:          "https://s3.#{ENV['S3_REGION']}.amazonaws.com",
  region:            ENV['S3_REGION'],
  access_key_id:     ENV['S3_ACCESS_KEY_ID'],
  secret_access_key: ENV['S3_SECRET_ACCESS_KEY'],
  logger:            Logger.new($stdout, level: Logger::INFO)
)

# Create a test file
File.write('/tmp/test_small.txt', 'Hello from S3MultiBucketClient!')

# Upload
result = client.upload_file(
  bucket:       ENV['S3_BUCKET'],
  key:          'test/small.txt',
  local_path:   '/tmp/test_small.txt',
  content_type: 'text/plain',
  metadata:     { 'test' => 'true' }
)
puts "Upload: key=#{result.key} size=#{result.size}"

# Verify with HEAD
info = client.head_object(bucket: ENV['S3_BUCKET'], key: 'test/small.txt')
puts "HEAD: #{info.inspect}"

# Cleanup
client.delete_object(bucket: ENV['S3_BUCKET'], key: 'test/small.txt')
```

### 2. Upload a large file with resume

```ruby
# Generate a 50MB file
File.open('/tmp/test_big.bin', 'wb') do |f|
  50.times { f.write(SecureRandom.bytes(1024 * 1024)) }
end

result = client.upload_file(
  bucket:     ENV['S3_BUCKET'],
  key:        'test/big.bin',
  local_path: '/tmp/test_big.bin',
  part_size:  5 * 1024 * 1024,
  state_file: '/tmp/test_big.state.json',
  on_progress: ->(c, t, pct) { print "\r#{pct}%" }
)
puts "\nDone! key=#{result.key}"

# Cleanup
client.delete_object(bucket: ENV['S3_BUCKET'], key: 'test/big.bin')
```

### 3. Download + verify

```ruby
result = client.download_file(
  bucket:     ENV['S3_BUCKET'],
  key:        'test/big.bin',
  local_path: '/tmp/downloaded.bin',
  on_progress: ->(c, t, pct) { print "\r#{pct}%" }
)
puts "\nDownloaded! path=#{result.path}"

# Stream download
total = 0
client.download_stream(bucket: ENV['S3_BUCKET'], key: 'test/big.bin') do |chunk|
  total += chunk.bytesize
end
puts "Streamed #{total} bytes"
```

### 4. Presigned URL

```ruby
url = client.presigned_url(
  bucket:     ENV['S3_BUCKET'],
  key:        'test/small.txt',
  expires_in: 300
)
puts "Download URL: #{url}"
```

---

## Running the automated test suite

### Requirements

```bash
gem install aws-sigv4 webrick minitest
# or
bundle install
```

### Running tests

```bash
# From the project root
rake test          # all tests (s3_client + s3_multi_bucket_client)
rake test:s3_multi_bucket_client
rake test:quick    # skip memory/race (fast)
```

### Running a single file

```bash
ruby tests/s3_multi_bucket_client/test_upload_state.rb
ruby tests/s3_multi_bucket_client/test_client.rb
ruby tests/s3_multi_bucket_client/test_smoke.rb
ruby tests/s3_multi_bucket_client/test_state.rb
ruby tests/s3_multi_bucket_client/test_features.rb
```

### Running a single test

```bash
ruby tests/s3_multi_bucket_client/test_client.rb -n test_human_readable_size
```

### Demo: Ctrl+C → resume

```bash
ruby tests/interactive/upload_resume_s3_multi_bucket_client.rb
```

### Test files

| File | # tests | Description |
|---|---|---|
| `tests/s3_multi_bucket_client/test_upload_state.rb` | 9 | UploadState: creation, serialization, tracking, gap detection, session |
| `tests/s3_multi_bucket_client/test_client.rb` | 22 | Client init, validation, utilities, constants, errors, XML, thread safety |
| `tests/s3_multi_bucket_client/test_smoke.rb` | 17 | Upload (auto-dispatch), download, HEAD, DELETE, low-level multipart, S3Helper |
| `tests/s3_multi_bucket_client/test_state.rb` | 3 | Full upload + state, resume from state, resume via resume_upload |
| `tests/s3_multi_bucket_client/test_race.rb` | 2 | Concurrent upload monotonic state, resume from half |
| `tests/s3_multi_bucket_client/test_memory.rb` | 1 | RAM measurement for a 200MB upload/download |
| `tests/s3_multi_bucket_client/test_features.rb` | 8 | Presigned, list multipart, events, logging, session tracking |

### Fake S3 server

The test suite shares a fake S3 server (WEBrick) from `tests/support/fake_s3_server.rb`. The server supports:

- Single PUT / GET / HEAD / DELETE
- Multipart: initiate, upload part, complete, abort
- Range download, Content-Range
- Metadata (x-amz-meta-*), Cache-Control
- List multipart uploads, list parts

### Cleanup

```bash
rm -rf tests/tmp/
```

---

## Troubleshooting common errors

### `ArgumentError: access_key_id is empty`

```ruby
# Fix: check ENV before passing
raise "Missing AWS credentials" unless ENV['S3_ACCESS_KEY_ID']
```

### `S3Error [403] Forbidden`

- Verify the IAM policy has `s3:PutObject`, `s3:GetObject`, `s3:DeleteObject` permissions
- For multipart: also requires `s3:ListMultipartUploadParts`, `s3:AbortMultipartUpload`

### `S3Error [404] Not Found` when resuming

The multipart upload on S3 has expired (lifecycle rule, typically 7 days). Delete the state file and re-upload:

```ruby
File.delete('/tmp/huge.upload.json') if File.exist?('/tmp/huge.upload.json')
```

### Logger too noisy

```ruby
# Lower the log level
client = S3MultiBucketClient.new(
  ...,
  logger: Logger.new($stdout, level: Logger::WARN)
)
```

### Inspect which transient errors are retried

```ruby
client.transient_errors
# => [Net::OpenTimeout, Net::ReadTimeout, Errno::ECONNRESET,
#     Errno::EPIPE, Errno::ECONNABORTED, EOFError, SocketError, IOError]
```

---

## Public method reference

| Method | Description |
|---|---|
| `upload_file` | Upload (auto-dispatch: single PUT or multipart based on size) |
| `resume_upload` | Resume from a state file |
| `upload_directory` | Upload all files in a directory |
| `download_file` | Streaming download (supports `range:`) |
| `download_stream` | Block-based streaming |
| `head_object` | GET metadata → parsed Hash |
| `delete_object` | Delete an object |
| `presigned_url` | Generate a signed URL |
| `list_multipart_uploads` | List in-progress multipart uploads |
| `list_parts` | List uploaded parts |
| `abort_multipart_upload` | Abort a multipart upload |
| `multipart_start` | Initiate a multipart upload (low-level) |
| `multipart_upload_part` | Upload a single part (low-level) |
| `multipart_complete` | Complete a multipart upload (low-level) |
| `multipart_abort` | Abort a multipart upload (low-level) |
| `setup_logger` | Configure the logger |
| `log_info/debug/warn/error` | Log with `[S3]` prefix |
| `thread_log_info/debug/warn/error` | Thread-safe logging (queued messages) |

**Class methods** (called on `S3MultiBucketClient`):

| Method | Description |
|---|---|
| `S3MultiBucketClient.on(event, &block)` | Register a callback for an event (returns the proc) |
| `S3MultiBucketClient.off(event, callback)` | Unregister a previously registered callback |
| `S3MultiBucketClient.clear_callbacks!` | Clear all callbacks |

## Result objects

| Class | Fields |
|---|---|
| `S3MultiBucketClient::UploadResult` | `key`, `size`, `etag`, `elapsed`, `throughput`, `extra` |
| `S3MultiBucketClient::DownloadResult` | `path`, `size`, `elapsed`, `throughput`, `extra` |

Access via `result.field`, `result[:field]`, or `result.to_h`.

## Nested classes

| Class | Description |
|---|---|
| `S3MultiBucketClient::UploadState` | Resumable upload state wrapper |
| `S3MultiBucketClient::DownloadState` | Resumable download state wrapper |
| `S3MultiBucketClient::PartUploader` | Standalone parallel uploader |
| `S3MultiBucketClient::PartDownloader` | Standalone parallel downloader (Range requests) |
| `S3MultiBucketClient::S3Error` | Structured S3 error |
| `S3MultiBucketClient::UploadError` | Upload-specific error |
| `S3MultiBucketClient::DownloadError` | Download-specific error |
