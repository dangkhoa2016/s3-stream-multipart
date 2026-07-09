# frozen_string_literal: true
# S3Client — Ví dụ upload hàng loạt thư mục (bulk upload)
#
# Minh họa API upload_directory để tải toàn bộ thư mục local lên S3
# song song, tự động chọn single PUT hoặc multipart cho từng file.
#
# Các tính năng được đề cập:
#   - Upload thư mục cơ bản (đệ quy)
#   - Lọc theo glob pattern (chỉ upload loại file cụ thể)
#   - Exclude patterns (bỏ qua file/thư mục)
#   - Upload song song nhiều file (max_files concurrency)
#   - Callback từng file: on_file_start, on_file_complete, on_file_error
#   - Custom content-type, metadata, cache-control
#   - Tinh chỉnh multipart threshold
#   - S3Helper.upload_bulk — wrapper tiện lợi
#   - Tích hợp event callbacks với bulk upload
#   - Tình huống thực tế: deploy static site, backup, thư viện media
#
# Bỏ comment từng block để chạy thử (cần cấu hình credentials qua ENV).

require_relative '../src/s3_client'

# ============================================================
# 0. Khởi tạo client
# ============================================================

client = S3Client.new(
  region:     'ap-southeast-1',
  bucket:     'my-bucket',
  access_key: ENV['S3_ACCESS_KEY_ID'],
  secret_key: ENV['S3_SECRET_ACCESS_KEY'],
  # Cho MinIO / R2 / Backblaze B2:
  # endpoint:       'https://minio.local:9000',
  # endpoint_style: :path
)

# ============================================================
# 1. Upload thư mục cơ bản — đệ quy, tất cả file
# ============================================================
#
# Upload mọi file trong /path/to/my-website/ lên S3 prefix "website/".
# S3 key của mỗi file = prefix + đường dẫn tương đối
#   VD: /path/to/my-website/css/style.css -> website/css/style.css
#
# Tự động chọn single PUT (file nhỏ) hoặc multipart (file lớn)
# dựa trên multipart_threshold (mặc định 100 MB).

# result = client.upload_directory(
#   directory: '/path/to/my-website',
#   prefix:    'website/'
# )
#
# puts "Đã upload:  #{result[:uploaded].size} file"
# puts "Thất bại:   #{result[:failed].size} file"
# puts "Bỏ qua:     #{result[:skipped].size} file"
# puts "Tổng cộng:  #{result[:total_files]} file (#{result[:total_bytes] / 1024 / 1024} MB)"
# puts "Thời gian:  #{'%.2f' % result[:elapsed]}s"
# puts "Tốc độ:     #{'%.2f' % result[:throughput]} MB/s"

# ============================================================
# 2. Lọc theo glob pattern — chỉ upload loại file cụ thể
# ============================================================
#
# Chỉ upload ảnh (jpg, png, webp) từ thư mục media.

# result = client.upload_directory(
#   directory: '/path/to/media-library',
#   prefix:    'images/',
#   pattern:   '**/*.{jpg,jpeg,png,webp}'
# )
#
# puts "Đã upload #{result[:uploaded].size} ảnh"
# result[:uploaded].each do |entry|
#   puts "  #{entry[:path]} -> #{entry[:key]} (#{entry[:size] / 1024} KB)"
# end

# ============================================================
# 3. Exclude patterns — bỏ qua file hoặc thư mục nhất định
# ============================================================
#
# Upload thư mục project nhưng bỏ qua node_modules, .git, và file log.

# result = client.upload_directory(
#   directory: '/path/to/my-project',
#   prefix:    'backup/my-project/',
#   exclude:   ['**/node_modules/**', '**/.git/**', '**/*.log', '**/tmp/**']
# )
#
# puts "Đã upload: #{result[:uploaded].size}, Bỏ qua: #{result[:skipped].size}"

# ============================================================
# 4. Kiểm soát concurrency — max_files upload song song
# ============================================================
#
# max_files kiểm soát số file được upload đồng thời (mặc định: 4).
# Mỗi file có thể tự dùng multipart với thread pool riêng.
#
# Đường truyền giới hạn bandwidth: giảm max_files để tránh tắc nghẽn.
# Bandwidth cao + nhiều file nhỏ: tăng max_files.

# result = client.upload_directory(
#   directory:   '/path/to/large-collection',
#   prefix:      'collection/',
#   max_files:   8,                     # 8 file song song
#   multipart_threshold: 50 * 1024 * 1024  # multipart cho file > 50 MB
# )

