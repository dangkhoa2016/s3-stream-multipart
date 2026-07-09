# S3 Upload Kiểm thử Thủ công

> 🌐 Language / Ngôn ngữ: [English](upload-USAGE.md) | **Tiếng Việt**

Các script để kiểm thử thủ công việc tải lên và liệt kê đối tượng với bộ nhớ tương thích S3 (AWS S3, MinIO, Cloudflare R2, Backblaze B2).

## Yêu cầu

- Ruby 3.2+

## Các Tập tin

| Tập tin | Mô tả |
|---|---|
| `upload.sh` | Trình khởi chạy Bash — xác thực cấu hình, sau đó chạy script tải lên Ruby |
| `upload_with_s3_client.rb` | Tải lên dùng `S3Client` (tự động PUT / multipart) |
| `upload_with_s3_multi_bucket_client.rb` | Tải lên dùng `S3MultiBucketClient` (tự động chọn PUT/multipart, nhiều bucket) |
| `list_objects.rb` | Liệt kê đối tượng trong bucket (ListObjectsV2) với đầu ra có màu |
| `upload-state.json` | *(được sinh ra)* Trạng thái khả tiếp tục cho tải lên S3Client |
| `upload-streaming-state.json` | *(được sinh ra)* Trạng thái khả tiếp tục cho tải lên S3MultiBucketClient |
| `upload_with_s3_client.log` | *(được sinh ra)* Tập tin nhật ký gỡ lỗi cho S3Client |
| `upload_with_s3_multi_bucket_client.log` | *(được sinh ra)* Tập tin nhật ký gỡ lỗi cho S3MultiBucketClient |

## Bắt đầu Nhanh

### Tùy chọn 1: AWS S3

```bash
export S3_ACCESS_KEY_ID=your-access-key-id
export S3_SECRET_ACCESS_KEY=your-secret-access-key
export S3_BUCKET=your-bucket-name
export S3_REGION=us-east-1

# Mặc định: dùng S3MultiBucketClient
bash upload.sh

# Hoặc chọn S3Client một cách tường minh
bash upload.sh s3_client
```

### Tùy chọn 2: MinIO (Bộ nhớ tương thích S3 Cục bộ)

```bash
# Khởi động MinIO
docker run -p 9000:9000 -p 9001:9001 \
  -e MINIO_ROOT_USER=minioadmin \
  -e MINIO_ROOT_PASSWORD=minioadmin \
  minio/minio server /data --console-address ":9001"
# Console: http://localhost:9001  (minioadmin / minioadmin)
# Tạo bucket (ví dụ: test-bucket) qua console trước.

export S3_ACCESS_KEY_ID=minioadmin
export S3_SECRET_ACCESS_KEY=minioadmin
export S3_BUCKET=test-bucket
export S3_REGION=us-east-1
export S3_ENDPOINT=http://localhost:9000

bash upload.sh
```

## Cấu hình

### Biến Môi trường

| Biến | Bắt buộc | Mặc định | Mô tả |
|---|---|---|---|
| `S3_ACCESS_KEY_ID` | Có | *(rỗng — được xác thực)* | AWS Access Key hoặc tên người dùng MinIO |
| `S3_SECRET_ACCESS_KEY` | Có | *(rỗng — được xác thực)* | AWS Secret Key hoặc mật khẩu MinIO |
| `S3_BUCKET` | Có | *(rỗng — được xác thực)* | Tên bucket S3 |
| `S3_REGION` | Không | `us-east-1` | Vùng AWS (giá trị bất kỳ cho MinIO) |
| `S3_ENDPOINT` | Xem ghi chú | *(rỗng)* | URL endpoint tùy chỉnh (bắt buộc cho S3MultiBucketClient) |
| `S3_SESSION_TOKEN` | Không | *(rỗng)* | Token phiên STS tạm thời |
| `S3_DEBUG` | Không | `true` | Bật ghi nhật ký mức DEBUG vào tập tin |
| `S3_LOG_FILE` | Không | `upload_with_*.log` | Đường dẫn tập tin nhật ký tùy chỉnh |
| `LOCAL_FILE_PATH` | Không | `../sample-files/breathtaking-...mp4` | Tập tin để tải lên |
| `S3_OBJECT_KEY` | Không | Giống tên tập tin | Khóa đối tượng S3 |

