# frozen_string_literal: true
# Ví dụ sử dụng S3MultiBucketClient (thư viện s3_multi_bucket_client.rb)
#
# File này minh họa toàn bộ API public của S3MultiBucketClient, bao gồm:
#   - Các thao tác cơ bản: upload/download/delete/head/presign
#   - Resumable multipart upload qua state_file + UploadState object
#   - Parallel download (multi-thread Range requests, resumable)
#   - SSE encryption (SSE-S3, SSE-KMS, SSE-C)
#   - Retry tuỳ chỉnh (max_retries, retry_delay, 429, jitter)
#   - Event callbacks (14+ sự kiện) để hook custom log / progress / alert
#   - Thread-safe logging từ worker threads
#   - Debug state file sau crash
#
# Mỗi section đều có comment giải thích; bạn có thể bỏ comment từng block
# để chạy thử (cần cấu hình credentials qua ENV).

require_relative '../src/s3_multi_bucket_client'

# ============================================================
# 0. Khởi tạo client
# ============================================================

# AWS S3:
client = S3MultiBucketClient.new(
  endpoint:          'https://s3.ap-southeast-1.amazonaws.com',
  region:            'ap-southeast-1',
  access_key_id:     ENV['S3_ACCESS_KEY_ID'],
  secret_access_key: ENV['S3_SECRET_ACCESS_KEY'],
  # logger:            Logger.new($stdout, level: Logger::INFO)
  # compute_md5:       false,                 # bật true nếu cần hash MD5 file (chậm cho file lớn)
  # max_retries:       3,                     # số lần retry (mặc định 3)
  # retry_delay:       0.25,                  # base delay cho backoff (mặc định 0.25s)
  # sse:               nil,                   # xem ví dụ SSE bên dưới
)

# MinIO / Cloudflare R2 / Backblaze B2:
# client = S3MultiBucketClient.new(
#   endpoint:          'https://minio.local:9000',
#   region:            'us-east-1',
#   access_key_id:     'minioadmin',
#   secret_access_key: 'minioadmin',
# )

# AWS STS (dùng temporary credentials):
# client = S3MultiBucketClient.new(
#   endpoint:          'https://s3.amazonaws.com',
#   region:            'us-east-1',
#   access_key_id:     ENV['S3_ACCESS_KEY_ID'],
#   secret_access_key: ENV['S3_SECRET_ACCESS_KEY'],
#   session_token:     ENV['AWS_SESSION_TOKEN'],
# )

# ============================================================
# 0a. SSE encryption — mã hóa phía máy chủ (Server-Side Encryption)
# ============================================================

# SSE-S3 (AWS quản lý key):
# client_sse = S3MultiBucketClient.new(
#   ...,
#   sse: { type: 'AES256' }
# )

# SSE-KMS (dùng AWS KMS key):
# client_sse = S3MultiBucketClient.new(
#   ...,
#   sse: { type: 'aws:kms', kms_key_id: 'arn:aws:kms:us-east-1:123456:key/abc-...' }
# )

# SSE-C (Customer-provided key — gửi key trên mỗi request):
# require 'base64'
# require 'digest'
# raw_key = SecureRandom.bytes(32)
# client_sse = S3MultiBucketClient.new(
#   ...,
#   sse: {
#     type:      'customer',
#     algorithm: 'AES256',
#     key:       Base64.strict_encode64(raw_key),
#     key_md5:   Base64.strict_encode64(Digest::MD5.digest(raw_key))
#   }
# )

# ============================================================
# 1. Upload file nhỏ (single PUT — streaming từ disk)
# ============================================================

# client.upload_file(
#   bucket:       'my-bucket',
#   key:          'documents/report.pdf',
#   file_path:    '/path/to/report.pdf',
#   content_type: 'application/pdf',
#   metadata:     { 'author' => 'alice' },
#   cache_control: 'max-age=3600'
# )

