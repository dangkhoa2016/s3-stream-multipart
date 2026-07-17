# s3sm CLI - Detailed Usage Guide

> 🌐 Language / Ngôn ngữ: **English** | [Tiếng Việt](USAGE_GUIDE.cli.vi.md)

`s3sm` is a command-line tool for interacting with S3-compatible storage, included in the `s3-stream-multipart` gem. It supports uploading, downloading, presigned URL generation, object deletion, multipart upload management, directory uploads, and directory downloads — all without the `aws-sdk-s3` gem.

**Source code:** [`exe/s3sm`](../exe/s3sm)

---

## Table of contents

- [Installation](#installation)
- [Global options](#global-options)
- [Environment variables](#environment-variables)
- [Commands](#commands)
  - [list](#list---list-objects-in-a-bucket)
  - [upload](#upload---upload-a-file)
  - [download](#download---download-a-file)
  - [presign](#presign---generate-a-presigned-url)
  - [delete](#delete---delete-an-object)
  - [list-parts](#list-parts---list-parts-of-a-multipart-upload)
  - [list-uploads](#list-uploads---list-active-multipart-uploads)
  - [upload-dir](#upload-dir---upload-a-directory)
  - [download-dir](#download-dir---download-a-directory)
- [Examples](#examples)
  - [AWS S3](#aws-s3)
  - [MinIO / Cloudflare R2](#minio--cloudflare-r2)
  - [Backblaze B2](#backblaze-b2)
  - [Workflow: upload then share](#workflow-upload-then-share)
  - [Workflow: clean up stale uploads](#workflow-clean-up-stale-uploads)
- [How client selection works](#how-client-selection-works)
- [Error handling](#error-handling)
- [Troubleshooting](#troubleshooting)

---

## Installation

Install the gem:

```bash
gem install s3-stream-multipart
```

Or add to your Gemfile:

```ruby
gem "s3-stream-multipart"
```

Then build locally:

```bash
gem build s3-stream-multipart.gemspec
gem install s3-stream-multipart-*.gem
```

Verify the CLI is available:

```bash
s3sm --help
```

---

## Global options

Global options must appear **before** the command:

```
s3sm [global-options] <command> [command-options]
```

| Option | Description | Default |
|---|---|---|
| `--endpoint URL` | S3-compatible endpoint URL (triggers `S3MultiBucketClient`) | *(none — uses `S3Client`)* |
| `--region REGION` | AWS region | `us-east-1` |
| `--bucket BUCKET` | Default bucket name | *(none)* |
| `--access-key KEY` | Access key ID | *(none)* |
| `--secret-key KEY` | Secret access key | *(none)* |
| `--endpoint-style STYLE` | Endpoint style: `path` or `virtual-hosted` | `auto` |
| `--signature-version VERSION` | Signing version: `v2` or `v4` | `v4` |
| `--debug` | Enable debug logging | off |
| `-h`, `--help` | Show help | — |

---

## Environment variables

All global options can be set via environment variables. CLI flags take precedence over env vars.

| Variable | Maps to |
|---|---|
| `AWS_ACCESS_KEY_ID` | `--access-key` |
| `AWS_SECRET_ACCESS_KEY` | `--secret-key` |
| `AWS_REGION` | `--region` |
| `AWS_BUCKET` | `--bucket` |
| `AWS_ENDPOINT` | `--endpoint` |
| `AWS_ENDPOINT_STYLE` | `--endpoint-style` |
| `AWS_SIGNATURE_VERSION` | `--signature-version` |

Example:

```bash
export AWS_ACCESS_KEY_ID=AKIAIOSFODNN7EXAMPLE
export AWS_SECRET_ACCESS_KEY=wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY
export AWS_REGION=ap-southeast-1
export AWS_BUCKET=my-bucket

s3sm upload report.pdf --key documents/report.pdf
```

---

## Commands

### `list` — List objects in a bucket

List objects in an S3 bucket, or list all buckets if no bucket is specified. Supports prefix filtering, delimiter, recursive listing, and auto-pagination.

```
s3sm list [options]
```

| Option | Description | Default |
|---|---|---|
| `--bucket BUCKET` | Bucket name (overrides global `--bucket`) | — |
| `--prefix PREFIX` | Filter by key prefix | `""` |
| `--delimiter DELIM` | Delimiter for common prefixes (ignored if `--recursive`) | `"/"` |
| `--recursive` | List all objects recursively (sets `delimiter=""`) | `false` |
| `--max-keys N` | Max keys per request | `100` |
| `--no-paginate` | Disable auto-pagination | `false` |

**Examples:**

```bash
# List all objects in a bucket
s3sm list --bucket my-bucket

# List objects with a specific prefix
s3sm list --bucket my-bucket --prefix data/

# List recursively (no delimiter)
s3sm list --bucket my-bucket --prefix data/ --recursive

# List without delimiter (flat listing, same as --recursive)
s3sm list --bucket my-bucket --prefix data/ --delimiter ""

# List max 50 objects
s3sm list --bucket my-bucket --max-keys 50

# List without auto-pagination (first page only)
s3sm list --bucket my-bucket --no-paginate

# List all buckets (no --bucket specified)
s3sm list
```

**Output (listing objects):**

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

**Output (listing all buckets):**

```
Buckets:
  my-bucket     2026-01-15T00:00:00.000Z
  my-backups    2026-03-20T00:00:00.000Z

Total: 2 buckets
```

**Source reference:** [`exe/s3sm:366-484`](../exe/s3sm#L366-L484) (`cmd_list`, `list_objects_in_bucket`, `list_all_buckets`, `parse_list_opts`)

---

### `upload` — Upload a file

Upload a local file to S3. Uses a streaming single PUT (no multipart — use the Ruby API for multipart with state files).

```
s3sm upload <local_path> [options]
```

| Option | Description |
|---|---|
| `--key KEY` | S3 object key (default: filename) |
| `--bucket BUCKET` | Bucket name (overrides global `--bucket`) |
| `--content-type TYPE` | Content-Type header (default: `application/octet-stream`) |
| `--skip-existing` | Skip if the object already exists with matching size + MD5 etag |
| `--concurrency N` | Max concurrent threads for transfer |
| `--retries N` | Max retries per part |
| `--cache-control VAL` | Cache-Control header value |

**Examples:**

```bash
# Basic upload (key defaults to filename)
s3sm upload photo.jpg --bucket my-bucket

# Upload with explicit key
s3sm upload photo.jpg --key photos/photo.jpg --bucket my-bucket

# With explicit content type
s3sm upload index.html --key site/index.html --content-type text/html --bucket my-bucket

# Skip if object already exists
s3sm upload data.csv --key reports/data.csv --skip-existing --bucket my-bucket
```

**Output:**

```
⬆  Uploading photo.jpg → photos/photo.jpg in my-bucket
  ✓ Uploaded photos/photo.jpg
```

**Source reference:** [`exe/s3sm:240-286`](../exe/s3sm#L240-L286) (`cmd_upload`, `parse_upload_opts`)

---

### `download` — Download a file

Download an object from S3 to a local file.

```
s3sm download <key> [local_path] [options]
```

| Option | Description |
|---|---|
| `--bucket BUCKET` | Bucket name (overrides global `--bucket`) |
| `--resume` | Resume a previous interrupted download |

**Examples:**

```bash
# Download to current directory (uses the object key as filename)
s3sm download photos/photo.jpg --bucket my-bucket

# Download to a specific path
s3sm download photos/photo.jpg /tmp/photo.jpg --bucket my-bucket

# Resume interrupted download
s3sm download large-video.mp4 /tmp/large-video.mp4 --resume --bucket my-bucket
```

**Output:**

```
⬇  Downloading photos/photo.jpg → .
  ✓ Downloaded to /tmp/photo.jpg
```

**Source reference:** [`exe/s3sm:290-316`](../exe/s3sm#L290-L316) (`cmd_download`, `parse_download_opts`)

---

### `presign` — Generate a presigned URL

Generate a temporary signed URL for an S3 object. No credentials are needed to use the resulting URL.

```
s3sm presign <key> [options]
```

| Option | Description | Default |
|---|---|---|
| `--bucket BUCKET` | Bucket name (overrides global `--bucket`) | — |
| `--expires SECONDS` | URL expiration time in seconds | `3600` (1 hour) |
| `--method METHOD` | HTTP method: `get`, `put`, `delete`, `head` | `get` |

**Examples:**

```bash
# Generate a download URL (expires in 1 hour)
s3sm presign documents/report.pdf --bucket my-bucket

# Generate an upload URL (expires in 10 minutes)
s3sm presign uploads/new-file.txt --method put --expires 600 --bucket my-bucket

# Generate a delete URL
s3sm presign old-file.txt --method delete --expires 300 --bucket my-bucket
```

**Output:**

```
🔗 https://my-bucket.s3.amazonaws.com/documents/report.pdf?X-Amz-Algorithm=...&X-Amz-Signature=...

Expires in 3600 seconds
```

**Source reference:** [`exe/s3sm:320-341`](../exe/s3sm#L320-L341) (`cmd_presign`, `parse_presign_opts`)

---

### `delete` — Delete an object

Delete an object from S3.

```
s3sm delete <key> [options]
```

| Option | Description |
|---|---|
| `--bucket BUCKET` | Bucket name (overrides global `--bucket`) |

**Examples:**

```bash
s3sm delete old-file.txt --bucket my-bucket
s3sm delete logs/2025-01.log --bucket backups
```

**Output:**

```
✗ Deleted old-file.txt
```

**Source reference:** [`exe/s3sm:345-362`](../exe/s3sm#L345-L362) (`cmd_delete`, `parse_delete_opts`)

---

### `list-parts` — List parts of a multipart upload

List the parts uploaded so far for a specific multipart upload.

```
s3sm list-parts <key> --upload-id ID [options]
```

| Option | Description |
|---|---|
| `--upload-id ID` | Upload ID **(required)** |
| `--bucket BUCKET` | Bucket name (overrides global `--bucket`) |
| `--max-parts N` | Max parts to list (default: `100`) |

**Examples:**

```bash
# First, find the upload ID
s3sm list-uploads --bucket my-bucket

# Then list its parts
s3sm list-parts data/large.bin --upload-id "abc-123-def" --bucket my-bucket
```

**Output:**

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

**Source reference:** [`exe/s3sm:488-523`](../exe/s3sm#L488-L523) (`cmd_list_parts`, `parse_list_parts_opts`)

---

### `list-uploads` — List active multipart uploads

List in-progress multipart uploads in a bucket. Useful for finding abandoned uploads to clean up.

```
s3sm list-uploads [options]
```

| Option | Description |
|---|---|
| `--bucket BUCKET` | Bucket name (overrides global `--bucket`) |
| `--prefix PREFIX` | Filter by key prefix |
| `--max-uploads N` | Max uploads to list (default: `100`) |

**Examples:**

```bash
# List all active uploads
s3sm list-uploads --bucket my-bucket

# List uploads under a specific prefix
s3sm list-uploads --prefix videos/ --bucket my-bucket
```

**Output:**

```
Multipart uploads
──────────────────────────────────────────────────────────────────────
Key                  Upload ID                           Initiated
──────────────────────────────────────────────────────────────────────
data/large.bin       abc-123-def                         2026-07-10T09:15:00.000Z
videos/movie.mp4     ghi-456-jkl                         2026-07-10T10:30:00.000Z
```

If there are no active uploads:

```
Multipart uploads
──────────────────────────────────────────────────────────────────────
(none)
```

**Source reference:** [`exe/s3sm:527-561`](../exe/s3sm#L527-L561) (`cmd_list_uploads`, `parse_list_uploads_opts`)

---

### `upload-dir` — Upload a directory

Upload all files in a directory to S3 in parallel. Supports resume from state files.

```
s3sm upload-dir <directory> [options]
```

| Option | Description | Default |
|---|---|---|
| `--bucket BUCKET` | Bucket name (overrides global `--bucket`) | — |
| `--prefix PREFIX` | Key prefix prepended to each uploaded file | `""` |
| `--pattern PAT` | File glob pattern to match | `**/*` |
| `--max-files N` | Max concurrent file uploads | `4` |
| `--no-skip-existing` | Upload even if file already exists with matching size + MD5 etag | *(skip enabled)* |
| `--resume` | Resume interrupted multipart uploads from state files | `true` |
| `--state-dir DIR` | Directory for per-file resume state | `/tmp/s3sm-state` |

**Examples:**

```bash
# Upload entire directory
s3sm upload-dir ./build --bucket my-bucket

# Upload with a key prefix
s3sm upload-dir ./dist --bucket my-bucket --prefix site/

# Upload only .js files
s3sm upload-dir ./dist --bucket my-bucket --pattern "**/*.js" --prefix assets/

# Parallel upload with 8 workers
s3sm upload-dir ./public --bucket my-bucket --max-files 8

# Upload even if files already exist (disable skip-existing)
s3sm upload-dir ./public --bucket my-bucket --no-skip-existing

# Use custom state directory for resume
s3sm upload-dir ./build --bucket my-bucket --resume --state-dir /tmp/my-state
```

**Output:**

Each file is displayed as it starts uploading, with index progress `[n/total]`:

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

If some files fail:

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

Skipped files (when `--skip-existing` is enabled) are also displayed inline with a skip indicator.

**Source reference:** [`exe/s3sm:565-616`](../exe/s3sm#L565-L616) (`cmd_upload_dir`, `parse_upload_dir_opts`)

---

### `download-dir` — Download a directory

Download all objects matching a prefix from S3 to a local directory in parallel.

```
s3sm download-dir <local_directory> [options]
```

| Option | Description | Default |
|---|---|---|
| `--bucket BUCKET` | Bucket name (overrides global `--bucket`) | — |
| `--prefix PREFIX` | Key prefix to filter objects | `""` |
| `--delimiter DELIM` | Delimiter for listing | *(auto)* |
| `--max-files N` | Max concurrent file downloads | `4` |

**Examples:**

```bash
# Download all objects from a bucket to a local directory
s3sm download-dir ./downloads --bucket my-bucket

# Download objects under a specific prefix
s3sm download-dir ./photos --bucket my-bucket --prefix photos/

# Parallel download with 8 workers
s3sm download-dir ./data --bucket my-bucket --prefix data/ --max-files 8
```

**Output:**

```
📂 Downloading from photos/ → ./photos
  ✓ Downloaded 8 files to ./photos
```

If some files fail:

```
📂 Downloading from data/ → ./data
  ✓ Downloaded 5 files to ./data
  ✗ Failed 2 files
    • data/missing.bin: Object not found (404)
    • data/large.bin: Connection timeout
```

**Source reference:** [`exe/s3sm:620-657`](../exe/s3sm#L620-L657) (`cmd_download_dir`, `parse_download_dir_opts`)

---

## Examples

### AWS S3

```bash
# Upload a file to AWS S3
s3sm upload backup.zip --key backups/2026-07/backup.zip \
  --bucket my-backups \
  --region ap-southeast-1 \
  --access-key AKIAIOSFODNN7EXAMPLE \
  --secret-key wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY

# Download it back
s3sm download backups/2026-07/backup.zip /tmp/backup.zip --bucket my-backups

# Generate a presigned download link (valid 2 hours)
s3sm presign backups/2026-07/backup.zip --bucket my-backups --expires 7200
```

### MinIO / Cloudflare R2

When using `--endpoint`, the CLI automatically switches to `S3MultiBucketClient`:

```bash
# Upload to MinIO
s3sm --endpoint https://minio.local:9000 \
  upload photo.jpg --key photos/photo.jpg --bucket my-bucket \
  --access-key minioadmin --secret-key minioadmin

# Upload directory to Cloudflare R2
s3sm --endpoint https://<account-id>.r2.cloudflarestorage.com \
  upload-dir ./site --bucket static-assets --prefix v2/ \
  --access-key ... --secret-key ...

# Download directory from MinIO
s3sm --endpoint https://minio.local:9000 \
  download-dir ./local-backup --bucket my-bucket --prefix backups/ \
  --access-key minioadmin --secret-key minioadmin

# List multipart uploads on MinIO
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

### Workflow: upload then share

```bash
# 1. Upload
s3sm upload contract.pdf --key docs/contract.pdf --bucket shared-files

# 2. Generate a shareable link (expires in 24h)
s3sm presign docs/contract.pdf --bucket shared-files --expires 86400
# → copy the printed URL and share it
```

### Workflow: clean up stale uploads

```bash
# 1. Find active multipart uploads
s3sm list-uploads --bucket my-bucket --prefix temp/

# 2. See which parts were uploaded
s3sm list-parts temp/large.bin --upload-id "abc-123" --bucket my-bucket

# 3. Delete the incomplete object if needed
s3sm delete temp/large.bin --bucket my-bucket
```

---

## How client selection works

The CLI creates one of two client types based on whether `--endpoint` is provided:

| `--endpoint` provided? | Client class | Bucket handling |
|---|---|---|
| No | `S3Client` | Bucket set once via `--bucket` or `AWS_BUCKET` |
| Yes | `S3MultiBucketClient` | Bucket can be overridden per command with `--bucket` |

This is determined in the `build_client` method at [`exe/s3sm:209-236`](../exe/s3sm#L209-L236):

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

For AWS S3 (no custom endpoint), `S3Client` is used — simpler and slightly faster.

For MinIO, R2, B2, or any S3-compatible endpoint, `--endpoint` triggers `S3MultiBucketClient` which supports path-style URLs automatically.

---

## Error handling

The CLI exits with status 1 and prints an error message on failure. S3 errors are parsed from the XML response body and formatted with the S3 error code, message, and bucket name.

### Basic CLI errors

| Message | Cause |
|---|---|
| `Unknown command: <cmd>` | Invalid command name |
| `Error: missing argument: --key` | Required option not provided |
| `Missing required credential: ...` | `access_key_id` or `secret_access_key` not found |
| `Usage: s3sm upload ...` | Required positional argument missing (e.g. no `--key`) |

### S3 error formatting

When an S3 error occurs (e.g. `NoSuchBucket`, `AccessDenied`), the CLI parses the XML response body to extract structured error details (`s3_code`, `s3_message`, `s3_bucket`) and displays a friendly, multi-line message:

```
✗ S3 error (NoSuchBucket)
  Bucket my-bucket does not exist. Create it first or check the bucket name.
```

Known S3 error codes get human-readable messages:

| S3 Code | Message |
|---|---|
| `NoSuchBucket` | Bucket does not exist. Create it first or check the bucket name. |
| `AccessDenied` | Access denied. Check your credentials and bucket permissions. |
| `SignatureDoesNotMatch` | Request signature mismatch. Check your access key and secret key. |
| `InvalidAccessKeyId` | Invalid access key. Verify your AWS_ACCESS_KEY_ID. |
| `ExpiredToken` | Security token has expired. Refresh your credentials. |
| `BucketAlreadyOwnedByYou` | Bucket already exists and is owned by you. |
| `BucketAlreadyExists` | Bucket already exists. Choose a different name. |

### Upload errors

Upload-specific errors (`UploadError`) are caught and displayed without stack traces:

```
✗ Upload failed: 403 Forbidden [AccessDenied: Access Denied]
```

For `upload-dir`, per-file errors are shown inline, and fatal errors (e.g. `QuotaReached`, `AccessDenied`) are logged once and abort remaining uploads.

All errors are printed to stderr. The CLI does not produce stack traces.

**Source reference:** [`exe/s3sm:110-118`](../exe/s3sm#L110-L118), [`exe/s3sm:741-795`](../exe/s3sm#L741-L795) (`format_s3_error_from_exception`, `S3_FRIENDLY_MESSAGES`)

---

## Troubleshooting

### `Missing required credential: access_key_id`

The CLI cannot find credentials. Either pass them explicitly or set environment variables:

```bash
export AWS_ACCESS_KEY_ID=...
export AWS_SECRET_ACCESS_KEY=...
s3sm upload ...
```

### `Unknown command: xyz`

Check available commands:

```bash
s3sm --help
```

### Upload succeeds but download says `404`

The object key might differ from the local filename. Use `list` or check the `upload` output which prints the exact key.

### Presigned URL returns `AccessDenied`

Check that the `--method` matches the intended action (GET for download, PUT for upload), and that `--expires` hasn't made the URL stale.

### `upload-dir` doesn't pick up hidden files

The default glob pattern is `**/*` which excludes dotfiles. Use `--pattern` with a custom pattern:

```bash
s3sm upload-dir ./config --bucket my-bucket --pattern "**/*" --prefix config/
```

> **Note:** For advanced use cases (multipart with state files, event callbacks, SSE encryption, progress callbacks, streaming downloads), use the **Ruby API** directly. See [USAGE_GUIDE.s3_client.md](USAGE_GUIDE.s3_client.md) and [USAGE_GUIDE.s3_multi_bucket_client.md](USAGE_GUIDE.s3_multi_bucket_client.md).
