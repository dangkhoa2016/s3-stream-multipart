# frozen_string_literal: true
# Ví dụ sử dụng S3Client (thư viện s3_client.rb)
#
# File này minh họa toàn bộ API public của S3Client, bao gồm:
#   - Các thao tác cơ bản: upload/download/delete/head/presign
#   - Resumable multipart upload qua state_file
#   - Event callbacks (21 sự kiện) để hook custom log / progress / alert
#   - Thread-safe logging từ worker threads
#   - Debug state file sau crash
#
# Mỗi section đều có comment giải thích; bạn có thể bỏ comment từng block
# để chạy thử (cần cấu hình credentials qua ENV).

require_relative '../src/s3_client'

# ============================================================
# 0. Khởi tạo client
# ============================================================

# AWS S3 (virtual-hosted style — mặc định):
client = S3Client.new(
  region:     'ap-southeast-1',
  bucket:     'my-bucket',
  access_key: ENV['S3_ACCESS_KEY_ID'],
  secret_key: ENV['S3_SECRET_ACCESS_KEY'],
  # logger:     Logger.new($stdout, level: Logger::INFO)
)

# MinIO / Cloudflare R2 / Backblaze B2 (path-style):
# client = S3Client.new(
#   region: 'us-east-1', bucket: 'my-bucket',
#   access_key: 'minioadmin', secret_key: 'minioadmin',
#   endpoint: 'https://minio.local:9000',
#   endpoint_style: :path
# )

# AWS STS (dùng temporary credentials):
# client = S3Client.new(
#   region: 'us-east-1', bucket: 'my-bucket',
#   access_key: ENV['S3_ACCESS_KEY_ID'],
#   secret_key: ENV['S3_SECRET_ACCESS_KEY'],
#   session_token: ENV['AWS_SESSION_TOKEN']
# )

# ============================================================
# 1. Upload file nhỏ (single PUT)
# ============================================================

# client.upload_file(
#   local_path: '/path/to/report.pdf',
#   key:        'documents/report.pdf',
#   content_type: 'application/pdf',
#   metadata:     { 'author' => 'alice' }
# )

# ============================================================
# 2. Multipart upload song song với progress_callback
# ============================================================
#
# Output mẫu (INFO level):
#   [S3] upload_file start: "movie.mp4" -> key="videos/movie.mp4" size=361806224 (345.00 MB) part_size=10485760 (10.00 MB) total_parts=35 concurrency=4 state=upload-state.json session=a5f8bf53ebadba22 md5=...
#   [S3] upload_file MULTIPART: key="videos/movie.mp4" total_parts=35 session=a5f8bf53ebadba22
#   [S3] [PLAN] total_parts=35 pending=35 pre_uploaded=0 concurrency=4 part_size=10.00 MB session=a5f8bf53ebadba22
#   [S3] [PART START] t0 → part 1/35 bytes=0-10485759 size=10.00 MB (2.9%)
#   [S3] [PART START] t1 → part 2/35 bytes=10485760-20971519 size=10.00 MB (5.7%)
#   ...
#   [S3] [PART DONE]  t0 ✓ part 1/35 size=10.00 MB time=2702.8ms speed=3.70 MB/s etag="\"378e5af6..." | progress=10.00 MB/345.00 MB (2.9%) avg=3.70 MB/s ETA=90.5s
#   [S3] [UPLOAD COMPLETE] key="videos/movie.mp4" etag="b33a03f8..." parts=35 elapsed=59.375s throughput=5.81 MB/s session=a5f8bf53ebadba22

progress_bytes = proc { |written, total|
  percent = total.positive? ? (written.to_f / total * 100).round(2) : 0
  puts "  Tiến trình: #{written}/#{total} bytes (#{percent}%)"
}

# result = client.upload_file(
#   local_path:  '/path/to/large-movie.mp4',
#   key:         'videos/movie.mp4',
#   part_size:   10 * 1024 * 1024,     # 10 MB per part
#   on_progress: progress_bytes,
  #   state_file:  'upload-state.json'   # lưu state sau mỗi part; tự xóa khi hoàn tất
# )

# ============================================================
# 3. Resume upload sau khi bị gián đoạn
# ============================================================

