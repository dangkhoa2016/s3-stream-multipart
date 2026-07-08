# S3MultiBucketClient — Upload Multipart có thể tiếp tục & Download Song song

> 🌐 Language / Ngôn ngữ: [English](ABOUT.s3_multi_bucket_client.md) | **Tiếng Việt**

Thư viện Ruby thuần (không phụ thuộc AWS SDK) để upload/download file lớn lên lưu trữ tương thích S3 (AWS S3, MinIO, Cloudflare R2, Backblaze B2, …).

**Tính năng chính:**

- **Dùng RAM thấp & ổn định** — upload: ~`part_size × threads`, download: vài chục KB
- **Download song song** — download file lớn song song qua nhiều luồng dùng Range requests, có thể tiếp tục
- **Có thể tiếp tục** — trạng thái được ghi JSON sau mỗi part; Ctrl+C rồi chạy lại để tiếp tục (cả upload & download)
- **Đa bucket** — một client có thể thao tác trên nhiều bucket khác nhau
- **Mã hoá SSE** — hỗ trợ SSE-S3, SSE-KMS, SSE-C
- **21 event callbacks** — gắn vào mọi điểm trong vòng đời (thanh tiến trình, cảnh báo, giám sát)
- **Thread-safe logging** — worker threads dùng `thread_log_*`, main thread drain
- **Chế độ Debug** — log chi tiết HTTP request/response khi `debug: true`

> **Tài liệu chi tiết:** xem [USAGE_GUIDE.s3_multi_bucket_client.md](USAGE_GUIDE.s3_multi_bucket_client.md) để biết API đầy đủ, ví dụ, định dạng state file, cookbook và xử lý lỗi.

---

## Cài đặt

```bash
gem install aws-sigv4
```

Yêu cầu Ruby >= 3.2.

```ruby
require_relative "path/to/src/s3_multi_bucket_client"
```

## Sử dụng nhanh

```ruby
client = S3MultiBucketClient.new(
  endpoint:          "https://s3.ap-southeast-1.amazonaws.com",
  region:            "ap-southeast-1",
  access_key_id:     ENV["S3_ACCESS_KEY_ID"],
  secret_access_key: ENV["S3_SECRET_ACCESS_KEY"],
  # log_file: "s3_upload.log",   # write logs to file
  # debug:    true,               # detailed HTTP logging
)

# Upload — tự động dispatch đến EmptyUpload / SinglePartUpload / MultipartUpload
# dựa trên kích thước file so với part_size (mặc định 8 MB cho MBC).
result = client.upload_file(
  bucket:     "my-bucket",
  key:        "videos/movie.mp4",
  local_path: "/path/to/large-movie.mp4",
  part_size:  8 * 1024 * 1024,
  max_threads: 4,
  state_file: "upload-state.json",
  on_progress: ->(uploaded, total) { puts "#{uploaded}/#{total}" }
)

# Download — streaming, không load toàn bộ file vào RAM
client.download_file(
  bucket:           "my-bucket",
  key:              "videos/movie.mp4",
  destination_path: "/path/to/downloaded.mp4"
)

# Download — Range (tải một phần file)
client.download_file(
  bucket:           "my-bucket",
  key:              "videos/movie.mp4",
  destination_path: "/path/to/partial.mp4",
  range:            [0, 1024 * 1024 - 1]  # 1MB đầu
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

# Xoá
client.delete_object(bucket: "my-bucket", key: "old-file.txt")
# => { key: "old-file.txt", status: "deleted" }
```

## Tiếp tục upload sau khi gián đoạn