# ============================================================
# 2. Multipart upload song song với progress callback
# ============================================================
#
# Output mẫu (INFO level):
#   [S3] upload_file_multipart start: "movie.mp4" -> key="videos/movie.mp4" size=361806224 (345.00 MB) part_size=8388608 (8.00 MB) total_parts=44 max_threads=4 state=- session=a5f8bf53ebadba22 md5=...
#   [S3] upload_file_multipart MULTIPART: key="videos/movie.mp4" total_parts=44 session=a5f8bf53ebadba22
#   [S3] [PLAN] total_parts=44 pending=44 pre_uploaded=0 concurrency=4 part_size=8.00 MB
#   [S3] [PART START] t0 → part 1/44 bytes=0-8388607 size=8.00 MB (11.4%)
#   ...
#   [S3] [PART DONE]  t0 ✓ part 1/44 size=8.00 MB time=2702.8ms speed=2.96 MB/s etag="378e5af6..." | progress=8.00 MB/345.00 MB (2.3%) avg=2.96 MB/s ETA=113.7s
#   [S3] [UPLOAD COMPLETE] key="videos/movie.mp4" parts=44 elapsed=59.375s throughput=5.81 MB/s session=a5f8bf53ebadba22

progress = proc { |completed, total, percent|
  puts "  Phần #{completed}/#{total} (#{percent}%)"
}

# result = client.upload_file_multipart(
#   bucket:            'my-bucket',
#   key:               'videos/movie.mp4',
#   file_path:         '/path/to/large-movie.mp4',
#   part_size:         8 * 1024 * 1024,     # 8 MB per part
#   max_threads:       4,                    # 4 luồng song song
#   max_retries:       nil,                  # nil = dùng max_retries của client
#   retry_delay:       nil,                  # nil = dùng retry_delay của client
#   content_type:      'application/octet-stream',
#   metadata:          { 'user' => 'alice' },
#   cache_control:     'no-cache',
#   progress_callback: progress,
#   state_file:        'upload-state.json',  # lưu state sau mỗi part; tự xóa khi hoàn tất
#   raise_on_error:    false                 # true = raise exception thay vì trả về {error, state}
# )
#
# if result[:error]
#   puts "Upload thất bại: #{result[:error]}"
#   puts "State được giữ lại — chạy lại để resume."
# else
#   puts "Upload hoàn tất: #{result[:parts_uploaded]} parts, #{'%.1f' % result[:throughput]} MB/s"
# end

# ============================================================
# 3. Resume upload sau khi bị gián đoạn
# ============================================================

# # Cách 1: resume_upload tường minh
# if File.exist?('upload-state.json')
#   client.resume_upload(
#     bucket:            'my-bucket',
#     key:               'videos/movie.mp4',
#     file_path:         '/path/to/large-movie.mp4',
#     state_file:        'upload-state.json',
#     progress_callback: progress
#   )
# end
#
# # Cách 2: upload_file_multipart + UploadState object
# if File.exist?('upload-state.json')
#   saved_state = S3MultiBucketClient::UploadState.from_file('upload-state.json')
#   puts "Resume: #{saved_state.completed_parts_count}/#{saved_state.total_parts} parts đã xong"
#   client.upload_file_multipart(
#     bucket:            'my-bucket',
#     key:               'videos/movie.mp4',
#     file_path:         '/path/to/large-movie.mp4',
#     resume_state:      saved_state,
#     progress_callback: progress
#   )
# end

# ============================================================
# 4. Streaming download với progress
# ============================================================

# client.download_file(
#   bucket:            'my-bucket',
#   key:               'videos/movie.mp4',
#   destination_path:  '/path/to/downloaded-movie.mp4',
#   progress_callback: proc { |current, total, percent|
#     puts "  Đã tải: #{current}/#{total} bytes (#{percent}%)"
#   }
# )

# ============================================================
# 4a. Download với Range (tải một phần của file)
# ============================================================