# # Tường minh dùng resume_upload:
# if File.exist?('upload-state.json')
#   client.resume_upload(
#     state_file:  'upload-state.json',
#     on_progress: progress_bytes
#   )
# end
#
# # Hoặc dùng upload_file_multipart + UploadState object (tương thích S3MultiBucketClient):
# if File.exist?('upload-state.json')
#   saved_state = S3Client::UploadState.from_file('upload-state.json')
#   progress_parts = proc { |completed, total, percent|
#     puts "  Phần #{completed}/#{total} (#{percent}%)"
#   }
#   client.upload_file_multipart(
#     local_path:       '/path/to/large-movie.mp4',
#     key:              'videos/movie.mp4',
#     resume_state:     saved_state,
#     progress_callback: progress_parts
#   )
# end

# ============================================================
# 4. Streaming download với progress
# ============================================================

# client.download_file(
#   key:         'videos/movie.mp4',
#   local_path:  '/path/to/downloaded-movie.mp4',
#   on_progress: proc { |current, total|
#     puts "  Đã tải: #{current}/#{total} bytes"
#   }
# )

# ============================================================
# 4a. Parallel download (đa luồng, nhanh cho file lớn)
# ============================================================
#
# Chia file thành nhiều parts, tải song song qua Range requests.
# Hỗ trợ resume qua state_file giống upload.

# result = client.download_file_parallel(
#   key:               'videos/movie.mp4',
#   local_path:        '/path/to/downloaded-movie.mp4',
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
# 5. HEAD object (lấy siêu dữ liệu)
# ============================================================

# metadata = client.head_object('documents/report.pdf')
# puts "  Dung lượng:   #{metadata[:content_length]}"
# puts "  Content-Type: #{metadata[:content_type]}"
# puts "  ETag:         #{metadata[:etag]}"
# puts "  User meta:    #{metadata[:metadata].inspect}"

# ============================================================
# 6. Presigned URL (URL ký trước)
# ============================================================

# url = client.presigned_url(
#   key: 'documents/report.pdf', method: :get, expires_in: 3600
# )
# puts "  Presigned URL: #{url}"

# ============================================================
# 7. List multipart uploads đang dở trên bucket
# ============================================================

# client.list_multipart_uploads.each { |u|
#   puts "  #{u[:key]}: upload_id=#{u[:upload_id]} initiated=#{u[:initiated]}"
# }

# ============================================================
# 8. Hủy bỏ multipart upload
# ============================================================

# client.abort_multipart_upload(
#   key: 'videos/movie.mp4', upload_id: 'xxxxx'
# )

# ============================================================
# 9. Xóa object
# ============================================================

# client.delete_object('old-file.txt')

# ============================================================
# 10. Download một đoạn byte (Range)
# ============================================================

# File.open('/tmp/chunk.bin', 'wb') do |out|
#   client.download_stream(key: 'videos/movie.mp4', range: (0..1023)) do |chunk|
#     out.write(chunk)
#   end
# end

# ============================================================
# 11. Download resume (từ file .part dở)
# ============================================================

# client.download_file_resume(
#   key:         'videos/movie.mp4',
#   local_path:  '/path/to/downloaded-movie.mp4',
#   on_progress: proc { |current, total|
#     puts "  Đã resume: #{current}/#{total} bytes"
#   }
# )

# ============================================================
# 12. S3Helper — shortcuts tiện lợi
# ============================================================

# S3Helper.upload(
#   client: client,
#   key: 'data/large-file.bin',
#   local_path: '/path/to/large-file.bin',
#   multipart_threshold: 100 * 1024 * 1024
# )
#
# S3Helper.download(
#   client: client,
#   key: 'data/large-file.bin',
#   local_path: '/path/to/downloaded.bin',
#   show_progress: true,
#   resume: true
# )
#
# # Download song song (multi-thread)
# S3Helper.download(
#   client: client,
#   key: 'data/large-file.bin',
#   local_path: '/path/to/downloaded.bin',
#   show_progress: true,
#   parallel: true,
#   max_threads: 4,
#   part_size: 8 * 1024 * 1024
# )

# ============================================================
# 13. API multipart cấp thấp (tự quản lý vòng đời)
# ============================================================

# upload_id = client.multipart_start(
#   key: 'manual-upload.bin',
#   content_type: 'application/octet-stream',
#   metadata: { 'source' => 'manual' }
# )
#
# etag1 = client.multipart_upload_part(
#   key: 'manual-upload.bin', upload_id: upload_id,
#   part_number: 1, body: File.binread('/tmp/part1.bin')
# )
#
# File.open('/tmp/part2.bin', 'rb') do |f|
#   etag2 = client.multipart_upload_part(
#     key: 'manual-upload.bin', upload_id: upload_id,
#     part_number: 2, body: f, length: File.size('/tmp/part2.bin')
#   )
# end
#
# client.multipart_complete(
#   key: 'manual-upload.bin', upload_id: upload_id,
#   parts: [
#     { part_number: 1, etag: etag1 },
#     { part_number: 2, etag: etag2 }
#   ]
# )
#
# client.list_parts(key: 'manual-upload.bin', upload_id: upload_id)
#       .each { |p| puts "  Part #{p[:part_number]}: etag=#{p[:etag]} size=#{p[:size]}" }