# ============================================================
# 5. Callback từng file — theo dõi tiến trình mỗi file
# ============================================================
#
# on_file_start:    gọi trước khi mỗi file bắt đầu upload
# on_file_complete: gọi sau khi mỗi file hoàn thành thành công
# on_file_error:    gọi khi một file bị lỗi
#
# Tham số callback:
#   on_file_start:    (local_path, s3_key, file_index, total_files)
#   on_file_complete: (local_path, s3_key, result_hash, file_index, total_files)
#   on_file_error:    (local_path, s3_key, error, file_index, total_files)

# result = client.upload_directory(
#   directory: '/path/to/assets',
#   prefix:    'assets/',
#
#   on_file_start: proc { |path, key, index, total|
#     puts "  [#{index}/#{total}] Đang upload: #{File.basename(path)} -> #{key}"
#   },
#
#   on_file_complete: proc { |path, key, result, index, total|
#     size_kb = (result[:size] || 0) / 1024
#     etag = result[:etag] || 'N/A'
#     puts "  [#{index}/#{total}] Xong: #{key} (#{size_kb} KB, etag=#{etag})"
#   },
#
#   on_file_error: proc { |path, key, error, index, total|
#     $stderr.puts "  [#{index}/#{total}] LỖI: #{key} — #{error.class}: #{error.message}"
#   }
# )
#
# if result[:failed].any?
#   $stderr.puts "\nCác file bị lỗi:"
#   result[:failed].each { |f| $stderr.puts "  #{f[:path]}: #{f[:error]}" }
# end

# ============================================================
# 6. Custom content-type, metadata, và cache-control
# ============================================================
#
# content_type: nil (mặc định) = tự động nhận diện từ phần mở rộng file
#   Tự động nhận diện: html, css, js, json, xml, txt, csv, md,
#   png, jpg, gif, svg, webp, ico, mp4, webm, mp3, wav, pdf, zip, v.v.
#   Mặc định "application/octet-stream" cho phần mở rộng không xác định.
#
# content_type: "application/octet-stream" = ép buộc một loại cho TẤT CẢ file
#
# metadata: metadata tùy chỉnh (header x-amz-meta-*)
# cache_control: header Cache-Control cho tất cả file được upload

# result = client.upload_directory(
#   directory:     '/path/to/static-site',
#   prefix:        'site/',
#   content_type:  nil,                       # tự động nhận diện từng file
#   metadata:      { 'deploy-id' => 'v2.3.1', 'deployed-by' => 'ci-pipeline' },
#   cache_control: 'public, max-age=31536000, immutable'
# )

# ============================================================
# 7. Ép buộc content-type cụ thể cho tất cả file
# ============================================================
#
# Khi upload thư mục chứa file có phần mở rộng không chuẩn
# nhưng biết loại nội dung (VD: tất cả là file dữ liệu binary).

# result = client.upload_directory(
#   directory:    '/path/to/data-files',
#   prefix:       'data/',
#   content_type: 'application/json'   # ép tất cả là JSON
# )

# ============================================================
# 8. Tinh chỉnh multipart threshold
# ============================================================
#
# multipart_threshold kiểm soát khi nào file chuyển từ single PUT sang
# multipart upload. Mặc định 100 MB.
#
# Threshold thấp (VD: 10 MB):
#   - Nhiều file dùng multipart -> song song nhiều hơn trong mỗi file
#   - Tốt hơn cho file lớn trên đường truyền không ổn định (resume từng part)
#   - Overhead cao hơn cho file nhỏ
#
# Threshold cao (VD: 500 MB):
#   - Ít file dùng multipart -> upload đơn giản hơn, ít S3 API call hơn
#   - Tốt hơn khi hầu hết file nhỏ-vừa

# result = client.upload_directory(
#   directory:           '/path/to/videos',
#   prefix:              'videos/',
#   multipart_threshold: 10 * 1024 * 1024,    # multipart cho file > 10 MB
#   max_files:           2                     # ít file song song hơn
# )

# ============================================================
# 9. S3Helper.upload_bulk — wrapper tiện lợi
# ============================================================
#
# S3Helper.upload_bulk cung cấp cùng API nhưng hoạt động với cả
# S3Client (single-bucket) và S3MultiBucketClient.
# Hữu ích khi viết code không phụ thuộc loại client.

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
# 10. Tích hợp event callbacks với bulk upload
# ============================================================
#
# Event callbacks của S3Client (đăng ký qua S3Client.on) cũng được kích hoạt
# trong quá trình bulk upload cho mỗi file. Cho phép giám sát tập trung.