# # Tải bytes 0 → 1MB-1 (1MB đầu tiên)
# client.download_file(
#   bucket:           'my-bucket',
#   key:              'videos/movie.mp4',
#   destination_path: '/path/to/partial.mp4',
#   range:            [0, 1024 * 1024 - 1]   # Array [start, end]
# )
#
# # Hoặc dùng Ruby Range
# client.download_file(
#   bucket:           'my-bucket',
#   key:              'videos/movie.mp4',
#   destination_path: '/path/to/partial.mp4',
#   range:            0..(1024 * 1024 - 1)   # Range (bao gồm cả đầu và cuối)
# )

# ============================================================
# 4b. Parallel download (đa luồng, nhanh cho file lớn)
# ============================================================
#
# Chia file thành nhiều parts, tải song song qua Range requests.
# Hỗ trợ resume qua state_file giống upload.

# result = client.download_file_parallel(
#   bucket:            'my-bucket',
#   key:               'videos/movie.mp4',
#   destination_path:  '/path/to/downloaded-movie.mp4',
#   part_size:         8 * 1024 * 1024,      # 8 MB per part
#   max_threads:       4,                     # 4 luồng song song
#   state_file:        'download-state.json', # resume support
#   progress_callback: proc { |completed, total, pct|
#     puts "  Phần #{completed}/#{total} (#{pct}%)"
#   }
# )
#
# puts "Đã tải: #{result[:size]} bytes, #{'%.1f' % result[:throughput]} MB/s"

# ============================================================
# 5. Download resume (từ file .part dở)
# ============================================================

# client.download_file_resume(
#   bucket:            'my-bucket',
#   key:               'videos/movie.mp4',
#   destination_path:  '/path/to/downloaded-movie.mp4',
#   progress_callback: proc { |current, total|
#     puts "  Đã resume: #{current}/#{total} bytes"
#   }
# )

# ============================================================
# 6. Download stream (dạng block, không ghi ra đĩa)
# ============================================================

# # Stream toàn bộ file
# client.download_stream(bucket: 'my-bucket', key: 'videos/movie.mp4') do |chunk|
#   $stdout.write(chunk)   # hoặc đẩy vào ZipInputStream, v.v.
# end
#
# # Stream với Range (chỉ tải 1 đoạn)
# client.download_stream(
#   bucket: 'my-bucket', key: 'videos/movie.mp4',
#   range: (1_000_000..2_000_000)   # bytes 1M → 2M
# ) { |chunk| process(chunk) }

# ============================================================
# 7. HEAD object (lấy siêu dữ liệu)
# ============================================================

# metadata = client.head_object(bucket: 'my-bucket', key: 'documents/report.pdf')
# puts "  Dung lượng:   #{metadata[:content_length]}"
# puts "  Content-Type: #{metadata[:content_type]}"
# puts "  ETag:         #{metadata[:etag]}"
# puts "  Last-Modified:#{metadata[:last_modified]}"
# puts "  Storage:      #{metadata[:storage_class]}"
# puts "  User meta:    #{metadata[:metadata].inspect}"

# ============================================================
# 8. Presigned URL (URL ký trước)
# ============================================================

# # GET URL (đọc file)
# url = client.presigned_url(
#   bucket: 'my-bucket', key: 'documents/report.pdf',
#   method: :get, expires_in: 3600
# )
# puts "  URL tải xuống: #{url}"
#
# # PUT URL (upload file)
# url = client.presigned_url(
#   bucket: 'my-bucket', key: 'uploads/new.bin',
#   method: :put, expires_in: 600
# )
# puts "  URL tải lên: #{url}"
#
# # Với query params bổ sung (ví dụ response-content-disposition)
# url = client.presigned_url(
#   bucket: 'my-bucket', key: 'documents/report.pdf',
#   method: :get, expires_in: 3600,
#   query: { 'response-content-disposition' => 'attachment; filename="report.pdf"' }
# )
# puts "  URL buộc tải xuống: #{url}"

