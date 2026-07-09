# frozen_string_literal: true
# S3Client usage example (library: s3_client.rb)
#
# This file demonstrates the full public API of S3Client, including:
#   - Basic operations: upload/download/delete/head/presign
#   - Resumable multipart upload via state_file
#   - Event callbacks (21 events) for custom logging / progress / alerting
#   - Thread-safe logging from worker threads
#   - Debug state file after crash
#
# Each section includes explanatory comments; uncomment blocks to
# run them (requires credentials configured via ENV).

require_relative '../src/s3_client'

# ============================================================
# 0. Client initialization
# ============================================================

# AWS S3 (virtual-hosted style — default):
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

# AWS STS (using temporary credentials):
# client = S3Client.new(
#   region: 'us-east-1', bucket: 'my-bucket',
#   access_key: ENV['S3_ACCESS_KEY_ID'],
#   secret_key: ENV['S3_SECRET_ACCESS_KEY'],
#   session_token: ENV['AWS_SESSION_TOKEN']
# )

# ============================================================
# 1. Upload small file (single PUT)
# ============================================================

# client.upload_file(
#   local_path: '/path/to/report.pdf',
#   key:        'documents/report.pdf',
#   content_type: 'application/pdf',
#   metadata:     { 'author' => 'alice' }
# )

# ============================================================
# 2. Parallel multipart upload with progress_callback
# ============================================================
#
# Sample output (INFO level):
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
  puts "  Progress: #{written}/#{total} bytes (#{percent}%)"
}

# result = client.upload_file(
#   local_path:  '/path/to/large-movie.mp4',
#   key:         'videos/movie.mp4',
#   part_size:   10 * 1024 * 1024,     # 10 MB per part
#   on_progress: progress_bytes,
  #   state_file:  'upload-state.json'   # save state after each part; auto-deleted on completion
# )

# ============================================================
# 3. Resume upload after interruption
# ============================================================

# # Explicit resume_upload:
# if File.exist?('upload-state.json')
#   client.resume_upload(
#     state_file:  'upload-state.json',
#     on_progress: progress_bytes
#   )
# end
#
# # Or use upload_file_multipart + UploadState object (compatible with S3MultiBucketClient):
# if File.exist?('upload-state.json')
#   saved_state = S3Client::UploadState.from_file('upload-state.json')
#   progress_parts = proc { |completed, total, percent|
#     puts "  Part #{completed}/#{total} (#{percent}%)"
#   }
#   client.upload_file_multipart(
#     local_path:       '/path/to/large-movie.mp4',
#     key:              'videos/movie.mp4',
#     resume_state:     saved_state,
#     progress_callback: progress_parts
#   )
# end

# ============================================================
# 4. Streaming download with progress
# ============================================================

# client.download_file(
#   key:         'videos/movie.mp4',
#   local_path:  '/path/to/downloaded-movie.mp4',
#   on_progress: proc { |current, total|
#     puts "  Downloaded: #{current}/#{total} bytes"
#   }
# )

# ============================================================
# 4a. Parallel download (multi-threaded, faster for large files)
# ============================================================
#
# Split file into multiple parts, download in parallel via Range requests.
# Supports resume via state_file (similar to upload).

# result = client.download_file_parallel(
#   key:               'videos/movie.mp4',
#   local_path:        '/path/to/downloaded-movie.mp4',
#   part_size:         8 * 1024 * 1024,      # 8 MB per part
#   max_threads:       4,                     # 4 parallel threads
#   state_file:        'download-state.json', # resume support
#   progress_callback: proc { |completed, total, pct|
#     puts "  Part #{completed}/#{total} (#{pct}%)"
#   }
# )
#
# puts "Downloaded: #{result[:size]} bytes, #{'%.1f' % result[:throughput]} MB/s"

# ============================================================
# 5. HEAD object (retrieve metadata)
# ============================================================

# metadata = client.head_object('documents/report.pdf')
# puts "  Size:         #{metadata[:content_length]}"
# puts "  Content-Type: #{metadata[:content_type]}"
# puts "  ETag:         #{metadata[:etag]}"
# puts "  User meta:    #{metadata[:metadata].inspect}"

# ============================================================
# 6. Presigned URL
# ============================================================

