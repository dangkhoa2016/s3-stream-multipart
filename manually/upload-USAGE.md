# S3 Upload Manual Tests

> 🌐 Language / Ngôn ngữ: **English** | [Tiếng Việt](upload-USAGE.vi.md)

Scripts for manually testing uploads and listing objects against S3-compatible storage (AWS S3, MinIO, Cloudflare R2, Backblaze B2).

## Prerequisites

- Ruby >= 2.7.8+

## Files

| File | Description |
|---|---|
| `upload.sh` | Bash launcher — validates config, then runs a Ruby upload script |
| `upload_with_s3_client.rb` | Upload using `S3Client` (auto PUT / multipart) |
| `upload_with_s3_multi_bucket_client.rb` | Upload using `S3MultiBucketClient` (auto-select PUT/multipart, multi-bucket) |
| `list_objects.rb` | List objects in a bucket (ListObjectsV2) with colored output |
| `upload-state.json` | *(generated)* Resumable state for S3Client uploads |
| `upload-streaming-state.json` | *(generated)* Resumable state for S3MultiBucketClient uploads |
| `upload_with_s3_client.log` | *(generated)* Debug log file for S3Client |
| `upload_with_s3_multi_bucket_client.log` | *(generated)* Debug log file for S3MultiBucketClient |

## Quick Start

### Option 1: AWS S3

```bash
export S3_ACCESS_KEY_ID=your-access-key-id
export S3_SECRET_ACCESS_KEY=your-secret-access-key
export S3_BUCKET=your-bucket-name
export S3_REGION=us-east-1

# Default: use S3MultiBucketClient
bash upload.sh

# Or choose S3Client explicitly
bash upload.sh s3_client
```

### Option 2: MinIO (Local S3-compatible Storage)

```bash
# Start MinIO
docker run -p 9000:9000 -p 9001:9001 \
  -e MINIO_ROOT_USER=minioadmin \
  -e MINIO_ROOT_PASSWORD=minioadmin \
  minio/minio server /data --console-address ":9001"
# Console: http://localhost:9001  (minioadmin / minioadmin)
# Create a bucket (e.g. test-bucket) via the console first.

export S3_ACCESS_KEY_ID=minioadmin
export S3_SECRET_ACCESS_KEY=minioadmin
export S3_BUCKET=test-bucket
export S3_REGION=us-east-1
export S3_ENDPOINT=http://localhost:9000

bash upload.sh
```

## Configuration

### Environment Variables

| Variable | Required | Default | Description |
|---|---|---|---|
| `S3_ACCESS_KEY_ID` | Yes | *(empty — validated)* | AWS Access Key or MinIO username |
| `S3_SECRET_ACCESS_KEY` | Yes | *(empty — validated)* | AWS Secret Key or MinIO password |
| `S3_BUCKET` | Yes | *(empty — validated)* | S3 bucket name |
| `S3_REGION` | No | `us-east-1` | AWS region (any value for MinIO) |
| `S3_ENDPOINT` | See note | *(empty)* | Custom endpoint URL (required for S3MultiBucketClient) |
| `S3_SESSION_TOKEN` | No | *(empty)* | Temporary STS session token |
| `S3_DEBUG` | No | `true` | Enable DEBUG-level logging to file |
| `S3_LOG_FILE` | No | `upload_with_*.log` | Custom log file path |
| `LOCAL_FILE_PATH` | No | `../sample-files/breathtaking-...mp4` | File to upload |
| `S3_OBJECT_KEY` | No | Same as filename | S3 object key |

**Streaming client extras** (only used by `upload_with_s3_multi_bucket_client.rb`):

| Variable | Default | Description |
|---|---|---|
| `S3_PART_SIZE_MB` | `8` | Part size in MB |
| `S3_MAX_THREADS` | `4` | Parallel upload threads |
| `S3_MAX_RETRIES` | `3` | Retries per part |
| `S3_CONTENT_TYPE` | `application/octet-stream` | Content-Type header |

### Choosing a Client

```bash
bash upload.sh streaming    # S3MultiBucketClient (default)
bash upload.sh s3_client    # S3Client
```

| | S3Client | S3MultiBucketClient |
|---|---|---|
| Upload API | `upload_file` auto-selects PUT / multipart | `upload_file` auto-selects PUT / multipart |
| Endpoint | Auto-detect (AWS → virtual-hosted, custom → path) | Always path-style |
| State file | `upload-state.json` | `upload-streaming-state.json` |

## Debug Mode

Debug mode is **on by default** (`S3_DEBUG=true`). It writes detailed HTTP request/response logs to a file:

```bash
# Default: logs to upload_with_s3_client.log or upload_with_s3_multi_bucket_client.log
bash upload.sh

# Custom log file
export S3_LOG_FILE=/tmp/my-upload.log
bash upload.sh

# Disable debug (INFO level only)
export S3_DEBUG=false
bash upload.sh
```

## Resumable Uploads

Both upload scripts persist state to a JSON file after each part. If the upload is interrupted (Ctrl+C, crash, network error), re-run the same command to resume automatically:

```bash
# First attempt — interrupted halfway
bash upload.sh

# Resume from where it left off
bash upload.sh
```

- State file is **auto-deleted** on successful completion
- State file is **preserved** on failure for resume
- The script inspects existing state files before upload (session ID, progress, file fingerprint)

## Listing Objects

Use `list_objects.rb` to list all objects in a bucket:

```bash
export S3_ACCESS_KEY_ID=your-key
export S3_SECRET_ACCESS_KEY=your-secret
export S3_BUCKET=your-bucket
export S3_REGION=us-east-1
# export S3_ENDPOINT=http://localhost:9000   # for MinIO

ruby list_objects.rb
```

Output includes object key, size, last modified time, storage class, and a total summary.

## Troubleshooting

| Error | Cause | Fix |
|---|---|---|
| `InvalidAccessKeyId` / `SignatureDoesNotMatch` | Wrong credentials | Verify `S3_ACCESS_KEY_ID` and `S3_SECRET_ACCESS_KEY` |
| `NoSuchBucket` | Bucket doesn't exist | Create the bucket first (AWS console or MinIO console) |
| `AccessDenied` | Missing IAM permissions | Grant `s3:PutObject` to the IAM user |
| `S3_ENDPOINT is required` | S3MultiBucketClient needs an endpoint | Set `S3_ENDPOINT` (e.g. `http://localhost:9000` for MinIO) |
| `File not found` | `LOCAL_FILE_PATH` doesn't exist | Check the path; sample files are in `../sample-files/` |
