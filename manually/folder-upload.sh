#!/bin/bash
set -euo pipefail

# ============================================================
# S3 Folder Upload Launcher
# ============================================================
#
# Uploads an entire local directory to S3 in parallel.
# Each file's S3 key = prefix + relative path.
# Auto-selects single PUT or multipart per file.
#
# Usage:
#   ./folder-upload.sh [options]
#
# Options:
#   -d, --directory DIR        Local directory to upload (or env LOCAL_FOLDER_PATH)
#   -b, --bucket BUCKET        S3 bucket (or env S3_BUCKET)
#   -p, --prefix PREFIX        S3 key prefix (default: "")
#   -r, --region REGION        AWS region (default: us-east-1)
#   -e, --endpoint URL         Custom S3 endpoint (MinIO/R2/B2)
#   -c, --client TYPE          s3_client or multi_bucket (default: s3_client)
#   -j, --max-files N          Parallel file uploads (default: 4)
#   -t, --multipart-threshold  Byte threshold for multipart (default: 100MB)
#   --pattern GLOB             Glob pattern (default: "**/*")
#   --exclude PATTERN          Exclude glob (repeatable)
#   --cache-control VALUE      Cache-Control header for all files
#   --content-type VALUE       Force content-type for all files
#   --skip-existing            Skip files that already match on S3 (or env S3_SKIP_EXISTING=true)
#   --overwrite                Force re-upload, overwrite existing files (default)
#   --state-dir DIR            Directory for per-file resume state (large files only, or env S3_STATE_DIR)
#   --debug                    Enable debug logging
#   -h, --help                 Show this help
#
# Environment variables:
#   S3_ACCESS_KEY_ID           Access key (required)
#   S3_SECRET_ACCESS_KEY       Secret key (required)
#   S3_BUCKET                  Bucket (if not passed via -b)
#   S3_REGION                  Region (if not passed via -r)
#   S3_ENDPOINT                Endpoint (if not passed via -e)
#   S3_SESSION_TOKEN           STS session token (optional)
#   LOCAL_FOLDER_PATH          Directory to upload (if not passed via -d)
#   S3_SKIP_EXISTING           Skip existing files: true/false (if not passed via --skip-existing)
#   S3_STATE_DIR               Directory for per-file resume state (if not passed via --state-dir)
#
# Examples:
#   # Upload a static site to AWS S3
#   export S3_ACCESS_KEY_ID=AKIA...
#   export S3_SECRET_ACCESS_KEY=...
#   ./folder-upload.sh -d ./dist -b my-website -p "v2/" \
#     --cache-control "public, max-age=31536000"
#
#   # Upload to MinIO
#   ./folder-upload.sh -d ./assets -b test-bucket \
#     -e http://localhost:9000 -c multi_bucket \
#     --skip-existing --max-files 8
#
#   # Upload only images, skip node_modules
#   ./folder-upload.sh -d ./project -b my-bucket -p "backup/" \
#     --pattern '**/*.{jpg,png,webp}' \
#     --exclude '**/node_modules/**' --exclude '**/.git/**'
#
# ============================================================

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

RUBY_SCRIPT_FILE="$(mktemp)"
trap 'rm -f "$RUBY_SCRIPT_FILE"' EXIT

# --- ANSI colors ---
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
# Parse arguments
# ============================================================
DIRECTORY=""
BUCKET=""
PREFIX=""
REGION=""
ENDPOINT=""
CLIENT_TYPE="s3_client"
MAX_FILES="4"
MULTIPART_THRESHOLD=$((100 * 1024 * 1024))
PATTERN="**/*"
EXCLUDES=()
CACHE_CONTROL=""
CONTENT_TYPE=""
SKIP_EXISTING=""
STATE_DIR=""
DEBUG_MODE="false"

show_help() {
  sed -n '5,/^$/{ s/^# //; s/^#//; p }' "$0"
  exit 0
}