# ============================================================
# ============================================================
#
#             ↓↓↓ TÍNH NĂNG MỚI: EVENT & LOGGING (dành cho observability) ↓↓↓
#
# ============================================================
# ============================================================


# ============================================================
# 14. Event callbacks — hook vào vòng đời với 21 sự kiện
# ============================================================
#
# Callbacks được đăng ký ở CLASS level (áp dụng cho mọi S3Client instance).
# Callback lỗi không làm upload fail — exception được catch & log ở WARN.
#
# Danh sách 21 sự kiện (14 upload + 7 download):
#
# Sự kiện Upload:
#   :upload_start      (local_path, key, size, total_parts, part_size, resumed)
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
# Sự kiện Download (dành cho download_file_parallel):
#   :download_start         (key, total_size, total_parts, part_size, resumed)
#   :download_part_start    (part_number, total_parts, thread_id, offset, length)
#   :download_part_complete (part_number, total_parts, thread_id, bytes, elapsed_ms, throughput)
#   :download_part_retry    (part_number, thread_id, attempt, max_retries, backoff, error)
#   :download_part_failed   (part_number, thread_id, error)
#   :download_complete      (result, elapsed, throughput)
#   :download_failed        (error, state_file_path)
#
# Sự kiện chung:
#   :thread_start      (thread_id, thread_object_id)
#   :thread_finish     (thread_id, thread_object_id, parts_processed)
#   :log               (level, message, thread_id, timestamp)

# --- 14a. Log khi từng part hoàn tất ---
# S3Client.on(:part_complete) do |pn, total, tid, etag, bytes, ms, speed|
#   puts "  [hook] #{tid} ✓ part #{pn}/#{total} " \
#        "size=#{bytes / 1024 / 1024} MB speed=#{speed} MB/s time=#{ms.round(1)}ms"
# end

# --- 14b. Log khi retry ---
# S3Client.on(:part_retry) do |pn, tid, attempt, max, backoff, err|
#   $stderr.puts "  ⚠ #{tid} retry #{attempt}/#{max} part #{pn}: #{err.class} — backoff #{backoff}s"
# end

# --- 14c. Thông báo khi upload hoàn tất / thất bại ---
# S3Client.on(:upload_complete) do |result, elapsed, throughput|
#   puts "  🎉 Hoàn tất #{result[:key]} (#{'%.1f' % throughput} MB/s trong #{'%.1f' % elapsed}s)"
#   # notify_slack("Upload hoàn tất: #{result[:key]} (#{'%.1f' % throughput} MB/s)")
# end
#
# S3Client.on(:upload_failed) do |err, state_path|
#   $stderr.puts "  ❌ Upload thất bại: #{err.message}"
#   $stderr.puts "     State được giữ tại: #{state_path || '(không có, đã hủy)'}"
#   # notify_pagerduty("Upload thất bại: #{err.message}, state=#{state_path}")
# end
#
# --- 14d. Log khi resume / state mismatch ---
# S3Client.on(:upload_resume) do |state|
#   total_parts = (state[:total_size].to_f / state[:part_size]).ceil
#   puts "  📂 Resume từ state: #{state[:parts].size}/#{total_parts} parts"
#   puts "     session=#{state[:upload_session_id]} resume_count=#{state[:resume_count]}"
# end
#
# S3Client.on(:state_load) do |state, path|
#   puts "  📥 Loaded state #{path}: upload_id=#{state[:upload_id]}"
# end
#
# S3Client.on(:state_mismatch) do |old_state, new_key, new_size|
#   $stderr.puts "  ⚠ State không khớp — đang hủy upload cũ id=#{old_state[:upload_id]}"
#   $stderr.puts "     Old key=#{old_state[:key].inspect}, New key=#{new_key.inspect} size=#{new_size}"
# end

# --- 14e. Vòng đời của worker threads ---
# S3Client.on(:thread_start)  { |tid, oid| puts "  ▶ #{tid} started (object_id=#{oid})" }
# S3Client.on(:thread_finish) { |tid, oid, count| puts "  ■ #{tid} finished (#{count} parts)" }

# --- 14f. Hủy callback ---
# cb = S3Client.on(:part_complete) { |*a| puts a.inspect }
# S3Client.off(:part_complete, cb)   # bỏ 1 callback cụ thể
# S3Client.clear_callbacks!          # xóa tất cả callback

