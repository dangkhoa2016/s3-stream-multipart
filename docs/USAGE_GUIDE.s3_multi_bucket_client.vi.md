# S3MultiBucketClient — Hướng dẫn sử dụng chi tiết

> 🌐 Language / Ngôn ngữ: [English](USAGE_GUIDE.s3_multi_bucket_client.md) | **Tiếng Việt**

Thư viện Ruby thuần (không phụ thuộc AWS SDK) để upload/download file lớn lên lưu trữ tương thích S3 (AWS S3, MinIO, Cloudflare R2, Backblaze B2, …) với các tính năng:

- **Tiết kiệm bộ nhớ** — streaming upload/download, không load toàn bộ file vào RAM
- **Có thể tiếp tục** — lưu trạng thái vào file JSON; Ctrl+C rồi chạy lại để tiếp tục (cả upload & download)
- **Song song** — thread pool upload nhiều part song song
- **Mã hoá SSE** — hỗ trợ SSE-S3, SSE-KMS, SSE-C
- **Retry** — tự động retry với exponential backoff + jitter cho lỗi transient và 429
- **Có thể theo dõi** — structured logging, debug mode, event callbacks, thread-safe logging
- **Tự động dispatch** — `upload_file` tự động chọn single PUT hoặc multipart dựa trên kích thước file

---

## Mục lục