# ============================================================
# 9. Liệt kê multipart uploads đang dở trên bucket
# ============================================================

# client.list_multipart_uploads(bucket: 'my-bucket').each { |u|
#   puts "  #{u[:key]}: upload_id=#{u[:upload_id]} initiated=#{u[:initiated]}"
# }

# ============================================================
# 10. Liệt kê parts của 1 multipart upload
# ============================================================

# client.list_parts(
#   bucket: 'my-bucket', key: 'videos/movie.mp4', upload_id: 'xxxxx'
# ).each { |p|
#   puts "  Part #{p[:part_number]}: etag=#{p[:etag]} size=#{p[:size]}"
# }

# ============================================================
# 11. Hủy bỏ multipart upload
# ============================================================

# client.abort_multipart_upload(
#   bucket: 'my-bucket', key: 'videos/movie.mp4', upload_id: 'xxxxx'
# )

# ============================================================
# 12. Xóa object
# ============================================================

# client.delete_object(bucket: 'my-bucket', key: 'old-file.txt')

# ============================================================
# 13. API multipart cấp thấp (tự quản lý vòng đời)
# ============================================================

# upload_id = client.multipart_start(
#   bucket: 'my-bucket', key: 'manual-upload.bin',
#   content_type: 'application/octet-stream',
#   metadata: { 'source' => 'manual' }
# )
#
# etag1 = client.multipart_upload_part(
#   bucket: 'my-bucket', key: 'manual-upload.bin',
#   upload_id: upload_id, part_number: 1,
#   body: File.binread('/tmp/part1.bin')
# )
#
# File.open('/tmp/part2.bin', 'rb') do |f|
#   etag2 = client.multipart_upload_part(
#     bucket: 'my-bucket', key: 'manual-upload.bin',
#     upload_id: upload_id, part_number: 2,
#     body: f, length: File.size('/tmp/part2.bin'), io_offset: 0
#   )
# end
#
# final_etag = client.multipart_complete(
#   bucket: 'my-bucket', key: 'manual-upload.bin',
#   upload_id: upload_id,
#   parts: [
#     { part_number: 1, etag: etag1 },
#     { part_number: 2, etag: etag2 }
#   ]
# )
#
# # Hoặc hủy (abort):
# client.multipart_abort(
#   bucket: 'my-bucket', key: 'manual-upload.bin', upload_id: upload_id
# )

# ============================================================
# 14. S3Helper — shortcuts tiện lợi
# ============================================================

# # Tự động phát hiện single/multipart
# S3Helper.upload(
#   client: client, bucket: 'my-bucket',
#   key: 'data/large-file.bin', file_path: '/path/to/large-file.bin',
#   multipart_threshold: 100 * 1024 * 1024
# )
#
# # Download với progress bar
# S3Helper.download(
#   client: client, bucket: 'my-bucket',
#   key: 'data/large-file.bin', destination: '/path/to/downloaded.bin',
#   show_progress: true,
#   resume: true
# )
#
# # Download parallel (multi-thread)
# S3Helper.download(
#   client: client, bucket: 'my-bucket',
#   key: 'data/large-file.bin', destination: '/path/to/downloaded.bin',
#   show_progress: true,
#   parallel: true,
#   max_threads: 4,
#   part_size: 8 * 1024 * 1024
# )


# ============================================================
# ============================================================
#
#             ↓↓↓ TÍNH NĂNG MỚI: EVENT & LOGGING (dành cho observability) ↓↓↓
#
# ============================================================
# ============================================================