**Các biến mở rộng cho client streaming** (chỉ được dùng bởi `upload_with_s3_multi_bucket_client.rb`):

| Biến | Mặc định | Mô tả |
|---|---|---|
| `S3_PART_SIZE_MB` | `8` | Kích thước phần theo MB |
| `S3_MAX_THREADS` | `4` | Luồng tải lên song song |
| `S3_MAX_RETRIES` | `3` | Số lần thử lại mỗi phần |
| `S3_CONTENT_TYPE` | `application/octet-stream` | Header Content-Type |

### Chọn Client

```bash
bash upload.sh streaming    # S3MultiBucketClient (mặc định)
bash upload.sh s3_client    # S3Client
```

| | S3Client | S3MultiBucketClient |
|---|---|---|
| API tải lên | `upload_file` tự động chọn PUT / multipart | `upload_file` tự động chọn PUT / multipart |
| Endpoint | Tự động phát hiện (AWS → virtual-hosted, tùy chỉnh → path) | Luôn dạng path |
| Tập tin trạng thái | `upload-state.json` | `upload-streaming-state.json` |

## Chế độ Gỡ lỗi

Chế độ gỡ lỗi **được bật theo mặc định** (`S3_DEBUG=true`). Nó ghi nhật ký chi tiết yêu cầu/phản hồi HTTP vào một tập tin:

```bash
# Mặc định: ghi vào upload_with_s3_client.log hoặc upload_with_s3_multi_bucket_client.log
bash upload.sh

# Tập tin nhật ký tùy chỉnh
export S3_LOG_FILE=/tmp/my-upload.log
bash upload.sh

# Tắt gỡ lỗi (chỉ mức INFO)
export S3_DEBUG=false
bash upload.sh
```

## Tải lên Khả Tiếp tục

Cả hai script tải lên đều lưu trạng thái vào tập tin JSON sau mỗi phần. Nếu quá trình tải lên bị gián đoạn (Ctrl+C, treo, lỗi mạng), chạy lại cùng lệnh để tự động tiếp tục:

```bash
# Lần thử đầu tiên — bị gián đoạn giữa chừng
bash upload.sh

# Tiếp tục từ nơi đã dừng
bash upload.sh
```

- Tập tin trạng thái được **tự động xóa** khi hoàn tất thành công
- Tập tin trạng thái được **giữ lại** khi thất bại để tiếp tục
- Script kiểm tra các tập tin trạng thái hiện có trước khi tải lên (ID phiên, tiến độ, dấu vân tay tập tin)

## Liệt kê Đối tượng

Dùng `list_objects.rb` để liệt kê tất cả đối tượng trong bucket:

```bash
export S3_ACCESS_KEY_ID=your-key
export S3_SECRET_ACCESS_KEY=your-secret
export S3_BUCKET=your-bucket
export S3_REGION=us-east-1
# export S3_ENDPOINT=http://localhost:9000   # cho MinIO

ruby list_objects.rb
```

Đầu ra bao gồm khóa đối tượng, kích thước, thời gian sửa đổi lần cuối, lớp lưu trữ và tổng kết.

## Xử lý Sự cố

| Lỗi | Nguyên nhân | Cách khắc phục |
|---|---|---|
| `InvalidAccessKeyId` / `SignatureDoesNotMatch` | Sai thông tin đăng nhập | Kiểm tra `S3_ACCESS_KEY_ID` và `S3_SECRET_ACCESS_KEY` |
| `NoSuchBucket` | Bucket không tồn tại | Tạo bucket trước (AWS console hoặc MinIO console) |
| `AccessDenied` | Thiếu quyền IAM | Cấp `s3:PutObject` cho người dùng IAM |
| `S3_ENDPOINT is required` | S3MultiBucketClient cần endpoint | Đặt `S3_ENDPOINT` (ví dụ: `http://localhost:9000` cho MinIO) |
| `File not found` | `LOCAL_FILE_PATH` không tồn tại | Kiểm tra đường dẫn; các tập tin mẫu nằm trong `../sample-files/` |
