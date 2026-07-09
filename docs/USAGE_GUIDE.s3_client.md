# S3Client - Detailed Usage Guide

> 🌐 Language / Ngôn ngữ: **English** | [Tiếng Việt](USAGE_GUIDE.s3_client.vi.md)

A pure Ruby library (no AWS SDK dependency) for uploading/downloading large files to S3-compatible storage (AWS S3, MinIO, Cloudflare R2, Backblaze B2, …) with the following features:

- **Memory-efficient** — streaming upload/download, never loads the whole file into RAM
- **Resumable** — persists state to a JSON file; Ctrl+C then re-run to resume (both upload & download)
- **Parallel** — thread pool uploads multiple parts in parallel
- **SSE encryption** — supports SSE-S3, SSE-KMS, SSE-C
- **Retry** — automatic retry with exponential backoff + jitter for transient errors, S3 5xx and 429
- **Observable** — structured logging, debug mode, 21 event callbacks, thread-safe logging
- **Unified API** — `upload_file` auto-selects single PUT or multipart based on file size

---

## Table of contents

- [Requirements](#requirements)
- [Installation](#installation)
- [Initializing the client](#initializing-the-client)
- [Uploading files](#uploading-files)
  - [Unified API — auto-select single PUT / multipart](#unified-api--auto-select-single-put--multipart)
  - [Multipart upload with progress callback](#multipart-upload-with-progress-callback)
  - [Resumable upload with state file](#resumable-upload-with-state-file)
  - [Explicit resume with resume_upload](#explicit-resume-with-resume_upload)
- [Downloading files](#downloading-files)
  - [Streaming download](#streaming-download)
  - [Download with Range](#download-with-range)
  - [Block-based streaming (no disk write)](#block-based-streaming-no-disk-write)
- [HEAD / DELETE object](#head--delete-object)
- [Low-level multipart API](#low-level-multipart-api)
- [Presigned URL](#presigned-url)
- [List multipart uploads / parts](#list-multipart-uploads--parts)
- [UploadState class](#uploadstate-class)
  - [S3Helper convenience module](#s3helper-convenience-module)
- [Logging & Observability](#logging--observability)
  - [Structured Logging](#structured-logging)
  - [Debug Mode](#debug-mode)
  - [Event Callbacks — 21 lifecycle events](#event-callbacks--21-lifecycle-events)
  - [Thread-safe Logging](#thread-safe-logging)
  - [Debugging the state file after a crash](#debugging-the-state-file-after-a-crash)
- [Result objects](#result-objects)
- [Error handling](#error-handling)
- [Running the automated test suite](#running-the-automated-test-suite)
- [Troubleshooting common errors](#troubleshooting-common-errors)
- [Public method reference](#public-method-reference)

---

## Requirements

- Ruby 3.2+
- Gem: `aws-sigv4`

```bash
gem install aws-sigv4
```

## Installation

Copy `s3_client.rb` into your project and require it:

```ruby
require_relative 'path/to/src/s3_client'
```

---

## Initializing the client

### AWS S3 (virtual-hosted style — default)

```ruby
require 'logger'

client = S3Client.new(
  region:            'ap-southeast-1',
  bucket:            'my-bucket',
  access_key_id:     ENV['S3_ACCESS_KEY_ID'],
  secret_access_key: ENV['S3_SECRET_ACCESS_KEY'],
  logger:            Logger.new($stdout, level: Logger::INFO)
)
```

### MinIO / Cloudflare R2 / Backblaze B2 (path-style)

```ruby
client = S3Client.new(
  region:            'us-east-1',
  bucket:            'my-bucket',
  access_key_id:     'minioadmin',
  secret_access_key: 'minioadmin',
  endpoint:          'https://minio.local:9000',
  endpoint_style:    :path,
  logger:            Logger.new($stdout)
)
```

### AWS STS (temporary credentials)

```ruby
client = S3Client.new(
  region:            'us-east-1',
  bucket:            'my-bucket',
  access_key_id:     ENV['S3_ACCESS_KEY_ID'],
  secret_access_key: ENV['S3_SECRET_ACCESS_KEY'],
  session_token:     ENV['AWS_SESSION_TOKEN'],
  open_timeout:      10,
  read_timeout:      600
)
```

### With file logging + debug mode

```ruby
client = S3Client.new(
  region:            'us-east-1',
  bucket:            'my-bucket',
  access_key_id:     ENV['S3_ACCESS_KEY_ID'],
  secret_access_key: ENV['S3_SECRET_ACCESS_KEY'],
  log_file:          's3_upload.log',
  debug:             true
)
```

### Initialization parameters

| Parameter | Type | Default | Description |
|---|---|---|---|
| `region` | String | (required) | AWS region |
| `bucket` | String | (required) | S3 bucket name |
| `access_key_id` | String | (required) | AWS Access Key |
| `secret_access_key` | String | (required) | AWS Secret Key |
| `endpoint` | String | `nil` | Custom endpoint URL |
| `session_token` | String | `nil` | STS session token |
| `part_size` | Integer | `10 * 1024 * 1024` | Part size (10 MB, min 5 MB) |
| `max_concurrency` | Integer | `4` | Parallel threads (1–32) |
| `max_retries` | Integer | `3` | Retry count |
| `retry_delay` | Float | `0.25` | Backoff base delay |
| `open_timeout` | Integer | `30` | Connection timeout |
| `read_timeout` | Integer | `600` | Read timeout |
| `endpoint_style` | Symbol | `:auto` | `:auto` / `:virtual_hosted` / `:path` |
| `logger` | Logger | `nil` | Custom Logger |
| `log_file` | String | `nil` | Log file path |
| `log_format` | Symbol | `:text` | `:text` or `:json` |
| `log_color` | Boolean | `false` | ANSI colors |
| `debug` | Boolean | `false` | Detailed HTTP logging |
| `sse` | Hash | `nil` | SSE config |

> **`endpoint_style: :auto`** — auto-detect: custom endpoint → `:path`, AWS default → `:virtual_hosted`.

### SSE encryption configuration

```ruby
# SSE-S3
sse = { type: "AES256" }

# SSE-KMS
sse = { type: "aws:kms", kms_key_id: "arn:aws:kms:..." }

# SSE-C
sse = { type: "customer", key: Base64.strict_encode64(raw_key), key_md5: Base64.strict_encode64(Digest::MD5.digest(raw_key)) }
```

> **Thread Safety:** Client instances are NOT thread-safe for concurrent public API calls. Internally, multipart uploads manage worker threads safely.

---

## Uploading files

### Unified API — auto-select single PUT / multipart

`upload_file` is the main method, **auto-deciding** the upload strategy based on file size:

| File size | Behavior |
|---|---|
| 0 bytes | EmptyUpload (single PUT with 0-length body) |
| ≤ `part_size` | SinglePartUpload (streaming PUT) |
| > `part_size` | MultipartUpload (parallel multipart) |

```ruby
result = client.upload_file(
  local_path:   '/path/to/huge.bin',
  key:          'data/huge.bin',
  content_type: 'application/octet-stream',
  metadata:     { 'user' => 'alice' },
  cache_control: 'max-age=3600',
  on_progress:  ->(written, total) {
    puts "#{written}/#{total} bytes"
  }
)

puts "Upload: key=#{result.key} etag=#{result.etag} size=#{result.size}"
puts "Elapsed: #{'%.1f' % result.elapsed}s, throughput: #{'%.1f' % result.throughput} MB/s"
```

**RAM consumption:** `~part_size × max_concurrency` (each thread reads one part into a buffer before sending).

### Multipart upload with progress callback

When the file is larger than `part_size`, the upload automatically switches to multipart:

```ruby
progress = ->(written, total) {
  pct = total.positive? ? (written.to_f / total * 100).round(1) : 0
  puts "  #{written / 1024 / 1024} / #{total / 1024 / 1024} MB (#{pct}%)"
}

result = client.upload_file(
  local_path:   '/path/to/large-movie.mp4',
  key:          'videos/movie.mp4',
  part_size:    10 * 1024 * 1024,
  on_progress:  progress,
  state_file:   'upload-state.json'
)

puts "Upload: etag=#{result.etag}"
puts "Elapsed: #{'%.1f' % result.elapsed}s, throughput: #{'%.1f' % result.throughput} MB/s"
```

Sample output (INFO level):
```
[2026-06-03 16:39:32.901] INFO -- [S3] upload_file start: "movie.mp4" -> key="videos/movie.mp4" size=361806224 (345.00 MB) part_size=10485760 (10.00 MB) total_parts=35 concurrency=4
[2026-06-03 16:39:33.025] INFO -- [S3] [PART START] t0 → part 1/35 bytes=0-10485759 size=10.00 MB (2.9%)
[2026-06-03 16:39:33.213] INFO -- [S3] [PART DONE]  t0 ✓ part 1/35 size=10.00 MB time=187.3ms speed=53.38 MB/s | progress=10.00 MB/345.00 MB (2.9%) avg=52.14 MB/s ETA=6.4s
[2026-06-03 16:39:37.018] INFO -- [S3] [UPLOAD COMPLETE] key="videos/movie.mp4" etag="b33a03f8..." parts=35 elapsed=4.117s throughput=83.79 MB/s
```

> **⚠️ S3 constraints:** `5MB ≤ part_size ≤ 5GB`, maximum **10,000 parts**/file. `upload_file` raises `ArgumentError` if exceeded.

### Resumable upload with state file

When uploading large files over an unreliable network, **just add `state_file:`**:

```ruby
client.upload_file(
  local_path: '/path/to/huge.bin',
  key:        'data/huge.bin',
  state_file: 'huge.upload.json'
)
```

**Workflow:**
1. **No state file yet** → create new multipart upload → save state → upload each part → persist state after each part (atomic write + fsync + rename)
2. **State file exists** → load → validate (key/part_size/total_size/local_path must match) → resume, skipping already-completed parts
3. **Upload completes** → state file is **automatically deleted**
4. **Upload fails** → state file is **preserved** → re-run to resume

### Explicit resume with resume_upload

```ruby
if File.exist?('huge.upload.json')
  result = client.resume_upload(
    state_file:  'huge.upload.json',
    on_progress: ->(written, total) {
      puts "#{written / 1024 / 1024} / #{total / 1024 / 1024} MB"
    }
  )
end
```

---

## Downloading files

### Streaming download

Streams ~64KB chunks from the server to disk, RAM never grows with file size:

```ruby
result = client.download_file(
  key:         'data/huge.bin',
  local_path:  '/path/to/downloaded.bin',
  on_progress: ->(written, total) {
    puts "#{written}/#{total} bytes"
  }
)

puts "Downloaded #{result.size} bytes to #{result.path}"
puts "Elapsed: #{'%.1f' % result.elapsed}s, throughput: #{'%.1f' % result.throughput} MB/s"
```

### Download with Range

`download_file` supports the `range:` parameter directly:

```ruby
result = client.download_file(
  key:        'data/huge.bin',
  local_path: '/tmp/chunk.bin',
  range:      (1_000_000..2_000_000)
)
```

### Block-based streaming (no disk write)

Pipe directly into a parser / upstream proxy / unzip:

```ruby
client.download_stream(key: 'data/huge.bin') do |chunk|
  $stdout.write(chunk)
end

client.download_stream(key: 'data/huge.bin', range: (0..1023)) do |chunk|
  process(chunk)
end
```

---

## HEAD / DELETE object

### HEAD — get metadata

Returns a **parsed Hash** (not the raw response):

```ruby
info = client.head_object('data/file.txt')

puts info[:content_length]
puts info[:metadata]['author']
puts info[:storage_class]
```

### DELETE — delete an object

```ruby
code = client.delete_object('data/old-file.txt')
```

---

## Low-level multipart API

For use cases that manage the multipart lifecycle manually:

```ruby
upload_id = client.multipart_start(
  key:          'data/file.bin',
  content_type: 'application/octet-stream',
  metadata:     { 'source' => 'manual' },
  cache_control: 'max-age=86400'
)

etag1 = client.multipart_upload_part(
  key: 'data/file.bin', upload_id: upload_id,
  part_number: 1, body: File.binread('/tmp/part1.bin')
)

File.open('/tmp/part2.bin', 'rb') do |f|
  etag2 = client.multipart_upload_part(
    key: 'data/file.bin', upload_id: upload_id,
    part_number: 2, body: f,
    length: File.size('/tmp/part2.bin'), io_offset: 0
  )
end

final_etag = client.multipart_complete(
  key: 'data/file.bin', upload_id: upload_id,
  parts: [
    { part_number: 1, etag: etag1 },
    { part_number: 2, etag: etag2 }
  ]
)

client.multipart_abort(key: 'data/file.bin', upload_id: upload_id)

client.abort_multipart_upload(key: 'data/file.bin', upload_id: upload_id)
```

---

## Presigned URL

Generate temporary signed URLs, no credentials needed:

```ruby
url = client.presigned_url(
  key: 'data/file.txt', method: :get, expires_in: 3600
)

url = client.presigned_url(
  key: 'uploads/new.bin', method: :put, expires_in: 600
)

url = client.presigned_url(
  key: 'data/file.txt', method: :head, expires_in: 3600
)

url = client.presigned_url(
  key: 'data/old.txt', method: :delete, expires_in: 300
)

url = client.presigned_url(
  key: 'data/file.txt', method: :get, expires_in: 3600,
  query: { 'response-content-disposition' => 'attachment; filename="download.txt"' }
)
```

---

## List multipart uploads / parts

```ruby
client.list_multipart_uploads.each do |u|
  puts "#{u[:key]}: upload_id=#{u[:upload_id]} initiated=#{u[:initiated]}"
end

client.list_multipart_uploads(prefix: 'videos/', max_uploads: 50)

client.list_parts(key: 'data/file.bin', upload_id: 'abc-123').each do |p|
  puts "Part #{p[:part_number]}: etag=#{p[:etag]} size=#{p[:size]}"
end
```

---

## UploadState class

OOP wrapper for resumable upload state — serialization, progress tracking, thread tracking:

```ruby
state = S3Client::UploadState.new(
  upload_id:  'abc-123',
  key:        'data/file.bin',
  part_size:  10 * 1024 * 1024,
  total_size: 200 * 1024 * 1024,
  local_path: '/tmp/file.bin',
  parts:      { 1 => '"e1"', 2 => '"e2"' }
)

json = state.to_json
hash = state.to_h

state = S3Client::UploadState.from_json(json_string)
state = S3Client::UploadState.from_file('/tmp/state.json')

state.upload_id
state.completed_parts_count
state.total_parts
state.progress_percentage
state.bytes_uploaded
state.pending_part_numbers
state.next_part_number
state.part_list
state.completed?

state.upload_session_id
state.file_md5
state.file_mtime
state.file_fingerprint
state.last_part_completed_at
state.resumed_at
state.resume_count
state.started_at
state.last_updated_at

state.in_progress_part_numbers
state.in_progress_parts
state.thread_states

state.summary
```

---

## S3Helper convenience module

```ruby
S3Helper.upload(
  client:     client,
  key:        'data/file.bin',
  local_path: '/tmp/file.bin',
  multipart_threshold: 100 * 1024 * 1024
)

S3Helper.download(
  client:        client,
  key:           'data/file.bin',
  local_path:    '/tmp/downloaded.bin',
  show_progress: true
)

S3Helper.upload_bulk(
  client:     client,
  directory:  '/path/to/files',
  prefix:     'uploads/',
  pattern:    '**/*',
  max_files:  4,
  multipart_threshold: 100 * 1024 * 1024
)
```

---

## Logging & Observability

`S3Client` has a 4-layer observability system: structured logging, debug mode, event callbacks, and thread-safe logging.

### Structured Logging

3 ways to pass a logger:

```ruby
client = S3Client.new(..., logger: Logger.new($stdout, level: Logger::INFO))

client = S3Client.new(..., log_file: 'upload.log')

client = S3Client.new(...)
```

Custom formatter with millisecond timestamps:
```
[2026-06-03 16:39:32.901] INFO -- [S3] upload_file start: "huge.bin" -> key="data/huge.bin" ...
```

4 log levels: `DEBUG` (detailed HTTP), `INFO` (lifecycle), `WARN` (retries, mismatches), `ERROR` (failures).

### Debug Mode

When `debug: true`, log every HTTP request/response in detail:

```ruby
client = S3Client.new(
  ...,
  log_file: 'debug.log',
  debug:    true
)
```

Sample output:
```
[2026-06-03 16:39:32.901] DEBUG -- [S3] [DETAILED REQUEST] PUT http://...
[2026-06-03 16:39:32.901] DEBUG -- [S3]   Body size: 10485760 bytes
[2026-06-03 16:39:33.100] DEBUG -- [S3] [DETAILED RESPONSE] 200 OK
[2026-06-03 16:39:33.100] DEBUG -- [S3]   Header: ETag: "abc123..."
[2026-06-03 16:39:33.100] DEBUG -- [S3]   Header: x-amz-request-id: ...
```

### Event Callbacks — 21 lifecycle events

Register callbacks at the **class level** (applies to every instance):

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
| `:thread_start` | `(thread_id, thread_object_id)` | Worker thread starts |
| `:thread_finish` | `(thread_id, thread_object_id, parts_processed)` | Worker thread ends |
| `:log` | `(level, message, thread_id, timestamp)` | Custom log from a worker thread |
| `:download_start` | `(key, total_size, total_parts, part_size, resumed)` | Download starts |
| `:download_part_start` | `(part_number, total_parts, thread_id, offset, length)` | Thread starts downloading a part |
| `:download_part_complete` | `(part_number, total_parts, thread_id, bytes, elapsed_ms, throughput)` | Part download completes |
| `:download_part_retry` | `(part_number, thread_id, attempt, max_retries, backoff, error)` | Retrying a part download |
| `:download_part_failed` | `(part_number, thread_id, error)` | Part download fails |
| `:download_complete` | `(result, elapsed, throughput)` | Download succeeds |
| `:download_failed` | `(error, state_file_path)` | Download fails |

```ruby
cb = S3Client.on(:part_complete) do |pn, total, tid, etag, bytes, ms, speed|
  puts "#{tid} ✓ part #{pn}/#{total} #{bytes / 1024 / 1024} MB @ #{speed} MB/s"
end

S3Client.on(:upload_complete) do |result, elapsed, throughput|
  notify_slack("Upload done: #{result.key} (#{'%.1f' % throughput} MB/s)")
end

S3Client.on(:upload_failed) do |err, state_path|
  $stderr.puts "Upload failed: #{err.message}"
  $stderr.puts "State: #{state_path || '(aborted)'}"
end

S3Client.off(:part_complete, cb)

S3Client.clear_callbacks!
```

**Use cases:**
- **Progress bar UI** via `:part_complete`
- **Alert on excessive retries** via `:part_retry` + `:part_failed`
- **Centralized logging** (Graylog/Loki/UDP) via `:log`
- **Monitoring dashboard** via `:upload_start`, `:upload_complete`, `:upload_failed`

Callback errors do not fail the upload — exceptions are caught and logged at WARN.

### Thread-safe Logging

Inside worker threads, **don't use `puts`** (output gets interleaved). Use:

```ruby
client.thread_log_info("custom message", "t0")
client.thread_log_warn("warning", "t0")
client.thread_log_error("error", "t0")
```

Mechanism:
1. Worker threads call `thread_log_*` → message goes into a `Queue` (thread-safe) + emits the `:log` event
2. Auto-drain at: after `[PART DONE]`, when a thread finishes, when upload completes

Output format:
```
[2026-06-03 16:38:50.914] INFO -- [thread:t0] [S3] part 5/35 done
[2026-06-03 16:38:50.914] WARN -- [thread:t1] [S3] retry 1/3 for part 7
```

### Debugging the state file after a crash

```ruby
if File.exist?('upload-state.json')
  state = S3Client::UploadState.from_file('upload-state.json')

  puts "Session:      #{state.upload_session_id}"
  puts "Progress:     #{state.summary}"
  puts "Completed:    #{state.part_list.map { |p| p[:part_number] }.inspect}"
  puts "In-progress:  #{state.in_progress_part_numbers.inspect}"
  puts "Pending:      #{state.pending_part_numbers.inspect}"
  puts "Resume count: #{state.resume_count}"
  puts "File MD5:     #{state.file_md5}"
end
```

---

## Result objects

`UploadResult` and `DownloadResult` are `Data.define` value objects returned by `upload_file`, `download_file`, and `resume_upload`:

```ruby
UploadResult   = Data.define(:key, :size, :etag, :elapsed, :throughput, :extra)
DownloadResult = Data.define(:path, :size, :elapsed, :throughput, :extra)
```

Access fields by name, index, or hash:

```ruby
result.key              # => "data/huge.bin"
result[:key]            # => "data/huge.bin"
result.to_h             # => { key: "...", size: ..., ... }
result.to_h.merge(result.extra)
```

## Error handling

Methods raise exceptions on failure — they do NOT return `{error:, state:}` hashes:

| Exception | Description |
|---|---|
| `S3Client::S3Error` | S3 server returned 4xx/5xx |
| `S3Client::UploadError` | Upload failed |
| `S3Client::DownloadError` | Download failed |

All inherit from `RuntimeError`.

```ruby
begin
  result = client.upload_file(
    local_path: '/path/to/huge.bin',
    key:        'data/huge.bin'
  )
  puts "Upload complete: #{result.key}"
rescue S3Client::UploadError => e
  puts "Upload failed: #{e.message}"
rescue S3Client::S3Error => e
  puts "S3 error: #{e.message} (code=#{e.code})"
end
```

---

## Running the automated test suite

The test suite uses **Minitest** and lives in the shared `tests/` directory of the project.

| File | Purpose | Duration |
|---|---|---|
| `tests/s3_client/test_smoke.rb` | Functional: 9 scenarios (upload 20MB, download full/range/stream, HEAD, DELETE, small PUT, abort) | ~5s |
| `tests/s3_client/test_state.rb` | Resumable: full upload + state, resume partial, stale state mismatch | ~3s |
| `tests/s3_client/test_race.rb` | Stress: 8 threads × 20 parts, monotonic state verification | ~10s |
| `tests/s3_client/test_memory.rb` | RAM: upload/download 200 MB, measure RSS | ~30s |
| `tests/s3_client/test_features.rb` | presigned_url, list_uploads/parts, download events, S3Helper | ~15s |

```bash
bundle install
rake test:s3_client
rake test
rake test:quick

ruby tests/s3_client/test_smoke.rb

ruby tests/s3_client/test_smoke.rb -n test_multipart_upload_20mb

ruby tests/interactive/upload_resume_s3_client.rb

rm -rf tests/tmp/
```

---

## Troubleshooting common errors

### `ArgumentError: part_size must be >= 5MB`

S3 requires every part to be ≥ 5 MB (except the last).

### `ArgumentError: exceeds 10,000 parts`

S3 limits to 10,000 parts/upload. A 100 GB file + `part_size=5MB` = 20,000 parts. Fix: increase `part_size`.

```ruby
client.upload_file(
  local_path: '/path/to/100gb.bin',
  key:        'data/100gb.bin',
  part_size:  20 * 1024 * 1024
)
```

### `Errno::ENOENT` when resuming

The local file has been deleted or moved. Restore the file or delete the state file to re-upload.

### State file regresses when observed continuously

Race condition when multiple threads persist state in parallel. **Fixed** with a `rename_mutex` wrapping `File.write + fsync + File.rename` → state file is always monotonically increasing.

### `S3 404 NoSuchUpload` when resuming

The multipart upload on S3 has expired (lifecycle rule, typically 7 days). Delete the state file and re-upload:

```ruby
File.delete('huge.upload.json') if File.exist?('huge.upload.json')
```

### `S3 500` when completing multipart

Usually a server-side error. The client auto-retries with exponential backoff. If it still fails, the state file is preserved for resume.

### Quick log grep

```bash
grep '✗' app.log
grep '↻' app.log
grep 'PART DONE' app.log
grep 'progress=' app.log
grep '\[STATE LOADED\]' app.log
grep 'session=' app.log
```

---

## Public method reference

| Method | Description |
|---|---|
| `upload_file` | Auto upload: empty → EmptyUpload, ≤ part_size → SinglePartUpload, > part_size → MultipartUpload |
| `resume_upload` | Resume a multipart upload from a state file |
| `download_file` | Streaming download, supports Range |
| `download_stream` | Streaming download yielding chunks to the caller |
| `head_object` | GET object metadata → parsed Hash with user metadata |
| `delete_object` | Delete an object, returns the HTTP status code |
| `presigned_url` | Generate a temporary signed URL |
| `list_multipart_uploads` | List in-progress multipart uploads |
| `list_parts` | List uploaded parts |
| `upload_directory` | Upload an entire directory in parallel, auto-selects PUT/multipart per file |
| `abort_multipart_upload` | Abort a multipart upload |
| `multipart_start` | Start a multipart upload (low-level) |
| `multipart_upload_part` | Upload a single part (low-level) |
| `multipart_complete` | Complete a multipart upload (low-level) |
| `multipart_abort` | Abort a multipart upload (low-level) |
| `human_readable_size` | Format bytes → "1.5 GB" |
| `extract_metadata_from_headers` | Extract `x-amz-meta-*` from response headers |
| `setup_logger` | Configure the logger |
| `log_info` / `log_warn` / `log_error` / `log_debug` | Log directly with `[S3]` prefix |
| `thread_log_info` / `thread_log_warn` / `thread_log_error` / `thread_log_debug` | Thread-safe logging |
| `emit_event` | Emit an event to registered callbacks |
| `transient_errors` | List of retryable errors |

**Class methods** (called on `S3Client`):

| Method | Description |
|---|---|
| `S3Client.on(event, &block)` | Register a callback for an event (returns the proc) |
| `S3Client.off(event, callback)` | Unregister a previously registered callback |
| `S3Client.clear_callbacks!` | Clear all callbacks |

## Nested classes

| Class | Description |
|---|---|
| `S3Client::UploadState` | OOP wrapper for resumable upload state — serialization, progress tracking, thread & in-progress tracking |
| `S3Client::S3Error` | S3 server error exception |
| `S3Client::UploadError` | Upload failure exception |
| `S3Client::DownloadError` | Download failure exception |
| `S3Client::UploadResult` | Data object: `key`, `size`, `etag`, `elapsed`, `throughput`, `extra` |
| `S3Client::DownloadResult` | Data object: `path`, `size`, `elapsed`, `throughput`, `extra` |