# ============================================================
# 15. Event callbacks — hook vào vòng đời với 14+ sự kiện
# ============================================================
#
# Callbacks được đăng ký ở CLASS level (áp dụng cho mọi S3MultiBucketClient instance).
# Callback bị lỗi sẽ không làm upload/download fail — exception được catch & log ở WARN.
#
# Danh sách sự kiện UPLOAD:
#   :upload_start      (file_path, key, size, total_parts, part_size, resumed)
#   :upload_resume     (state)
#   :part_start        (part_number, total_parts, thread_id, offset, length)
#   :part_complete     (part_number, total_parts, thread_id, etag, bytes, elapsed_ms, throughput)
#   :part_retry        (part_number, thread_id, attempt, max_retries, backoff, error)
#   :part_failed       (part_number, thread_id, error, exhausted)
#   :state_save        (state_snapshot, completed_count, total_parts, thread_id)
#   :state_load        (state, path)
#   :state_mismatch    (old_state, new_key, new_size)
#   :upload_complete   (result, elapsed, throughput)
#   :upload_failed     (error, state_preserved_path)
#
# Danh sách sự kiện DOWNLOAD:
#   :download_start          (key, bucket, total_size, total_parts, part_size, resumed)
#   :download_part_start     (part_number, total_parts, thread_id, offset, length)
#   :download_part_complete  (part_number, total_parts, thread_id, bytes, elapsed_ms, throughput)
#   :download_part_retry     (part_number, thread_id, attempt, max_retries, backoff, error)
#   :download_part_failed    (part_number, thread_id, error)
#   :download_complete       (result, elapsed, throughput)
#   :download_failed         (error, state_file_path)
#
# Sự kiện chung:
#   :thread_start      (thread_id, thread_object_id)
#   :thread_finish     (thread_id, thread_object_id, parts_processed)
#   :log               (level, message, thread_id, timestamp)

# --- 15a. Log khi từng part hoàn tất ---
# S3MultiBucketClient.on(:part_complete) do |pn, total, tid, etag, bytes, ms, speed|
#   puts "  [hook] #{tid} ✓ part #{pn}/#{total} " \
#        "size=#{bytes / 1024 / 1024} MB speed=#{speed} MB/s time=#{ms.round(1)}ms"
# end

# --- 15b. Log khi retry ---
# S3MultiBucketClient.on(:part_retry) do |pn, tid, attempt, max, backoff, err|
#   $stderr.puts "  ⚠ #{tid} retry #{attempt}/#{max} part #{pn}: #{err.class} — backoff #{backoff}s"
# end

# --- 15c. Thông báo khi upload hoàn tất / thất bại ---
# S3MultiBucketClient.on(:upload_complete) do |result, elapsed, throughput|
#   puts "  🎉 Hoàn tất #{result[:key]} (#{'%.1f' % throughput} MB/s trong #{'%.1f' % elapsed}s)"
#   # notify_slack("Upload hoàn tất: #{result[:key]} (#{'%.1f' % throughput} MB/s)")
# end
#
# S3MultiBucketClient.on(:upload_failed) do |err, state_path|
#     $stderr.puts "  ❌ Upload thất bại: #{err.message}"
#   $stderr.puts "     State được giữ tại: #{state_path || '(không có)'}"
#   # notify_pagerduty("Upload thất bại: #{err.message}, state=#{state_path}")
# end

# --- 15d. Log khi resume / state mismatch ---
# S3MultiBucketClient.on(:upload_resume) do |state|
#   total_parts = (state[:total_size].to_f / state[:part_size]).ceil
#   parts_done = state[:parts].is_a?(Array) ? state[:parts].size : state[:parts].size
#   puts "  📂 Resume từ state: #{parts_done}/#{total_parts} parts"
#   puts "     session=#{state[:upload_session_id]} resume_count=#{state[:resume_count]}"
# end
#
# S3MultiBucketClient.on(:state_load) do |state, path|
#   puts "  📥 Loaded state #{path}: upload_id=#{state[:upload_id]}"
# end
#
# S3MultiBucketClient.on(:state_mismatch) do |old_state, new_key, new_size|
#   $stderr.puts "  ⚠ State không khớp — đang hủy upload cũ id=#{old_state[:upload_id]}"
#   $stderr.puts "     Key cũ=#{old_state[:key].inspect}, Key mới=#{new_key.inspect} size=#{new_size}"
# end

