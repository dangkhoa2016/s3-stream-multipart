# Folder Upload — Usage Guide

> 🌐 Language / Ngôn ngữ: **English** | [Tiếng Việt](folder-upload-USAGE.vi.md)

The `folder-upload.sh` script is a command-line tool to upload **entire directories** to S3 (or S3-compatible storage such as MinIO, Cloudflare R2, Backblaze B2) in parallel.

Each file in the local directory maps to an S3 object key using:

```
S3 key = prefix + relative path
```

Example: uploading `./dist` with prefix `website/` maps `./dist/css/style.css` to key `website/css/style.css`.

The script automatically selects **single PUT** (small files) or **multipart upload** (large files) based on the `--multipart-threshold` (default 100 MB).

---

## Table of Contents

- [Requirements](#requirements)
- [Setting up credentials](#setting-up-credentials)
- [Basic usage](#basic-usage)
- [All options](#all-options)
- [Environment variables](#environment-variables)
- [Configuration priority](#configuration-priority)
- [Choosing the client type](#choosing-the-client-type)
- [Scenario examples](#scenario-examples)
  - [1. Deploy static website to AWS S3](#1-deploy-static-website-to-aws-s3)
  - [2. Upload to local MinIO](#2-upload-to-local-minio)
  - [3. Upload only images, skip node_modules and .git](#3-upload-only-images-skip-node_modules-and-git)
  - [4. Backup data directory](#4-backup-data-directory)
  - [5. Deploy with different cache-control per file type](#5-deploy-with-different-cache-control-per-file-type)
  - [6. Upload large files with low multipart threshold](#6-upload-large-files-with-low-multipart-threshold)
  - [7. Skip existing files / Overwrite on S3](#7-skip-existing-files--overwrite-on-s3)
  - [8. Upload with STS temporary credentials](#8-upload-with-sts-temporary-credentials)
- [Sample output](#sample-output)
- [Performance tuning](#performance-tuning)
- [Error handling](#error-handling)
- [Comparison: upload.sh vs folder-upload.sh](#comparison-uploadsh-vs-folder-uploadsh)

---

## Requirements

- **Bash** 4.0+
- **Ruby** >= 2.7.8+ (s3-stream-multipart gem uses `Data.define`)
- Credentials with write access to the target bucket

Check Ruby:

```bash
ruby --version          # >= 2.7.8
```

---

## Setting up credentials

Before running, set the environment variables:

```bash
# AWS S3
export S3_ACCESS_KEY_ID="AKIAIOSFODNN7EXAMPLE"
export S3_SECRET_ACCESS_KEY="wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY"

# MinIO (local testing)
export S3_ACCESS_KEY_ID="minioadmin"
export S3_SECRET_ACCESS_KEY="minioadmin"
```

---

## Basic usage

```bash
# Minimal: only directory and bucket required
./folder-upload.sh -d ./my-folder -b my-bucket

# With prefix
./folder-upload.sh -d ./dist -b my-website -p "v2/"

# Using environment variables exclusively
export LOCAL_FOLDER_PATH="./dist"
export S3_BUCKET="my-bucket"
export S3_ACCESS_KEY_ID="AKIA..."
export S3_SECRET_ACCESS_KEY="..."
./folder-upload.sh
```

View help:

```bash
./folder-upload.sh --help
```

---

## All options

| Option | Short | Description | Default |
|--------|-------|-------------|---------|
| `--directory DIR` | `-d` | Local directory to upload | Env `LOCAL_FOLDER_PATH` |
| `--bucket BUCKET` | `-b` | S3 bucket name | Env `S3_BUCKET` |
| `--prefix PREFIX` | `-p` | S3 key prefix | `""` (empty) |
| `--region REGION` | `-r` | AWS region | `us-east-1` |
| `--endpoint URL` | `-e` | Custom S3 endpoint | AWS default |
| `--client TYPE` | `-c` | Client type: `s3_client` or `multi_bucket` | `s3_client` |
| `--max-files N` | `-j` | Number of concurrent file uploads | `4` |
| `--multipart-threshold N` | `-t` | Byte threshold to switch to multipart | `104857600` (100 MB) |
| `--pattern GLOB` | | Glob pattern to filter files | `**/*` (all) |
| `--exclude PATTERN` | | Glob pattern to exclude (repeatable) | None |
| `--cache-control VALUE` | | Cache-Control header for all files | None |
| `--content-type VALUE` | | Force Content-Type for all files | Auto-detect |
| `--skip-existing` | | Skip files already on S3 (compares size + etag). Env: `S3_SKIP_EXISTING=true` | `false` (overwrite) |
| `--overwrite` | | Force overwrite existing S3 files (overrides `S3_SKIP_EXISTING`) | Default |
| `--debug` | | Enable verbose debug logging | `false` |
| `--state-dir DIR` | | Directory for resume state files | Env `S3_STATE_DIR` |
| `--help` | `-h` | Show help | |

---

## Environment variables

| Variable | Description | Required |
|----------|-------------|----------|
| `S3_ACCESS_KEY_ID` | Access key ID | Yes |
| `S3_SECRET_ACCESS_KEY` | Secret access key | Yes |
| `S3_BUCKET` | Bucket name (if not using `-b`) | If `-b` is missing |
| `S3_REGION` | Region (if not using `-r`) | No |
| `S3_ENDPOINT` | Endpoint URL (if not using `-e`) | No |
| `S3_SESSION_TOKEN` | STS session token | No |
| `LOCAL_FOLDER_PATH` | Directory to upload (if not using `-d`) | If `-d` is missing |
| `S3_STATE_DIR` | Directory for resume state files (if not using `--state-dir`) | No |
| `S3_SKIP_EXISTING` | Skip existing files: `true`/`false` (if not using `--skip-existing`/`--overwrite`) | No |

---

## Configuration priority

```
CLI argument > Environment variable > Default value
```

Example: `-b my-bucket` overrides `S3_BUCKET=other-bucket`.

---

## Choosing the client type

The script supports 2 client types suitable for different storage backends:

### S3Client (`-c s3_client`) — Default

- Suitable for **AWS S3** and S3-compatible storage.
- Automatically builds the endpoint from region + bucket (virtual-hosted style).
- Falls back to path-style when a custom endpoint (`-e`) is provided.

```bash
# AWS S3
./folder-upload.sh -d ./dist -b my-bucket

# MinIO with S3Client
./folder-upload.sh -d ./dist -b my-bucket -e http://localhost:9000
```

### S3MultiBucketClient (`-c multi_bucket`)

- Suitable when uploading to **multiple different buckets** with the same client.
- **Requires** `--endpoint` or `S3_ENDPOINT`.
- Uses path-style endpoint.

```bash
./folder-upload.sh -d ./dist -b my-bucket \
  -e https://s3.ap-southeast-1.amazonaws.com \
  -c multi_bucket -r ap-southeast-1
```

### When to use which?

| Scenario | Recommended |
|----------|-------------|
| Regular AWS S3 | `s3_client` (default) |
| MinIO, R2, Backblaze B2 | `s3_client` + `-e` |
| Upload same data to multiple buckets | `multi_bucket` |
| Custom S3-compatible service | Try `s3_client` first; switch to `multi_bucket` on error |

---

## Scenario examples

### 1. Deploy static website to AWS S3

Upload a build directory (Next.js export, Hugo, Jekyll...) with appropriate cache-control:

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

Result: each file in `./out` is uploaded with its corresponding S3 key.

### 2. Upload to local MinIO

Start MinIO:

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

### 3. Upload only images, skip node_modules and .git

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

> `--exclude` is repeatable — each flag adds one pattern.

### 4. Backup data directory

```bash
./folder-upload.sh \
  -d /var/data/app \
  -b backup-bucket \
  -p "backups/$(date +%Y/%m/%d)/" \
  --exclude '**/*.tmp' \
  --exclude '**/*.lock' \
  --max-files 2
```

Use a low `--max-files` to reduce bandwidth pressure.

### 5. Deploy with different cache-control per file type

The script applies `--cache-control` to **all** files. For per-type caching, run multiple passes with `--pattern`:

```bash
# HTML — short cache (5 minutes)
./folder-upload.sh -d ./dist -b my-bucket \
  --pattern '**/*.html' \
  --cache-control 'public, max-age=300'

# Static assets — long cache (1 year)
./folder-upload.sh -d ./dist -b my-bucket \
  --pattern '**/*.{js,css,png,jpg,svg,woff2}' \
  --cache-control 'public, max-age=31536000, immutable'

# Remaining files — medium cache (1 hour)
./folder-upload.sh -d ./dist -b my-bucket \
  --pattern '**/*.{json,xml,txt,map}' \
  --cache-control 'public, max-age=3600'
```

### 6. Upload large files with low multipart threshold

The default multipart threshold is 100 MB. For directories with many large video files, lower the threshold to benefit from parallel part uploads:

```bash
./folder-upload.sh \
  -d ./videos \
  -b media-bucket \
  -p "uploads/" \
  --multipart-threshold $((10 * 1024 * 1024)) \
  --max-files 2
```

Files > 10 MB will use multipart upload (split into parts + parallel part upload).

### 7. Skip existing files / Overwrite on S3

The script supports 2 modes for files already on S3:

**Default: overwrite** — re-uploads all files, no S3 check.

**Skip existing** — checks S3 first; if **same size and etag**, skip:

```bash
# Using CLI flag
./folder-upload.sh -d ./large-dataset -b data-bucket -p "dataset/" --skip-existing

# Or using environment variable
export S3_SKIP_EXISTING=true
./folder-upload.sh -d ./large-dataset -b data-bucket -p "dataset/"
```

**Override: force overwrite when env var is set to skip:**

```bash
export S3_SKIP_EXISTING=true

# This time, overwrite everything → use --overwrite
./folder-upload.sh -d ./dist -b my-bucket --overwrite
```

Priority order:

```
--skip-existing / --overwrite (CLI) > S3_SKIP_EXISTING (env) > default (overwrite)
```

| Scenario | Result |
|----------|--------|
| No flag, no env | Overwrite (default) |
| `--skip-existing` | Skip matching files |
| `--overwrite` | Overwrite (force) |
| `S3_SKIP_EXISTING=true` | Skip matching files |
| `S3_SKIP_EXISTING=true` + `--overwrite` | Overwrite (CLI wins) |
| `S3_SKIP_EXISTING=false` + `--skip-existing` | Skip matching files (CLI wins) |

Useful when re-uploading after interruption — only uploads files not yet on S3.

### 8. Upload with STS temporary credentials

```bash
export S3_ACCESS_KEY_ID="ASIA..."
export S3_SECRET_ACCESS_KEY="..."
export S3_SESSION_TOKEN="IQoJb3JpZ2lu..."

./folder-upload.sh -d ./data -b my-bucket -p "temp/"
```

The script auto-detects `S3_SESSION_TOKEN` and passes it to the client.

---

## Sample output

A successful run produces output like:

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

## Performance tuning

### max-files (`-j`)

Controls the number of **concurrent** file uploads. Each file may internally use multipart with its own thread pool.

| Scenario | Suggested `--max-files` |
|----------|------------------------|
| Low bandwidth (< 50 Mbps) | `2` |
| Medium bandwidth | `4` (default) |
| High bandwidth + many small files | `8` — `16` |
| Very large files (> 1 GB each) | `2` — `4` |

### multipart-threshold (`-t`)

Byte threshold determining whether a file uses single PUT or multipart upload.

| Threshold | When to use |
|-----------|-------------|
| `104857600` (100 MB) — default | Suitable for most cases |
| `10485760` (10 MB) | Unstable connection, needs per-part retry |
| `524288000` (500 MB) | Mostly small-to-medium files, reduces S3 API call overhead |

### Automatic content-type detection

When `--content-type` is omitted, the script auto-detects MIME type from file extension:

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
| Unknown | `application/octet-stream` |

---

## Error handling

### Common errors

| Error message | Cause | Resolution |
|---------------|-------|------------|
| `S3_ACCESS_KEY_ID is not set` | Missing credentials | `export S3_ACCESS_KEY_ID=...` |
| `Bucket not specified` | Missing bucket | Use `-b bucket-name` or `export S3_BUCKET=...` |
| `Directory not specified (use -d or set LOCAL_FOLDER_PATH)` | No directory specified | Use `-d /path` or `export LOCAL_FOLDER_PATH=./dist` |
| `Directory not found: /path` | Directory does not exist | Verify `-d` path or `LOCAL_FOLDER_PATH` |
| `S3_ENDPOINT is required for S3MultiBucketClient` | `-c multi_bucket` without endpoint | Add `-e https://...` |
| Exit code `1` with "Failed files" list | Some uploads failed | Check logs, retry with `--skip-existing` |

### Debug mode

Add `--debug` to see detailed HTTP request/response logging:

```bash
./folder-upload.sh -d ./test -b my-bucket --debug
```

### Automatic retry

The script inherits the retry mechanism from the Ruby S3 client:

- **Transient errors** (timeout, connection reset): automatic retry with exponential backoff.
- **S3 5xx errors**: automatic retry.
- **Multipart**: if a single part fails, only that part is retried — no need to re-upload from scratch.

---

## Comparison: upload.sh vs folder-upload.sh

| Feature | `upload.sh` | `folder-upload.sh` |
|---------|------------|---------------------|
| Upload | **1 file** (single) | **Entire directory** (many files) |
| CLI args | None (uses ENV) | Yes (CLI args + ENV) |
| Ruby script | Runs separate `.rb` file | Inline Ruby |
| Pattern/exclude | No | Yes (`--pattern`, `--exclude`) |
| Cache-control | In Ruby script | `--cache-control` |
| Skip/Overwrite | No | `--skip-existing`, `--overwrite`, env `S3_SKIP_EXISTING` |
| Progress | Detailed in Ruby | Per-file summary |
| Use case | Upload 1 large file (video, archive) | Deploy website, backup directory |
