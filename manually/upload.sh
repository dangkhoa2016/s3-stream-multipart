#!/bin/bash
set -euo pipefail

# ============================================================
# S3 Upload Launcher
# ============================================================
#
# A convenience wrapper that validates configuration, then
# delegates to one of the Ruby upload scripts:
#   - upload_with_s3_client.rb           (S3Client — auto PUT/multipart)
#   - upload_with_s3_multi_bucket_client.rb (S3MultiBucketClient — explicit multipart)
#
# Usage:
#   ./upload.sh                    # default: streaming client
#   ./upload.sh s3_client          # use S3Client
#   ./upload.sh streaming          # use S3MultiBucketClient
#
# BEFORE RUNNING:
#   1. For AWS S3 — set AWS credentials with S3 write permissions
#   2. For MinIO  — start MinIO, create a bucket, set credentials
#
# Example MinIO setup:
#   docker run -p 9000:9000 -p 9001:9001 \
#     minio/minio server /data --console-address ":9001"
#   # Console: http://localhost:9001  (minioadmin / minioadmin)
#
# ============================================================

# --- ANSI color helpers ---
RED='\033[31m'
GREEN='\033[32m'
YELLOW='\033[33m'
CYAN='\033[36m'
BOLD='\033[1m'
DIM='\033[2m'
RESET='\033[0m'

info()  { echo -e "${CYAN}▸${RESET} $*"; }
ok()    { echo -e "${GREEN}✓${RESET} $*"; }
warn()  { echo -e "${YELLOW}⚠${RESET} $*"; }
error() { echo -e "${RED}✗${RESET} $*" >&2; }

# ============================================================
# 1. CHOOSE WHICH RUBY SCRIPT TO RUN
# ============================================================
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CLIENT="${1:-streaming}"

case "$CLIENT" in
  s3_client|client|s3)
    RUBY_SCRIPT="$SCRIPT_DIR/upload_with_s3_client.rb"
    CLIENT_LABEL="S3Client"
    ;;
  streaming|s3_streaming|streaming_client)
    RUBY_SCRIPT="$SCRIPT_DIR/upload_with_s3_multi_bucket_client.rb"
    CLIENT_LABEL="S3MultiBucketClient"
    ;;
  *)
    error "Unknown client: $CLIENT"
    echo "Usage: $0 [s3_client | streaming]"
    exit 1
    ;;
esac

if [ ! -f "$RUBY_SCRIPT" ]; then
  error "Ruby script not found: $RUBY_SCRIPT"
  exit 1
fi

# ============================================================
# 2. CONFIGURATION (override via environment variables)
# ============================================================
export S3_ACCESS_KEY_ID="${S3_ACCESS_KEY_ID:-}"
export S3_SECRET_ACCESS_KEY="${S3_SECRET_ACCESS_KEY:-}"
export S3_BUCKET="${S3_BUCKET:-}"
export S3_REGION="${S3_REGION:-us-east-1}"
export S3_ENDPOINT="${S3_ENDPOINT:-}"
export S3_SESSION_TOKEN="${S3_SESSION_TOKEN:-}"
export S3_DEBUG="${S3_DEBUG:-true}"

# --- For MinIO (uncomment and update if using MinIO) ---
# export S3_ACCESS_KEY_ID=minioadmin
# export S3_SECRET_ACCESS_KEY=minioadmin
# export S3_BUCKET=test-bucket
# export S3_REGION=us-east-1
# export S3_ENDPOINT=http://localhost:9000

# --- File to upload ---
DEFAULT_FILE="$SCRIPT_DIR/../sample-files/breathtaking-8k-video-ultra-hd-8k-hdr-60fps-dolby-vision.mp4"
export LOCAL_FILE_PATH="${LOCAL_FILE_PATH:-$DEFAULT_FILE}"
export S3_OBJECT_KEY="${S3_OBJECT_KEY:-$(basename "$LOCAL_FILE_PATH")}"

# ============================================================
# 3. VALIDATE CONFIGURATION
# ============================================================
echo ""
echo -e "${BOLD}╔══════════════════════════════════════════╗${RESET}"
echo -e "${BOLD}║  S3 Upload — Configuration Check         ║${RESET}"
echo -e "${BOLD}╚══════════════════════════════════════════╝${RESET}"
echo ""

ERRORS=0

# Validate credentials
if [ -z "$S3_ACCESS_KEY_ID" ]; then
  error "S3_ACCESS_KEY_ID is not set"
  ERRORS=$((ERRORS + 1))
fi
if [ -z "$S3_SECRET_ACCESS_KEY" ]; then
  error "S3_SECRET_ACCESS_KEY is not set"
  ERRORS=$((ERRORS + 1))
fi

# Validate bucket
if [ -z "$S3_BUCKET" ]; then
  error "S3_BUCKET is not set"
  ERRORS=$((ERRORS + 1))
fi

# S3MultiBucketClient requires an explicit endpoint
if [ "$CLIENT_LABEL" = "S3MultiBucketClient" ] && [ -z "$S3_ENDPOINT" ]; then
  error "S3_ENDPOINT is required for S3MultiBucketClient"
  ERRORS=$((ERRORS + 1))
fi

# Validate file
if [ ! -f "$LOCAL_FILE_PATH" ]; then
  error "File not found: $LOCAL_FILE_PATH"
  ERRORS=$((ERRORS + 1))
fi

if [ "$ERRORS" -gt 0 ]; then
  echo ""
  error "$ERRORS configuration error(s) found."
  echo ""
  echo "  For AWS S3:"
  echo "    export S3_ACCESS_KEY_ID=your-access-key"
  echo "    export S3_SECRET_ACCESS_KEY=your-secret-key"
  echo "    export S3_BUCKET=your-bucket"
  echo ""
  echo "  For MinIO (local testing):"
  echo "    export S3_ACCESS_KEY_ID=minioadmin"
  echo "    export S3_SECRET_ACCESS_KEY=minioadmin"
  echo "    export S3_BUCKET=test-bucket"
  echo "    export S3_ENDPOINT=http://localhost:9000"
  echo ""
  exit 1
fi

# ============================================================
# 4. PRINT SUMMARY
# ============================================================
FILE_SIZE=$(du -h "$LOCAL_FILE_PATH" | cut -f1)

info "Client:     ${BOLD}${CLIENT_LABEL}${RESET}"
info "Endpoint:   ${S3_ENDPOINT:-AWS S3 default}"
info "Region:     ${S3_REGION}"
info "Bucket:     ${S3_BUCKET}"
info "Key:        ${S3_OBJECT_KEY}"
info "Local file: ${LOCAL_FILE_PATH}"
info "File size:  ${FILE_SIZE}"
info "Debug:      ${S3_DEBUG}"
[ -n "$S3_SESSION_TOKEN" ] && info "Session:    ${DIM}(temporary credentials)${RESET}"
echo ""
ok "Configuration valid — starting upload..."
echo ""

# ============================================================
# 5. RUN THE UPLOAD
# ============================================================
ruby "$RUBY_SCRIPT"
EXIT_CODE=$?

if [ "$EXIT_CODE" -eq 0 ]; then
  echo ""
  ok "Upload finished successfully (exit code 0)"
else
  echo ""
  error "Upload exited with code $EXIT_CODE"
fi

exit "$EXIT_CODE"
