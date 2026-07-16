# S3Client — Upload Multipart có thể tiếp tục & Download Streaming

> 🌐 Language / Ngôn ngữ: [English](ABOUT.s3_client.md) | **Tiếng Việt**

Thư viện Ruby thuần (không phụ thuộc AWS SDK) để upload/download file lớn lên lưu trữ tương thích S3 (AWS S3, MinIO, Cloudflare R2, Backblaze B2, …).

**Tính năng chính:**

- **Yêu cầu Ruby >= 2.7.8** — sử dụng `Data.define` cho đối tượng kết quả
- **Dùng RAM thấp & ổn định** — upload: ~`part_size × concurrency`, download: vài chục KB
- **Có thể tiếp tục** — trạng thái được ghi JSON sau mỗi part; Ctrl+C rồi chạy lại để tiếp tục (cả upload & download)
- **API thống nhất** — `upload_file` tự động chọn EmptyUpload / SinglePartUpload / MultipartUpload dựa trên kích thước file
- **Mã hoá SSE** — hỗ trợ SSE-S3, SSE-KMS, SSE-C
- **21 event callbacks** — gắn vào mọi điểm trong vòng đời (thanh tiến trình, cảnh báo, giám sát)
- **Thread-safe logging** — worker threads dùng `thread_log_*`
- **Chế độ Debug** — log chi tiết HTTP request/response khi `debug: true`
- **Structured logging** — chọn `log_format: :text` (mặc định) hoặc `:json`; đầu ra màu với `log_color: true`

> **Tài liệu chi tiết:** xem [USAGE_GUIDE.s3_client.md](USAGE_GUIDE.s3_client.md) để biết API đầy đủ, ví dụ, định dạng state file, cookbook và xử lý lỗi.

---

## Cài đặt

```bash
gem install aws-sigv4
```

```ruby
require_relative "path/to/src/s3_client"
```

## Sử dụng nhanh

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

# Upload — tự động chọn single PUT hoặc multipart
result = client.upload_file(
  local_path:  "huge.bin",
  key:         "/data/huge.bin",
  state_file:  "huge.upload.json",
  on_progress: ->(written, total) { puts "#{written * 100 / total}%" }
)
puts "Uploaded #{result.key}: #{result.size} bytes in #{'%.2f' % result.elapsed}s"

# Download — streaming, không load toàn bộ file vào RAM
client.download_file(key: "/data/huge.bin", destination_path: "huge_copy.bin")

# HEAD metadata
info = client.head_object("/data/huge.bin")
puts "Size: #{info[:content_length]}, Type: #{info[:content_type]}"

# Presigned URL
url = client.presigned_url(key: "/data/huge.bin", expires_in: 3600)
```

## Tiếp tục upload sau khi gián đoạn

```ruby
# Thêm state_file: vào upload_file — trạng thái được ghi tự động sau mỗi part
client.upload_file(local_path: "huge.bin", key: "/data/huge.bin", state_file: "upload.json")

# Ctrl+C → chạy lại lệnh tương tự → tự động tiếp tục từ các part còn thiếu
# File state tự động xoá khi upload hoàn tất
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

21 sự kiện: `:upload_start`, `:upload_resume`, `:part_start`, `:part_complete`, `:part_retry`, `:part_failed`, `:state_save`, `:state_load`, `:state_mismatch`, `:upload_complete`, `:upload_failed`, `:thread_start`, `:thread_finish`, `:log`, `:download_start`, `:download_part_start`, `:download_part_complete`, `:download_part_retry`, `:download_part_failed`, `:download_complete`, `:download_failed`.

## Tóm tắt API

| Nhóm | Phương thức |
|---|---|
| **Upload** | `upload_file` (tự động dispatch), `resume_upload`, `upload_directory` |
| **Download** | `download_file` (hỗ trợ Range), `download_stream` (dạng block) |
| **Object ops** | `head_object`, `delete_object`, `presigned_url` |
| **Multipart** | `multipart_start`, `multipart_upload_part`, `multipart_complete`, `multipart_abort`, `abort_multipart_upload` |
| **Danh sách** | `list_multipart_uploads`, `list_parts` |
| **Logging** | `log_info/debug/warn/error`, `thread_log_*`, `emit_event`, `setup_logger` |
| **Lớp** | `S3Client.on/off/clear_callbacks!` |
| **Lồng nhau** | `S3Client::UploadState`, `S3Client::DownloadState`, `S3Client::S3Error` (với thuộc tính `s3_code`, `s3_message`, `s3_bucket`), `S3Client::UploadError`, `S3Client::DownloadError` |
| **Helper** | `S3Helper.upload`, `S3Helper.download`, `S3Helper.upload_bulk`, `human_readable_size` |

## Chạy kiểm thử

```bash
rake test:s3_client                    # chỉ chạy test s3_client
ruby tests/s3_client/test_smoke.rb     # chạy một file
ruby tests/s3_client/test_smoke.rb -n test_multipart_upload_20mb  # chạy một test
ruby tests/interactive/upload_resume_s3_client.rb  # demo Ctrl+C resume
```

| File | Nội dung |
|---|---|
| `tests/s3_client/test_smoke.rb` | Kiểm thử chức năng |
| `tests/s3_client/test_state.rb` | Kiểm thử upload có thể tiếp tục |
| `tests/s3_client/test_race.rb` | Kiểm thử stress: 8 threads, trạng thái đơn điệu |
| `tests/s3_client/test_memory.rb` | Đo RAM (200 MB) |
| `tests/s3_client/test_features.rb` | Presigned, list, download, events, S3Helper |
| `tests/s3_client/test_concurrent.rb` | Kiểm thử thread pool & parallel transfer |
| `tests/s3_client/test_request_executor.rb` | Kiểm thử HTTP request executor |
| `tests/s3_client/test_event_registry.rb` | Kiểm thử callback registry |
| `tests/s3_client/test_upload_state_manager.rb` | Kiểm thử upload state persistence |
| `tests/s3_client/test_parallel_download.rb` | Kiểm thử download đa luồng |

## Cấu trúc dự án

```
s3-stream-multipart/
├── src/                      # Mã nguồn
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
├── usage/                    # Ví dụ sử dụng
├── docs/                     # Hướng dẫn (EN + VI) và so sánh
├── tests/                    # Bộ kiểm thử chung (Minitest)
│   ├── support/              # Fake S3 server + helpers (dùng chung)
│   ├── s3_client/            # 20 file test
│   ├── s3_multi_bucket_client/  # 7 file test
│   └── interactive/          # Demo Ctrl+C resume
├── Gemfile
├── s3-stream-multipart.gemspec
└── Rakefile
```

## Hạn chế

1. **SSE-S3 / SSE-KMS / SSE-C** — truyền `sse:` khi khởi tạo client. SSE-C gửi key trên mỗi request part (không bao giờ bị log).
2. **Cấu hình retry** — `max_retries:` / `retry_delay:` trong constructor. Retry lỗi 5xx + 429 + transient. Backoff 2x với jitter.
3. **MinIO / R2 / endpoint không phải AWS** — phải truyền `endpoint:` và thường cần `endpoint_style: :path`.