# ============================================================
# 15. Progress bar với event :part_complete
# ============================================================
#
# Dùng event thay vì on_progress callback để tách biệt giao diện và logic:

# require 'io/console'
# bar_width  = 40
# last_print = Time.at(0)
# parts_done = []
#
# S3Client.on(:part_complete) do |pn, total, _tid, _etag, _bytes, _ms, _speed|
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
# client.upload_file(
#   local_path: '/path/to/huge.bin',
#   key: '/huge.bin',
#   state_file: 'huge.upload.json'
# )

# ============================================================
# 16. Cảnh báo khi retry quá nhiều hoặc part fail vĩnh viễn
# ============================================================

# retry_counts = Hash.new(0)
#
# S3Client.on(:part_retry) do |pn, tid, attempt, max, backoff, err|
#   retry_counts[pn] += 1
#   if retry_counts[pn] >= max - 1
#     $stderr.puts "  🔔 Part #{pn} retry #{retry_counts[pn]} lần — sắp hết retry"
#     # PagerDuty.alert("S3 part #{pn} retry #{retry_counts[pn]} lần: #{err.class}")
#   end
# end
#
# S3Client.on(:part_complete) { |pn, *_| retry_counts.delete(pn) }
#
# S3Client.on(:part_failed) do |pn, tid, err, exhausted|
#   if exhausted
#     $stderr.puts "  🔥 Part #{pn} failed vĩnh viễn: #{err.message}"
#     # PagerDuty.alert("S3 part #{pn} failed: #{err.message}")
#   end
# end

# ============================================================
# 16a. Event callbacks cho download — hook vào quá trình download song song
# ============================================================

# --- Log khi bắt đầu download ---
# S3Client.on(:download_start) do |key, total_size, total_parts, part_size, resumed|
#   puts "  ⬇ Bắt đầu download: #{key} size=#{total_size / 1024 / 1024} MB " \
#        "parts=#{total_parts} part_size=#{part_size / 1024 / 1024} MB resumed=#{resumed}"
# end
#
# --- Log khi từng part download hoàn tất ---
# S3Client.on(:download_part_complete) do |pn, total, tid, bytes, ms, speed|
#   puts "  [DL] #{tid} ✓ part #{pn}/#{total} " \
#        "size=#{bytes / 1024 / 1024} MB speed=#{speed} MB/s time=#{ms.round(1)}ms"
# end
#
# --- Log khi download retry ---
# S3Client.on(:download_part_retry) do |pn, tid, attempt, max, backoff, err|
#   $stderr.puts "  ⚠ [DL] #{tid} retry #{attempt}/#{max} part #{pn}: #{err.class} — backoff #{backoff.round(2)}s"
# end
#
# --- Thông báo khi download hoàn tất / thất bại ---
# S3Client.on(:download_complete) do |result, elapsed, throughput|
#   puts "  🎉 Download hoàn tất #{result[:key]} (#{'%.1f' % throughput} MB/s trong #{'%.1f' % elapsed}s)"
# end
#
# S3Client.on(:download_failed) do |err, state_path|
#   $stderr.puts "  ❌ Download thất bại: #{err.message}"
#   $stderr.puts "     State: #{state_path || '(không có)'}"
# end

# --- Log khi từng part download hoàn tất ---
# S3Client.on(:download_part_complete) do |pn, total, tid, bytes, ms, speed|
#   puts "  [DL] #{tid} ✓ part #{pn}/#{total} " \
#        "size=#{bytes / 1024 / 1024} MB speed=#{speed} MB/s time=#{ms.round(1)}ms"
# end

# --- Log khi download retry ---
# S3Client.on(:download_part_retry) do |pn, tid, attempt, max, backoff, err|
#   $stderr.puts "  ⚠ [DL] #{tid} retry #{attempt}/#{max} part #{pn}: #{err.class} — backoff #{backoff.round(2)}s"
# end

# --- Thông báo khi download hoàn tất / thất bại ---
# S3Client.on(:download_complete) do |result, elapsed, throughput|
#   puts "  🎉 Download hoàn tất #{result[:key]} (#{'%.1f' % throughput} MB/s trong #{'%.1f' % elapsed}s)"
# end
#
# S3Client.on(:download_failed) do |err, state_path|
#   $stderr.puts "  ❌ Download thất bại: #{err.message}"
#   $stderr.puts "     State: #{state_path || '(không có)'}"
# end

