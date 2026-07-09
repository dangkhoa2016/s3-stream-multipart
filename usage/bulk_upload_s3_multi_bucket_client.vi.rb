# frozen_string_literal: true
# S3MultiBucketClient — Ví dụ upload hàng loạt thư mục (bulk upload)
#
# Minh họa API upload_directory để tải toàn bộ thư mục local lên nhiều
# S3 bucket khác nhau song song, tự động chọn single PUT hoặc multipart
# cho từng file.
#
# Khác với S3Client (single-bucket), S3MultiBucketClient nhận tham số `bucket:`,
# cho phép cùng một client instance upload lên nhiều bucket khác nhau.
#
# Các tính năng được đề cập:
#   - Upload thư mục cơ bản vào bucket cụ thể
#   - Upload đa bucket (cùng thư mục -> nhiều bucket)
#   - Lọc theo glob pattern và exclude patterns
#   - Callback từng file và theo dõi tiến trình
#   - S3Helper.upload_bulk — wrapper tiện lợi
#   - Tình huống thực tế
#
# Bỏ comment từng block để chạy thử (cần cấu hình credentials qua ENV).

require_relative '../src/s3_multi_bucket_client'

# ============================================================
# 0. Khởi tạo client
# ============================================================

client = S3MultiBucketClient.new(
  endpoint:          ENV['S3_ENDPOINT'] || 'https://s3.ap-southeast-1.amazonaws.com',
  region:            'ap-southeast-1',
  access_key_id:     ENV['S3_ACCESS_KEY_ID'],
  secret_access_key: ENV['S3_SECRET_ACCESS_KEY']
)

# ============================================================
# 1. Upload thư mục cơ bản vào bucket cụ thể
# ============================================================
#
# Upload mọi file trong /path/to/my-website/ vào bucket "web-assets"
# với prefix "site/".
#   VD: /path/to/my-website/css/style.css -> site/css/style.css

# result = client.upload_directory(
#   bucket:    'web-assets',
#   directory: '/path/to/my-website',
#   prefix:    'site/'
# )
#
# puts "Đã upload:  #{result[:uploaded].size} file"
# puts "Thất bại:   #{result[:failed].size} file"
# puts "Tổng cộng:  #{result[:total_files]} file (#{result[:total_bytes] / 1024 / 1024} MB)"
# puts "Thời gian:  #{'%.2f' % result[:elapsed]}s"
# puts "Tốc độ:     #{'%.2f' % result[:throughput]} MB/s"

# ============================================================
# 2. Upload đa bucket — cùng thư mục vào nhiều bucket khác nhau
# ============================================================
#
# Lợi thế chính của S3MultiBucketClient: một client, nhiều bucket.
# Upload cùng assets vào nhiều bucket theo vùng để phân phối địa lý.

# buckets = ['assets-us-east', 'assets-eu-west', 'assets-ap-southeast']
#
# buckets.each do |bucket|
#   puts "\nĐang upload vào #{bucket}..."
#   result = client.upload_directory(
#     bucket:    bucket,
#     directory: '/path/to/shared-assets',
#     prefix:    'assets/',
#     max_files: 4,
#     on_file_complete: proc { |path, key, res, idx, total|
#       puts "  [#{idx}/#{total}] ✓ #{bucket}:#{key}"
#     }
#   )
#   puts "  Xong: #{result[:uploaded].size} file, #{'%.1f' % result[:throughput]} MB/s"
# end

# ============================================================
# 3. Lọc theo glob pattern — chỉ upload loại file cụ thể
# ============================================================

# result = client.upload_directory(
#   bucket:    'media-bucket',
#   directory: '/path/to/media-library',
#   prefix:    'images/',
#   pattern:   '**/*.{jpg,jpeg,png,webp,gif,svg}'
# )
#
# puts "Đã upload #{result[:uploaded].size} ảnh vào media-bucket"

# ============================================================
# 4. Exclude patterns — bỏ qua file hoặc thư mục nhất định
# ============================================================

# result = client.upload_directory(
#   bucket:    'backup-bucket',
#   directory: '/path/to/my-project',
#   prefix:    'backup/project/',
#   exclude:   ['**/node_modules/**', '**/.git/**', '**/*.log', '**/tmp/**']
# )