# --- 15e. Vòng đời của worker threads ---
# S3MultiBucketClient.on(:thread_start)  { |tid, oid| puts "  ▶ #{tid} started (object_id=#{oid})" }
# S3MultiBucketClient.on(:thread_finish) { |tid, oid, count| puts "  ■ #{tid} finished (#{count} parts)" }

# --- 15f. Hủy callback ---
# cb = S3MultiBucketClient.on(:part_complete) { |*a| puts a.inspect }
# S3MultiBucketClient.off(:part_complete, cb)   # bỏ 1 callback cụ thể
# S3MultiBucketClient.clear_callbacks!          # xóa tất cả callback

# ============================================================
# 16. Progress bar với event :part_complete
# ============================================================
#
# Dùng event thay vì progress_callback để tách biệt giao diện và logic:

# require 'io/console'
# bar_width  = 40
# last_print = Time.at(0)
# parts_done = []
#
# S3MultiBucketClient.on(:part_complete) do |pn, total, _tid, _etag, _bytes, _ms, _speed|
#   parts_done << pn
#   now = Time.now
#   next if now - last_print < 0.1   # giới hạn: max 10 lần/giây
#   last_print = now
#
#   pct = parts_done.size.to_f / total * 100
#   filled = (pct / 100.0 * bar_width).to_i
#   bar = "█" * filled + "░" * (bar_width - filled)
#   $stderr.print "\r  [#{bar}] #{pct.round(1)}% (#{pn}/#{total})"
#   $stderr.puts if pn == total
# end
#
# client.upload_file_multipart(
#   bucket: 'my-bucket', key: '/huge.bin',
#   file_path: '/path/to/huge.bin',
#   state_file: 'huge.upload.json'
# )

# ============================================================
# 17. Cảnh báo khi retry quá nhiều hoặc part fail vĩnh viễn
# ============================================================

# retry_counts = Hash.new(0)
#
# S3MultiBucketClient.on(:part_retry) do |pn, tid, attempt, max, backoff, err|
#   retry_counts[pn] += 1
#   if retry_counts[pn] >= max - 1
#     $stderr.puts "  🔔 Part #{pn} retry #{retry_counts[pn]} lần — sắp hết retry"
#     # PagerDuty.alert("S3 part #{pn} retry #{retry_counts[pn]}x: #{err.class}")
#   end
# end
#
# S3MultiBucketClient.on(:part_complete) { |pn, *_| retry_counts.delete(pn) }
#
# S3MultiBucketClient.on(:part_failed) do |pn, tid, err, exhausted|
#   if exhausted
#     $stderr.puts "  🔥 Part #{pn} thất bại vĩnh viễn: #{err.message}"
#     # PagerDuty.alert("S3 part #{pn} failed: #{err.message}")
#   end
# end

# ============================================================
# 18. Thread-safe logging — KHÔNG dùng puts trong worker thread
# ============================================================
#
# Khi viết callback hoặc code tùy chỉnh chạy trong worker thread,
# KHÔNG dùng puts/print trực tiếp — output có thể bị chồng chéo.
# Thay vào đó, dùng thread_log_*:

# S3MultiBucketClient.on(:part_start) do |pn, total, tid, offset, length|
#   # Sai (bị chồng chéo):
#   #   puts "#{tid} đang upload part #{pn}"
#   #
#   # Đúng (thread-safe):
#   client.thread_log_info("custom: bat dau part #{pn} (#{length} bytes)", tid)
# end
#
# # API:
# #   client.thread_log_info(msg, tid)
# #   client.thread_log_debug(msg, tid)
# #   client.thread_log_warn(msg, tid)
# #   client.thread_log_error(msg, tid)
# #
# # Main thread drain:
#   #   client.drain_thread_logs           # chuyển tiếp tới logger của instance
#   #   S3MultiBucketClient.drain_logs(my_logger)     # chuyển tiếp tới logger bất kỳ
#   #
#   # Định dạng output (sau khi drain):
#   #   [2026-06-03 16:38:50.914] INFO -- [thread:t0] [S3] custom: bat dau part 5 (8388608 bytes)