# url = client.presigned_url(
#   key: 'documents/report.pdf', method: :get, expires_in: 3600
# )
# puts "  Presigned URL: #{url}"

# ============================================================
# 7. List in-progress multipart uploads on the bucket
# ============================================================

# client.list_multipart_uploads.each { |u|
#   puts "  #{u[:key]}: upload_id=#{u[:upload_id]} initiated=#{u[:initiated]}"
# }

# ============================================================
# 8. Abort multipart upload
# ============================================================

# client.abort_multipart_upload(
#   key: 'videos/movie.mp4', upload_id: 'xxxxx'
# )

# ============================================================
# 9. Delete object
# ============================================================

# client.delete_object('old-file.txt')

# ============================================================
# 10. Download a byte range
# ============================================================

# File.open('/tmp/chunk.bin', 'wb') do |out|
#   client.download_stream(key: 'videos/movie.mp4', range: (0..1023)) do |chunk|
#     out.write(chunk)
#   end
# end

# ============================================================
# 11. Download resume (from incomplete .part file)
# ============================================================

# client.download_file_resume(
#   key:         'videos/movie.mp4',
#   local_path:  '/path/to/downloaded-movie.mp4',
#   on_progress: proc { |current, total|
#     puts "  Resumed: #{current}/#{total} bytes"
#   }
# )

# ============================================================
# 12. S3Helper — convenient shortcuts
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
# # Parallel download (multi-thread)
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
# 13. Low-level multipart API (manual lifecycle management)
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
#             ↓↓↓ NEW FEATURES: EVENT & LOGGING (for observability) ↓↓↓
#
# ============================================================
# ============================================================


# ============================================================
# 14. Event callbacks — lifecycle hooks with 21 events
# ============================================================
#
# Callbacks are registered at the CLASS level (apply to every S3Client instance).
# A failing callback does NOT cause the upload to fail — exceptions are caught & logged at WARN.
#
# List of 21 events (14 upload + 7 download):
#
# Upload events:
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
# Download events (for download_file_parallel):
#   :download_start         (key, total_size, total_parts, part_size, resumed)
#   :download_part_start    (part_number, total_parts, thread_id, offset, length)
#   :download_part_complete (part_number, total_parts, thread_id, bytes, elapsed_ms, throughput)
#   :download_part_retry    (part_number, thread_id, attempt, max_retries, backoff, error)
#   :download_part_failed   (part_number, thread_id, error)
#   :download_complete      (result, elapsed, throughput)
#   :download_failed        (error, state_file_path)
#
# Common events:
#   :thread_start      (thread_id, thread_object_id)
#   :thread_finish     (thread_id, thread_object_id, parts_processed)
#   :log               (level, message, thread_id, timestamp)

# --- 14a. Log when each part completes ---
# S3Client.on(:part_complete) do |pn, total, tid, etag, bytes, ms, speed|
#   puts "  [hook] #{tid} ✓ part #{pn}/#{total} " \
#        "size=#{bytes / 1024 / 1024} MB speed=#{speed} MB/s time=#{ms.round(1)}ms"
# end

# --- 14b. Log on retry ---
# S3Client.on(:part_retry) do |pn, tid, attempt, max, backoff, err|
#   $stderr.puts "  ⚠ #{tid} retry #{attempt}/#{max} part #{pn}: #{err.class} — backoff #{backoff}s"
# end

# --- 14c. Notify on upload complete / failure ---
# S3Client.on(:upload_complete) do |result, elapsed, throughput|
#   puts "  🎉 Completed #{result[:key]} (#{'%.1f' % throughput} MB/s in #{'%.1f' % elapsed}s)"
#   # notify_slack("Upload complete: #{result[:key]} (#{'%.1f' % throughput} MB/s)")
# end
#
# S3Client.on(:upload_failed) do |err, state_path|
#   $stderr.puts "  ❌ Upload failed: #{err.message}"
#   $stderr.puts "     State preserved at: #{state_path || '(none, aborted)'}"
#   # notify_pagerduty("Upload failed: #{err.message}, state=#{state_path}")
# end
#
# --- 14d. Log on resume / state mismatch ---
# S3Client.on(:upload_resume) do |state|
#   total_parts = (state[:total_size].to_f / state[:part_size]).ceil
#   puts "  📂 Resume from state: #{state[:parts].size}/#{total_parts} parts"
#   puts "     session=#{state[:upload_session_id]} resume_count=#{state[:resume_count]}"
# end
#
# S3Client.on(:state_load) do |state, path|
#   puts "  📥 Loaded state #{path}: upload_id=#{state[:upload_id]}"
# end
#
# S3Client.on(:state_mismatch) do |old_state, new_key, new_size|
#   $stderr.puts "  ⚠ State mismatch — aborting old upload id=#{old_state[:upload_id]}"
#   $stderr.puts "     Old key=#{old_state[:key].inspect}, New key=#{new_key.inspect} size=#{new_size}"
# end

