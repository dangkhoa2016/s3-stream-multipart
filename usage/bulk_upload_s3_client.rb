# frozen_string_literal: true
# S3Client — Bulk directory upload usage examples
#
# Demonstrates the upload_directory API for uploading entire local directories
# to S3 in parallel, with auto-selection of single PUT vs multipart per file.
#
# Features covered:
#   - Basic directory upload (recursive)
#   - Glob pattern filtering (include only specific file types)
#   - Exclude patterns (skip files/directories)
#   - Parallel file uploads (max_files concurrency)
#   - Per-file callbacks: on_file_start, on_file_complete, on_file_error
#   - Custom content-type, metadata, cache-control
#   - Multipart threshold tuning
#   - S3Helper.upload_bulk convenience wrapper
#   - Event callbacks integration with bulk upload
#   - Real-world scenarios: static site deploy, backup, media library
#
# Uncomment blocks to run (requires credentials configured via ENV).

require_relative '../src/s3_client'

# ============================================================
# 0. Client initialization
# ============================================================

client = S3Client.new(
  region:     'ap-southeast-1',
  bucket:     'my-bucket',
  access_key: ENV['S3_ACCESS_KEY_ID'],
  secret_key: ENV['S3_SECRET_ACCESS_KEY'],
  # For MinIO / R2 / Backblaze B2:
  # endpoint:       'https://minio.local:9000',
  # endpoint_style: :path
)

# ============================================================
# 1. Basic directory upload — recursive, all files
# ============================================================
#
# Uploads every file under /path/to/my-website/ to S3 prefix "website/".
# Each file's S3 key is: prefix + relative_path
#   e.g. /path/to/my-website/css/style.css -> website/css/style.css
#
# Per-file auto-selects single PUT (small files) or multipart (large files)
# based on multipart_threshold (default 100 MB).

# result = client.upload_directory(
#   directory: '/path/to/my-website',
#   prefix:    'website/'
# )
#
# puts "Uploaded:   #{result[:uploaded].size} files"
# puts "Failed:     #{result[:failed].size} files"
# puts "Skipped:    #{result[:skipped].size} files"
# puts "Total:      #{result[:total_files]} files (#{result[:total_bytes] / 1024 / 1024} MB)"
# puts "Elapsed:    #{'%.2f' % result[:elapsed]}s"
# puts "Throughput: #{'%.2f' % result[:throughput]} MB/s"

# ============================================================
# 2. Filter by glob pattern — upload only specific file types
# ============================================================
#
# Upload only images (jpg, png, webp) from a media directory.

# result = client.upload_directory(
#   directory: '/path/to/media-library',
#   prefix:    'images/',
#   pattern:   '**/*.{jpg,jpeg,png,webp}'
# )
#
# puts "Uploaded #{result[:uploaded].size} images"
# result[:uploaded].each do |entry|
#   puts "  #{entry[:path]} -> #{entry[:key]} (#{entry[:size] / 1024} KB)"
# end

# ============================================================
# 3. Exclude patterns — skip certain files or directories
# ============================================================
#
# Upload a project directory but skip node_modules, .git, and log files.

# result = client.upload_directory(
#   directory: '/path/to/my-project',
#   prefix:    'backup/my-project/',
#   exclude:   ['**/node_modules/**', '**/.git/**', '**/*.log', '**/tmp/**']
# )
#
# puts "Uploaded: #{result[:uploaded].size}, Skipped: #{result[:skipped].size}"

# ============================================================
# 4. Concurrency control — max_files parallel uploads
# ============================================================
#
# max_files controls how many files are uploaded simultaneously (default: 4).
# Each file itself may use multipart with its own thread pool internally.
#
# For bandwidth-limited connections, lower max_files to avoid congestion.
# For high-bandwidth + many small files, increase max_files.

# result = client.upload_directory(
#   directory:   '/path/to/large-collection',
#   prefix:      'collection/',
#   max_files:   8,                     # 8 files in parallel
#   multipart_threshold: 50 * 1024 * 1024  # multipart for files > 50 MB
# )

# ============================================================
# 5. Per-file callbacks — track progress of each file
# ============================================================
#
# on_file_start:    called before each file begins uploading
# on_file_complete: called after each file finishes successfully
# on_file_error:    called when a file fails to upload
#
# Callback arguments:
#   on_file_start:    (local_path, s3_key, file_index, total_files)
#   on_file_complete: (local_path, s3_key, result_hash, file_index, total_files)
#   on_file_error:    (local_path, s3_key, error, file_index, total_files)

