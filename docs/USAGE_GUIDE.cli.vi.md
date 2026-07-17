# s3sm CLI - Hướng dẫn sử dụng chi tiết

> 🌐 Language / Ngôn ngữ: [English](USAGE_GUIDE.cli.md) | **Tiếng Việt**

`s3sm` là công cụ dòng lệnh để tương tác với lưu trữ S3-compatible, được bao gồm trong gem `s3-stream-multipart`. Hỗ trợ tải lên, tải xuống, tạo URL presigned, xóa đối tượng, quản lý tải lên multipart, tải lên thư mục, và tải xuống thư mục — tất cả mà không cần gem `aws-sdk-s3`.

**Mã nguồn:** [`exe/s3sm`](../exe/s3sm)

---

## Mục lục

- [Cài đặt](#cài-đặt)
- [Tùy chọn toàn cục](#tùy-chọn-toàn-cục)
- [Biến môi trường](#biến-môi-trường)
- [Các lệnh](#các-lệnh)
  - [list](#list---liệt-kê-các-đối-tượng-trong-bucket)
  - [upload](#upload---tải-lên-một-tập-tin)
  - [download](#download---tải-xuống-một-tập-tin)
  - [presign](#presign---tạo-url-presigned)
  - [delete](#delete---xóa-một-đối-tượng)
  - [list-parts](#list-parts---liệt-kê-các-part-của-multipart-upload)
  - [list-uploads](#list-uploads---liệt-kê-các-multipart-upload-đang-hoạt-động)
  - [upload-dir](#upload-dir---tải-lên-một-thư-mục)
  - [download-dir](#download-dir---tải-xuống-một-thư-mục)
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

Kiểm tra CLI có sẵn:

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
| `--endpoint-style STYLE` | Kiểu endpoint: `path` hoặc `virtual-hosted` | `auto` |
| `--signature-version VERSION` | Phiên bản chữ ký: `v2` hoặc `v4` | `v4` |
| `--debug` | Bật chế độ gỡ lỗi | tắt |
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
| `AWS_ENDPOINT_STYLE` | `--endpoint-style` |
| `AWS_SIGNATURE_VERSION` | `--signature-version` |

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

### `list` — Liệt kê các đối tượng trong bucket

Liệt kê các đối tượng trong bucket S3, hoặc liệt kê tất cả bucket nếu không chỉ định bucket. Hỗ trợ lọc theo prefix, delimiter, liệt kê đệ quy, và tự động phân trang.

```
s3sm list [tùy-chọn]
```

| Tùy chọn | Mô tả | Mặc định |
|---|---|---|
| `--bucket BUCKET` | Tên bucket (ghi đè `--bucket` toàn cục) | — |
| `--prefix PREFIX` | Lọc theo key prefix | `""` |
| `--delimiter DELIM` | Delimiter cho common prefixes (bị bỏ qua nếu `--recursive`) | `"/"` |
| `--recursive` | Liệt kê tất cả đối tượng đệ quy (đặt `delimiter=""`) | `false` |
| `--max-keys N` | Số key tối đa mỗi request | `100` |
| `--no-paginate` | Tắt tự động phân trang | `false` |

**Ví dụ:**

```bash
# Liệt kê tất cả đối tượng trong bucket
s3sm list --bucket my-bucket

# Liệt kê đối tượng theo prefix cụ thể
s3sm list --bucket my-bucket --prefix data/

# Liệt kê đệ quy (không delimiter)
s3sm list --bucket my-bucket --prefix data/ --recursive

# Liệt kê phẳng (không delimiter, giống --recursive)
s3sm list --bucket my-bucket --prefix data/ --delimiter ""

# Liệt kê tối đa 50 đối tượng
s3sm list --bucket my-bucket --max-keys 50

# Liệt kê không phân trang (chỉ trang đầu tiên)
s3sm list --bucket my-bucket --no-paginate

# Liệt kê tất cả bucket (không chỉ định --bucket)
s3sm list
```

**Đầu ra (liệt kê đối tượng):**

```
Objects in my-bucket (prefix: data/):
  Key                           Size        LastModified                  StorageClass    ETag
  data/file1.bin                1.0 MB      2026-07-15T10:30:00.000Z      STANDARD        "a1b2c3d4..."
  data/file2.bin                2.0 MB      2026-07-15T11:00:00.000Z      STANDARD        "d4e5f6a7..."

Common prefixes:
  data/2026-07/
  data/2026-08/

Total: 2 objects, 3.0 MB
```

**Đầu ra (liệt kê tất cả bucket):**

```
Buckets:
  my-bucket     2026-01-15T00:00:00.000Z
  my-backups    2026-03-20T00:00:00.000Z

Total: 2 buckets
```

**Tham chiếu mã nguồn:** [`exe/s3sm:366-484`](../exe/s3sm#L366-L484) (`cmd_list`, `list_objects_in_bucket`, `list_all_buckets`, `parse_list_opts`)

---

### `upload` — Tải lên một tập tin

Tải lên một tập tin cục bộ lên S3. Sử dụng streaming single PUT (không multipart — dùng API Ruby cho multipart với state file).

```
s3sm upload <đường-dẫn-tập-tin> [tùy-chọn]
```

| Tùy chọn | Mô tả |
|---|---|
| `--key KEY` | Khóa đối tượng S3 (mặc định: tên file) |
| `--bucket BUCKET` | Tên bucket (ghi đè `--bucket` toàn cục) |
| `--content-type TYPE` | Header Content-Type (mặc định: `application/octet-stream`) |
| `--skip-existing` | Bỏ qua nếu đối tượng đã tồn tại với kích thước + MD5 etag khớp |
| `--concurrency N` | Số luồng đồng thời tối đa |
| `--retries N` | Số lần thử lại tối đa mỗi part |
| `--cache-control VAL` | Giá trị header Cache-Control |

**Ví dụ:**

```bash
# Tải lên cơ bản (key mặc định là tên file)
s3sm upload photo.jpg --bucket my-bucket

# Tải lên với key chỉ định
s3sm upload photo.jpg --key photos/photo.jpg --bucket my-bucket

# Chỉ định content type
s3sm upload index.html --key site/index.html --content-type text/html --bucket my-bucket

# Bỏ qua nếu đã tồn tại
s3sm upload data.csv --key reports/data.csv --skip-existing --bucket my-bucket
```

**Đầu ra:**

```
⬆  Uploading photo.jpg → photos/photo.jpg in my-bucket
  ✓ Uploaded photos/photo.jpg
```

**Tham chiếu mã nguồn:** [`exe/s3sm:240-286`](../exe/s3sm#L240-L286) (`cmd_upload`, `parse_upload_opts`)

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
# Tải xuống về thư mục hiện tại (dùng tên đối tượng làm tên file)
s3sm download photos/photo.jpg --bucket my-bucket

# Tải xuống về đường dẫn cụ thể
s3sm download photos/photo.jpg /tmp/photo.jpg --bucket my-bucket

# Tiếp tục tải xuống bị gián đoạn
s3sm download large-video.mp4 /tmp/large-video.mp4 --resume --bucket my-bucket
```

**Đầu ra:**

```
⬇  Downloading photos/photo.jpg → .
  ✓ Downloaded to /tmp/photo.jpg
```

**Tham chiếu mã nguồn:** [`exe/s3sm:290-316`](../exe/s3sm#L290-L316) (`cmd_download`, `parse_download_opts`)

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
🔗 https://my-bucket.s3.amazonaws.com/documents/report.pdf?X-Amz-Algorithm=...&X-Amz-Signature=...

Expires in 3600 seconds
```

**Tham chiếu mã nguồn:** [`exe/s3sm:320-341`](../exe/s3sm#L320-L341) (`cmd_presign`, `parse_presign_opts`)

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
✗ Deleted old-file.txt
```

**Tham chiếu mã nguồn:** [`exe/s3sm:345-362`](../exe/s3sm#L345-L362) (`cmd_delete`, `parse_delete_opts`)

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
Parts for data/large.bin
Upload: abc-123-def
────────────────────────────────────────────────────────────────
Part         ETag                                  Size
────────────────────────────────────────────────────────────────
Part 1       "e1b2c3d4..."                         10.0 MB
Part 2       "f5a6b7c8..."                         10.0 MB
Part 3       "d9e0f1a2..."                         5.0 MB
```

**Tham chiếu mã nguồn:** [`exe/s3sm:488-523`](../exe/s3sm#L488-L523) (`cmd_list_parts`, `parse_list_parts_opts`)

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
Multipart uploads
──────────────────────────────────────────────────────────────────────
Key                  Upload ID                           Initiated
──────────────────────────────────────────────────────────────────────
data/large.bin       abc-123-def                         2026-07-10T09:15:00.000Z
videos/movie.mp4     ghi-456-jkl                         2026-07-10T10:30:00.000Z
```

Nếu không có upload nào:

```
Multipart uploads
──────────────────────────────────────────────────────────────────────
(none)
```

**Tham chiếu mã nguồn:** [`exe/s3sm:527-561`](../exe/s3sm#L527-L561) (`cmd_list_uploads`, `parse_list_uploads_opts`)

---

### `upload-dir` — Tải lên một thư mục

Tải lên tất cả tập tin trong một thư mục lên S3 song song. Hỗ trợ tiếp tục từ state file.

```
s3sm upload-dir <thư-mục> [tùy-chọn]
```

| Tùy chọn | Mô tả | Mặc định |
|---|---|---|
| `--bucket BUCKET` | Tên bucket (ghi đè `--bucket` toàn cục) | — |
| `--prefix PREFIX` | Tiền tố key thêm vào mỗi tập tin tải lên | `""` |
| `--pattern PAT` | Mẫu glob tập tin cần khớp | `**/*` |
| `--max-files N` | Số file tải lên đồng thời tối đa | `4` |
| `--no-skip-existing` | Tải lên ngay cả khi file đã tồn tại với size + MD5 etag khớp | *(bật bỏ qua)* |
| `--resume` | Tiếp tục multipart upload bị gián đoạn từ state file | `true` |
| `--state-dir THƯ-MỤC` | Thư mục lưu state cho mỗi file resume | `/tmp/s3sm-state` |

**Ví dụ:**

```bash
# Tải lên toàn bộ thư mục
s3sm upload-dir ./build --bucket my-bucket

# Tải lên với tiền tố key
s3sm upload-dir ./dist --bucket my-bucket --prefix site/

# Chỉ tải file .js
s3sm upload-dir ./dist --bucket my-bucket --pattern "**/*.js" --prefix assets/

# Tải lên song song 8 worker
s3sm upload-dir ./public --bucket my-bucket --max-files 8

# Tải lên ngay cả khi file đã tồn tại (tắt skip-existing)
s3sm upload-dir ./public --bucket my-bucket --no-skip-existing

# Dùng thư mục state tùy chỉnh cho resume
s3sm upload-dir ./build --bucket my-bucket --resume --state-dir /tmp/my-state
```

**Đầu ra:**

Mỗi file được hiển thị khi bắt đầu upload, với tiến trình `[n/total]`:

```
📂 Uploading directory ./build → my-bucket
   Mode: skip-existing, resume
  ⬆ [1/12] small.txt → small.txt
  ✓ [1/12] small.txt (1.2 KB, 0.01s)
  ⬆ [2/12] data.csv → data.csv
  ✓ [2/12] data.csv (45.0 KB, 0.03s)
  ...
  ✓ Uploaded 12 files from ./build
```

Nếu một số file bị lỗi:

```
📂 Uploading directory ./build → my-bucket
   Mode: skip-existing, resume
  ⬆ [1/10] good.txt → good.txt
  ✓ [1/10] good.txt (1.0 KB, 0.01s)
  ⬆ [2/10] broken.bin → broken.bin
  ✗ [2/10] broken.bin: Connection timeout
  ...
  ✓ Uploaded 8 files from ./build
  ✗ Failed 2 files
    • broken.bin: Connection timeout
    • missing.log: File not found
```

Các file bị bỏ qua (khi bật `--skip-existing`) cũng được hiển thị inline với chỉ báo bỏ qua.

**Tham chiếu mã nguồn:** [`exe/s3sm:565-616`](../exe/s3sm#L565-L616) (`cmd_upload_dir`, `parse_upload_dir_opts`)

---

### `download-dir` — Tải xuống một thư mục

Tải xuống tất cả đối tượng khớp với tiền tố từ S3 về thư mục cục bộ song song.

```
s3sm download-dir <thư-mục-đích> [tùy-chọn]
```

| Tùy chọn | Mô tả | Mặc định |
|---|---|---|
| `--bucket BUCKET` | Tên bucket (ghi đè `--bucket` toàn cục) | — |
| `--prefix PREFIX` | Tiền tố key để lọc đối tượng | `""` |
| `--delimiter DELIM` | Delimiter cho liệt kê | *(tự động)* |
| `--max-files N` | Số file tải xuống đồng thời tối đa | `4` |

**Ví dụ:**

```bash
# Tải xuống tất cả đối tượng từ bucket về thư mục cục bộ
s3sm download-dir ./downloads --bucket my-bucket

# Tải xuống đối tượng theo tiền tố cụ thể
s3sm download-dir ./photos --bucket my-bucket --prefix photos/

# Tải xuống song song 8 worker
s3sm download-dir ./data --bucket my-bucket --prefix data/ --max-files 8
```

**Đầu ra:**

```
📂 Downloading from photos/ → ./photos
  ✓ Downloaded 8 files to ./photos
```

Nếu một số file bị lỗi:

```
📂 Downloading from data/ → ./data
  ✓ Downloaded 5 files to ./data
  ✗ Failed 2 files
    • data/missing.bin: Object not found (404)
    • data/large.bin: Connection timeout
```

**Tham chiếu mã nguồn:** [`exe/s3sm:620-657`](../exe/s3sm#L620-L657) (`cmd_download_dir`, `parse_download_dir_opts`)

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

# Tải thư mục xuống từ MinIO
s3sm --endpoint https://minio.local:9000 \
  download-dir ./local-backup --bucket my-bucket --prefix backups/ \
  --access-key minioadmin --secret-key minioadmin

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

Điều này được xác định trong phương thức `build_client` tại [`exe/s3sm:209-236`](../exe/s3sm#L209-L236):

```ruby
if endpoint
  S3MultiBucketClient.new(
    region: region, bucket: bucket, endpoint: endpoint,
    access_key_id: ak, secret_access_key: sk,
    debug: global[:debug],
    signature_version: signature_version,
    **(endpoint_style ? { endpoint_style: endpoint_style } : {})
  )
else
  S3Client.new(region: region, bucket: bucket,
               access_key_id: ak, secret_access_key: sk,
               debug: global[:debug],
               signature_version: signature_version)
end
```

Cho AWS S3 (không custom endpoint), `S3Client` được dùng — đơn giản hơn và nhanh hơn một chút.

Cho MinIO, R2, B2, hoặc bất kỳ endpoint S3-compatible nào, `--endpoint` sẽ kích hoạt `S3MultiBucketClient` hỗ trợ URL path-style tự động.

---

## Xử lý lỗi

CLI thoát với mã 1 và in thông báo lỗi khi gặp sự cố. Lỗi S3 được phân tích từ body XML và hiển thị với mã lỗi, thông tin, và tên bucket.

### Lỗi CLI cơ bản

| Thông báo | Nguyên nhân |
|---|---|
| `Unknown command: <cmd>` | Tên lệnh không hợp lệ |
| `Error: missing argument: --key` | Thiếu tùy chọn bắt buộc |
| `Missing required credential: ...` | Không tìm thấy `access_key_id` hoặc `secret_access_key` |
| `Usage: s3sm upload ...` | Thiếu đối số bắt buộc (ví dụ: không có `--key`) |

### Định dạng lỗi S3

Khi xảy ra lỗi S3 (ví dụ: `NoSuchBucket`, `AccessDenied`), CLI phân tích body XML để trích xuất thông tin có cấu trúc (`s3_code`, `s3_message`, `s3_bucket`) và hiển thị thông báo thân thiện:

```
✗ S3 error (NoSuchBucket)
  Bucket my-bucket does not exist. Create it first or check the bucket name.
```

Các mã lỗi S3 đã biết nhận thông báo dễ đọc:

| Mã S3 | Thông báo |
|---|---|
| `NoSuchBucket` | Bucket không tồn tại. Tạo bucket trước hoặc kiểm tra tên bucket. |
| `AccessDenied` | Từ chối truy cập. Kiểm tra thông tin xác thực và quyền bucket. |
| `SignatureDoesNotMatch` | Chữ ký request không khớp. Kiểm tra access key và secret key. |
| `InvalidAccessKeyId` | Access key không hợp lệ. Xác minh AWS_ACCESS_KEY_ID. |
| `ExpiredToken` | Token bảo mật đã hết hạn. Làm mới thông tin xác thực. |
| `BucketAlreadyOwnedByYou` | Bucket đã tồn tại và thuộc về bạn. |
| `BucketAlreadyExists` | Bucket đã tồn tại. Chọn tên khác. |

### Lỗi upload

Lỗi upload cụ thể (`UploadError`) được bắt và hiển thị không có stack trace:

```
✗ Upload failed: 403 Forbidden [AccessDenied: Access Denied]
```

Với `upload-dir`, lỗi từng file được hiển thị inline, và lỗi nghiêm trọng (ví dụ: `QuotaReached`, `AccessDenied`) được ghi nhật ký một lần và dừng các upload còn lại.

Tất cả lỗi đều in ra stderr. CLI không tạo stack trace.

**Tham chiếu mã nguồn:** [`exe/s3sm:110-118`](../exe/s3sm#L110-L118), [`exe/s3sm:741-795`](../exe/s3sm#L741-L795) (`format_s3_error_from_exception`, `S3_FRIENDLY_MESSAGES`)

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

Khóa đối tượng có thể khác với tên tập tin cục bộ. Dùng `list` hoặc kiểm tra đầu ra `upload` để xem key chính xác.

### URL presigned trả về `AccessDenied`

Kiểm tra rằng `--method` khớp với hành động dự kiến (GET cho tải xuống, PUT cho tải lên), và `--expires` chưa khiến URL hết hạn.

### `upload-dir` không nhận các file ẩn

Mẫu glob mặc định là `**/*` loại trừ dotfiles. Dùng `--pattern` với mẫu tùy chỉnh:

```bash
s3sm upload-dir ./config --bucket my-bucket --pattern "**/*" --prefix config/
```

> **Lưu ý:** Cho các trường hợp nâng cao (multipart với state file, event callback, mã hóa SSE, callback tiến trình, tải xuống streaming), hãy dùng **API Ruby** trực tiếp. Xem [USAGE_GUIDE.s3_client.md](USAGE_GUIDE.s3_client.md) và [USAGE_GUIDE.s3_multi_bucket_client.md](USAGE_GUIDE.s3_multi_bucket_client.md).
