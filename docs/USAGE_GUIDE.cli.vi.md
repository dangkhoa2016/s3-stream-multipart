# s3sm CLI - Hướng dẫn sử dụng chi tiết

> 🌐 Language / Ngôn ngữ: [English](USAGE_GUIDE.cli.md) | **Tiếng Việt**

`s3sm` là công cụ dòng lệnh để tương tác với lưu trữ S3-compatible, được bao gồm trong gem `s3-stream-multipart`. Hỗ trợ tải lên, tải xuống, tạo URL presigned, xóa đối tượng, quản lý tải lên multipart, và tải lên thư mục — tất cả mà không cần gem `aws-sdk-s3`.

**Mã nguồn:** [`exe/s3sm`](../exe/s3sm)

---

## Mục lục

- [Cài đặt](#cài-đặt)
- [Tùy chọn toàn cục](#tùy-chọn-toàn-cục)
- [Biến môi trường](#biến-môi-trường)
- [Các lệnh](#các-lệnh)
  - [upload](#upload---tải-lên-một-tập-tin)
  - [download](#download---tải-xuống-một-tập-tin)
  - [presign](#presign---tạo-url-presigned)
  - [delete](#delete---xóa-một-đối-tượng)
  - [list-parts](#list-parts---liệt-kê-các-part-của-multipart-upload)
  - [list-uploads](#list-uploads---liệt-kê-các-multipart-upload-đang-hoạt-động)
  - [upload-dir](#upload-dir---tải-lên-một-thư-mục)
- [Ví dụ](#ví-dụ)
  - [AWS S3](#aws-s3)
  - [MinIO / Cloudflare R2](#minio--cloudflare-r2)
  - [Backblaze B2](#backblaze-b2)
  - [Quy trình: tải lên rồi chia sẻ](#quy-trình-tải-lên-rồi-chia-sẻ)
  - [Quy trình: dọn dẹp upload cũ](#quy-trình-dọn-dẹp-upload-cũ)
- [Cách chọn client](#cách-chọn-client)
- [Xử lý lỗi](#xử-lý-lỗi)
- [Khắc phục sự cố](#khắc-phục-sự-cố)

---

## Cài đặt

Cài đặt gem:

```bash
gem install s3-stream-multipart
```

Hoặc thêm vào Gemfile:

```ruby
gem "s3-stream-multipart"
```

Sau đó build cục bộ:

```bash
gem build s3-stream-multipart.gemspec
gem install s3-stream-multipart-*.gem
```

Kiểm tra CLI:

```bash
s3sm --help
```

---

## Tùy chọn toàn cục

Tùy chọn toàn cục phải đặt **trước** lệnh:

```
s3sm [tùy-chọn-toàn-cục] <lệnh> [tùy-chọn-lệnh]
```

| Tùy chọn | Mô tả | Mặc định |
|---|---|---|
| `--endpoint URL` | URL endpoint S3-compatible (kích hoạt `S3MultiBucketClient`) | *(không có — dùng `S3Client`)* |
| `--region REGION` | Vùng AWS | `us-east-1` |
| `--bucket BUCKET` | Tên bucket mặc định | *(không có)* |
| `--access-key KEY` | Access key ID | *(không có)* |
| `--secret-key KEY` | Secret access key | *(không có)* |
| `-h`, `--help` | Hiển thị trợ giúp | — |

---

## Biến môi trường

Tất cả tùy chọn toàn cục có thể đặt qua biến môi trường. Flag CLI có ưu tiên hơn biến môi trường.

| Biến | Áp dụng cho |
|---|---|
| `AWS_ACCESS_KEY_ID` | `--access-key` |
| `AWS_SECRET_ACCESS_KEY` | `--secret-key` |
| `AWS_REGION` | `--region` |
| `AWS_BUCKET` | `--bucket` |
| `AWS_ENDPOINT` | `--endpoint` |

Ví dụ:

```bash
export AWS_ACCESS_KEY_ID=AKIAIOSFODNN7EXAMPLE
export AWS_SECRET_ACCESS_KEY=wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY
export AWS_REGION=ap-southeast-1
export AWS_BUCKET=my-bucket

s3sm upload report.pdf --key documents/report.pdf
```

---

## Các lệnh

### `upload` — Tải lên một tập tin

Tải lên một tập tin cục bộ lên S3. Sử dụng streaming single PUT (không multipart — dùng API Ruby cho multipart với state file).

```
s3sm upload <đường-dẫn-tập-tin> --key KEY [tùy-chọn]
```

| Tùy chọn | Mô tả |
|---|---|
| `--key KEY` | Khóa đối tượng S3 **(bắt buộc)** |
| `--bucket BUCKET` | Tên bucket (ghi đè `--bucket` toàn cục) |
| `--content-type TYPE` | Header Content-Type (mặc định: `application/octet-stream`) |
| `--skip-existing` | Bỏ qua nếu đối tượng đã tồn tại |
| `--concurrency N` | Số luồng đồng thời tối đa |
| `--retries N` | Số lần thử lại tối đa mỗi part |
| `--cache-control VAL` | Giá trị header Cache-Control |

**Ví dụ:**

```bash
# Tải lên cơ bản
s3sm upload photo.jpg --key photos/photo.jpg --bucket my-bucket

# Chỉ定 content type
s3sm upload index.html --key site/index.html --content-type text/html --bucket my-bucket

# Bỏ qua nếu đã tồn tại
s3sm upload data.csv --key reports/data.csv --skip-existing --bucket my-bucket
```

**Đầu ra:**

```
Uploaded: photos/photo.jpg
```

**Tham chiếu mã nguồn:** [`exe/s3sm:75-106`](../exe/s3sm#L75-L106) (`cmd_upload`, `parse_upload_opts`)

---

### `download` — Tải xuống một tập tin

Tải xuống một đối tượng từ S3 về tập tin cục bộ.

```
s3sm download <key> [đường-dẫn-đích] [tùy-chọn]
```

| Tùy chọn | Mô tả |
|---|---|
| `--bucket BUCKET` | Tên bucket (ghi đè `--bucket` toàn cục) |
| `--resume` | Tiếp tục tải xuống bị gián đoạn trước đó |

**Ví dụ:**

```bash
# Tải xuống về thư mục hiện tại
s3sm download photos/photo.jpg --bucket my-bucket

# Tải xuống về đường dẫn cụ thể
s3sm download photos/photo.jpg /tmp/photo.jpg --bucket my-bucket

# Tiếp tục tải xuống bị gián đoạn
s3sm download large-video.mp4 /tmp/large-video.mp4 --resume --bucket my-bucket
```

**Đầu ra:**

```
Downloaded to: /tmp/photo.jpg
```

**Tham chiếu mã nguồn:** [`exe/s3sm:108-131`](../exe/s3sm#L108-L131) (`cmd_download`, `parse_download_opts`)

---

### `presign` — Tạo URL presigned

Tạo URL ký tạm thời cho đối tượng S3. Không cần thông tin xác thực để sử dụng URL kết quả.

```
s3sm presign <key> [tùy-chọn]
```

| Tùy chọn | Mô tả | Mặc định |
|---|---|---|
| `--bucket BUCKET` | Tên bucket (ghi đè `--bucket` toàn cục) | — |
| `--expires GIÂY` | Thời gian hết hạn URL (giây) | `3600` (1 giờ) |
| `--method METHOD` | HTTP method: `get`, `put`, `delete`, `head` | `get` |

**Ví dụ:**

```bash
# Tạo URL tải xuống (hết hạn sau 1 giờ)
s3sm presign documents/report.pdf --bucket my-bucket

# Tạo URL tải lên (hết hạn sau 10 phút)
s3sm presign uploads/new-file.txt --method put --expires 600 --bucket my-bucket

# Tạo URL xóa
s3sm presign old-file.txt --method delete --expires 300 --bucket my-bucket
```

**Đầu ra:**

```
https://my-bucket.s3.amazonaws.com/documents/report.pdf?X-Amz-Algorithm=...&X-Amz-Signature=...
```

**Tham chiếu mã nguồn:** [`exe/s3sm:133-152`](../exe/s3sm#L133-L152) (`cmd_presign`, `parse_presign_opts`)

---

### `delete` — Xóa một đối tượng

Xóa một đối tượng khỏi S3.

```
s3sm delete <key> [tùy-chọn]
```

| Tùy chọn | Mô tả |
|---|---|
| `--bucket BUCKET` | Tên bucket (ghi đè `--bucket` toàn cục) |

**Ví dụ:**

```bash
s3sm delete old-file.txt --bucket my-bucket
s3sm delete logs/2025-01.log --bucket backups
```

**Đầu ra:**

```
Deleted: old-file.txt
```

**Tham chiếu mã nguồn:** [`exe/s3sm:154-171`](../exe/s3sm#L154-L171) (`cmd_delete`, `parse_delete_opts`)

---

### `list-parts` — Liệt kê các part của một multipart upload

Liệt kê các part đã tải lên cho một multipart upload cụ thể.

```
s3sm list-parts <key> --upload-id ID [tùy-chọn]
```

| Tùy chọn | Mô tả |
|---|---|
| `--upload-id ID` | ID tải lên **(bắt buộc)** |
| `--bucket BUCKET` | Tên bucket (ghi đè `--bucket` toàn cục) |
| `--max-parts N` | Số part tối đa cần liệt kê (mặc định: `100`) |

**Ví dụ:**

```bash
# Trước tiên, tìm upload ID
s3sm list-uploads --bucket my-bucket

# Sau đó liệt kê các part
s3sm list-parts data/large.bin --upload-id "abc-123-def" --bucket my-bucket
```

**Đầu ra:**

```
Parts for data/large.bin (upload: abc-123-def):
  Part 1: ETag="e1b2c3d4..." Size=10485760
  Part 2: ETag="f5a6b7c8..." Size=10485760
  Part 3: ETag="d9e0f1a2..." Size=5242880
```

**Tham chiếu mã nguồn:** [`exe/s3sm:173-193`](../exe/s3sm#L173-L193) (`cmd_list_parts`, `parse_list_parts_opts`)

---

### `list-uploads` — Liệt kê các multipart upload đang hoạt động

Liệt kê các multipart upload đang diễn ra trong một bucket. Hữu ích để tìm các upload bị bỏ rơi và dọn dẹp.

```
s3sm list-uploads [tùy-chọn]
```

| Tùy chọn | Mô tả |
|---|---|
| `--bucket BUCKET` | Tên bucket (ghi đè `--bucket` toàn cục) |
| `--prefix PREFIX` | Lọc theo tiền tố key |
| `--max-uploads N` | Số upload tối đa cần liệt kê (mặc định: `100`) |

**Ví dụ:**

```bash
# Liệt kê tất cả upload đang hoạt động
s3sm list-uploads --bucket my-bucket

# Liệt kê upload theo tiền tố
s3sm list-uploads --prefix videos/ --bucket my-bucket
```

**Đầu ra:**

```
Multipart uploads:
  data/large.bin — abc-123-def — 2026-07-10T09:15:00.000Z
  videos/movie.mp4 — ghi-456-jkl — 2026-07-10T10:30:00.000Z
```

Nếu không có upload nào:

```
Multipart uploads:
  (none)
```

**Tham chiếu mã nguồn:** [`exe/s3sm:195-218`](../exe/s3sm#L195-L218) (`cmd_list_uploads`, `parse_list_uploads_opts`)

---

### `upload-dir` — Tải lên một thư mục

Tải lên tất cả tập tin trong một thư mục lên S3 song song.

```
s3sm upload-dir <thư-mục> [tùy-chọn]
```

| Tùy chọn | Mô tả | Mặc định |
|---|---|---|
| `--bucket BUCKET` | Tên bucket (ghi đè `--bucket` toàn cục) | — |
| `--prefix PREFIX` | Tiền tố key thêm vào mỗi tập tin tải lên | `""` |
| `--pattern PAT` | Mẫu glob tập tin cần khớp | `**/*` |
| `--max-files N` | Số file tải lên đồng thời tối đa | `4` |
| `--skip-existing` | Bỏ qua các đối tượng đã tồn tại | `false` |

**Ví dụ:**

```bash
# Tải lên toàn bộ thư mục
s3sm upload-dir ./build --bucket my-bucket

# Tải lên với tiền tố key
s3sm upload-dir ./dist --bucket my-bucket --prefix site/

# Chỉ tải file .js
s3sm upload-dir ./dist --bucket my-bucket --pattern "**/*.js" --prefix assets/

# Tải lên song song 8 worker, bỏ qua file đã có
s3sm upload-dir ./public --bucket my-bucket --max-files 8 --skip-existing
```

**Đầu ra:**

```
Uploaded 12 files from ./build
```

**Tham chiếu mã nguồn:** [`exe/s3sm:220-242`](../exe/s3sm#L220-L242) (`cmd_upload_dir`, `parse_upload_dir_opts`)

---

## Ví dụ

### AWS S3

```bash
# Tải lên file vào AWS S3
s3sm upload backup.zip --key backups/2026-07/backup.zip \
  --bucket my-backups \
  --region ap-southeast-1 \
  --access-key AKIAIOSFODNN7EXAMPLE \
  --secret-key wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY

# Tải nó xuống
s3sm download backups/2026-07/backup.zip /tmp/backup.zip --bucket my-backups

# Tạo link presigned (hết hạn 2 giờ)
s3sm presign backups/2026-07/backup.zip --bucket my-backups --expires 7200
```

### MinIO / Cloudflare R2

Khi dùng `--endpoint`, CLI tự động chuyển sang `S3MultiBucketClient`:

```bash
# Tải lên MinIO
s3sm --endpoint https://minio.local:9000 \
  upload photo.jpg --key photos/photo.jpg --bucket my-bucket \
  --access-key minioadmin --secret-key minioadmin

# Tải thư mục lên Cloudflare R2
s3sm --endpoint https://<account-id>.r2.cloudflarestorage.com \
  upload-dir ./site --bucket static-assets --prefix v2/ \
  --access-key ... --secret-key ...

# Liệt kê multipart upload trên MinIO
s3sm --endpoint https://minio.local:9000 \
  list-uploads --bucket my-bucket \
  --access-key minioadmin --secret-key minioadmin
```

### Backblaze B2

```bash
s3sm --endpoint https://s3.<region>.backblazeb2.com \
  upload data.bin --key backups/data.bin --bucket my-b2-bucket \
  --access-key ... --secret-key ... --region us-west-000
```

### Quy trình: tải lên rồi chia sẻ

```bash
# 1. Tải lên
s3sm upload contract.pdf --key docs/contract.pdf --bucket shared-files

# 2. Tạo link chia sẻ (hết hạn 24h)
s3sm presign docs/contract.pdf --bucket shared-files --expires 86400
# → copy URL in ra và chia sẻ
```

### Quy trình: dọn dẹp upload cũ

```bash
# 1. Tìm các multipart upload đang hoạt động
s3sm list-uploads --bucket my-bucket --prefix temp/

# 2. Xem đã upload những part nào
s3sm list-parts temp/large.bin --upload-id "abc-123" --bucket my-bucket

# 3. Xóa đối tượng chưa hoàn thành nếu cần
s3sm delete temp/large.bin --bucket my-bucket
```

---

## Cách chọn client

CLI tạo một trong hai loại client dựa trên việc `--endpoint` có được cung cấp hay không:

| `--endpoint` được cung cấp? | Lớp client | Xử lý bucket |
|---|---|---|
| Không | `S3Client` | Bucket đặt một lần qua `--bucket` hoặc `AWS_BUCKET` |
| Có | `S3MultiBucketClient` | Bucket có thể ghi đè mỗi lệnh với `--bucket` |

Điều này được xác định trong phương thức `build_client` tại [`exe/s3sm:55-73`](../exe/s3sm#L55-L73):

```ruby
if endpoint
  S3MultiBucketClient.new(region:, bucket:, endpoint:, access_key_id:, secret_access_key:)
else
  S3Client.new(region:, bucket:, access_key_id:, secret_access_key:)
end
```

Cho AWS S3 (không custom endpoint), `S3Client` được dùng — đơn giản hơn và nhanh hơn một chút.

Cho MinIO, R2, B2, hoặc bất kỳ endpoint S3-compatible nào, `--endpoint` sẽ kích hoạt `S3MultiBucketClient` hỗ trợ URL path-style tự động.

---

## Xử lý lỗi

CLI thoát với mã 1 và in thông báo lỗi khi gặp sự cố:

| Thông báo | Nguyên nhân |
|---|---|
| `Unknown command: <cmd>` | Tên lệnh không hợp lệ |
| `Error: missing argument: --key` | Thiếu tùy chọn bắt buộc |
| `Missing required credential: ...` | Không tìm thấy `access_key_id` hoặc `secret_access_key` |
| `Usage: s3sm upload ...` | Thiếu đối số bắt buộc (ví dụ: không có `--key`) |

Tất cả lỗi đều in ra stderr. CLI không tạo stack trace.

**Tham chiếu mã nguồn:** [`exe/s3sm:18-21`](../exe/s3sm#L18-L21)

---

## Khắc phục sự cố

### `Missing required credential: access_key_id`

CLI không tìm thấy thông tin xác thực. Cung cấp chúng trực tiếp hoặc đặt biến môi trường:

```bash
export AWS_ACCESS_KEY_ID=...
export AWS_SECRET_ACCESS_KEY=...
s3sm upload ...
```

### `Unknown command: xyz`

Kiểm tra danh sách lệnh có sẵn:

```bash
s3sm --help
```

### Tải lên thành công nhưng tải xuống báo `404`

Khóa đối tượng có thể khác với tên tập tin cục bộ. Dùng `list-uploads` hoặc kiểm tra đầu ra `upload` để xem key chính xác.

### URL presigned trả về `AccessDenied`

Kiểm tra rằng `--method` khớp với hành động dự kiến (GET cho tải xuống, PUT cho tải lên), và `--expires` chưa khiến URL hết hạn.

### `upload-dir` không nhận các file ẩn

Mẫu glob mặc định là `**/*` loại trừ dotfiles. Dùng `--pattern` với mẫu tùy chỉnh:

```bash
s3sm upload-dir ./config --bucket my-bucket --pattern "**/*" --prefix config/
```

> **Lưu ý:** Cho các trường hợp nâng cao (multipart với state file, event callback, mã hóa SSE, callback tiến trình, tải xuống streaming), hãy dùng **API Ruby** trực tiếp. Xem [USAGE_GUIDE.s3_client.md](USAGE_GUIDE.s3_client.md) và [USAGE_GUIDE.s3_multi_bucket_client.md](USAGE_GUIDE.s3_multi_bucket_client.md).
