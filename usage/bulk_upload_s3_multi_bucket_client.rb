# frozen_string_literal: true
# S3MultiBucketClient — Bulk directory upload usage examples
#
# Demonstrates the upload_directory API for uploading entire local directories
# to multiple S3 buckets in parallel, with auto-selection of single PUT vs
# multipart per file.
#
# Unlike S3Client (single-bucket), S3MultiBucketClient accepts a `bucket:`
# parameter, allowing the same client instance to upload to different buckets.
#
# Features covered:
#   - Basic directory upload to a specific bucket
#   - Multi-bucket upload (same directory -> different buckets)
#   - Glob pattern filtering and exclude patterns
#   - Per-file callbacks and progress tracking
#   - S3Helper.upload_bulk convenience wrapper
#   - Real-world scenarios
#
# Uncomment blocks to run (requires credentials configured via ENV).

require_relative '../src/s3_multi_bucket_client'

# ============================================================
# 0. Client initialization
# ============================================================

client = S3MultiBucketClient.new(
  endpoint:          ENV['S3_ENDPOINT'] || 'https://s3.ap-southeast-1.amazonaws.com',
  region:            'ap-southeast-1',
  access_key_id:     ENV['S3_ACCESS_KEY_ID'],
  secret_access_key: ENV['S3_SECRET_ACCESS_KEY']
)

# ============================================================
# 1. Basic directory upload to a specific bucket
# ============================================================
#
# Upload every file under /path/to/my-website/ to bucket "web-assets"
# with prefix "site/".
#   e.g. /path/to/my-website/css/style.css -> site/css/style.css

# result = client.upload_directory(
#   bucket:    'web-assets',
#   directory: '/path/to/my-website',
#   prefix:    'site/'
# )
#
# puts "Uploaded:   #{result[:uploaded].size} files"
# puts "Failed:     #{result[:failed].size} files"
# puts "Total:      #{result[:total_files]} files (#{result[:total_bytes] / 1024 / 1024} MB)"
# puts "Elapsed:    #{'%.2f' % result[:elapsed]}s"
# puts "Throughput: #{'%.2f' % result[:throughput]} MB/s"

# ============================================================
# 2. Multi-bucket upload — same directory to different buckets
# ============================================================
#
# The key advantage of S3MultiBucketClient: one client, multiple buckets.
# Upload the same assets to multiple regional buckets for geo-distribution.

# buckets = ['assets-us-east', 'assets-eu-west', 'assets-ap-southeast']
#
# buckets.each do |bucket|
#   puts "\nUploading to #{bucket}..."
#   result = client.upload_directory(
#     bucket:    bucket,
#     directory: '/path/to/shared-assets',
#     prefix:    'assets/',
#     max_files: 4,
#     on_file_complete: proc { |path, key, res, idx, total|
#       puts "  [#{idx}/#{total}] ✓ #{bucket}:#{key}"
#     }
#   )
#   puts "  Done: #{result[:uploaded].size} files, #{'%.1f' % result[:throughput]} MB/s"
# end

# ============================================================
# 3. Filter by glob pattern — upload only specific file types
# ============================================================

# result = client.upload_directory(
#   bucket:    'media-bucket',
#   directory: '/path/to/media-library',
#   prefix:    'images/',
#   pattern:   '**/*.{jpg,jpeg,png,webp,gif,svg}'
# )
#
# puts "Uploaded #{result[:uploaded].size} images to media-bucket"

# ============================================================
# 4. Exclude patterns — skip certain files or directories
# ============================================================

# result = client.upload_directory(
#   bucket:    'backup-bucket',
#   directory: '/path/to/my-project',
#   prefix:    'backup/project/',
#   exclude:   ['**/node_modules/**', '**/.git/**', '**/*.log', '**/tmp/**']
# )

# ============================================================
# 5. Per-file callbacks — track progress
# ============================================================

# result = client.upload_directory(
#   bucket:    'deploy-bucket',
#   directory: '/path/to/build',
#   prefix:    'deploy/',
#
#   on_file_start: proc { |path, key, index, total|
#     puts "  [#{index}/#{total}] -> #{key}"
#   },
#
#   on_file_complete: proc { |path, key, result, index, total|
#     size_kb = (result[:size] || 0) / 1024
#     puts "  [#{index}/#{total}] ✓ #{key} (#{size_kb} KB)"
#   },
#
#   on_file_error: proc { |path, key, error, index, total|
#     $stderr.puts "  [#{index}/#{total}] ✗ #{key} — #{error.message}"
#   }
# )

# ============================================================
# 6. Custom content-type, metadata, and cache-control
# ============================================================

