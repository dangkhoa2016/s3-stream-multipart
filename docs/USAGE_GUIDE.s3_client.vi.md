# S3Client — Hướng dẫn sử dụng chi tiết

> 🌐 Language / Ngôn ngữ: [English](USAGE_GUIDE.s3_client.md) | **Tiếng Việt**

Thư viện Ruby thuần (không phụ thuộc AWS SDK) để upload/download file lớn lên lưu trữ tương thích S3 (AWS S3, MinIO, Cloudflare R2, Backblaze B2, …) với các tính năng:

- **Tiết kiệm bộ nhớ** — upload/download streaming, không load toàn bộ file vào RAM
- **Có thể tiếp tục** — lưu trạng thái vào file JSON; Ctrl+C rồi chạy lại để tiếp tục (cả upload & download)
- **Song song** — thread pool upload nhiều part song song
- **Mã hoá SSE** — hỗ trợ SSE-S3, SSE-KMS, SSE-C
- **Retry** — tự động retry với exponential backoff + jitter cho lỗi transient, S3 5xx và 429
- **Có thể theo dõi** — structured logging, debug mode, 21 event callbacks, thread-safe logging
- **API thống nhất** — `upload_file` tự động chọn single PUT hoặc multipart dựa trên kích thước file

---

## Mục lục