# ============================================================
# 5. Callback từng file — theo dõi tiến trình
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
# 6. Custom content-type, metadata, và cache-control
# ============================================================

# result = client.upload_directory(
#   bucket:        'cdn-bucket',
#   directory:     '/path/to/static-site',
#   prefix:        'v2/',
#   content_type:  nil,                                     # tự động nhận diện từng file
#   metadata:      { 'version' => '2.3.1', 'env' => 'production' },
#   cache_control: 'public, max-age=31536000, immutable'
# )

# ============================================================
# 7. Tinh chỉnh concurrency và multipart threshold
# ============================================================

# result = client.upload_directory(
#   bucket:              'large-files-bucket',
#   directory:           '/path/to/videos',
#   prefix:              'videos/',
#   max_files:           2,                              # 2 file song song
#   multipart_threshold: 10 * 1024 * 1024                # multipart cho file > 10 MB
# )

# ============================================================
# 8. S3Helper.upload_bulk — wrapper tiện lợi không phụ thuộc client
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
# 9. Tích hợp event callbacks
# ============================================================
#
# Event callbacks của S3MultiBucketClient được kích hoạt trong quá trình
# bulk upload cho mỗi file.

# S3MultiBucketClient.on(:upload_complete) do |result, elapsed, throughput|
#   puts "  [EVENT] Hoàn thành: #{result[:key]} (#{'%.1f' % throughput} MB/s)"
# end
#
# S3MultiBucketClient.on(:upload_failed) do |error, state_path|
#   $stderr.puts "  [EVENT] Thất bại: #{error.message}"
# end
#
# result = client.upload_directory(
#   bucket:    'event-test-bucket',
#   directory: '/path/to/test-files',
#   prefix:    'test/'
# )

# ============================================================
# 10. Tình huống thực tế: Deploy đa vùng
# ============================================================
#
# Deploy static assets vào nhiều bucket theo vùng cho CDN origin.

# build_dir = '/path/to/dist'
# regions = {
#   'us-east-1'      => 'cdn-origin-us',
#   'eu-west-1'      => 'cdn-origin-eu',
#   'ap-southeast-1' => 'cdn-origin-ap'
# }
#
# regions.each do |region, bucket|
#   puts "\nĐang deploy vào #{bucket} (#{region})..."
#
#   # File HTML — cache ngắn
#   client.upload_directory(
#     bucket: bucket, directory: build_dir, prefix: '',
#     pattern: '**/*.html',
#     cache_control: 'public, max-age=300'
#   )
#
#   # Static assets — cache dài
#   result = client.upload_directory(
#     bucket: bucket, directory: build_dir, prefix: '',
#     pattern: '**/*.{js,css,png,jpg,svg,woff2}',
#     cache_control: 'public, max-age=31536000, immutable'
#   )
#
#   puts "  Đã deploy #{result[:uploaded].size} file vào #{bucket}"
# end

# ============================================================
# 11. Tình huống thực tế: Backup hàng đêm đa bucket
# ============================================================

# backup_sources = {
#   '/var/data/app1' => { bucket: 'backup-prod', prefix: "app1/#{Time.now.strftime('%Y/%m/%d')}/" },
#   '/var/data/app2' => { bucket: 'backup-prod', prefix: "app2/#{Time.now.strftime('%Y/%m/%d')}/" },
#   '/var/logs'      => { bucket: 'backup-logs', prefix: "logs/#{Time.now.strftime('%Y/%m/%d')}/" }
# }
#
# backup_sources.each do |dir, config|
#   puts "Đang backup #{dir} -> #{config[:bucket]}:#{config[:prefix]}"
#   result = client.upload_directory(
#     bucket:    config[:bucket],
#     directory: dir,
#     prefix:    config[:prefix],
#     exclude:   ['**/*.tmp', '**/*.lock'],
#     max_files: 2,
#     on_file_error: proc { |path, key, error, idx, total|
#       $stderr.puts "  BACKUP LỖI: #{key} — #{error.message}"
#     }
#   )
#   puts "  #{result[:uploaded].size} file (#{result[:total_bytes] / 1024 / 1024} MB)"
# end

# ============================================================
# 12. Cấu trúc result hash (tham khảo)
# ============================================================
#
# upload_directory trả về Hash với cấu trúc:
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