```ruby
# Truyền state_file: — trạng thái được ghi tự động sau mỗi part
client.upload_file(
  bucket: "my-bucket", key: "data/huge.bin",
  local_path: "/path/to/huge.bin", state_file: "upload.json"
)

# Ctrl+C → chạy lại lệnh tương tự → tự động tiếp tục
# Hoặc tiếp tục tường minh:
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

21 sự kiện: `:upload_start`, `:upload_resume`, `:part_start`, `:part_complete`, `:part_retry`, `:part_failed`, `:state_save`, `:state_load`, `:state_mismatch`, `:upload_complete`, `:upload_failed`, `:thread_start`, `:thread_finish`, `:log`, `:download_start`, `:download_part_start`, `:download_part_complete`, `:download_part_retry`, `:download_part_failed`, `:download_complete`, `:download_failed`.

## Tóm tắt API

| Nhóm | Phương thức |
|---|---|
| **Upload** | `upload_file` (tự động dispatch: empty/single/multipart), `resume_upload` |
| **Download** | `download_file` (streaming + Range), `download_stream` (block + Range) |
| **Bulk** | `upload_directory` (pattern, exclude, concurrency, state) |
| **Object ops** | `head_object`, `delete_object`, `presigned_url` |
| **Multipart** | `multipart_start`, `multipart_upload_part`, `multipart_complete`, `multipart_abort`, `abort_multipart_upload` |
| **Danh sách** | `list_multipart_uploads`, `list_parts` |
| **Logging** | `log_info/debug/warn/error`, `thread_log_*`, `emit_event`, `setup_logger` |
| **Lớp** | `S3MultiBucketClient.on/off/clear_callbacks!`, `S3MultiBucketClient.drain_logs` |
| **Lồng nhau** | `S3MultiBucketClient::UploadState`, `S3MultiBucketClient::DownloadState`, `S3MultiBucketClient::PartUploader`, `S3MultiBucketClient::PartDownloader` |
| **Kết quả** | `UploadResult` (Data — `.key`, `[:key]`, `.to_h`), `DownloadResult` (Data — `.path`, `[:path]`, `.to_h`) |
| **Lỗi** | `S3Error`, `UploadError`, `DownloadError` |
| **Helper** | `S3Helper.upload`, `S3Helper.download`, `human_readable_size` |

## Chạy kiểm thử

```bash
rake test:s3_multi_bucket_client                  # chỉ chạy test MBC
rake test:quick                                   # bỏ qua test memory/race
ruby tests/s3_multi_bucket_client/test_smoke.rb          # chạy một file
ruby tests/s3_multi_bucket_client/test_client.rb -n test_human_readable_size  # chạy một test
ruby tests/interactive/upload_resume_s3_multi_bucket_client.rb  # demo Ctrl+C resume
```

| File | Nội dung |
|---|---|
| `tests/s3_multi_bucket_client/test_upload_state.rb` | Kiểm thử unit (không cần server) |
| `tests/s3_multi_bucket_client/test_download_state.rb` | Kiểm thử download state unit |
| `tests/s3_multi_bucket_client/test_client.rb` | Kiểm thử unit (khởi tạo, tiện ích, lỗi) |
| `tests/s3_multi_bucket_client/test_smoke.rb` | Kiểm thử chức năng |
| `tests/s3_multi_bucket_client/test_state.rb` | Kiểm thử upload có thể tiếp tục |
| `tests/s3_multi_bucket_client/test_race.rb` | Kiểm thử stress: 8 threads, trạng thái đơn điệu |
| `tests/s3_multi_bucket_client/test_memory.rb` | Đo RAM |
| `tests/s3_multi_bucket_client/test_features.rb` | Presigned, list, events, logging, S3Helper |
| `tests/s3_multi_bucket_client/test_bulk_upload.rb` | Kiểm thử bulk upload |
| `tests/s3_multi_bucket_client/test_coverage.rb` | Kiểm thử coverage |

## Cấu trúc dự án

```
s3-stream-multipart/
├── src/                      # Mã nguồn
│   ├── s3_multi_bucket_client.rb # S3MultiBucketClient (entry point)
│   ├── s3_client.rb              # S3Client (single-bucket variant)
│   ├── s3-stream-multipart.rb              # Top-level require
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
├── usage/                    # Ví dụ sử dụng
├── docs/                     # Hướng dẫn (EN + VI) và so sánh
├── manually/                 # Script upload thủ công
├── tests/                    # Bộ kiểm thử chung (Minitest)
│   ├── support/              # Fake S3 server + helpers (dùng chung)
│   ├── s3_client/            # File test S3Client
│   ├── s3_multi_bucket_client/  # 10 file test
│   └── interactive/          # Demo Ctrl+C resume
├── Gemfile
└── Rakefile
```

## Khác biệt so với S3Client

| | S3MultiBucketClient | S3Client |
|---|---|---|
| **Bucket** | Truyền theo phương thức (`bucket:`) | Cố định trong constructor |
| **Upload API** | Cùng `upload_file` (tự động dispatch) | Cùng `upload_file` (tự động dispatch) |
| **Default part_size** | 8 MB | 10 MB |
| **Xử lý lỗi** | Ném `S3Error`/`UploadError`/`DownloadError` | Giống (kế thừa) |
| **`delete_object`** | Trả về `{key:, status: 'deleted'}` (Hash) | Trả về `204` (Integer) |
| **`presigned_url`** | Cần `bucket:` | Không cần `bucket:` |
| **`head_object`** | Cần `bucket:` | Không cần `bucket:` |

## Hạn chế

1. **MD5 hashing KHÔNG khả dụng** — dùng mtime + size làm fingerprint (tức thì).
2. **SSE-S3 / SSE-KMS / SSE-C** — truyền `sse:` khi khởi tạo client. SSE-C gửi key trên mỗi request part (không bao giờ bị log).
3. **Cấu hình retry** — `max_retries:` / `retry_delay:` trong constructor. Retry lỗi 5xx + 429 + transient. Backoff 2× với jitter.
4. **Định dạng log** — `log_format: :text` (mặc định) hoặc `:json`. `log_color:` bật màu ANSI.
5. **`download_file` hỗ trợ Range** — truyền `range: [start, end]` hoặc `range: start..end`.
6. **Upload ném lỗi khi thất bại** — cả `S3Client` và `S3MultiBucketClient` đều ném `S3Error`/`UploadError`/`DownloadError`. Không có kiểu trả về `{error:, state:}` im lặng.
