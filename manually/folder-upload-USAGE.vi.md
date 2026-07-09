# Folder Upload — Hướng dẫn sử dụng

> 🌐 Language / Ngôn ngữ: [English](folder-upload-USAGE.md) | **Tiếng Việt**

Script `folder-upload.sh` là công cụ dòng lệnh để upload **toàn bộ thư mục** lên S3 (hoặc S3-compatible storage như MinIO, Cloudflare R2, Backblaze B2) một cách song song.

Mỗi file trong thư mục local được map thành một S3 object key theo công thức:

```
S3 key = prefix + đường dẫn tương đối
```

Ví dụ: upload thư mục `./dist` với prefix `website/` thì file `./dist/css/style.css` sẽ thành key `website/css/style.css`.

Script tự động chọn **single PUT** (file nhỏ) hoặc **multipart upload** (file lớn) dựa trên ngưỡng `--multipart-threshold` (mặc định 100 MB).

---

## Mục lục

- [Yêu cầu](#yêu-cầu)
- [Cài đặt credentials](#cài-đặt-credentials)
- [Cách sử dụng cơ bản](#cách-sử-dụng-cơ-bản)
- [Tất cả options](#tất-cả-options)
- [Biến môi trường](#biến-môi-trường)
- [Thứ tự ưu tiên cấu hình](#thứ-tự-ưu-tiên-cấu-hình)
- [Chọn loại client](#chọn-loại-client)
- [Ví dụ theo tình huống](#ví-dụ-theo-tình-huống)
  - [1. Deploy static website lên AWS S3](#1-deploy-static-website-lên-aws-s3)
  - [2. Upload vào MinIO local](#2-upload-vào-minio-local)
  - [3. Upload chỉ ảnh, bỏ qua node_modules và .git](#3-upload-chỉ-ảnh-bỏ-qua-node_modules-và-git)
  - [4. Backup thư mục dữ liệu](#4-backup-thư-mục-dữ-liệu)
  - [5. Deploy với cache-control khác nhau cho từng loại file](#5-deploy-với-cache-control-khác-nhau-cho-từng-loại-file)
  - [6. Upload file lớn với multipart threshold thấp](#6-upload-file-lớn-với-multipart-threshold-thấp)
  - [7. Skip file đã tồn tại trên S3](#7-skip-file-đã-tồn-tại-trên-s3)
  - [8. Upload với STS temporary credentials](#8-upload-với-sts-temporary-credentials)
- [Output mẫu](#output-mẫu)
- [Tinh chỉnh hiệu năng](#tinh-chỉnh-hiệu-năng)
- [Xử lý lỗi](#xử-lý-lỗi)
- [So sánh upload.sh và folder-upload.sh](#so-sánh-uploadsh-và-folder-uploadsh)

---

## Yêu cầu

- **Bash** 4.0+
- **Ruby** 3.2+ (s3-stream-multipart gem sử dụng `Data.define`)
- Credentials có quyền ghi vào bucket đích

Kiểm tra Ruby:

```bash
ruby --version          # >= 3.2
```

---

## Cài đặt credentials

Trước khi chạy, cần set biến môi trường:

```bash
# AWS S3
export S3_ACCESS_KEY_ID="AKIAIOSFODNN7EXAMPLE"
export S3_SECRET_ACCESS_KEY="wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY"

# MinIO (local testing)
export S3_ACCESS_KEY_ID="minioadmin"
export S3_SECRET_ACCESS_KEY="minioadmin"
```

---

## Cách sử dụng cơ bản

```bash
# Tối thiểu: chỉ cần thư mục và bucket
./folder-upload.sh -d ./my-folder -b my-bucket

# Với prefix
./folder-upload.sh -d ./dist -b my-website -p "v2/"

# Dùng hoàn toàn biến môi trường
export LOCAL_FOLDER_PATH="./dist"
export S3_BUCKET="my-bucket"
export S3_ACCESS_KEY_ID="AKIA..."
export S3_SECRET_ACCESS_KEY="..."
./folder-upload.sh
```

Xem trợ giúp:

```bash
./folder-upload.sh --help
```

---

## Tất cả options

| Option | Viết tắt | Mô tả | Mặc định |
|--------|----------|--------|----------|
| `--directory DIR` | `-d` | Thư mục local cần upload | Env `LOCAL_FOLDER_PATH` |
| `--bucket BUCKET` | `-b` | Tên S3 bucket | Env `S3_BUCKET` |
| `--prefix PREFIX` | `-p` | Tiền tố S3 key | `""` (rỗng) |
| `--region REGION` | `-r` | AWS region | `us-east-1` |
| `--endpoint URL` | `-e` | Custom S3 endpoint | AWS default |
| `--client TYPE` | `-c` | Loại client: `s3_client` hoặc `multi_bucket` | `s3_client` |
| `--max-files N` | `-j` | Số file upload song song | `4` |
| `--multipart-threshold N` | `-t` | Ngưỡng byte để chuyển sang multipart | `104857600` (100 MB) |
| `--pattern GLOB` | | Glob pattern lọc file | `**/*` (tất cả) |
| `--exclude PATTERN` | | Glob pattern loại trừ (dùng nhiều lần) | Không có |
| `--cache-control VALUE` | | Header Cache-Control cho tất cả file | Không có |
| `--content-type VALUE` | | Ép Content-Type cho tất cả file | Tự động nhận diện |
| `--skip-existing` | | Bỏ qua file đã tồn tại trên S3 (so sánh size + etag). Env: `S3_SKIP_EXISTING=true` | `false` (ghi đè) |
| `--overwrite` | | Ép ghi đè file đã tồn tại trên S3 (override `S3_SKIP_EXISTING`) | Mặc định |
| `--debug` | | Bật debug logging chi tiết | `false` |
| `--state-dir DIR` | | Thư mục lưu file state resume | Env `S3_STATE_DIR` |
| `--help` | `-h` | Hiển thị trợ giúp | |

---

## Biến môi trường

| Biến | Mô tả | Bắt buộc |
|------|--------|----------|
| `S3_ACCESS_KEY_ID` | Access key ID | Có |
| `S3_SECRET_ACCESS_KEY` | Secret access key | Có |
| `S3_BUCKET` | Tên bucket (nếu không dùng `-b`) | Nếu thiếu `-b` |
| `S3_REGION` | Region (nếu không dùng `-r`) | Không |
| `S3_ENDPOINT` | Endpoint URL (nếu không dùng `-e`) | Không |
| `S3_SESSION_TOKEN` | STS session token | Không |
| `LOCAL_FOLDER_PATH` | Thư mục cần upload (nếu không dùng `-d`) | Nếu thiếu `-d` |
| `S3_STATE_DIR` | Thư mục lưu file state resume (nếu không dùng `--state-dir`) | Không |
| `S3_SKIP_EXISTING` | Bỏ qua file đã tồn tại: `true`/`false` (nếu không dùng `--skip-existing`/`--overwrite`) | Không |

---

## Thứ tự ưu tiên cấu hình

```
CLI argument > Biến môi trường > Giá trị mặc định
```

Ví dụ: `-b my-bucket` sẽ override `S3_BUCKET=other-bucket`.

---

## Chọn loại client

Script hỗ trợ 2 loại client, phù hợp với từng loại storage:

### S3Client (`-c s3_client`) — Mặc định

- Phù hợp cho **AWS S3** và các S3-compatible storage.
- Tự động build endpoint từ region + bucket (virtual-hosted style).
- Nếu có custom endpoint (`-e`), tự động chuyển sang path-style.

```bash
# AWS S3
./folder-upload.sh -d ./dist -b my-bucket

# MinIO với S3Client
./folder-upload.sh -d ./dist -b my-bucket -e http://localhost:9000
```

### S3MultiBucketClient (`-c multi_bucket`)

- Phù hợp khi cần upload vào **nhiều bucket khác nhau** bằng cùng một client.
- **Bắt buộc** phải có `--endpoint` hoặc `S3_ENDPOINT`.
- Sử dụng path-style endpoint.

```bash
./folder-upload.sh -d ./dist -b my-bucket \
  -e https://s3.ap-southeast-1.amazonaws.com \
  -c multi_bucket -r ap-southeast-1
```

### Khi nào chọn loại nào?

| Tình huống | Nên dùng |
|------------|----------|
| AWS S3 thông thường | `s3_client` (mặc định) |
| MinIO, R2, Backblaze B2 | `s3_client` + `-e` |
| Cần upload cùng data vào nhiều bucket | `multi_bucket` |
| Custom S3-compatible service | Thử `s3_client` trước, nếu lỗi chuyển `multi_bucket` |

---

## Ví dụ theo tình huống

### 1. Deploy static website lên AWS S3

Upload thư mục build (Next.js export, Hugo, Jekyll...) với cache-control phù hợp:

```bash
export S3_ACCESS_KEY_ID="AKIA..."
export S3_SECRET_ACCESS_KEY="..."

./folder-upload.sh \
  -d ./out \
  -b my-website-bucket \
  --cache-control "public, max-age=31536000, immutable" \
  --skip-existing \
  --max-files 8
```

Kết quả: mỗi file trong `./out` được upload với key tương ứng trên S3.

### 2. Upload vào MinIO local

Khởi động MinIO:

```bash
docker run -p 9000:9000 -p 9001:9001 \
  minio/minio server /data --console-address ":9001"
# Console: http://localhost:9001  (minioadmin / minioadmin)
```

Upload:

```bash
export S3_ACCESS_KEY_ID="minioadmin"
export S3_SECRET_ACCESS_KEY="minioadmin"

./folder-upload.sh \
  -d ./assets \
  -b test-bucket \
  -e http://localhost:9000 \
  -c multi_bucket \
  --max-files 8 \
  --skip-existing
```

### 3. Upload chỉ ảnh, bỏ qua node_modules và .git

```bash
./folder-upload.sh \
  -d ./my-project \
  -b my-bucket \
  -p "media/" \
  --pattern '**/*.{jpg,jpeg,png,webp,gif,svg}' \
  --exclude '**/node_modules/**' \
  --exclude '**/.git/**' \
  --exclude '**/tmp/**'
```

> `--exclude` có thể dùng nhiều lần, mỗi lần một pattern.

### 4. Backup thư mục dữ liệu

```bash
./folder-upload.sh \
  -d /var/data/app \
  -b backup-bucket \
  -p "backups/$(date +%Y/%m/%d)/" \
  --exclude '**/*.tmp' \
  --exclude '**/*.lock' \
  --max-files 2
```

Dùng `--max-files` thấp để giảm áp lực lên bandwidth.

### 5. Deploy với cache-control khác nhau cho từng loại file

Script áp dụng `--cache-control` cho **tất cả** file. Nếu cần cache khác nhau theo loại file, chạy nhiều lần với `--pattern`:

```bash
# HTML — cache ngắn (5 phút)
./folder-upload.sh -d ./dist -b my-bucket \
  --pattern '**/*.html' \
  --cache-control 'public, max-age=300'

# Static assets — cache dài (1 năm)
./folder-upload.sh -d ./dist -b my-bucket \
  --pattern '**/*.{js,css,png,jpg,svg,woff2}' \
  --cache-control 'public, max-age=31536000, immutable'

# Các file còn lại — cache vừa (1 giờ)
./folder-upload.sh -d ./dist -b my-bucket \
  --pattern '**/*.{json,xml,txt,map}' \
  --cache-control 'public, max-age=3600'
```

### 6. Upload file lớn với multipart threshold thấp

Mặc định multipart threshold là 100 MB. Với thư mục chứa nhiều file video lớn, giảm threshold xuống để tận dụng parallel upload cho từng file:

```bash
./folder-upload.sh \
  -d ./videos \
  -b media-bucket \
  -p "uploads/" \
  --multipart-threshold $((10 * 1024 * 1024)) \
  --max-files 2
```

File > 10 MB sẽ dùng multipart upload (chia nhỏ + upload song song các part).

### 7. Skip file đã tồn tại / Ghi đè lên S3

Script hỗ trợ 2 chế độ khi file đã tồn tại trên S3:

**Mặc định: ghi đè (overwrite)** — upload lại tất cả file, không kiểm tra S3.

**Skip existing** — kiểm tra file trên S3 trước, nếu **cùng size và etag** thì bỏ qua:

```bash
# Dùng CLI flag
./folder-upload.sh -d ./large-dataset -b data-bucket -p "dataset/" --skip-existing

# Hoặc dùng biến môi trường
export S3_SKIP_EXISTING=true
./folder-upload.sh -d ./large-dataset -b data-bucket -p "dataset/"
```

**Override: ép ghi đè khi env var đang set skip:**

```bash
export S3_SKIP_EXISTING=true

# Lần này muốn ghi đè tất cả → dùng --overwrite
./folder-upload.sh -d ./dist -b my-bucket --overwrite
```

Thứ tự ưu tiên:

```
--skip-existing / --overwrite (CLI) > S3_SKIP_EXISTING (env) > mặc định (ghi đè)
```

| Tình huống | Kết quả |
|------------|---------|
| Không flag, không env | Ghi đè (mặc định) |
| `--skip-existing` | Skip file trùng |
| `--overwrite` | Ghi đè (ép) |
| `S3_SKIP_EXISTING=true` | Skip file trùng |
| `S3_SKIP_EXISTING=true` + `--overwrite` | Ghi đè (CLI thắng) |
| `S3_SKIP_EXISTING=false` + `--skip-existing` | Skip file trùng (CLI thắng) |

Hữu ích khi re-upload sau khi bị gián đoạn — chỉ upload lại những file chưa có trên S3.

### 8. Upload với STS temporary credentials

```bash
export S3_ACCESS_KEY_ID="ASIA..."
export S3_SECRET_ACCESS_KEY="..."
export S3_SESSION_TOKEN="IQoJb3JpZ2lu..."

./folder-upload.sh -d ./data -b my-bucket -p "temp/"
```

Script tự động detect `S3_SESSION_TOKEN` và truyền vào client.

---

## Output mẫu

Khi chạy thành công, output trông như sau:

```
╔══════════════════════════════════════════╗
║  S3 Folder Upload — Configuration        ║
╚══════════════════════════════════════════╝

▸ Client:     S3Client
▸ Endpoint:   AWS S3 default
▸ Region:     ap-southeast-1
▸ Bucket:     my-bucket
▸ Prefix:     website/
▸ Directory:  /home/user/projects/my-site/dist
▸ Files:      42 files (156M)
▸ Pattern:    **/*
▸ Parallel:   4 files
▸ Multipart:  threshold 100 MB
▸ Cache:      public, max-age=31536000, immutable

✓ Configuration valid — starting folder upload...

Starting folder upload...
  [1/42] Uploading: index.html -> website/index.html
  [2/42] Uploading: style.css -> website/css/style.css
  [1/42] Done: website/index.html (12 KB, etag=abc123...)
  [2/42] Done: website/css/style.css (45 KB, etag=def456...)
  ...
  [42/42] Done: website/images/hero.jpg (2048 KB, etag=xyz789...)

============================================================
Upload Summary
============================================================
  Uploaded:   42 files
  Failed:     0 files
  Skipped:    0 files
  Total:      42 files (156 MB)
  Elapsed:    23.45s
  Throughput: 6.65 MB/s

✓ Folder upload finished successfully (exit code 0)
```

---

## Tinh chỉnh hiệu năng

### max-files (`-j`)

Kiểm soát số file upload **đồng thời**. Mỗi file có thể tự dùng multipart với thread pool riêng bên trong.

| Tình huống | Gợi ý `--max-files` |
|------------|---------------------|
| Bandwidth thấp (< 50 Mbps) | `2` |
| Bandwidth trung bình | `4` (mặc định) |
| Bandwidth cao + nhiều file nhỏ | `8` — `16` |
| File rất lớn (> 1 GB mỗi file) | `2` — `4` |

### multipart-threshold (`-t`)

Ngưỡng byte để quyết định file dùng single PUT hay multipart upload.

| Ngưỡng | Khi nào dùng |
|--------|-------------|
| `104857600` (100 MB) — mặc định | Phù hợp hầu hết trường hợp |
| `10485760` (10 MB) | Đường truyền không ổn định, cần retry từng part |
| `524288000` (500 MB) | Hầu hết file nhỏ-vừa, giảm overhead S3 API calls |

### Content-type tự động nhận diện

Khi không dùng `--content-type`, script tự động nhận diện MIME type từ phần mở rộng file:

| Extension | Content-Type |
|-----------|-------------|
| `.html`, `.htm` | `text/html` |
| `.css` | `text/css` |
| `.js` | `application/javascript` |
| `.json` | `application/json` |
| `.xml` | `application/xml` |
| `.png` | `image/png` |
| `.jpg`, `.jpeg` | `image/jpeg` |
| `.gif` | `image/gif` |
| `.svg` | `image/svg+xml` |
| `.webp` | `image/webp` |
| `.mp4` | `video/mp4` |
| `.webm` | `video/webm` |
| `.mp3` | `audio/mpeg` |
| `.pdf` | `application/pdf` |
| `.woff`, `.woff2` | `font/woff`, `font/woff2` |
| Không xác định | `application/octet-stream` |

---

## Xử lý lỗi

### Lỗi thường gặp

| Thông báo lỗi | Nguyên nhân | Cách xử lý |
|---------------|------------|-----------|
| `S3_ACCESS_KEY_ID is not set` | Chưa set credentials | `export S3_ACCESS_KEY_ID=...` |
| `Bucket not specified` | Thiếu bucket | Dùng `-b bucket-name` hoặc `export S3_BUCKET=...` |
| `Directory not specified (use -d or set LOCAL_FOLDER_PATH)` | Chưa chỉ định thư mục | Dùng `-d /path` hoặc `export LOCAL_FOLDER_PATH=./dist` |
| `Directory not found: /path` | Thư mục không tồn tại | Kiểm tra lại đường dẫn `-d` hoặc `LOCAL_FOLDER_PATH` |
| `S3_ENDPOINT is required for S3MultiBucketClient` | Dùng `-c multi_bucket` nhưng thiếu endpoint | Thêm `-e https://...` |
| Exit code `1` với danh sách "Failed files" | Một số file upload thất bại | Kiểm tra log, thử lại với `--skip-existing` |

### Debug mode

Thêm `--debug` để xem chi tiết từng HTTP request/response:

```bash
./folder-upload.sh -d ./test -b my-bucket --debug
```

### Retry tự động

Script kế thừa cơ chế retry từ Ruby S3 client:

- **Lỗi transient** (timeout, connection reset): tự động retry với exponential backoff.
- **S3 5xx errors**: tự động retry.
- **Multipart**: nếu một part thất bại, retry part đó, không cần upload lại từ đầu.

---

## So sánh upload.sh và folder-upload.sh

| Tính năng | `upload.sh` | `folder-upload.sh` |
|-----------|------------|---------------------|
| Upload | **1 file** đơn lẻ | **Cả thư mục** (nhiều file) |
| CLI args | Không (dùng ENV) | Có (CLI args + ENV) |
| Ruby script | Chạy file `.rb` riêng | Inline Ruby |
| Pattern/exclude | Không | Có (`--pattern`, `--exclude`) |
| Cache-control | Trong Ruby script | `--cache-control` |
| Skip/Overwrite | Không | `--skip-existing`, `--overwrite`, env `S3_SKIP_EXISTING` |
| Progress | Chi tiết trong Ruby | Tóm tắt từng file |
| Use case | Upload 1 file lớn (video, archive) | Deploy website, backup thư mục |