- [Yêu cầu](#yêu-cầu)
- [Cài đặt](#cài-đặt)
- [Khởi tạo client](#khởi-tạo-client)
- [Upload file](#upload-file)
  - [API thống nhất — tự động chọn single PUT / multipart](#api-thống-nhất--tự-động-chọn-single-put--multipart)
  - [Multipart upload với progress callback](#multipart-upload-với-progress-callback)
  - [Resumable upload với state file](#resumable-upload-với-state-file)
  - [Resume tường minh với resume_upload](#resume-tường-minh-với-resume_upload)
- [Download file](#download-file)
  - [Streaming download](#streaming-download)
  - [Download với Range](#download-với-range)
  - [Streaming dạng block (không ghi đĩa)](#streaming-dạng-block-không-ghi-đĩa)
- [HEAD / DELETE object](#head--delete-object)
- [Multipart API cấp thấp](#multipart-api-cấp-thấp)
- [Presigned URL](#presigned-url)
- [Liệt kê multipart uploads / parts](#liệt-kê-multipart-uploads--parts)
- [Lớp UploadState](#lớp-uploadstate)
  - [Module tiện ích S3Helper](#module-tiện-ích-s3helper)
- [Logging & Quan sát](#logging--quan-sát)
  - [Structured Logging](#structured-logging)
  - [Chế độ Debug](#chế-độ-debug)
  - [Event Callbacks — 21 sự kiện vòng đời](#event-callbacks--21-sự-kiện-vòng-đời)
  - [Thread-safe Logging](#thread-safe-logging)
  - [Gỡ lỗi state file sau crash](#gỡ-lỗi-state-file-sau-crash)
- [Đối tượng kết quả](#đối-tượng-kết-quả)
- [Xử lý lỗi](#xử-lý-lỗi)
- [Chạy bộ kiểm thử tự động](#chạy-bộ-kiểm-thử-tự-động)
- [Xử lý lỗi thường gặp](#xử-lý-lỗi-thường-gặp)
- [Tham khảo phương thức công khai](#tham-khảo-phương-thức-công-khai)

---

## Yêu cầu

- Ruby >= 2.7.8+
- Gem: `aws-sigv4`

```bash
gem install aws-sigv4
```

## Cài đặt

Copy `s3_client.rb` vào dự án và require:

```ruby
require_relative 'path/to/src/s3_client'
```

---

## Khởi tạo client

### AWS S3 (virtual-hosted style — mặc định)

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

### AWS STS (thông tin xác thực tạm thời)

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

### Với file logging + debug mode

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

### Tham số khởi tạo

| Tham số | Kiểu | Mặc định | Mô tả |
|---------|------|---------|-------|
| `region` | String | (bắt buộc) | AWS region |
| `bucket` | String | (bắt buộc) | Tên S3 bucket |
| `access_key_id` | String | (bắt buộc) | AWS Access Key |
| `secret_access_key` | String | (bắt buộc) | AWS Secret Key |
| `endpoint` | String | `nil` | URL endpoint tuỳ chỉnh |
| `session_token` | String | `nil` | STS session token |
| `part_size` | Integer | `10 * 1024 * 1024` | Kích thước part (10 MB, tối thiểu 5 MB) |
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

> **`endpoint_style: :auto`** — tự động phát hiện: endpoint tuỳ chỉnh → `:path`, AWS mặc định → `:virtual_hosted`.

### Cấu hình mã hoá SSE

```ruby
# SSE-S3
sse = { type: "AES256" }

# SSE-KMS
sse = { type: "aws:kms", kms_key_id: "arn:aws:kms:..." }

# SSE-C
sse = { type: "customer", key: Base64.strict_encode64(raw_key), key_md5: Base64.strict_encode64(Digest::MD5.digest(raw_key)) }
```

> **An toàn luồng:** Các instance client KHÔNG an toàn cho luồng khi gọi API công cộng đồng thời. Nội bộ, multipart upload quản lý worker threads an toàn.

---

## Upload file

### API thống nhất — tự động chọn single PUT / multipart

`upload_file` là phương thức chính, **tự động quyết định** chiến lược upload dựa trên kích thước file:

| Kích thước file | Hành vi |
|----------------|---------|
| 0 byte | EmptyUpload (single PUT với body rỗng) |
| ≤ `part_size` | SinglePartUpload (streaming PUT) |
| > `part_size` | MultipartUpload (multipart song song) |

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

**Tiêu thụ RAM:** `~part_size × max_concurrency` (mỗi luồng đọc một part vào bộ đệm trước khi gửi).

### Multipart upload với progress callback

Khi file lớn hơn `part_size`, upload tự động chuyển sang multipart:

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

Ví dụ output (mức INFO):
```
[2026-06-03 16:39:32.901] INFO -- [S3] upload_file start: "movie.mp4" -> key="videos/movie.mp4" size=361806224 (345.00 MB) part_size=10485760 (10.00 MB) total_parts=35 concurrency=4
[2026-06-03 16:39:33.025] INFO -- [S3] [PART START] t0 → part 1/35 bytes=0-10485759 size=10.00 MB (2.9%)
[2026-06-03 16:39:33.213] INFO -- [S3] [PART DONE]  t0 ✓ part 1/35 size=10.00 MB time=187.3ms speed=53.38 MB/s | progress=10.00 MB/345.00 MB (2.9%) avg=52.14 MB/s ETA=6.4s
[2026-06-03 16:39:37.018] INFO -- [S3] [UPLOAD COMPLETE] key="videos/movie.mp4" etag="b33a03f8..." parts=35 elapsed=4.117s throughput=83.79 MB/s
```

> **⚠️ Ràng buộc S3:** `5MB ≤ part_size ≤ 5GB`, tối đa **10.000 parts**/file. `upload_file` ném `ArgumentError` nếu vượt quá.

### Resumable upload với state file

Khi upload file lớn qua mạng không ổn định, **chỉ cần thêm `state_file:`**:

```ruby
client.upload_file(
  local_path: '/path/to/huge.bin',
  key:        'data/huge.bin',
  state_file: 'huge.upload.json'
)
```

**Luồng xử lý:**
1. **Chưa có state file** → tạo multipart upload mới → lưu state → upload từng part → ghi state sau mỗi part (atomic write + fsync + rename)
2. **State file đã tồn tại** → load → kiểm tra (key/part_size/total_size/local_path phải khớp) → tiếp tục, bỏ qua part đã hoàn thành
3. **Upload hoàn tất** → state file được **tự động xoá**
4. **Upload thất bại** → state file được **giữ nguyên** → chạy lại để tiếp tục

### Resume tường minh với resume_upload

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

## Download file

### Streaming download

Stream ~64KB chunks từ server xuống đĩa, RAM không tăng theo kích thước file:

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

### Download với Range

`download_file` hỗ trợ tham số `range:` trực tiếp:

```ruby
result = client.download_file(
  key:        'data/huge.bin',
  local_path: '/tmp/chunk.bin',
  range:      (1_000_000..2_000_000)
)
```

### Streaming dạng block (không ghi đĩa)

Pipe trực tiếp vào parser / upstream proxy / unzip:

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

### HEAD — lấy metadata

Trả về **Hash đã parse** (không phải response thô):

```ruby
info = client.head_object('data/file.txt')

puts info[:content_length]
puts info[:metadata]['author']
puts info[:storage_class]
```

### DELETE — xoá object

```ruby
code = client.delete_object('data/old-file.txt')
```

---

## Multipart API cấp thấp

Cho trường hợp tự quản lý vòng đời multipart:

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

Tạo URL ký tạm thời, không cần thông tin xác thực:

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

## Liệt kê multipart uploads / parts

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

## Lớp UploadState

Wrapper OOP cho trạng thái resumable upload — serialization, theo dõi tiến trình, theo dõi luồng:

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

## Module tiện ích S3Helper

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

## Logging & Quan sát

`S3Client` có hệ thống quan sát 4 lớp: structured logging, debug mode, event callbacks, và thread-safe logging.

### Structured Logging

3 cách truyền logger:

```ruby
client = S3Client.new(..., logger: Logger.new($stdout, level: Logger::INFO))

client = S3Client.new(..., log_file: 'upload.log')

client = S3Client.new(...)
```

Custom formatter với timestamp mili giây:
```
[2026-06-03 16:39:32.901] INFO -- [S3] upload_file start: "huge.bin" -> key="data/huge.bin" ...
```

4 mức log: `DEBUG` (HTTP chi tiết), `INFO` (vòng đời), `WARN` (retry, không khớp), `ERROR` (lỗi).

### Chế độ Debug

Khi `debug: true`, log mọi HTTP request/response chi tiết:

```ruby
client = S3Client.new(
  ...,
  log_file: 'debug.log',
  debug:    true
)
```

Ví dụ output:
```
[2026-06-03 16:39:32.901] DEBUG -- [S3] [DETAILED REQUEST] PUT http://...
[2026-06-03 16:39:32.901] DEBUG -- [S3]   Body size: 10485760 bytes
[2026-06-03 16:39:33.100] DEBUG -- [S3] [DETAILED RESPONSE] 200 OK
[2026-06-03 16:39:33.100] DEBUG -- [S3]   Header: ETag: "abc123..."
[2026-06-03 16:39:33.100] DEBUG -- [S3]   Header: x-amz-request-id: ...
```

### Event Callbacks — 21 sự kiện vòng đời

Đăng ký callback ở **cấp lớp** (áp dụng cho mọi instance):

| Sự kiện | Tham số | Khi nào kích hoạt |
|---------|---------|-------------------|
| `:upload_start` | `(local_path, key, size, total_parts, part_size, resumed)` | Upload bắt đầu |
| `:upload_resume` | `(state)` | Đang tiếp tục từ state file |
| `:part_start` | `(part_number, total_parts, thread_id, offset, length)` | Luồng bắt đầu một part |
| `:part_complete` | `(part_number, total_parts, thread_id, etag, bytes, elapsed_ms, throughput)` | Part hoàn thành |
| `:part_retry` | `(part_number, thread_id, attempt, max_retries, backoff, error)` | Đang retry một part |
| `:part_failed` | `(part_number, thread_id, error, exhausted)` | Part thất bại |
| `:state_save` | `(state_snapshot, completed_count, total_parts, thread_id)` | State được ghi xuống đĩa |
| `:state_load` | `(state, path)` | State được load khi resume |
| `:state_mismatch` | `(old_state, new_key, new_size)` | State không khớp |
| `:upload_complete` | `(result, elapsed, throughput)` | Upload thành công |
| `:upload_failed` | `(error, state_preserved_path)` | Upload thất bại |
| `:thread_start` | `(thread_id, thread_object_id)` | Worker thread bắt đầu |
| `:thread_finish` | `(thread_id, thread_object_id, parts_processed)` | Worker thread kết thúc |
| `:log` | `(level, message, thread_id, timestamp)` | Log tuỳ chỉnh từ worker thread |
| `:download_start` | `(key, total_size, total_parts, part_size, resumed)` | Download bắt đầu |
| `:download_part_start` | `(part_number, total_parts, thread_id, offset, length)` | Luồng bắt đầu download một part |
| `:download_part_complete` | `(part_number, total_parts, thread_id, bytes, elapsed_ms, throughput)` | Download part hoàn thành |
| `:download_part_retry` | `(part_number, thread_id, attempt, max_retries, backoff, error)` | Đang retry download part |
| `:download_part_failed` | `(part_number, thread_id, error)` | Download part thất bại |
| `:download_complete` | `(result, elapsed, throughput)` | Download thành công |
| `:download_failed` | `(error, state_file_path)` | Download thất bại |

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

**Trường hợp sử dụng:**
- **Giao diện progress bar** qua `:part_complete`
- **Cảnh báo khi retry quá nhiều** qua `:part_retry` + `:part_failed`
- **Logging tập trung** (Graylog/Loki/UDP) qua `:log`
- **Dashboard giám sát** qua `:upload_start`, `:upload_complete`, `:upload_failed`

Lỗi callback không làm hỏng upload — ngoại lệ được bắt và log ở mức WARN.

### Thread-safe Logging

Bên trong worker threads, **không dùng `puts`** (output bị lẫn). Dùng:

```ruby
client.thread_log_info("custom message", "t0")
client.thread_log_warn("warning", "t0")
client.thread_log_error("error", "t0")
```

Cơ chế:
1. Worker threads gọi `thread_log_*` → message vào `Queue` (thread-safe) + kích hoạt sự kiện `:log`
2. Tự động drain tại: sau `[PART DONE]`, khi thread kết thúc, khi upload hoàn tất

Định dạng output:
```
[2026-06-03 16:38:50.914] INFO -- [thread:t0] [S3] part 5/35 done
[2026-06-03 16:38:50.914] WARN -- [thread:t1] [S3] retry 1/3 for part 7
```

### Gỡ lỗi state file sau crash

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

## Đối tượng kết quả

`UploadResult` và `DownloadResult` là đối tượng giá trị `Data.define` được trả về bởi `upload_file`, `download_file`, và `resume_upload`:

```ruby
UploadResult   = Data.define(:key, :size, :etag, :elapsed, :throughput, :extra)
DownloadResult = Data.define(:path, :size, :elapsed, :throughput, :extra)
```

Truy cập theo tên, chỉ số, hoặc hash:

```ruby
result.key              # => "data/huge.bin"
result[:key]            # => "data/huge.bin"
result.to_h             # => { key: "...", size: ..., ... }
result.to_h.merge(result.extra)
```

## Xử lý lỗi

Các phương thức ném ngoại lệ khi thất bại — chúng KHÔNG trả về hash `{error:, state:}`:

| Ngoại lệ | Mô tả |
|---------|-------|
| `S3Client::S3Error` | S3 server trả về 4xx/5xx |
| `S3Client::UploadError` | Upload thất bại (bao gồm mã lỗi/thông tin từ body XML) |
| `S3Client::DownloadError` | Download thất bại |

Tất cả đều kế thừa từ `RuntimeError`.

### Thuộc tính S3Error

`S3Error` phân tích body XML và cung cấp truy cập có cấu trúc đến chi tiết lỗi:

| Thuộc tính | Kiểu | Mô tả |
|---|---|---|
| `code` | `String` | Mã trạng thái HTTP (ví dụ: `"404"`, `"403"`) |
| `request_id` | `String` | AWS request ID từ header `x-amz-request-id` |
| `s3_code` | `String` | Mã lỗi S3 từ XML `<Code>` (ví dụ: `"NoSuchBucket"`) |
| `s3_message` | `String` | Thông báo lỗi S3 từ XML `<Message>` |
| `s3_bucket` | `String` | Tên bucket từ XML `<BucketName>` |

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
  puts "S3 error: #{e.message}"
  puts "  code: #{e.code}"         # trạng thái HTTP
  puts "  s3_code: #{e.s3_code}"   # mã lỗi S3
  puts "  bucket: #{e.s3_bucket}"  # tên bucket
end
```

### Xác thực phản hồi XML

Trước khi phân tích các phản hồi XML (ví dụ từ `list_objects`, `list_multipart_uploads`, `list_parts`), client kiểm tra Content-Type của phản hồi. Nếu phản hồi rõ ràng không phải XML (ví dụ HTML), `S3Error` được ném với thông báo mô tả thay vì lỗi REXML khó hiểu.

### Xác thực endpoint

Khi xây dựng `S3Client` với `endpoint:` tùy chỉnh, URL endpoint được kiểm tra để đảm bảo bắt đầu bằng `http://` hoặc `https://` và có hostname hợp lệ. Endpoint không hợp lệ ném `ArgumentError` tại thời điểm khởi tạo.

---

## Chạy bộ kiểm thử tự động

Bộ kiểm thử dùng **Minitest** và nằm trong thư mục `tests/` của dự án.

| File | Mục đích | Thời gian |
|------|---------|-----------|
| `tests/s3_client/test_smoke.rb` | Chức năng: 9 kịch bản (upload 20MB, download full/range/stream, HEAD, DELETE, small PUT, abort) | ~5s |
| `tests/s3_client/test_state.rb` | Resumable: upload đầy đủ + state, resume một phần, state mismatch cũ | ~3s |
| `tests/s3_client/test_race.rb` | Stress: 8 threads × 20 parts, kiểm tra tính đơn điệu của state | ~10s |
| `tests/s3_client/test_memory.rb` | RAM: upload/download 200 MB, đo RSS | ~30s |
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

## Xử lý lỗi thường gặp

### `ArgumentError: part_size must be >= 5MB`

S3 yêu cầu mỗi part phải ≥ 5 MB (trừ part cuối).

### `ArgumentError: exceeds 10,000 parts`

S3 giới hạn 10.000 parts/upload. File 100 GB + `part_size=5MB` = 20.000 parts. Sửa: tăng `part_size`.

```ruby
client.upload_file(
  local_path: '/path/to/100gb.bin',
  key:        'data/100gb.bin',
  part_size:  20 * 1024 * 1024
)
```

### `Errno::ENOENT` khi resume

File cục bộ đã bị xoá hoặc di chuyển. Khôi phục file hoặc xoá state file để upload lại.

### State file thụt lùi khi bị quan sát liên tục

Race condition khi nhiều luồng ghi state song song. **Đã sửa** với `rename_mutex` bao bọc `File.write + fsync + File.rename` → state file luôn tăng đơn điệu.

### `S3 404 NoSuchUpload` khi resume

Multipart upload trên S3 đã hết hạn (lifecycle rule, thường 7 ngày). Xoá state file và upload lại:

```ruby
File.delete('huge.upload.json') if File.exist?('huge.upload.json')
```

### `S3 500` khi hoàn tất multipart

Thường là lỗi phía máy chủ. Client tự động retry với exponential backoff. Nếu vẫn thất bại, state file được giữ nguyên để resume.

### Grep log nhanh

```bash
grep '✗' app.log
grep '↻' app.log
grep 'PART DONE' app.log
grep 'progress=' app.log
grep '\[STATE LOADED\]' app.log
grep 'session=' app.log
```

---

## Tham khảo phương thức công khai

| Phương thức | Mô tả |
|-------------|-------|
| `upload_file` | Tự động upload: empty → EmptyUpload, ≤ part_size → SinglePartUpload, > part_size → MultipartUpload |
| `resume_upload` | Tiếp tục multipart upload từ state file |
| `download_file` | Streaming download, hỗ trợ Range |
| `download_stream` | Streaming download trả chunk cho caller |
| `head_object` | GET object metadata → Hash đã parse với user metadata |
| `delete_object` | Xoá object, trả về mã HTTP status |
| `presigned_url` | Tạo URL ký tạm thời |
| `list_multipart_uploads` | Liệt kê multipart uploads đang thực hiện |
| `list_parts` | Liệt kê các part đã upload |
| `upload_directory` | Upload toàn bộ thư mục song song, tự động chọn PUT/multipart mỗi file |
| `abort_multipart_upload` | Huỷ multipart upload |
| `multipart_start` | Bắt đầu multipart upload (cấp thấp) |
| `multipart_upload_part` | Upload một part (cấp thấp) |
| `multipart_complete` | Hoàn tất multipart upload (cấp thấp) |
| `multipart_abort` | Huỷ multipart upload (cấp thấp) |
| `human_readable_size` | Định dạng byte → "1.5 GB" |
| `extract_metadata_from_headers` | Trích xuất `x-amz-meta-*` từ response headers |
| `setup_logger` | Cấu hình logger |
| `log_info` / `log_warn` / `log_error` / `log_debug` | Log trực tiếp với tiền tố `[S3]` |
| `thread_log_info` / `thread_log_warn` / `thread_log_error` / `thread_log_debug` | Thread-safe logging |
| `emit_event` | Phát sự kiện đến các callback đã đăng ký |
| `transient_errors` | Danh sách lỗi có thể retry |

**Phương thức lớp** (gọi trên `S3Client`):

| Phương thức | Mô tả |
|-------------|-------|
| `S3Client.on(event, &block)` | Đăng ký callback cho sự kiện (trả về proc) |
| `S3Client.off(event, callback)` | Huỷ đăng ký callback |
| `S3Client.clear_callbacks!` | Xoá tất cả callbacks |

## Các lớp lồng nhau

| Lớp | Mô tả |
|-----|-------|
| `S3Client::UploadState` | Wrapper OOP cho trạng thái resumable upload — serialization, theo dõi tiến trình, theo dõi luồng & in-progress |
| `S3Client::S3Error` | Ngoại lệ lỗi S3 server |
| `S3Client::UploadError` | Ngoại lệ upload thất bại |
| `S3Client::DownloadError` | Ngoại lệ download thất bại |
| `S3Client::UploadResult` | Data object: `key`, `size`, `etag`, `elapsed`, `throughput`, `extra` |
| `S3Client::DownloadResult` | Data object: `path`, `size`, `elapsed`, `throughput`, `extra` |