# result = client.upload_directory(
#   directory: '/path/to/assets',
#   prefix:    'assets/',
#
#   on_file_start: proc { |path, key, index, total|
#     puts "  [#{index}/#{total}] Uploading: #{File.basename(path)} -> #{key}"
#   },
#
#   on_file_complete: proc { |path, key, result, index, total|
#     size_kb = (result[:size] || 0) / 1024
#     etag = result[:etag] || 'N/A'
#     puts "  [#{index}/#{total}] Done: #{key} (#{size_kb} KB, etag=#{etag})"
#   },
#
#   on_file_error: proc { |path, key, error, index, total|
#     $stderr.puts "  [#{index}/#{total}] FAILED: #{key} — #{error.class}: #{error.message}"
#   }
# )
#
# if result[:failed].any?
#   $stderr.puts "\nFailed files:"
#   result[:failed].each { |f| $stderr.puts "  #{f[:path]}: #{f[:error]}" }
# end

# ============================================================
# 6. Custom content-type, metadata, and cache-control
# ============================================================
#
# content_type: nil (default) = auto-detect from file extension
#   Auto-detection covers: html, css, js, json, xml, txt, csv, md,
#   png, jpg, gif, svg, webp, ico, mp4, webm, mp3, wav, pdf, zip, etc.
#   Falls back to "application/octet-stream" for unknown extensions.
#
# content_type: "application/octet-stream" = force a specific type for ALL files
#
# metadata: user-defined metadata (x-amz-meta-* headers)
# cache_control: Cache-Control header for all uploaded files

# result = client.upload_directory(
#   directory:     '/path/to/static-site',
#   prefix:        'site/',
#   content_type:  nil,                       # auto-detect per file
#   metadata:      { 'deploy-id' => 'v2.3.1', 'deployed-by' => 'ci-pipeline' },
#   cache_control: 'public, max-age=31536000, immutable'
# )

# ============================================================
# 7. Force a specific content-type for all files
# ============================================================
#
# When uploading a directory of files with non-standard extensions
# but known content type (e.g., all binary data files).

# result = client.upload_directory(
#   directory:    '/path/to/data-files',
#   prefix:       'data/',
#   content_type: 'application/json'   # force JSON for all files
# )

# ============================================================
# 8. Multipart threshold tuning
# ============================================================
#
# multipart_threshold controls when a file switches from single PUT to
# multipart upload. Default is 100 MB.
#
# Lower threshold (e.g. 10 MB):
#   - More files use multipart -> more parallelism within each file
#   - Better for large files on unreliable connections (resume per-part)
#   - Higher overhead for small files
#
# Higher threshold (e.g. 500 MB):
#   - Fewer files use multipart -> simpler upload, less S3 API calls
#   - Better when most files are small-medium

# result = client.upload_directory(
#   directory:           '/path/to/videos',
#   prefix:              'videos/',
#   multipart_threshold: 10 * 1024 * 1024,    # multipart for files > 10 MB
#   max_files:           2                     # fewer parallel files
# )

# ============================================================
# 9. S3Helper.upload_bulk — convenience wrapper
# ============================================================
#
# S3Helper.upload_bulk provides the same API but works with both
# S3Client (single-bucket) and S3MultiBucketClient.
# Useful when writing code that should be client-agnostic.

# result = S3Helper.upload_bulk(
#   client:    client,
#   directory: '/path/to/uploads',
#   prefix:    'bulk/',
#   pattern:   '**/*',
#   exclude:   ['**/.DS_Store'],
#   max_files: 4,
#   on_file_start: proc { |path, key, idx, total|
#     puts "  [#{idx}/#{total}] #{key}"
#   },
#   on_file_complete: proc { |path, key, result, idx, total|
#     puts "  [#{idx}/#{total}] ✓ #{key}"
#   }
# )

# ============================================================
# 10. Event callbacks integration with bulk upload
# ============================================================
#
# S3Client event callbacks (registered via S3Client.on) also fire
# during bulk upload for each file's underlying upload operation.
# This allows centralized monitoring across all files.

# S3Client.on(:upload_start) do |local_path, key, size, total_parts, part_size, resumed|
#   puts "  [EVENT] Starting: #{key} (#{size / 1024 / 1024} MB, #{total_parts} parts)"
# end
#
# S3Client.on(:upload_complete) do |result, elapsed, throughput|
#   puts "  [EVENT] Completed: #{result[:key]} (#{'%.1f' % throughput} MB/s)"
# end
#
# S3Client.on(:upload_failed) do |error, state_path|
#   $stderr.puts "  [EVENT] Failed: #{error.message}"
# end
#
# # Now run the bulk upload — events fire for each file automatically
# result = client.upload_directory(
#   directory: '/path/to/media',
#   prefix:    'media/',
#   max_files: 4
# )

# ============================================================
# 11. Real-world scenario: Static website deployment
# ============================================================
#
# Deploy a built static site (e.g. Next.js export, Hugo, Jekyll) to S3
# for static hosting. HTML gets short cache, assets get long cache.

