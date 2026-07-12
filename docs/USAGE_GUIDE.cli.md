# s3sm CLI - Detailed Usage Guide

> 🌐 Language / Ngôn ngữ: **English** | [Tiếng Việt](USAGE_GUIDE.cli.vi.md)

`s3sm` is a command-line tool for interacting with S3-compatible storage, included in the `s3-stream-multipart` gem. It supports uploading, downloading, presigned URL generation, object deletion, multipart upload management, and directory uploads — all without the `aws-sdk-s3` gem.

**Source code:** [`exe/s3sm`](../exe/s3sm)

---

## Table of contents

- [Installation](#installation)
- [Global options](#global-options)
- [Environment variables](#environment-variables)
- [Commands](#commands)
  - [upload](#upload---upload-a-file)
  - [download](#download---download-a-file)
  - [presign](#presign---generate-a-presigned-url)
  - [delete](#delete---delete-an-object)
  - [list-parts](#list-parts---list-parts-of-a-multipart-upload)
  - [list-uploads](#list-uploads---list-active-multipart-uploads)
  - [upload-dir](#upload-dir---upload-a-directory)
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

### `upload` — Upload a file

Upload a local file to S3. Uses a streaming single PUT (no multipart — use the Ruby API for multipart with state files).

```
s3sm upload <local_path> --key KEY [options]
```

| Option | Description |
|---|---|
| `--key KEY` | S3 object key **(required)** |
| `--bucket BUCKET` | Bucket name (overrides global `--bucket`) |
| `--content-type TYPE` | Content-Type header (default: `application/octet-stream`) |
| `--skip-existing` | Skip if the object already exists in the bucket |
| `--concurrency N` | Max concurrent threads for transfer |
| `--retries N` | Max retries per part |
| `--cache-control VAL` | Cache-Control header value |

**Examples:**

```bash
# Basic upload
s3sm upload photo.jpg --key photos/photo.jpg --bucket my-bucket

# With explicit content type
s3sm upload index.html --key site/index.html --content-type text/html --bucket my-bucket

# Skip if object already exists
s3sm upload data.csv --key reports/data.csv --skip-existing --bucket my-bucket
```

**Output:**

```
Uploaded: photos/photo.jpg
```

**Source reference:** [`exe/s3sm:75-106`](../exe/s3sm#L75-L106) (`cmd_upload`, `parse_upload_opts`)

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
Downloaded to: /tmp/photo.jpg
```

**Source reference:** [`exe/s3sm:108-131`](../exe/s3sm#L108-L131) (`cmd_download`, `parse_download_opts`)

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
https://my-bucket.s3.amazonaws.com/documents/report.pdf?X-Amz-Algorithm=...&X-Amz-Signature=...
```

**Source reference:** [`exe/s3sm:133-152`](../exe/s3sm#L133-L152) (`cmd_presign`, `parse_presign_opts`)

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
Deleted: old-file.txt
```

**Source reference:** [`exe/s3sm:154-171`](../exe/s3sm#L154-L171) (`cmd_delete`, `parse_delete_opts`)

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
Parts for data/large.bin (upload: abc-123-def):
  Part 1: ETag="e1b2c3d4..." Size=10485760
  Part 2: ETag="f5a6b7c8..." Size=10485760
  Part 3: ETag="d9e0f1a2..." Size=5242880
```

**Source reference:** [`exe/s3sm:173-193`](../exe/s3sm#L173-L193) (`cmd_list_parts`, `parse_list_parts_opts`)

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
Multipart uploads:
  data/large.bin — abc-123-def — 2026-07-10T09:15:00.000Z
  videos/movie.mp4 — ghi-456-jkl — 2026-07-10T10:30:00.000Z
```

If there are no active uploads:

```
Multipart uploads:
  (none)
```

**Source reference:** [`exe/s3sm:195-218`](../exe/s3sm#L195-L218) (`cmd_list_uploads`, `parse_list_uploads_opts`)

---

### `upload-dir` — Upload a directory

Upload all files in a directory to S3 in parallel.

```
s3sm upload-dir <directory> [options]
```

| Option | Description | Default |
|---|---|---|
| `--bucket BUCKET` | Bucket name (overrides global `--bucket`) | — |
| `--prefix PREFIX` | Key prefix prepended to each uploaded file | `""` |
| `--pattern PAT` | File glob pattern to match | `**/*` |
| `--max-files N` | Max concurrent file uploads | `4` |
| `--skip-existing` | Skip objects that already exist | `false` |

**Examples:**

```bash
# Upload entire directory
s3sm upload-dir ./build --bucket my-bucket

# Upload with a key prefix
s3sm upload-dir ./dist --bucket my-bucket --prefix site/

# Upload only .js files
s3sm upload-dir ./dist --bucket my-bucket --pattern "**/*.js" --prefix assets/

# Parallel upload with 8 workers, skip existing
s3sm upload-dir ./public --bucket my-bucket --max-files 8 --skip-existing
```

**Output:**

```
Uploaded 12 files from ./build
```

**Source reference:** [`exe/s3sm:220-242`](../exe/s3sm#L220-L242) (`cmd_upload_dir`, `parse_upload_dir_opts`)

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

This is determined in the `build_client` method at [`exe/s3sm:55-73`](../exe/s3sm#L55-L73):

```ruby
if endpoint
  S3MultiBucketClient.new(region:, bucket:, endpoint:, access_key_id:, secret_access_key:)
else
  S3Client.new(region:, bucket:, access_key_id:, secret_access_key:)
end
```

For AWS S3 (no custom endpoint), `S3Client` is used — simpler and slightly faster.

For MinIO, R2, B2, or any S3-compatible endpoint, `--endpoint` triggers `S3MultiBucketClient` which supports path-style URLs automatically.

---

## Error handling

The CLI exits with status 1 and prints an error message on failure:

| Message | Cause |
|---|---|
| `Unknown command: <cmd>` | Invalid command name |
| `Error: missing argument: --key` | Required option not provided |
| `Missing required credential: ...` | `access_key_id` or `secret_access_key` not found |
| `Usage: s3sm upload ...` | Required positional argument missing (e.g. no `--key`) |

All errors are printed to stderr. The CLI does not produce stack traces.

**Source reference:** [`exe/s3sm:18-21`](../exe/s3sm#L18-L21)

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

The object key might differ from the local filename. Use `list-uploads` or check the `upload` output which prints the exact key.

### Presigned URL returns `AccessDenied`

Check that the `--method` matches the intended action (GET for download, PUT for upload), and that `--expires` hasn't made the URL stale.

### `upload-dir` doesn't pick up hidden files

The default glob pattern is `**/*` which excludes dotfiles. Use `--pattern` with a custom pattern:

```bash
s3sm upload-dir ./config --bucket my-bucket --pattern "**/*" --prefix config/
```

> **Note:** For advanced use cases (multipart with state files, event callbacks, SSE encryption, progress callbacks, streaming downloads), use the **Ruby API** directly. See [USAGE_GUIDE.s3_client.md](USAGE_GUIDE.s3_client.md) and [USAGE_GUIDE.s3_multi_bucket_client.md](USAGE_GUIDE.s3_multi_bucket_client.md).