# ============================================================
# 19. Log tập trung qua event :log (Graylog / Loki / UDP)
# ============================================================

# require 'socket'
# require 'json'
#
# udp = UDPSocket.new
# S3MultiBucketClient.on(:log) do |level, msg, tid, ts|
#   payload = {
#     host: Socket.gethostname,
#     app: 'uploader',
#     component: 's3_multi_bucket_client',
#     level: level, thread: tid,
#     timestamp: ts.iso8601(3),
#     message: msg
#   }.to_json
#   udp.send(payload, 0, 'log-collector.local', 12201)
# end

# ============================================================
# 20. Debug state file sau crash — kiểm tra trước khi resume
# ============================================================
#
# Hữu ích khi process bị kill -9 hoặc mất điện: state file có thể
# còn `in_progress_parts` (parts đang upload dở) — cần kiểm tra để biết
# phần nào cần upload lại.

# if File.exist?('upload-state.json')
#   state = S3MultiBucketClient::UploadState.from_file('upload-state.json')
#
#   puts "=== Kiểm tra state file ==="
#   puts "  Session:          #{state.upload_session_id}"
#   puts "  Upload ID:        #{state.upload_id}"
#   puts "  Key:              #{state.key}"
#   puts "  Bucket:           #{state.bucket}"
#   puts "  File path:        #{state.file_path}"
#   puts "  Total size:       #{state.total_size} (#{state.total_size.to_f / 1024 / 1024 / 1024} GB)"
#   puts "  Part size:        #{state.part_size} (#{state.part_size / 1024 / 1024} MB)"
#   puts "  Progress:         #{state.summary}"
#   puts "  Started at:       #{state.started_at}"
#   puts "  Last updated:     #{state.last_updated_at}"
#   puts "  Last part done:   #{state.last_part_completed_at}"
#   puts "  Resumed at:       #{state.resumed_at}"
#   puts "  Resume count:     #{state.resume_count}"
#   puts "  File MD5:         #{state.file_md5}"
#   puts "  File MTIME:       #{state.file_mtime}"
#   puts "  Fingerprint:      #{state.file_fingerprint}"
#   puts "  Completed?:       #{state.completed?}"
#   puts
#   puts "  Completed parts (#{state.completed_parts_count}):"
#   puts "    #{state.part_list.map { |p| p[:part_number] }.inspect}"
#   puts "  In-progress parts (từ lần crash trước):"
#   puts "    #{state.in_progress_part_numbers.inspect}"
#   puts "  Pending parts (#{state.pending_part_numbers.size}):"
#   puts "    #{state.pending_part_numbers.size <= 50 ? state.pending_part_numbers.inspect : '(quá dài, xem state file)'}"
#   puts
#   puts "  Thread states:"
#   state.thread_states.each do |tid, info|
#     puts "    #{tid}: status=#{info[:status]} " \
#          "current_part=#{info[:current_part] || 'none'} " \
#          "parts_done=#{(info[:parts_done] || []).size} " \
#          "native_tid=#{info[:native_thread_id] || '?'}"
#   end
#
#   # Kiểm tra file MD5 trước khi resume
#   if state.file_md5 && File.exist?(state.file_path)
#     require 'digest'
#     current_md5 = Digest::MD5.file(state.file_path).hexdigest
#     if current_md5 == state.file_md5
#       puts "\n  ✓ File MD5 khớp — an toàn để resume"
#     else
#       puts "\n  ✗ File MD5 KHÁC (mong đợi #{state.file_md5}, nhận được #{current_md5})"
#       puts "    File đã bị thay đổi — nên xóa state và upload lại từ đầu."
#     end
#   end
# end