while [ $# -gt 0 ]; do
  case "$1" in
    -d|--directory)          DIRECTORY="$2"; shift 2 ;;
    -b|--bucket)             BUCKET="$2"; shift 2 ;;
    -p|--prefix)             PREFIX="$2"; shift 2 ;;
    -r|--region)             REGION="$2"; shift 2 ;;
    -e|--endpoint)           ENDPOINT="$2"; shift 2 ;;
    -c|--client)             CLIENT_TYPE="$2"; shift 2 ;;
    -j|--max-files)          MAX_FILES="$2"; shift 2 ;;
    -t|--multipart-threshold) MULTIPART_THRESHOLD="$2"; shift 2 ;;
    --pattern)               PATTERN="$2"; shift 2 ;;
    --exclude)               EXCLUDES+=("$2"); shift 2 ;;
    --cache-control)         CACHE_CONTROL="$2"; shift 2 ;;
    --content-type)          CONTENT_TYPE="$2"; shift 2 ;;
    --skip-existing)         SKIP_EXISTING="true"; shift ;;
    --overwrite)             SKIP_EXISTING="false"; shift ;;
    --state-dir)             STATE_DIR="$2"; shift 2 ;;
    --debug)                 DEBUG_MODE="true"; shift ;;
    -h|--help)               show_help ;;
    *)                       error "Unknown option: $1"; echo "Run with --help for usage."; exit 1 ;;
  esac
done

# ============================================================
# Resolve configuration (CLI args > ENV > defaults)
# ============================================================
DIRECTORY="${DIRECTORY:-${LOCAL_FOLDER_PATH:-}}"
BUCKET="${BUCKET:-${S3_BUCKET:-}}"
REGION="${REGION:-${S3_REGION:-us-east-1}}"
ENDPOINT="${ENDPOINT:-${S3_ENDPOINT:-}}"
ACCESS_KEY="${S3_ACCESS_KEY_ID:-}"
SECRET_KEY="${S3_SECRET_ACCESS_KEY:-}"
SESSION_TOKEN="${S3_SESSION_TOKEN:-}"

# --skip-existing / --overwrite: CLI flag > env var > default (false = overwrite)
if [ -z "$SKIP_EXISTING" ]; then
  SKIP_EXISTING="${S3_SKIP_EXISTING:-false}"
fi
STATE_DIR="${STATE_DIR:-${S3_STATE_DIR:-}}"

# ============================================================
# Validate
# ============================================================
echo ""
echo -e "${BOLD}╔══════════════════════════════════════════╗${RESET}"
echo -e "${BOLD}║  S3 Folder Upload — Configuration        ║${RESET}"
echo -e "${BOLD}╚══════════════════════════════════════════╝${RESET}"
echo ""

ERRORS=0

if [ -z "$ACCESS_KEY" ]; then
  error "S3_ACCESS_KEY_ID is not set"
  ERRORS=$((ERRORS + 1))
fi
if [ -z "$SECRET_KEY" ]; then
  error "S3_SECRET_ACCESS_KEY is not set"
  ERRORS=$((ERRORS + 1))
fi
if [ -z "$BUCKET" ]; then
  error "Bucket not specified (use -b or set S3_BUCKET)"
  ERRORS=$((ERRORS + 1))
fi
if [ -z "$DIRECTORY" ]; then
  error "Directory not specified (use -d or set LOCAL_FOLDER_PATH)"
  ERRORS=$((ERRORS + 1))
elif [ ! -d "$DIRECTORY" ]; then
  error "Directory not found: $DIRECTORY"
  ERRORS=$((ERRORS + 1))
fi

# Resolve client type
case "$CLIENT_TYPE" in
  s3_client|client|s3)
    CLIENT_TYPE="s3_client"
    CLIENT_LABEL="S3Client"
    ;;
  multi_bucket|multi|streaming|s3_multi_bucket_client)
    CLIENT_TYPE="multi_bucket"
    CLIENT_LABEL="S3MultiBucketClient"
    ;;
  *)
    error "Unknown client type: $CLIENT_TYPE (use s3_client or multi_bucket)"
    ERRORS=$((ERRORS + 1))
    ;;
esac

# Multi-bucket client requires endpoint
if [ "$CLIENT_TYPE" = "multi_bucket" ] && [ -z "$ENDPOINT" ]; then
  error "S3_ENDPOINT is required for S3MultiBucketClient (use -e or set S3_ENDPOINT)"
  ERRORS=$((ERRORS + 1))
fi

if [ "$ERRORS" -gt 0 ]; then
  echo ""
  error "$ERRORS configuration error(s) found."
  echo ""
  echo "  Set credentials:"
  echo "    export S3_ACCESS_KEY_ID=your-access-key"
  echo "    export S3_SECRET_ACCESS_KEY=your-secret-key"
  echo ""
  echo "  Basic usage:"
  echo "    $0 -d /path/to/folder -b my-bucket -p \"prefix/\""
  echo ""
  echo "  Or use environment variables:"
  echo "    export LOCAL_FOLDER_PATH=./dist"
  echo "    export S3_BUCKET=my-bucket"
  echo "    $0"
  echo ""
  echo "  For MinIO:"
  echo "    $0 -d ./assets -b test-bucket -e http://localhost:9000 -c multi_bucket"
  echo ""
  echo "  Run with --help for all options."
  exit 1