- [Yêu cầu](#yêu-cầu)
- [Cài đặt](#cài-đặt)
- [Khởi tạo client](#khởi-tạo-client)
  - [Mã hoá SSE](#mã-hoá-sse)
- [Upload file](#upload-file)
  - [Auto-dispatch upload](#auto-dispatch-upload)
  - [Resumable upload với state file](#resumable-upload-với-state-file)
  - [Resume tường minh với resume_upload](#resume-tường-minh-với-resume_upload)
- [Download file](#download-file)
  - [Streaming download](#streaming-download)
  - [Download với Range](#download-với-range)
  - [Streaming dạng block (không ghi đĩa)](#streaming-dạng-block-không-ghi-đĩa)
- [HEAD / DELETE object](#head--delete-object)
- [Multipart API cấp thấp](#multipart-api-cấp-thấp)
- [Presigned URL](#presigned-url)
- [Lớp UploadState](#lớp-uploadstate)
- [Lớp DownloadState](#lớp-downloadstate)
- [Lớp PartUploader](#lớp-partuploader)
- [Module tiện ích S3Helper](#module-tiện-ích-s3helper)
- [Logging & Quan sát](#logging--quan-sát)
  - [Structured Logging](#structured-logging)
  - [Chế độ Debug](#chế-độ-debug)
  - [Event Callbacks — 21 sự kiện vòng đời](#event-callbacks--21-sự-kiện-vòng-đời)
  - [Thread-safe Logging](#thread-safe-logging)
  - [Gỡ lỗi state file sau crash](#gỡ-lỗi-state-file-sau-crash)
- [Kiểm thử thủ công với S3 thật](#kiểm-thử-thủ-công-với-s3-thật)
- [Chạy bộ kiểm thử tự động](#chạy-bộ-kiểm-thử-tự-động)
- [Xử lý lỗi thường gặp](#xử-lý-lỗi-thường-gặp)

---

## Yêu cầu

- Ruby >= 2.7.8+
- Gem: `aws-sigv4`

```bash
gem install aws-sigv4
```

## Cài đặt

Copy `s3_multi_bucket_client.rb` vào dự án và require:

```ruby
require_relative 'path/to/src/s3_multi_bucket_client'
```

---

## Khởi tạo client

### Cơ bản

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

### Với MinIO / Cloudflare R2 (path-style endpoint)

```ruby
client = S3MultiBucketClient.new(
  endpoint:          'https://minio.local:9000',
  region:            'us-east-1',
  access_key_id:     'minioadmin',
  secret_access_key: 'minioadmin',
  logger:            Logger.new($stdout)
)
```

### Với session token (STS temporary credentials)

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

### Tham số khởi tạo

| Tham số | Kiểu | Mặc định | Mô tả |
|---------|------|---------|-------|
| `endpoint` | String | (bắt buộc trừ khi có `bucket:`) | S3 endpoint |
| `region` | String | (bắt buộc) | AWS region |
| `access_key_id` | String | (bắt buộc) | AWS Access Key |
| `secret_access_key` | String | (bắt buộc) | AWS Secret Key |
| `bucket` | String | `nil` | Bucket mặc định (tuỳ chọn) |
| `session_token` | String | `nil` | STS token |
| `part_size` | Integer | `8 * 1024 * 1024` | Kích thước part (8 MB) |
| `max_concurrency` | Integer | `4` | Số luồng song song (1–32) |
| `max_retries` | Integer | `3` | Số lần retry |
| `retry_delay` | Float | `0.25` | Thời gian chờ backoff cơ bản |
| `open_timeout` | Integer | `30` | Timeout kết nối |
| `read_timeout` | Integer | `600` | Timeout đọc |
| `endpoint_style` | Symbol | `:auto` | `:auto` / `:virtual_hosted` / `:path` |
| `logger` | Logger | `nil` | Logger tuỳ chỉnh |
| `log_file` | String | `nil` | Đường dẫn file log |
| `log_format` | Symbol | `:text` | `:text` hoặc `:json` |
| `log_color` | Boolean | `false` | Màu ANSI |
| `debug` | Boolean | `false` | Log HTTP chi tiết |
| `sse` | Hash | `nil` | Cấu hình SSE |

### Mã hoá SSE

```ruby
# SSE-S3 (key do AWS quản lý)
client = S3MultiBucketClient.new(
  ...,
  sse: { type: 'AES256' }
)

# SSE-KMS (AWS KMS key)
client = S3MultiBucketClient.new(
  ...,
  sse: { type: 'aws:kms', kms_key_id: 'arn:aws:kms:us-east-1:123456:key/abc-...' }
)

# SSE-C (key do khách hàng cung cấp — key gửi mỗi request, KHÔNG bao giờ log)
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

## Upload file

### Auto-dispatch upload

`upload_file` tự động dispatch dựa trên kích thước file:
- **0 byte** → EmptyUpload (không có HTTP request)
- **≤ part_size** → SinglePartUpload (single PUT)
- **> part_size** → MultipartUpload (song song, có thể tiếp tục)

```ruby
# File nhỏ → single PUT
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
# File lớn → multipart (song song, có thể tiếp tục)
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

**Tiêu thụ RAM:** `~part_size × max_threads` (mỗi luồng đọc một part vào bộ đệm trước khi gửi).

> **Ràng buộc S3:** `5MB ≤ part_size ≤ 5GB`, tối đa **10.000 parts**/file. Thư viện tự động điều chỉnh `part_size` nếu vượt quá giới hạn.

**Khi thất bại:** ném `S3BaseClient::UploadError` hoặc `S3BaseClient::S3Error`.

### Resumable upload với state file

Khi upload file lớn qua mạng không ổn định:

```ruby
# Lần chạy đầu: truyền state_file
client.upload_file(
  bucket:     'my-bucket',
  key:        'data/huge.bin',
  local_path: '/tmp/huge.bin',
  state_file: '/tmp/huge.upload.json'
)

# Nếu Ctrl+C hoặc crash, chạy lại lệnh tương tự → tự động resume
# State file tự động xoá khi upload hoàn tất
```

### Resume tường minh với `resume_upload`

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

## Download file

### Streaming download

Stream chunks từ server xuống đĩa, RAM không tăng theo kích thước file.

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

### Download với Range

`download_file` hỗ trợ tham số `range:` cho download một phần:

```ruby
# Download bytes 0 → 1MB-1 (1MB đầu) — dùng Array
client.download_file(
  bucket:           'my-bucket',
  key:              'data/huge.bin',
  destination_path: '/tmp/chunk.bin',
  range:            [0, 1024 * 1024 - 1]
)

# Hoặc dùng Ruby Range
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

### Streaming dạng block (không ghi đĩa)

Pipe trực tiếp vào parser / upstream proxy / unzip:

```ruby
client.download_stream(bucket: 'my-bucket', key: 'data/huge.bin') do |chunk|
  $stdout.write(chunk)
end

# Với Range
written = client.download_stream(
  bucket: 'my-bucket',
  key:    'data/huge.bin',
  range:  (1_000_000..2_000_000)
) { |chunk| process(chunk) }
```

---

## HEAD / DELETE object

### HEAD — lấy metadata

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

### DELETE — xoá object

```ruby
result = client.delete_object(bucket: 'my-bucket', key: 'data/file.txt')
# => { key: "data/file.txt", status: "deleted" }
```

---

## Multipart API cấp thấp

Cho trường hợp tự quản lý vòng đời multipart (ví dụ tiếp tục qua process/máy khác):

```ruby
# 1. Bắt đầu multipart upload
upload_id = client.multipart_start(
  bucket:       'my-bucket',
  key:          'data/file.bin',
  content_type: 'application/octet-stream',
  metadata:     { 'source' => 'manual' },
  cache_control: 'max-age=86400'
)

# 2. Upload từng part
etag1 = client.multipart_upload_part(
  bucket:      'my-bucket',
  key:         'data/file.bin',
  upload_id:   upload_id,
  part_number: 1,
  body:        File.binread('/tmp/part1.bin')
)

# Hoặc với IO
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

# 3. Hoàn tất
final_etag = client.multipart_complete(
  bucket:    'my-bucket',
  key:       'data/file.bin',
  upload_id: upload_id,
  parts:     [
    { part_number: 1, etag: etag1 },
    { part_number: 2, etag: etag2 }
  ]
)

# Hoặc huỷ
client.multipart_abort(
  bucket:    'my-bucket',
  key:       'data/file.bin',
  upload_id: upload_id
)
```

---

## Presigned URL

Tạo URL ký tạm thời, không cần thông tin xác thực:

```ruby
# GET URL (đọc file)
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

# Với tham số query bổ sung
url = client.presigned_url(
  bucket:     'my-bucket',
  key:        'data/file.txt',
  method:     :get,
  expires_in: 3600,
  query:      { 'response-content-disposition' => 'attachment; filename="download.txt"' }
)
```

---

## Lớp UploadState

Wrapper OOP cho trạng thái resumable upload:

```ruby
# Tạo mới
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

# Phương thức theo dõi
state.upload_id               # "abc-123"
state.completed_parts_count   # 2
state.total_parts             # 25
state.progress_percentage     # 8.0
state.bytes_uploaded          # 16777216
state.pending_part_numbers    # [3, 4, 5, ... 25]
state.next_part_number        # 3
state.part_list               # [{part_number: 1, etag: '"e1"'}, ...]
state.completed?              # false

# Session & theo dõi
state.upload_session_id       # "a5f8bf53ebadba22" (16-char hex, không đổi khi resume)
state.file_fingerprint        # "mtime_float-size" fast fingerprint (luôn có)
state.file_mtime              # mtime của file cục bộ
state.last_part_completed_at  # "2026-06-03T08:05:12Z"
state.resumed_at              # "2026-06-03T08:06:00Z" (nếu đã resume)
state.resume_count            # 2 (số lần resume)
state.started_at              # "2026-06-03T08:00:00Z"
state.last_updated_at         # "2026-06-03T08:05:12Z"

# Theo dõi luồng & in-progress
state.in_progress_part_numbers  # [14, 15] — parts đang upload
state.in_progress_parts         # {14 => "t2", 15 => "t0"}
state.thread_states             # {"t0" => {status:, current_part:, parts_done:, ...}, ...}

# Tóm tắt ngắn gọn cho logs
state.summary  # "parts=2/25 (8.0%) bytes=16777216/209715200 in_progress=[14, 15] threads=4"
```

---

## Lớp DownloadState

Wrapper OOP cho trạng thái resumable download:

```ruby
# Tạo mới
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

# Phương thức theo dõi
state.completed_parts_count   # 2
state.total_parts             # 25
state.progress_percentage     # 8.0
state.bytes_downloaded        # 16777216
state.pending_part_numbers    # [3, 4, 5, ... 25]
state.completed?              # false

# Session & theo dõi
state.download_session_id     # "a5f8bf53..."
state.resumed_at              # "2026-06-06T10:00:00Z"
state.resume_count            # 1
state.started_at              # "2026-06-06T09:50:00Z"
state.last_updated_at         # "2026-06-06T09:55:00Z"

state.summary  # "parts=2/25 (8.0%) bytes=16777216/209715200"
```

---

## Lớp PartUploader

Trình upload song song độc lập, hoạt động với UploadState:

```ruby
# Xây dựng UploadState
state = S3MultiBucketClient::UploadState.new(
  upload_id:  upload_id,
  key:        'data/file.bin',
  local_path: '/tmp/file.bin',
  part_size:  8 * 1024 * 1024,
  total_size: File.size('/tmp/file.bin'),
  parts:      { 1 => '"etag1"' }
)

# Upload các part còn thiếu
uploader = S3MultiBucketClient::PartUploader.new(
  client, state,
  max_threads:       4,
  max_retries:       3,
  retry_delay:       0.25,
  on_progress:       ->(completed, total, pct) { puts "#{pct}%" },
  state_file:        '/tmp/state.json'
)

parts = uploader.upload_all!

# Hoàn tất
client.multipart_complete(
  bucket:    state.bucket,
  key:       state.key,
  upload_id: state.upload_id,
  parts:     state.part_list
)
```

---

## Module tiện ích S3Helper

```ruby
# Tự động phát hiện single/multipart
S3Helper.upload(
  client:    client,
  bucket:    'my-bucket',
  key:       'data/file.bin',
  local_path: '/tmp/file.bin'
)

# Download với progress bar
S3Helper.download(
  client:        client,
  bucket:        'my-bucket',
  key:           'data/file.bin',
  destination:   '/tmp/file.bin',
  show_progress: true
)

# Bulk upload thư mục
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

## Logging & Quan sát

`S3MultiBucketClient` có hệ thống quan sát 4 lớp: structured logging, debug mode, event callbacks, và thread-safe logging.

### Structured Logging

3 cách truyền logger:

```ruby
# 1. Logger tuỳ chỉnh
client = S3MultiBucketClient.new(..., logger: Logger.new($stdout, level: Logger::INFO))

# 2. Ghi vào file
client = S3MultiBucketClient.new(..., log_file: 'upload.log')

# 3. STDOUT mặc định
client = S3MultiBucketClient.new(...)
```

Custom formatter với timestamp mili giây:
```
[2026-06-03 16:39:32.901] INFO -- [S3] upload_file start: "huge.bin" -> key="data/huge.bin" ...
```

4 mức log: `DEBUG` (HTTP chi tiết), `INFO` (vòng đời), `WARN` (retry, không khớp), `ERROR` (lỗi).

### Chế độ Debug

Khi `debug: true`, log mọi HTTP request/response chi tiết:

```ruby
client = S3MultiBucketClient.new(
  ...,
  log_file: 'debug.log',
  debug:    true
)
```

Ví dụ output:
```
[2026-06-03 16:39:32.901] DEBUG -- [S3] [DETAILED REQUEST] PUT http://...
[2026-06-03 16:39:32.901] DEBUG -- [S3]   Body size: 8388608 bytes
[2026-06-03 16:39:33.100] DEBUG -- [S3] [DETAILED RESPONSE] 200 OK
[2026-06-03 16:39:33.100] DEBUG -- [S3]   Header: ETag: "abc123..."
```

### Event Callbacks — 21 sự kiện vòng đời

Đăng ký callback ở **cấp lớp** (áp dụng cho mọi instance):

**Sự kiện Upload:**

| Sự kiện | Tham số | Khi nào kích hoạt |
|---------|---------|-------------------|
| `:upload_start` | `(local_path, key, total_size, total_parts, part_size, resumed)` | Upload bắt đầu |
| `:upload_resume` | `(state)` | Đang tiếp tục từ state file |
| `:part_start` | `(part_number, total_parts, thread_id, offset, length)` | Luồng bắt đầu một part |
| `:part_complete` | `(part_number, total_parts, thread_id, etag, bytes, elapsed_ms, throughput)` | Part hoàn thành |
| `:part_retry` | `(part_number, thread_id, attempt, max_retries, backoff, error)` | Đang retry một part |
| `:part_failed` | `(part_number, thread_id, error, exhausted)` | Part thất bại |
| `:state_save` | `(state_snapshot, completed_count, total_parts, thread_id)` | State được ghi xuống đĩa |
| `:state_load` | `(state, path)` | State được load khi resume |
| `:state_mismatch` | `(state, key, total_size)` | State không khớp |
| `:upload_complete` | `(result, elapsed, throughput)` | Upload thành công |
| `:upload_error` | `(key, upload_id, error)` | Upload thất bại |

**Sự kiện Download:**

| Sự kiện | Tham số | Khi nào kích hoạt |
|---------|---------|-------------------|
| `:download_start` | `(key, total_size, total_parts, part_size, resumed)` | Download bắt đầu |
| `:download_part_start` | `(part_number, total_parts, thread_id, offset, length)` | Luồng bắt đầu download part |
| `:download_part_complete` | `(part_number, total_parts, thread_id, tempfile, bytes, elapsed_ms, throughput)` | Download part hoàn thành |
| `:download_part_retry` | `(part_number, thread_id, attempt, max_retries, backoff, error)` | Đang retry download part |
| `:download_part_failed` | `(part_number, thread_id, error)` | Download part thất bại |
| `:download_complete` | `(result_hash, elapsed, throughput)` | Download thành công |
| `:download_failed` | `(error, state_file)` | Download thất bại |

**Sự kiện chung:**

| Sự kiện | Tham số | Khi nào kích hoạt |
|---------|---------|-------------------|
| `:thread_start` | `(thread_id, thread_object_id)` | Worker thread bắt đầu |
| `:thread_finish` | `(thread_id, thread_object_id, parts_processed)` | Worker thread kết thúc |
| `:log` | `(level, message, thread_id, timestamp)` | Log tuỳ chỉnh từ worker thread |

```ruby
# Đăng ký callback
cb = S3MultiBucketClient.on(:part_complete) do |pn, total, tid, etag, bytes, ms, speed|
  puts "#{tid} ✓ part #{pn}/#{total} #{bytes / 1024 / 1024} MB @ #{speed} MB/s"
end

S3MultiBucketClient.on(:upload_complete) do |result, elapsed, throughput|
  notify_slack("Upload done: #{result.key} (#{'%.1f' % throughput} MB/s)")
end

# Huỷ đăng ký callback
S3MultiBucketClient.off(:part_complete, cb)

# Xoá tất cả
S3MultiBucketClient.clear_callbacks!
```

**Trường hợp sử dụng:** giao diện progress bar, cảnh báo retry/lỗi, logging tập trung, dashboard giám sát. Lỗi callback không làm hỏng upload.

### Thread-safe Logging

Bên trong worker threads, **không dùng `puts`** (output bị lẫn). Dùng:

```ruby
# Từ worker thread
client.thread_log_info("custom message", "t0")
client.thread_log_warn("warning", "t0")
client.thread_log_error("error", "t0")
```

Định dạng output:
```
[2026-06-03 16:38:50.914] INFO -- [thread:t0] [S3] part 5/35 done
```

### Gỡ lỗi state file sau crash

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

## Kiểm thử thủ công với S3 thật

### 1. Upload một file

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

# Tạo file kiểm thử
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

# Xác minh với HEAD
info = client.head_object(bucket: ENV['S3_BUCKET'], key: 'test/small.txt')
puts "HEAD: #{info.inspect}"

# Dọn dẹp
client.delete_object(bucket: ENV['S3_BUCKET'], key: 'test/small.txt')
```

### 2. Upload file lớn với resume

```ruby
# Tạo file 50MB
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

# Dọn dẹp
client.delete_object(bucket: ENV['S3_BUCKET'], key: 'test/big.bin')
```

### 3. Download + xác minh

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

## Chạy bộ kiểm thử tự động

### Yêu cầu

```bash
gem install aws-sigv4 webrick minitest
# hoặc
bundle install
```

### Chạy tests

```bash
# Từ thư mục gốc dự án
rake test          # tất cả tests (s3_client + s3_multi_bucket_client)
rake test:s3_multi_bucket_client
rake test:quick    # bỏ qua memory/race (nhanh)
```

### Chạy một file

```bash
ruby tests/s3_multi_bucket_client/test_upload_state.rb
ruby tests/s3_multi_bucket_client/test_client.rb
ruby tests/s3_multi_bucket_client/test_smoke.rb
ruby tests/s3_multi_bucket_client/test_state.rb
ruby tests/s3_multi_bucket_client/test_features.rb
ruby tests/s3_multi_bucket_client/test_coverage.rb
ruby tests/s3_multi_bucket_client/test_race.rb
ruby tests/s3_multi_bucket_client/test_memory.rb
ruby tests/s3_multi_bucket_client/test_download_state.rb
ruby tests/s3_multi_bucket_client/test_bulk_upload.rb
```

### Chạy một test

```bash
ruby tests/s3_multi_bucket_client/test_client.rb -n test_human_readable_size
```

### Demo: Ctrl+C → resume

```bash
ruby tests/interactive/upload_resume_s3_multi_bucket_client.rb
```

### File kiểm thử

| File | # tests | Mô tả |
|------|---------|-------|
| `tests/s3_multi_bucket_client/test_upload_state.rb` | 9 | UploadState: tạo, serialization, theo dõi, phát hiện gap, session |
| `tests/s3_multi_bucket_client/test_client.rb` | 52 | Khởi tạo client, validation, utilities, constants, errors, XML, thread safety |
| `tests/s3_multi_bucket_client/test_smoke.rb` | 17 | Upload (auto-dispatch), download, HEAD, DELETE, low-level multipart, S3Helper |
| `tests/s3_multi_bucket_client/test_state.rb` | 3 | Upload đầy đủ + state, resume từ state, resume qua resume_upload |
| `tests/s3_multi_bucket_client/test_race.rb` | 2 | Upload đồng thời kiểm tra state đơn điệu, resume từ nửa chừng |
| `tests/s3_multi_bucket_client/test_memory.rb` | 1 | Đo RAM cho upload/download 200MB |
| `tests/s3_multi_bucket_client/test_features.rb` | 40 | Presigned, list multipart, events, logging, session tracking, download stream, bulk |
| `tests/s3_multi_bucket_client/test_coverage.rb` | 71 | Edge cases: error paths, state file, abort, list_buckets, download helpers |
| `tests/s3_multi_bucket_client/test_download_state.rb` | 9 | DownloadState: tạo, serialization, theo dõi, summary |
| `tests/s3_multi_bucket_client/test_bulk_upload.rb` | 8 | Bulk upload: thư mục, pattern, exclude, callbacks, skip existing |

### Fake S3 server

Bộ kiểm thử dùng chung fake S3 server (WEBrick) từ `tests/support/fake_s3_server.rb`. Server hỗ trợ:

- Single PUT / GET / HEAD / DELETE
- Multipart: initiate, upload part, complete, abort
- Range download, Content-Range
- Metadata (x-amz-meta-*), Cache-Control
- List multipart uploads, list parts

### Dọn dẹp

```bash
rm -rf tests/tmp/
```

---

## Xử lý lỗi thường gặp

### `ArgumentError: access_key_id is empty`

```ruby
# Sửa: kiểm tra ENV trước khi truyền
raise "Missing AWS credentials" unless ENV['S3_ACCESS_KEY_ID']
```

### `S3Error [403] Forbidden`

- Xác minh IAM policy có quyền `s3:PutObject`, `s3:GetObject`, `s3:DeleteObject`
- Cho multipart: cần thêm `s3:ListMultipartUploadParts`, `s3:AbortMultipartUpload`

### `S3Error [404] Not Found` khi resume

Multipart upload trên S3 đã hết hạn (lifecycle rule, thường 7 ngày). Xoá state file và upload lại:

```ruby
File.delete('/tmp/huge.upload.json') if File.exist?('/tmp/huge.upload.json')
```

### Logger quá nhiều

```ruby
# Giảm mức log
client = S3MultiBucketClient.new(
  ...,
  logger: Logger.new($stdout, level: Logger::WARN)
)
```

### Kiểm tra lỗi transient nào được retry

```ruby
client.transient_errors
# => [Net::OpenTimeout, Net::ReadTimeout, Errno::ECONNRESET,
#     Errno::EPIPE, Errno::ECONNABORTED, EOFError, SocketError, IOError]
```

---

## Tham khảo phương thức công khai

| Phương thức | Mô tả |
|-------------|-------|
| `upload_file` | Upload (tự động dispatch: single PUT hoặc multipart dựa trên kích thước) |
| `resume_upload` | Tiếp tục từ state file |
| `upload_directory` | Upload tất cả file trong thư mục (song song, có skip/resume) |
| `download_file` | Streaming download (hỗ trợ `range:`, `destination_path:`) |
| `download_stream` | Streaming dạng block (yield chunks, hỗ trợ `range:`) |
| `download_directory` | Download tất cả file theo prefix về thư mục cục bộ |
| `head_object` | GET metadata → Hash đã parse |
| `delete_object` | Xoá object |
| `presigned_url` | Tạo URL ký |
| `list_buckets` | Liệt kê tất cả buckets trong tài khoản |
| `list_objects` | Liệt kê objects theo prefix |
| `list_multipart_uploads` | Liệt kê multipart uploads đang thực hiện |
| `list_parts` | Liệt kê các part đã upload |
| `abort_multipart_upload` | Huỷ multipart upload |
| `create_multipart_upload` | Bắt đầu multipart upload (trả về upload_id) |
| `multipart_start` | Alias của `create_multipart_upload` (cấp thấp) |
| `multipart_upload_part` | Upload một part (cấp thấp) |
| `multipart_complete` | Hoàn tất multipart upload (cấp thấp) |
| `multipart_abort` | Huỷ multipart upload (cấp thấp) |
| `setup_logger` | Cấu hình logger |
| `log_info/debug/warn/error` | Log với tiền tố `[S3]` |
| `thread_log_info/debug/warn/error` | Thread-safe logging (hàng đợi message) |

**Phương thức lớp** (gọi trên `S3MultiBucketClient`):

| Phương thức | Mô tả |
|-------------|-------|
| `S3MultiBucketClient.on(event, &block)` | Đăng ký callback cho sự kiện (trả về proc) |
| `S3MultiBucketClient.off(event, callback)` | Huỷ đăng ký callback |
| `S3MultiBucketClient.clear_callbacks!` | Xoá tất cả callbacks |

## Đối tượng kết quả

| Lớp | Trường |
|-----|--------|
| `S3MultiBucketClient::UploadResult` | `key`, `size`, `etag`, `elapsed`, `throughput`, `extra` |
| `S3MultiBucketClient::DownloadResult` | `path`, `size`, `elapsed`, `throughput`, `extra` |

Truy cập qua `result.field`, `result[:field]`, hoặc `result.to_h`.

## Các lớp lồng nhau

| Lớp | Mô tả |
|-----|-------|
| `S3MultiBucketClient::UploadState` | Wrapper trạng thái resumable upload |
| `S3MultiBucketClient::DownloadState` | Wrapper trạng thái resumable download |
| `S3MultiBucketClient::PartUploader` | Trình upload song song độc lập |
| `S3MultiBucketClient::PartDownloader` | Trình download song song độc lập (Range requests) |
| `S3MultiBucketClient::S3Error` | Lỗi S3 có cấu trúc (phân tích từ body XML phản hồi) |
| `S3MultiBucketClient::UploadError` | Lỗi upload cụ thể (bao gồm mã lỗi/thông tin S3) |
| `S3MultiBucketClient::ResumableUploadError` | Lỗi resumable upload cụ thể (con của UploadError) |
| `S3MultiBucketClient::DownloadError` | Lỗi download cụ thể |

### Thuộc tính S3Error

`S3Error` phân tích body XML và cung cấp truy cập có cấu trúc đến chi tiết lỗi:

| Thuộc tính | Kiểu | Mô tả |
|---|---|---|
| `code` | `String` | Mã trạng thái HTTP (ví dụ: `"404"`, `"403"`) |
| `request_id` | `String` | AWS request ID từ header `x-amz-request-id` |
| `s3_code` | `String` | Mã lỗi S3 từ XML `<Code>` (ví dụ: `"NoSuchBucket"`) |
| `s3_message` | `String` | Thông báo lỗi S3 từ XML `<Message>` |
| `s3_bucket` | `String` | Tên bucket từ XML `<BucketName>` |

### Mã hóa URL trong build_uri

Keys đối tượng được mã hóa URL khi xây dựng URI request, nhưng dấu gạch chéo (`/`) trong keys được giữ nguyên để duy trì cấu trúc phân cấp. Mỗi đoạn đường dẫn được mã hóa riêng lẻ bằng `CGI.escape`, với `+` được thay bằng `%20` và `%7E` được thay bằng `~`.

```ruby
# Key dạng "path/to/file.txt" được mã hóa thành:
# /bucket/path/to/file.txt  (giữ nguyên slashes)

# Key có khoảng trắng dạng "my file.txt" được mã hóa thành:
# /bucket/my%20file.txt
```

### Xác thực endpoint

Khi xây dựng `S3MultiBucketClient`, URL `endpoint:` được kiểm tra để đảm bảo bắt đầu bằng `http://` hoặc `https://` và có hostname hợp lệ. Endpoint không hợp lệ ném `ArgumentError` tại thời điểm khởi tạo.

### Xác thực phản hồi XML

Trước khi phân tích các phản hồi XML (ví dụ từ `list_objects`, `list_multipart_uploads`, `list_parts`), client kiểm tra Content-Type của phản hồi. Nếu phản hồi rõ ràng không phải XML (ví dụ HTML), `S3Error` được ném với thông báo mô tả thay vì lỗi REXML khó hiểu.