# ============================================================
# 21. Ví dụ hoàn chỉnh: upload với đầy đủ observability
# ============================================================

# # 1. Đăng ký callbacks
# S3MultiBucketClient.on(:part_complete) { |pn, total, tid, _etag, bytes, ms, speed|
#   puts "  ✓ #{tid} part #{pn}/#{total} #{bytes / 1024 / 1024} MB @ #{speed} MB/s"
# }
# S3MultiBucketClient.on(:part_retry) { |pn, tid, attempt, max, backoff, err|
#   $stderr.puts "  ⚠ #{tid} retry #{attempt}/#{max} part #{pn}: #{err.class}"
# }
# S3MultiBucketClient.on(:upload_resume) { |state|
#   parts = state[:parts].is_a?(Array) ? state[:parts].size : state[:parts].size
#   puts "  📂 Resume: #{parts} parts đã xong"
# }
# S3MultiBucketClient.on(:upload_complete) { |result, elapsed, throughput|
#   puts "  🎉 Hoan tat #{result[:key]} (#{'%.1f' % throughput} MB/s trong #{'%.1f' % elapsed}s)"
# }
#
# # 2. Tạo client với DEBUG file logger
# logger = Logger.new('upload.log')
# logger.level = Logger::DEBUG
# client = S3MultiBucketClient.new(
#   endpoint:          ENV['S3_ENDPOINT'],
#   region:            'auto',
#   access_key_id:     ENV['S3_ACCESS_KEY'],
#   secret_access_key: ENV['S3_SECRET_KEY'],
#   logger:            logger
# )
#
# # 3. Upload
# result = client.upload_file_multipart(
#   bucket:     'my-bucket',
#   key:        'data/huge.bin',
#   file_path:  '/path/to/huge.bin',
#   state_file: 'huge.upload.json'
# )
#
# if result[:error]
#   puts "  Upload thất bại: #{result[:error]}"
# else
#   puts "  Số parts:  #{result[:parts_uploaded]}"
#   puts "  Thời gian: #{'%.2f' % result[:elapsed]}s"
#   puts "  Throughput: #{'%.2f' % result[:throughput]} MB/s"
# end

# ============================================================
# 22. Debug download state file — kiểm tra tiến trình parallel download
# ============================================================

# if File.exist?('download-state.json')
#   dl_state = S3MultiBucketClient::DownloadState.from_file('download-state.json')
#
#   puts "=== Download State ==="
#   puts "  Session:        #{dl_state.download_session_id}"
#   puts "  Key:            #{dl_state.key}"
#   puts "  Bucket:         #{dl_state.bucket}"
#   puts "  Destination:    #{dl_state.destination_path}"
#   puts "  Total size:     #{dl_state.total_size} (#{dl_state.total_size.to_f / 1024 / 1024 / 1024} GB)"
#   puts "  Part size:      #{dl_state.part_size} (#{dl_state.part_size / 1024 / 1024} MB)"
#   puts "  Progress:       #{dl_state.summary}"
#   puts "  Started at:     #{dl_state.started_at}"
#   puts "  Last updated:   #{dl_state.last_updated_at}"
#   puts "  Resumed at:     #{dl_state.resumed_at}"
#   puts "  Resume count:   #{dl_state.resume_count}"
#   puts "  Completed?:     #{dl_state.completed?}"
#   puts
#   puts "  Downloaded parts (#{dl_state.completed_parts_count}):"
#   puts "    #{dl_state.parts.map { |p| p[:part_number] }.inspect}"
#   puts "  Pending parts (#{dl_state.pending_part_numbers.size}):"
#   puts "    #{dl_state.pending_part_numbers.size <= 50 ? dl_state.pending_part_numbers.inspect : '(quá dài, xem state file)'}"
# end