# --- 14e. Worker thread lifecycle ---
# S3Client.on(:thread_start)  { |tid, oid| puts "  ▶ #{tid} started (object_id=#{oid})" }
# S3Client.on(:thread_finish) { |tid, oid, count| puts "  ■ #{tid} finished (#{count} parts)" }

# --- 14f. Remove callbacks ---
# cb = S3Client.on(:part_complete) { |*a| puts a.inspect }
# S3Client.off(:part_complete, cb)   # remove a specific callback
# S3Client.clear_callbacks!          # remove all callbacks

# ============================================================
# 15. Progress bar with event :part_complete
# ============================================================
#
# Use events instead of on_progress callback to decouple UI from logic:

# require 'io/console'
# bar_width  = 40
# last_print = Time.at(0)
# parts_done = []
#
# S3Client.on(:part_complete) do |pn, total, _tid, _etag, _bytes, _ms, _speed|
#   parts_done << pn
#   now = Time.now
#   next if now - last_print < 0.1   # rate-limit: max 10 times/sec
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
# 16. Alert on excessive retries or permanent part failure
# ============================================================

# retry_counts = Hash.new(0)
#
# S3Client.on(:part_retry) do |pn, tid, attempt, max, backoff, err|
#   retry_counts[pn] += 1
#   if retry_counts[pn] >= max - 1
#     $stderr.puts "  🔔 Part #{pn} retry #{retry_counts[pn]} times — retries nearly exhausted"
#     # PagerDuty.alert("S3 part #{pn} retry #{retry_counts[pn]}x: #{err.class}")
#   end
# end
#
# S3Client.on(:part_complete) { |pn, *_| retry_counts.delete(pn) }
#
# S3Client.on(:part_failed) do |pn, tid, err, exhausted|
#   if exhausted
#     $stderr.puts "  🔥 Part #{pn} failed permanently: #{err.message}"
#     # PagerDuty.alert("S3 part #{pn} failed: #{err.message}")
#   end
# end

# ============================================================
# 16a. Download event callbacks — hook into parallel download process
# ============================================================

# --- Log when download starts ---
# S3Client.on(:download_start) do |key, total_size, total_parts, part_size, resumed|
#   puts "  ⬇ Starting download: #{key} size=#{total_size / 1024 / 1024} MB " \
#        "parts=#{total_parts} part_size=#{part_size / 1024 / 1024} MB resumed=#{resumed}"
# end
#
# --- Log when each download part completes ---
# S3Client.on(:download_part_complete) do |pn, total, tid, bytes, ms, speed|
#   puts "  [DL] #{tid} ✓ part #{pn}/#{total} " \
#        "size=#{bytes / 1024 / 1024} MB speed=#{speed} MB/s time=#{ms.round(1)}ms"
# end
#
# --- Log on download retry ---
# S3Client.on(:download_part_retry) do |pn, tid, attempt, max, backoff, err|
#   $stderr.puts "  ⚠ [DL] #{tid} retry #{attempt}/#{max} part #{pn}: #{err.class} — backoff #{backoff.round(2)}s"
# end
#
# --- Notify on download complete / failure ---
# S3Client.on(:download_complete) do |result, elapsed, throughput|
#   puts "  🎉 Download completed #{result[:key]} (#{'%.1f' % throughput} MB/s in #{'%.1f' % elapsed}s)"
# end
#
# S3Client.on(:download_failed) do |err, state_path|
#   $stderr.puts "  ❌ Download failed: #{err.message}"
#   $stderr.puts "     State: #{state_path || '(none)'}"
# end

