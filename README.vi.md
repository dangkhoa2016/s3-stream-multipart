# s3-stream-multipart

[![CI](https://github.com/dangkhoa2016/s3-stream-multipart/actions/workflows/ci.yml/badge.svg)](https://github.com/dangkhoa2016/s3-stream-multipart/actions/workflows/ci.yml)
[![Gem Version](https://img.shields.io/gem/v/s3-stream-multipart)](https://rubygems.org/gems/s3-stream-multipart)

> 🌐 Language / Ngôn ngữ: [English](README.md) | **Tiếng Việt**

Một Ruby client nhẹ, tiết kiệm bộ nhớ cho lưu trữ tương thích S3. Hỗ trợ AWS S3, MinIO, Cloudflare R2, Backblaze B2 và mọi nhà cung cấp tương thích S3.

Hỗ trợ upload/download đa luồng song song (multipart) với khả năng tiếp tục, event callbacks, presigned URL và mã hoá SSE — tất cả đều không cần gem `aws-sdk-s3` (dùng `aws-sigv4` + `Net::HTTP`).

## Tính năng

- Upload multipart song song (có thể tiếp tục qua file trạng thái)
- Download chunk streaming (đa luồng, có thể tiếp tục)
- Tạo presigned URL (upload, download, delete)
- Mã hoá phía máy chủ (SSE-S3, SSE-KMS, SSE-C)
- Tự động retry với exponential backoff + jitter
- Event callbacks (21+ sự kiện cho logging/progress/alerting)
- Lưu trạng thái nguyên tử (tiếp tục an toàn sau crash)
- Upload thư mục hàng loạt với theo dõi tiến trình
- Biến thể đơn bucket (`S3Client`) và đa bucket (`S3MultiBucketClient`)
- Phương thức factory `S3Client.build` tự động chọn client phù hợp

## Yêu cầu

Ruby **>= 3.2** (dùng `Data.define`, endless methods và các tính năng hiện đại khác).

## Cài đặt

```ruby
# Gemfile
gem "s3-stream-multipart"
```

Hoặc build cục bộ:

```bash
gem build s3-stream-multipart.gemspec
gem install s3-stream-multipart-3.0.0.gem
```

## Bắt đầu nhanh

### Dùng factory (khuyến nghị)

```ruby
require "s3-stream-multipart"

# Client đơn bucket (truyền bucket:) → trả về S3Client
client = S3Client.build(
  region:            "us-east-1",
  bucket:            "my-bucket",
  access_key_id:     ENV["S3_ACCESS_KEY_ID"],
  secret_access_key: ENV["S3_SECRET_ACCESS_KEY"]
)

client.upload_file(local_path: "photo.jpg", key: "photos/photo.jpg")

# Client đa bucket (bỏ bucket:, thêm endpoint:) → trả về S3MultiBucketClient
client = S3Client.build(
  region:            "us-east-1",
  endpoint:          "https://minio.local:9000",
  access_key_id:     "minioadmin",
  secret_access_key: "minioadmin"
)

client.upload_file(bucket: "my-bucket", local_path: "photo.jpg", key: "photos/photo.jpg")
```

`S3Client.build(bucket: "b", ...)` → `S3Client` (một bucket cố định).
`S3Client.build(endpoint: "...", ...)` → `S3MultiBucketClient` (bucket riêng mỗi lần gọi).
Ném `ArgumentError` nếu không có `bucket:` hoặc `endpoint:`.

### Dùng trực tiếp S3Client (một bucket)

```ruby
require "s3-stream-multipart"

client = S3Client.new(
  region:            "us-east-1",
  bucket:            "my-bucket",
  access_key_id:     ENV["S3_ACCESS_KEY_ID"],
  secret_access_key: ENV["S3_SECRET_ACCESS_KEY"]
)

# Upload file nhỏ (PUT đơn)
client.upload_file(local_path: "report.pdf", key: "documents/report.pdf")

# Upload multipart có tiếp tục
client.upload_file(
  local_path: "large_video.mp4",
  key:        "videos/large_video.mp4",
  state_file: "uploads/large_video.state.json"
)
```

### Dùng trực tiếp S3MultiBucketClient (nhiều bucket)

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
# S3Client (trả về DownloadResult với .path, .size, .elapsed, .throughput)
result = client.download_file(key: "videos/large.mp4", destination_path: "large.mp4")
puts "Downloaded #{result.size} bytes in #{result.elapsed}s"

# S3MultiBucketClient (yêu cầu bucket:)
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

## An toàn luồng (Thread Safety)

Các instance client **không** an toàn cho luồng khi gọi API công cộng đồng thời (ví dụ gọi
`upload_file` từ nhiều luồng trên cùng một client). Nội bộ, mỗi multipart upload/download
quản lý các worker threads của riêng nó một cách an toàn.

**Tốt:** Dùng lại một client tuần tự qua nhiều request.
**Xấu:** Dùng chung một client giữa các luồng mà không có đồng bộ hoá bên ngoài.

`Logger` và `aws-sigv4::Signer` của Ruby an toàn cho luồng; mọi trạng thái mutable nội bộ
đều dùng mutex hoặc chỉ đọc sau khi khởi tạo.

## Hiệu năng & Bộ nhớ

- **Upload** (file N GB): RSS đỉnh ≈ `part_size × max_concurrency` — mỗi luồng đọc
  đúng một part, gửi đi, rồi giải phóng.
- **Download** (file N GB): RSS đỉnh ≈ chunk buffer (mặc định 64 KB).
  `Net::HTTP#read_body` ghi chunk trực tiếp vào `File#write` — không có bộ đệm trung gian.

## CLI

Giao diện dòng lệnh có sẵn sau khi cài gem:

```bash
# Upload file
s3sm upload photo.jpg --bucket my-bucket --key photos/photo.jpg

# Download file
s3sm download photos/photo.jpg /tmp/photo.jpg --bucket my-bucket

# Tạo presigned URL (hết hạn trong 1 giờ)
s3sm presign photos/photo.jpg --bucket my-bucket --expires 3600

# Xoá object
s3sm delete photos/photo.jpg --bucket my-bucket

# Upload thư mục
s3sm upload-dir ./build --bucket my-bucket --prefix site/

# Liệt kê multipart uploads đang hoạt động
s3sm list-uploads --bucket my-bucket

# Dùng biến môi trường cho thông tin xác thực
export AWS_ACCESS_KEY_ID=...
export AWS_SECRET_ACCESS_KEY=...
export AWS_REGION=us-east-1
export AWS_BUCKET=my-bucket
s3sm upload photo.jpg --key photos/photo.jpg

# Endpoint tuỳ chỉnh (MinIO, R2, v.v.)
s3sm --endpoint https://minio.local:9000 upload photo.jpg \
  --bucket my-bucket --key photos/photo.jpg
```

Chạy `s3sm --help` để xem tất cả lệnh và tuỳ chọn.

## Tham khảo API đầy đủ

### Kiểu trả về

Tất cả upload/download trả về đối tượng `Data` (`.key`, `result[:key]`, hoặc `result.to_h`):

```ruby
UploadResult   = Data.define(:key, :size, :etag, :elapsed, :throughput, :extra)
DownloadResult = Data.define(:path, :size, :elapsed, :throughput, :extra)
```

| Trường | Kiểu | UploadResult | DownloadResult | Ghi chú |
|--------|------|-------------|---------------|---------|
| `.key` | String | ✓ | — | Key của object trên S3 |
| `.path` | String | — | ✓ | Đường dẫn file cục bộ |
| `.size` | Integer | ✓ | ✓ | Số byte |
| `.etag` | String | ✓ | — | ETag S3 (MD5 hoặc hash multipart) |
| `.elapsed` | Float | ✓ | ✓ | Thời gian thực tế (giây) |
| `.throughput` | Float | ✓ | ✓ | Tốc độ MB/s hiệu dụng |
| `.extra` | Hash | ✓ | ✓ | Upload ID, parts, bucket, destination, v.v. |

`.to_h` gộp các key từ `extra` lên cấp cao nhất để có thể destructure trực tiếp:

```ruby
result = client.upload_file(local_path: "f.bin", key: "f.bin")
result.key          # "f.bin"
result[:key]        # "f.bin"
result.to_h         # { key: "f.bin", size: 100, etag: "...", elapsed: 0.5, throughput: 0.2, extra: {...} }
# các key của extra (upload_id, parts, v.v.) được gộp vào to_h:
result[:upload_id]  # "abc123"  (từ extra)
```

### S3Client

| Phương thức | Mô tả |
|-------------|-------|
| `upload_file(key:, local_path:, content_type:, metadata:, cache_control:, part_size:, state_file:, skip_existing:, on_progress:, max_threads:, max_retries:, retry_delay:)` | Upload file (tự động dispatch: PUT 0-byte, streaming PUT, hoặc multipart) |
| `download_file(key:, destination_path:, range:, on_progress:)` | Download file (streaming) |
| `download_stream(key:, &)` | Stream body chunks không qua bộ đệm |
| `resume_upload(state_file:, key:, on_progress:, bucket:, local_path:)` | Tiếp tục upload bị gián đoạn từ file trạng thái |
| `upload_directory(directory:, prefix:, pattern:, exclude:, max_files:, multipart_threshold:, on_file_start:, on_file_complete:, on_file_error:, content_type:, metadata:, cache_control:, skip_existing:, state_dir:)` | Upload mọi file trong thư mục |
| `head_object(key:)` → Hash | Lấy metadata object |
| `delete_object(key:)` → `204` (Integer) S3Client / `{key:, status: 'deleted'}` (Hash) MBC | Xoá object |
| `presigned_url(key:, method:, expires_in:, query:)` → String | Tạo presigned URL |
| `list_multipart_uploads(key_prefix:, max_uploads:)` → Array | Liệt kê multipart uploads đang thực hiện |
| `list_parts(key:, upload_id:, max_parts:)` → Array | Liệt kê các part của một upload |
| `abort_multipart_upload(key:, upload_id:)` → Hash `{key:, upload_id:, status: "aborted"}` | Huỷ và dọn dẹp các part |

### S3MultiBucketClient

Giống S3Client, thêm:

| Tham số bổ sung | Áp dụng cho |
|-----------------|-------------|
| `bucket:` (bắt buộc) | `upload_file`, `download_file`, `upload_directory`, `head_object`, `delete_object`, `presigned_url` |

```ruby
client.upload_file(bucket: "my-bucket", local_path: "f.txt", key: "f.txt")
client.download_file(bucket: "my-bucket", key: "f.txt", destination_path: "f.txt")
```

### S3Helper

```ruby
# Upload một lần nhanh (tự động phát hiện S3Client hay S3MultiBucketClient)
S3Helper.upload(client:, key:, local_path:, bucket:, ...)

# Download một lần nhanh (có thể kèm progress bar)
S3Helper.download(client:, key:, local_path:, destination:, bucket:, ...)

# Upload thư mục hàng loạt
S3Helper.upload_bulk(client:, directory:, prefix:, bucket:, max_files:, ...)
```

### Xử lý lỗi

Các phương thức ném ngoại lệ có kiểu khi thất bại:

| Ngoại lệ | Khi nào |
|----------|---------|
| `S3BaseClient::S3Error` | Server trả về lỗi (status 4xx/5xx) |
| `S3BaseClient::UploadError` | Lỗi upload cụ thể (part lỗi, etag không khớp) |
| `S3BaseClient::DownloadError` | Lỗi download cụ thể (mất kết nối, partial content) |

Tất cả đều kế thừa từ `RuntimeError`. Bắt từ cụ thể nhất đến tổng quát nhất:

```ruby
begin
  client.upload_file(local_path: "data.bin", key: "data.bin")
rescue S3BaseClient::UploadError => e
  retry if e.message.include?("part")  # thử lại nếu part lỗi
rescue S3BaseClient::S3Error => e
  puts "S3 returned #{e.code}: #{e.message}"
rescue Net::ReadTimeout, Net::OpenTimeout => e
  puts "Network issue — consider increasing read_timeout:"
end
```

### Tuỳ chọn khởi tạo

Cả hai client đều chấp nhận:

| Tuỳ chọn | Mặc định | Mô tả |
|----------|---------|-------|
| `access_key_id:` | — | Access key kiểu AWS |
| `secret_access_key:` | — | Secret key kiểu AWS |
| `region:` | — | AWS region (ví dụ `us-east-1`) |
| `bucket:` | — | Bucket mặc định (S3Client: bắt buộc; MBC: tuỳ chọn) |
| `endpoint:` | — | Endpoint S3 tuỳ chỉnh |
| `endpoint_style:` | `:auto` | Kiểu URL `:path` hoặc `:virtual_host` |
| `part_size:` | `10_485_760` (10 MiB) S3Client / `8_388_608` (8 MiB) MBC | Kích thước chunk multipart (tối thiểu 5 MiB) |
| `max_concurrency:` | `4` | Số part song song tối đa (giới hạn 1–32) |
| `max_retries:` | `3` | Số lần retry cho lỗi tạm thời |
| `retry_delay:` | `0.25` | Thời gian chờ retry cơ bản (giây) (exponential + jitter) |
| `open_timeout:` | `30` | Timeout kết nối HTTP (giây) |
| `read_timeout:` | `600` | Timeout đọc HTTP (giây) |
| `session_token:` | — | STS session token cho thông tin xác thực tạm thời |
| `sse:` | — | Cấu hình mã hoá phía máy chủ (xem bên dưới) |
| `debug:` | `false` | Bật logging HTTP request/response chi tiết |
| `logger:` | — | Instance `Logger` tuỳ chỉnh |
| `log_file:` | — | Đường dẫn đến file log (bỏ qua nếu đã đặt `logger:`) |
| `log_color:` | `false` | Tô màu ANSI trong output log |
| `log_format:` | `:text` | `:text` hoặc `:json` |

#### Mã hoá phía máy chủ (`sse:`)

Tuỳ chọn `sse:` chấp nhận Hash với key `:type`:

| Loại | Định dạng Hash | Mô tả |
|------|----------------|-------|
| SSE-S3 | `{ type: "AES256" }` | Key do Amazon S3 quản lý |
| SSE-KMS | `{ type: "aws:kms", kms_key_id: "..." }` | AWS KMS (tuỳ chọn key ID) |
| SSE-C | `{ type: "customer", key: "base64...", key_md5: "base64..." }` | Key do khách hàng cung cấp |

```ruby
# Ví dụ SSE-C
client = S3Client.new(region: "us-east-1", bucket: "my-bucket",
                       access_key_id: "...", secret_access_key: "...",
                       sse: { type: "customer", key: "base64key==", key_md5: "base64md5==" })
```

## Tài liệu

### Hướng dẫn

- [Hướng dẫn S3Client](docs/USAGE_GUIDE.s3_client.vi.md) — API đầy đủ, ví dụ, định dạng file trạng thái
- [Hướng dẫn S3MultiBucketClient](docs/USAGE_GUIDE.s3_multi_bucket_client.vi.md) — ví dụ đa bucket với SSE, retry, bulk upload
- [Hướng dẫn CLI](docs/USAGE_GUIDE.cli.vi.md) — tham khảo công cụ dòng lệnh `s3sm`

### Tổng quan

- [Tổng quan S3Client](docs/ABOUT.s3_client.vi.md) — tóm tắt tính năng
- [Tổng quan S3MultiBucketClient](docs/ABOUT.s3_multi_bucket_client.vi.md) — tóm tắt tính năng

### Script & Sử dụng thủ công

- [Hướng dẫn script upload](manually/upload-USAGE.vi.md) — tham khảo `upload.sh` với S3Client & S3MultiBucketClient
- [Hướng dẫn script upload thư mục](manually/folder-upload-USAGE.vi.md) — tham khảo `folder-upload.sh` cho batch upload
- [Upload script usage (English)](manually/upload-USAGE.md)
- [Folder upload script usage (English)](manually/folder-upload-USAGE.md)

## Phát triển

```bash
git clone https://github.com/dangkhoa2016/s3-stream-multipart.git
cd s3-stream-multipart
bundle install
bundle exec rake test    # chạy tất cả tests
bundle exec rake test:quick  # bỏ qua tests bộ nhớ/race
```

## Giấy phép

[MIT](LICENSE)