# ============================================================
# 17. Thread-safe logging — KHÔNG dùng puts trong worker thread
# ============================================================
#
# Khi viết callback hoặc code tùy chỉnh chạy trong worker thread,
# KHÔNG dùng puts/print trực tiếp — output có thể bị chồng chéo.
# Thay vào đó, dùng thread_log_*:

# S3Client.on(:part_start) do |pn, total, tid, offset, length|
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
#   #   S3Client.drain_logs(my_logger)     # chuyển tiếp tới logger bất kỳ
#   #
#   # Định dạng output (sau khi drain):
#   #   [2026-06-03 16:38:50.914] INFO -- [thread:t0] [S3] custom: bat dau part 5 (10485760 bytes)

# ============================================================
# 18. Log tập trung qua event :log (Graylog / Loki / UDP)
# ============================================================

# require 'socket'
# require 'json'
#
# udp = UDPSocket.new
# S3Client.on(:log) do |level, msg, tid, ts|
#   payload = {
#     host: Socket.gethostname,
#     app: 'uploader',
#     component: 's3_client',
#     level: level, thread: tid,
#     timestamp: ts.iso8601(3),
#     message: msg
#   }.to_json
#   udp.send(payload, 0, 'log-collector.local', 12201)
# end

# ============================================================
# 19. Debug state file sau crash — kiểm tra trước khi resume
# ============================================================
#
# Hữu ích khi process bị kill -9 hoặc mất điện: state file có thể
# còn `in_progress_parts` (parts đang upload dở) — cần kiểm tra để biết
# phần nào cần upload lại.

# if File.exist?('upload-state.json')
#   state = S3Client::UploadState.from_file('upload-state.json')
#
#   puts "=== Kiểm tra state file ==="
#   puts "  Session:          #{state.upload_session_id}"
#   puts "  Upload ID:        #{state.upload_id}"
#   puts "  Key:              #{state.key}"
#   puts "  Local path:       #{state.local_path}"
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
#   puts "  Completed?:       #{state.completed?}"
#   puts
#   puts "  Completed parts (#{state.completed_parts_count}):"
#   puts "    #{state.part_list.map { |p| p[:part_number] }.inspect}"
#   puts "  In-progress parts (từ lần crash trước):"
#   puts "    #{state.in_progress_parts.inspect}"
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
#   if state.file_md5 && File.exist?(state.local_path)
#     require 'digest'
#     current_md5 = Digest::MD5.file(state.local_path).hexdigest
#     if current_md5 == state.file_md5
#     puts "\n  ✓ File MD5 khớp — an toàn để resume"
#     else
#       puts "\n  ✗ File MD5 KHÁC (mong đợi #{state.file_md5}, nhận được #{current_md5})"
#       puts "    File đã bị thay đổi — client sẽ tự hủy & upload lại từ đầu."
#     end
#   end
# end

# ============================================================
# 20. Ví dụ hoàn chỉnh: upload với đầy đủ observability
# ============================================================

# # 1. Đăng ký callbacks
# S3Client.on(:part_complete) { |pn, total, tid, _etag, bytes, ms, speed|
#   puts "  ✓ #{tid} part #{pn}/#{total} #{bytes / 1024 / 1024} MB @ #{speed} MB/s"
# }
# S3Client.on(:part_retry) { |pn, tid, attempt, max, backoff, err|
#   $stderr.puts "  ⚠ #{tid} retry #{attempt}/#{max} part #{pn}: #{err.class}"
# }
# S3Client.on(:upload_resume) { |state|
#   puts "  📂 Resume: #{state[:parts].size} parts"
# }
# S3Client.on(:upload_complete) { |result, elapsed, throughput|
#   puts "  🎉 Hoàn tất #{result[:key]} (#{'%.1f' % throughput} MB/s trong #{'%.1f' % elapsed}s)"
# }
#
# # 2. Tạo client với DEBUG file logger
# logger = Logger.new('upload.log')
# logger.level = Logger::DEBUG
# client = S3Client.new(
#   region: 'auto', bucket: 'my-bucket',
#   access_key: ENV['S3_ACCESS_KEY'], secret_key: ENV['S3_SECRET_KEY'],
#   endpoint: ENV['S3_ENDPOINT'], endpoint_style: :path,
#   logger: logger
# )
#
# # 3. Upload
# result = client.upload_file(
#   local_path: 'huge.bin',
#   key:        '/data/huge.bin',
#   state_file: 'huge.upload.json'
# )
#
# puts "  ETag:   #{result[:etag]}"
# puts "  Parts:  #{result[:parts].size}"
# puts "  Thời gian: #{'%.2f' % result[:elapsed]}s"