# S3Client.on(:upload_start) do |local_path, key, size, total_parts, part_size, resumed|
#   puts "  [EVENT] Bắt đầu: #{key} (#{size / 1024 / 1024} MB, #{total_parts} parts)"
# end
#
# S3Client.on(:upload_complete) do |result, elapsed, throughput|
#   puts "  [EVENT] Hoàn thành: #{result[:key]} (#{'%.1f' % throughput} MB/s)"
# end
#
# S3Client.on(:upload_failed) do |error, state_path|
#   $stderr.puts "  [EVENT] Thất bại: #{error.message}"
# end
#
# # Chạy bulk upload — events tự động kích hoạt cho mỗi file
# result = client.upload_directory(
#   directory: '/path/to/media',
#   prefix:    'media/',
#   max_files: 4
# )

# ============================================================
# 11. Tình huống thực tế: Deploy static website
# ============================================================
#
# Deploy một static site đã build (VD: Next.js export, Hugo, Jekyll) lên S3
# cho static hosting. HTML cache ngắn, assets cache dài.

# build_dir = '/path/to/out'    # Thư mục export của Next.js
#
# # Upload file HTML với cache ngắn (thường xuyên cập nhật)
# html_result = client.upload_directory(
#   directory:     build_dir,
#   prefix:        '',
#   pattern:       '**/*.html',
#   cache_control: 'public, max-age=300',           # 5 phút
#   content_type:  nil,                              # tự động nhận diện
#   metadata:      { 'deploy' => Time.now.utc.iso8601 }
# )
#
# # Upload static assets với cache dài (filename có hash)
# asset_result = client.upload_directory(
#   directory:     build_dir,
#   prefix:        '',
#   pattern:       '**/*.{js,css,png,jpg,jpeg,gif,svg,webp,woff,woff2,ttf,ico}',
#   cache_control: 'public, max-age=31536000, immutable',  # 1 năm
#   content_type:  nil
# )
#
# # Upload các file còn lại (JSON manifests, XML sitemaps, v.v.)
# other_result = client.upload_directory(
#   directory:     build_dir,
#   prefix:        '',
#   pattern:       '**/*.{json,xml,txt,map}',
#   cache_control: 'public, max-age=3600'            # 1 giờ
# )
#
# total = html_result[:uploaded].size + asset_result[:uploaded].size + other_result[:uploaded].size
# puts "Đã deploy #{total} file lên S3"

# ============================================================
# 12. Tình huống thực tế: Backup hàng đêm với báo cáo lỗi
# ============================================================
#
# Backup thư mục dữ liệu hàng đêm, ghi log các file lỗi để cảnh báo.

# backup_dir = '/var/data/app'
# date_prefix = "backups/#{Time.now.strftime('%Y/%m/%d')}/"
# failed_files = []
#
# result = client.upload_directory(
#   directory: backup_dir,
#   prefix:    date_prefix,
#   exclude:   ['**/*.tmp', '**/*.lock'],
#   max_files: 2,                                    # nhẹ nhàng với bandwidth
#   multipart_threshold: 20 * 1024 * 1024,
#
#   on_file_error: proc { |path, key, error, index, total|
#     failed_files << { path: path, key: key, error: error.message }
#     $stderr.puts "  BACKUP LỖI: #{key} — #{error.message}"
#   },
#
#   on_file_complete: proc { |path, key, result, index, total|
#     puts "  [#{index}/#{total}] ✓ #{key}"
#   }
# )
#
# puts "\nTổng kết backup:"
# puts "  Đã upload: #{result[:uploaded].size} file (#{result[:total_bytes] / 1024 / 1024} MB)"
# puts "  Thất bại:  #{result[:failed].size} file"
# puts "  Thời gian: #{'%.1f' % result[:elapsed]}s"
#
# if failed_files.any?
#   puts "CẢNH BÁO: #{failed_files.size} file backup thất bại!"
#   failed_files.each { |f| puts "  #{f[:key]}: #{f[:error]}" }
# end

# ============================================================
# 13. Tình huống thực tế: Thư viện media với thanh tiến trình
# ============================================================
#
# Upload thư viện media lớn với thanh tiến trình trực quan.

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
#     $stderr.puts "\n  LỖI: #{key} — #{error.message}"
#   }
# )
#
# puts "\nXong: #{result[:uploaded].size} file, #{'%.1f' % result[:throughput]} MB/s"

# ============================================================
# 14. Cấu trúc result hash (tham khảo)
# ============================================================
#
# upload_directory trả về Hash với cấu trúc:
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
#   skipped: [],                          # hiện chưa dùng, dành cho tương lai
#   total_files: 42,                      # tổng số file tìm được bởi glob
#   total_bytes: 1073741824,              # tổng kích thước file đã upload
#   elapsed: 123.456,                     # thời gian thực (giây)
#   throughput: 8.23                      # MB/s
# }