# --- Log when each download part completes ---
# S3Client.on(:download_part_complete) do |pn, total, tid, bytes, ms, speed|
#   puts "  [DL] #{tid} ✓ part #{pn}/#{total} " \
#        "size=#{bytes / 1024 / 1024} MB speed=#{speed} MB/s time=#{ms.round(1)}ms"
# end

# --- Log on download retry ---
# S3Client.on(:download_part_retry) do |pn, tid, attempt, max, backoff, err|
#   $stderr.puts "  ⚠ [DL] #{tid} retry #{attempt}/#{max} part #{pn}: #{err.class} — backoff #{backoff.round(2)}s"
# end

# --- Notify on download complete / failure ---
# S3Client.on(:download_complete) do |result, elapsed, throughput|
#   puts "  🎉 Download completed #{result[:key]} (#{'%.1f' % throughput} MB/s in #{'%.1f' % elapsed}s)"
# end
#
# S3Client.on(:download_failed) do |err, state_path|
#   $stderr.puts "  ❌ Download failed: #{err.message}"
#   $stderr.puts "     State: #{state_path || '(none)'}"
# end

# ============================================================
# 17. Thread-safe logging — DO NOT use puts in worker threads
# ============================================================
#
# When writing callbacks or custom code running in worker threads,
# DO NOT use puts/print directly — output may interleave.
# Instead, use thread_log_*:

# S3Client.on(:part_start) do |pn, total, tid, offset, length|
#   # Wrong (interleaved output):
#   #   puts "#{tid} is uploading part #{pn}"
#   #
#   # Correct (thread-safe):
#   client.thread_log_info("custom: starting part #{pn} (#{length} bytes)", tid)
# end
#
# # API:
# #   client.thread_log_info(msg, tid)
# #   client.thread_log_debug(msg, tid)
# #   client.thread_log_warn(msg, tid)
# #   client.thread_log_error(msg, tid)
# #
# # Main thread drain:
#   #   client.drain_thread_logs           # forward to the instance's logger
#   #   S3Client.drain_logs(my_logger)     # forward to any logger
#   #
#   # Output format (after drain):
#   #   [2026-06-03 16:38:50.914] INFO -- [thread:t0] [S3] custom: starting part 5 (10485760 bytes)

# ============================================================
# 18. Centralized logging via :log event (Graylog / Loki / UDP)
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
# 19. Debug state file after crash — inspect before resuming
# ============================================================
#
# Useful when the process is kill -9'd or power is lost: the state file may
# still have `in_progress_parts` (parts that were being uploaded) — inspect
# to determine which parts need to be re-uploaded.

# if File.exist?('upload-state.json')
#   state = S3Client::UploadState.from_file('upload-state.json')
#
#   puts "=== State file inspection ==="
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
#   puts "  In-progress parts (from previous crash):"
#   puts "    #{state.in_progress_parts.inspect}"
#   puts "  Pending parts (#{state.pending_part_numbers.size}):"
#   puts "    #{state.pending_part_numbers.size <= 50 ? state.pending_part_numbers.inspect : '(too long, see state file)'}"
#   puts
#   puts "  Thread states:"
#   state.thread_states.each do |tid, info|
#     puts "    #{tid}: status=#{info[:status]} " \
#          "current_part=#{info[:current_part] || 'none'} " \
#          "parts_done=#{(info[:parts_done] || []).size} " \
#          "native_tid=#{info[:native_thread_id] || '?'}"
#   end
#
#   # Check file MD5 before resuming
#   if state.file_md5 && File.exist?(state.local_path)
#     require 'digest'
#     current_md5 = Digest::MD5.file(state.local_path).hexdigest
#     if current_md5 == state.file_md5
#     puts "\n  ✓ File MD5 matches — safe to resume"
#     else
#       puts "\n  ✗ File MD5 MISMATCH (expected #{state.file_md5}, got #{current_md5})"
#       puts "    File has changed — client will automatically abort & re-upload from scratch."
#     end
#   end
# end

# ============================================================
# 20. Complete example: upload with full observability
# ============================================================

# # 1. Register callbacks
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
#   puts "  🎉 Completed #{result[:key]} (#{'%.1f' % throughput} MB/s in #{'%.1f' % elapsed}s)"
# }
#
# # 2. Create client with DEBUG file logger
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
# puts "  Elapsed: #{'%.2f' % result[:elapsed]}s"