# result = client.upload_directory(
#   bucket:        'cdn-bucket',
#   directory:     '/path/to/static-site',
#   prefix:        'v2/',
#   content_type:  nil,                                     # auto-detect per file
#   metadata:      { 'version' => '2.3.1', 'env' => 'production' },
#   cache_control: 'public, max-age=31536000, immutable'
# )

# ============================================================
# 7. Concurrency and multipart threshold tuning
# ============================================================

# result = client.upload_directory(
#   bucket:              'large-files-bucket',
#   directory:           '/path/to/videos',
#   prefix:              'videos/',
#   max_files:           2,                              # 2 files in parallel
#   multipart_threshold: 10 * 1024 * 1024                # multipart for files > 10 MB
# )

# ============================================================
# 8. S3Helper.upload_bulk — client-agnostic convenience wrapper
# ============================================================

# result = S3Helper.upload_bulk(
#   client:    client,
#   bucket:    'my-bucket',
#   directory: '/path/to/uploads',
#   prefix:    'bulk/',
#   pattern:   '**/*',
#   exclude:   ['**/.DS_Store', '**/*.tmp'],
#   max_files: 4,
#   on_file_complete: proc { |path, key, res, idx, total|
#     puts "  [#{idx}/#{total}] ✓ #{key}"
#   }
# )

# ============================================================
# 9. Event callbacks integration
# ============================================================
#
# S3MultiBucketClient event callbacks fire during bulk upload
# for each file's underlying upload operation.

# S3MultiBucketClient.on(:upload_complete) do |result, elapsed, throughput|
#   puts "  [EVENT] Completed: #{result[:key]} (#{'%.1f' % throughput} MB/s)"
# end
#
# S3MultiBucketClient.on(:upload_failed) do |error, state_path|
#   $stderr.puts "  [EVENT] Failed: #{error.message}"
# end
#
# result = client.upload_directory(
#   bucket:    'event-test-bucket',
#   directory: '/path/to/test-files',
#   prefix:    'test/'
# )

# ============================================================
# 10. Real-world scenario: Multi-region deployment
# ============================================================
#
# Deploy static assets to multiple regional buckets for CDN origin.

# build_dir = '/path/to/dist'
# regions = {
#   'us-east-1'      => 'cdn-origin-us',
#   'eu-west-1'      => 'cdn-origin-eu',
#   'ap-southeast-1' => 'cdn-origin-ap'
# }
#
# regions.each do |region, bucket|
#   puts "\nDeploying to #{bucket} (#{region})..."
#
#   # HTML files — short cache
#   client.upload_directory(
#     bucket: bucket, directory: build_dir, prefix: '',
#     pattern: '**/*.html',
#     cache_control: 'public, max-age=300'
#   )
#
#   # Static assets — long cache
#   result = client.upload_directory(
#     bucket: bucket, directory: build_dir, prefix: '',
#     pattern: '**/*.{js,css,png,jpg,svg,woff2}',
#     cache_control: 'public, max-age=31536000, immutable'
#   )
#
#   puts "  Deployed #{result[:uploaded].size} files to #{bucket}"
# end

# ============================================================
# 11. Real-world scenario: Nightly multi-bucket backup
# ============================================================

# backup_sources = {
#   '/var/data/app1' => { bucket: 'backup-prod', prefix: "app1/#{Time.now.strftime('%Y/%m/%d')}/" },
#   '/var/data/app2' => { bucket: 'backup-prod', prefix: "app2/#{Time.now.strftime('%Y/%m/%d')}/" },
#   '/var/logs'      => { bucket: 'backup-logs', prefix: "logs/#{Time.now.strftime('%Y/%m/%d')}/" }
# }
#
# backup_sources.each do |dir, config|
#   puts "Backing up #{dir} -> #{config[:bucket]}:#{config[:prefix]}"
#   result = client.upload_directory(
#     bucket:    config[:bucket],
#     directory: dir,
#     prefix:    config[:prefix],
#     exclude:   ['**/*.tmp', '**/*.lock'],
#     max_files: 2,
#     on_file_error: proc { |path, key, error, idx, total|
#       $stderr.puts "  BACKUP FAILED: #{key} — #{error.message}"
#     }
#   )
#   puts "  #{result[:uploaded].size} files (#{result[:total_bytes] / 1024 / 1024} MB)"
# end

# ============================================================
# 12. Result hash structure reference
# ============================================================
#
# upload_directory returns a Hash with this structure:
#
# {
#   uploaded: [
#     { path: "/local/file1.txt", key: "prefix/file1.txt", etag: "...", size: 1024, elapsed: 0.5 },
#     ...
#   ],
#   failed: [
#     { path: "/local/bad.txt", key: "prefix/bad.txt", error: "Upload failed: ..." },
#     ...
#   ],
#   skipped: [],
#   total_files: 42,
#   total_bytes: 1073741824,
#   elapsed: 123.456,
#   throughput: 8.23                      # MB/s
# }