fi

# ============================================================
# Print summary
# ============================================================
DIRECTORY="$(cd "$DIRECTORY" && pwd)"
FILE_COUNT=$(find "$DIRECTORY" -type f | wc -l)
DIR_SIZE=$(du -sh "$DIRECTORY" 2>/dev/null | cut -f1)

info "Client:     ${BOLD}${CLIENT_LABEL}${RESET}"
info "Endpoint:   ${ENDPOINT:-AWS S3 default}"
info "Region:     ${REGION}"
info "Bucket:     ${BUCKET}"
info "Prefix:     ${PREFIX:-${DIM}(none)${RESET}}"
info "Directory:  ${DIRECTORY}"
info "Files:      ${FILE_COUNT} files (${DIR_SIZE})"
info "Pattern:    ${PATTERN}"
if [ ${#EXCLUDES[@]} -gt 0 ]; then
  info "Exclude:    ${EXCLUDES[*]}"
fi
info "Parallel:   ${MAX_FILES} files"
info "Multipart:  threshold $(( MULTIPART_THRESHOLD / 1024 / 1024 )) MB"
[ -n "$CACHE_CONTROL" ]  && info "Cache:      ${CACHE_CONTROL}"
[ -n "$CONTENT_TYPE" ]   && info "Content:    ${CONTENT_TYPE}"
[ "$SKIP_EXISTING" = "true" ] && info "Skip:       existing files"
[ -n "$STATE_DIR" ] && info "State dir:  ${STATE_DIR}"
[ -n "$SESSION_TOKEN" ]  && info "Session:    ${DIM}(temporary credentials)${RESET}"
echo ""
ok "Configuration valid — starting folder upload..."
echo ""

# ============================================================
# Build and run inline Ruby script
# ============================================================

# Build Ruby exclude array literal
RUBY_EXCLUDES="[]"
if [ ${#EXCLUDES[@]} -gt 0 ]; then
  RUBY_EXCLUDES="["
  for i in "${!EXCLUDES[@]}"; do
    [ "$i" -gt 0 ] && RUBY_EXCLUDES+=", "
    RUBY_EXCLUDES+="'${EXCLUDES[$i]}'"
  done
  RUBY_EXCLUDES+="]"
fi

# Build optional Ruby params
RUBY_CACHE_CONTROL=""
[ -n "$CACHE_CONTROL" ] && RUBY_CACHE_CONTROL="cache_control: '${CACHE_CONTROL}',"

RUBY_CONTENT_TYPE=""
[ -n "$CONTENT_TYPE" ] && RUBY_CONTENT_TYPE="content_type: '${CONTENT_TYPE}',"

RUBY_SKIP_EXISTING=""
[ "$SKIP_EXISTING" = "true" ] && RUBY_SKIP_EXISTING="skip_existing: true,"

RUBY_STATE_DIR=""
[ -n "$STATE_DIR" ] && RUBY_STATE_DIR="state_dir: '${STATE_DIR}',"

# Choose require path and build client code
if [ "$CLIENT_TYPE" = "s3_client" ]; then
  RUBY_REQUIRE="require_relative '${PROJECT_DIR}/src/s3_client'"
  RUBY_CLIENT_INIT="client = S3Client.new(
  region:     '${REGION}',
  bucket:     '${BUCKET}',
  access_key_id: ENV['S3_ACCESS_KEY_ID'],
  secret_access_key: ENV['S3_SECRET_ACCESS_KEY'],
  session_token: ENV['S3_SESSION_TOKEN']&.then { |v| v.empty? ? nil : v },
  endpoint:   ENV['S3_ENDPOINT']&.then { |v| v.empty? ? nil : v },
  max_concurrency: ${MAX_FILES},
  debug:      ${DEBUG_MODE},
  log_color:  true
)"
  RUBY_UPLOAD_CALL="result = client.upload_directory(
  directory: '${DIRECTORY}',
  prefix:    '${PREFIX}',
  pattern:   '${PATTERN}',
  exclude:   ${RUBY_EXCLUDES},
  max_files: ${MAX_FILES},
  multipart_threshold: ${MULTIPART_THRESHOLD},
  ${RUBY_CACHE_CONTROL}
  ${RUBY_CONTENT_TYPE}
  ${RUBY_SKIP_EXISTING}
  ${RUBY_STATE_DIR}
  on_file_start: proc { |path, key, index, total|
    \$stderr.puts \"  [#{index}/#{total}] Uploading: #{File.basename(path)} -> #{key}\"
  },
  on_file_complete: proc { |path, key, res, index, total|
    size = res[:size] || 0
    etag = res[:etag] || 'N/A'
    \$stderr.puts \"  [#{index}/#{total}] Done: #{key} (#{size / 1024} KB, etag=#{etag})\"
  },
  on_file_error: proc { |path, key, error, index, total|
    \$stderr.puts \"  [#{index}/#{total}] FAILED: #{key} -- #{error.class}: #{error.message}\"
  }
)"
else
  RUBY_REQUIRE="require_relative '${PROJECT_DIR}/src/s3_multi_bucket_client'"
  RUBY_CLIENT_INIT="client = S3MultiBucketClient.new(
  endpoint:          ENV['S3_ENDPOINT'],
  region:            '${REGION}',
  access_key_id:     ENV['S3_ACCESS_KEY_ID'],
  secret_access_key: ENV['S3_SECRET_ACCESS_KEY'],
  session_token:     ENV['S3_SESSION_TOKEN']&.then { |v| v.empty? ? nil : v },
  debug:             ${DEBUG_MODE},
  log_color:         true
)"
  RUBY_UPLOAD_CALL="result = client.upload_directory(
  bucket:    '${BUCKET}',
  directory: '${DIRECTORY}',
  prefix:    '${PREFIX}',
  pattern:   '${PATTERN}',
  exclude:   ${RUBY_EXCLUDES},
  max_files: ${MAX_FILES},
  multipart_threshold: ${MULTIPART_THRESHOLD},
  ${RUBY_CACHE_CONTROL}
  ${RUBY_CONTENT_TYPE}
  ${RUBY_SKIP_EXISTING}
  ${RUBY_STATE_DIR}
  on_file_start: proc { |path, key, index, total|
    \$stderr.puts \"  [#{index}/#{total}] Uploading: #{File.basename(path)} -> #{key}\"
  },
  on_file_complete: proc { |path, key, res, index, total|
    size = res[:size] || 0
    etag = res[:etag] || 'N/A'
    \$stderr.puts \"  [#{index}/#{total}] Done: #{key} (#{size / 1024} KB, etag=#{etag})\"
  },
  on_file_error: proc { |path, key, error, index, total|
    \$stderr.puts \"  [#{index}/#{total}] FAILED: #{key} -- #{error.class}: #{error.message}\"
  }
)"
fi