# build_dir = '/path/to/out'    # Next.js export directory
#
# # Upload HTML files with short cache (frequently updated)
# html_result = client.upload_directory(
#   directory:     build_dir,
#   prefix:        '',
#   pattern:       '**/*.html',
#   cache_control: 'public, max-age=300',           # 5 minutes
#   content_type:  nil,                              # auto-detect
#   metadata:      { 'deploy' => Time.now.utc.iso8601 }
# )
#
# # Upload static assets with long cache (hashed filenames)
# asset_result = client.upload_directory(
#   directory:     build_dir,
#   prefix:        '',
#   pattern:       '**/*.{js,css,png,jpg,jpeg,gif,svg,webp,woff,woff2,ttf,ico}',
#   cache_control: 'public, max-age=31536000, immutable',  # 1 year
#   content_type:  nil
# )
#
# # Upload remaining files (JSON manifests, XML sitemaps, etc.)
# other_result = client.upload_directory(
#   directory:     build_dir,
#   prefix:        '',
#   pattern:       '**/*.{json,xml,txt,map}',
#   cache_control: 'public, max-age=3600'            # 1 hour
# )
#
# total = html_result[:uploaded].size + asset_result[:uploaded].size + other_result[:uploaded].size
# puts "Deployed #{total} files to S3"

# ============================================================
# 12. Real-world scenario: Nightly backup with error reporting
# ============================================================
#
# Back up a data directory nightly, log failures for alerting.

# backup_dir = '/var/data/app'
# date_prefix = "backups/#{Time.now.strftime('%Y/%m/%d')}/"
# failed_files = []
#
# result = client.upload_directory(
#   directory: backup_dir,
#   prefix:    date_prefix,
#   exclude:   ['**/*.tmp', '**/*.lock'],
#   max_files: 2,                                    # gentle on bandwidth
#   multipart_threshold: 20 * 1024 * 1024,
#
#   on_file_error: proc { |path, key, error, index, total|
#     failed_files << { path: path, key: key, error: error.message }
#     $stderr.puts "  BACKUP FAILED: #{key} — #{error.message}"
#   },
#
#   on_file_complete: proc { |path, key, result, index, total|
#     puts "  [#{index}/#{total}] ✓ #{key}"
#   }
# )
#
# puts "\nBackup summary:"
# puts "  Uploaded: #{result[:uploaded].size} files (#{result[:total_bytes] / 1024 / 1024} MB)"
# puts "  Failed:   #{result[:failed].size} files"
# puts "  Elapsed:  #{'%.1f' % result[:elapsed]}s"
#
# if failed_files.any?
#   # Send alert
#   puts "ALERT: #{failed_files.size} files failed backup!"
#   failed_files.each { |f| puts "  #{f[:key]}: #{f[:error]}" }
# end

# ============================================================
# 13. Real-world scenario: Media library with progress bar
# ============================================================
#
# Upload a large media library with a visual progress bar.

# media_dir = '/path/to/media'
# total_files = Dir.glob(File.join(media_dir, '**/*')).count { |f| File.file?(f) }
# completed = 0
# bar_width = 40
#
# result = client.upload_directory(
#   directory: media_dir,
#   prefix:    'media/',
#   max_files: 6,
#   pattern:   '**/*.{mp4,mov,avi,mkv,mp3,wav,flac}',
#
#   on_file_complete: proc { |path, key, res, index, total|
#     completed += 1
#     pct = (completed.to_f / total * 100).round(1)
#     filled = (pct / 100.0 * bar_width).to_i
#     bar = "█" * filled + "░" * (bar_width - filled)
#     $stderr.print "\r  [#{bar}] #{pct}% (#{completed}/#{total}) #{File.basename(path)}"
#     $stderr.puts if completed == total
#   },
#
#   on_file_error: proc { |path, key, error, index, total|
#     $stderr.puts "\n  FAILED: #{key} — #{error.message}"
#   }
# )
#
# puts "\nDone: #{result[:uploaded].size} files, #{'%.1f' % result[:throughput]} MB/s"

# ============================================================
# 14. Result hash structure reference
# ============================================================
#
# upload_directory returns a Hash with this structure:
#
# {
#   uploaded: [
#     { path: "/local/file1.txt", key: "prefix/file1.txt", etag: "...", size: 1024, elapsed: 0.5 },
#     { path: "/local/file2.jpg", key: "prefix/file2.jpg", etag: "...", size: 2048, elapsed: 0.3 },
#     ...
#   ],
#   failed: [
#     { path: "/local/bad.txt", key: "prefix/bad.txt", error: "Upload failed: ..." },
#     ...
#   ],
#   skipped: [],                          # currently unused, reserved for future use
#   total_files: 42,                      # total files found by glob
#   total_bytes: 1073741824,              # sum of uploaded file sizes
#   elapsed: 123.456,                     # wall clock time (seconds)
#   throughput: 8.23                      # MB/s
# }