# Write Ruby script to temp file (heredoc avoids bash quoting issues with Ruby interpolation)
cat > "$RUBY_SCRIPT_FILE" <<RUBY_SCRIPT
${RUBY_REQUIRE}

${RUBY_CLIENT_INIT}

puts 'Starting folder upload...'
t0 = Time.now

${RUBY_UPLOAD_CALL}

elapsed = Time.now - t0

puts ''
puts '=' * 60
puts 'Upload Summary'
puts '=' * 60
puts "  Uploaded:   #{result[:uploaded].size} files"
puts "  Failed:     #{result[:failed].size} files"
puts "  Skipped:    #{result[:skipped].size} files"
puts "  Total:      #{result[:total_files]} files (#{result[:total_bytes] / 1024 / 1024} MB)"
puts "  Elapsed:    #{'%.2f' % result[:elapsed]}s"
puts "  Throughput: #{'%.2f' % result[:throughput]} MB/s"

if result[:failed].any?
  puts ''
  puts 'Failed files:'
  result[:failed].each { |f| puts "  #{f[:path]}: #{f[:error]}" }
end

exit(result[:failed].any? ? 1 : 0)
RUBY_SCRIPT

# Run the Ruby script
ruby "$RUBY_SCRIPT_FILE"

EXIT_CODE=$?

if [ "$EXIT_CODE" -eq 0 ]; then
  echo ""
  ok "Folder upload finished successfully (exit code 0)"
else
  echo ""
  error "Folder upload exited with code $EXIT_CODE"
fi

exit "$EXIT_CODE"
