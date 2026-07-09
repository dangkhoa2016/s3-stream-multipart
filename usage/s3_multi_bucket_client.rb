# frozen_string_literal: true
# S3MultiBucketClient usage example (library: s3_multi_bucket_client.rb)
#
# This file demonstrates the full public API of S3MultiBucketClient, including:
#   - Basic operations: upload/download/delete/head/presign
#   - Resumable multipart upload via state_file + UploadState object
#   - Parallel download (multi-thread Range requests, resumable)
#   - SSE encryption (SSE-S3, SSE-KMS, SSE-C)
#   - Custom retry (max_retries, retry_delay, 429, jitter)
#   - Event callbacks (14+ events) for custom logging / progress / alerting
#   - Thread-safe logging from worker threads
#   - Debug state file after crash
#
# Each section includes explanatory comments; uncomment blocks to
# run them (requires credentials configured via ENV).

require_relative '../src/s3_multi_bucket_client'

# ============================================================
# 0. Client initialization
# ============================================================

# AWS S3:
client = S3MultiBucketClient.new(
  endpoint:          'https://s3.ap-southeast-1.amazonaws.com',
  region:            'ap-southeast-1',
  access_key_id:     ENV['S3_ACCESS_KEY_ID'],
  secret_access_key: ENV['S3_SECRET_ACCESS_KEY'],
  # logger:            Logger.new($stdout, level: Logger::INFO)
  # compute_md5:       false,                 # enable if file MD5 hash is needed (slow for large files)
  # max_retries:       3,                     # number of retries (default 3)
  # retry_delay:       0.25,                  # base delay for backoff (default 0.25s)
  # sse:               nil,                   # see SSE examples below
)

# MinIO / Cloudflare R2 / Backblaze B2:
# client = S3MultiBucketClient.new(
#   endpoint:          'https://minio.local:9000',
#   region:            'us-east-1',
#   access_key_id:     'minioadmin',
#   secret_access_key: 'minioadmin',
# )

# AWS STS (using temporary credentials):
# client = S3MultiBucketClient.new(
#   endpoint:          'https://s3.amazonaws.com',
#   region:            'us-east-1',
#   access_key_id:     ENV['S3_ACCESS_KEY_ID'],
#   secret_access_key: ENV['S3_SECRET_ACCESS_KEY'],
#   session_token:     ENV['AWS_SESSION_TOKEN'],
# )

# ============================================================
# 0a. SSE encryption — Server-Side Encryption
# ============================================================

# SSE-S3 (AWS manages keys):
# client_sse = S3MultiBucketClient.new(
#   ...,
#   sse: { type: 'AES256' }
# )

# SSE-KMS (using AWS KMS key):
# client_sse = S3MultiBucketClient.new(
#   ...,
#   sse: { type: 'aws:kms', kms_key_id: 'arn:aws:kms:us-east-1:123456:key/abc-...' }
# )

# SSE-C (Customer-provided key — send key on every request):
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
# 1. Upload small file (single PUT — streaming from disk)
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
# 2. Parallel multipart upload with progress callback
# ============================================================
#
# Sample output (INFO level):
#   [S3] upload_file_multipart start: "movie.mp4" -> key="videos/movie.mp4" size=361806224 (345.00 MB) part_size=8388608 (8.00 MB) total_parts=44 max_threads=4 state=- session=a5f8bf53ebadba22 md5=...
#   [S3] upload_file_multipart MULTIPART: key="videos/movie.mp4" total_parts=44 session=a5f8bf53ebadba22
#   [S3] [PLAN] total_parts=44 pending=44 pre_uploaded=0 concurrency=4 part_size=8.00 MB
#   [S3] [PART START] t0 → part 1/44 bytes=0-8388607 size=8.00 MB (11.4%)
#   ...
#   [S3] [PART DONE]  t0 ✓ part 1/44 size=8.00 MB time=2702.8ms speed=2.96 MB/s etag="378e5af6..." | progress=8.00 MB/345.00 MB (2.3%) avg=2.96 MB/s ETA=113.7s
#   [S3] [UPLOAD COMPLETE] key="videos/movie.mp4" parts=44 elapsed=59.375s throughput=5.81 MB/s session=a5f8bf53ebadba22

progress = proc { |completed, total, percent|
  puts "  Part #{completed}/#{total} (#{percent}%)"
}

# result = client.upload_file_multipart(
#   bucket:            'my-bucket',
#   key:               'videos/movie.mp4',
#   file_path:         '/path/to/large-movie.mp4',
#   part_size:         8 * 1024 * 1024,     # 8 MB per part
#   max_threads:       4,                    # 4 parallel threads
#   max_retries:       nil,                  # nil = use client's max_retries
#   retry_delay:       nil,                  # nil = use client's retry_delay
#   content_type:      'application/octet-stream',
#   metadata:          { 'user' => 'alice' },
#   cache_control:     'no-cache',
#   progress_callback: progress,
#   state_file:        'upload-state.json',  # save state after each part; auto-deleted on completion
#   raise_on_error:    false                 # true = raise exception instead of returning {error, state}
# )
#
# if result[:error]
#   puts "Upload failed: #{result[:error]}"
#   puts "State preserved — re-run to resume."
# else
#   puts "Upload completed: #{result[:parts_uploaded]} parts, #{'%.1f' % result[:throughput]} MB/s"
# end

# ============================================================
# 3. Resume upload after interruption
# ============================================================

# # Method 1: explicit resume_upload
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
# # Method 2: upload_file_multipart + UploadState object
# if File.exist?('upload-state.json')
#   saved_state = S3MultiBucketClient::UploadState.from_file('upload-state.json')
#   puts "Resume: #{saved_state.completed_parts_count}/#{saved_state.total_parts} parts completed"
#   client.upload_file_multipart(
#     bucket:            'my-bucket',
#     key:               'videos/movie.mp4',
#     file_path:         '/path/to/large-movie.mp4',
#     resume_state:      saved_state,
#     progress_callback: progress
#   )
# end

# ============================================================
# 4. Streaming download with progress
# ============================================================

# client.download_file(
#   bucket:            'my-bucket',
#   key:               'videos/movie.mp4',
#   destination_path:  '/path/to/downloaded-movie.mp4',
#   progress_callback: proc { |current, total, percent|
#     puts "  Downloaded: #{current}/#{total} bytes (#{percent}%)"
#   }
# )

# ============================================================
# 4a. Download with Range (partial file download)
# ============================================================

# # Download bytes 0 → 1MB-1 (first 1MB)
# client.download_file(
#   bucket:           'my-bucket',
#   key:              'videos/movie.mp4',
#   destination_path: '/path/to/partial.mp4',
#   range:            [0, 1024 * 1024 - 1]   # Array [start, end]
# )
#
# # Or use Ruby Range
# client.download_file(
#   bucket:           'my-bucket',
#   key:              'videos/movie.mp4',
#   destination_path: '/path/to/partial.mp4',
#   range:            0..(1024 * 1024 - 1)   # Range (inclusive)
# )

# ============================================================
# 4b. Parallel download (multi-threaded, faster for large files)
# ============================================================
#
# Split file into multiple parts, download in parallel via Range requests.
# Supports resume via state_file (similar to upload).

# result = client.download_file_parallel(
#   bucket:            'my-bucket',
#   key:               'videos/movie.mp4',
#   destination_path:  '/path/to/downloaded-movie.mp4',
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
# 5. Download resume (from incomplete .part file)
# ============================================================

# client.download_file_resume(
#   bucket:            'my-bucket',
#   key:               'videos/movie.mp4',
#   destination_path:  '/path/to/downloaded-movie.mp4',
#   progress_callback: proc { |current, total|
#     puts "  Resumed: #{current}/#{total} bytes"
#   }
# )

# ============================================================
# 6. Download stream (block-based, no disk write)
# ============================================================

# # Stream the entire file
# client.download_stream(bucket: 'my-bucket', key: 'videos/movie.mp4') do |chunk|
#   $stdout.write(chunk)   # or pipe into ZipInputStream, etc.
# end
#
# # Stream with Range (partial download)
# client.download_stream(
#   bucket: 'my-bucket', key: 'videos/movie.mp4',
#   range: (1_000_000..2_000_000)   # bytes 1M → 2M
# ) { |chunk| process(chunk) }

# ============================================================
# 7. HEAD object (retrieve metadata)
# ============================================================

# metadata = client.head_object(bucket: 'my-bucket', key: 'documents/report.pdf')
# puts "  Size:         #{metadata[:content_length]}"
# puts "  Content-Type: #{metadata[:content_type]}"
# puts "  ETag:         #{metadata[:etag]}"
# puts "  Last-Modified:#{metadata[:last_modified]}"
# puts "  Storage:      #{metadata[:storage_class]}"
# puts "  User meta:    #{metadata[:metadata].inspect}"

# ============================================================
# 8. Presigned URL
# ============================================================

# # GET URL (read file)
# url = client.presigned_url(
#   bucket: 'my-bucket', key: 'documents/report.pdf',
#   method: :get, expires_in: 3600
# )
# puts "  Download URL: #{url}"
#
# # PUT URL (upload file)
# url = client.presigned_url(
#   bucket: 'my-bucket', key: 'uploads/new.bin',
#   method: :put, expires_in: 600
# )
# puts "  Upload URL: #{url}"
#
# # With additional query params (e.g. response-content-disposition)
# url = client.presigned_url(
#   bucket: 'my-bucket', key: 'documents/report.pdf',
#   method: :get, expires_in: 3600,
#   query: { 'response-content-disposition' => 'attachment; filename="report.pdf"' }
# )
# puts "  Force-download URL: #{url}"

# ============================================================
# 9. List in-progress multipart uploads on the bucket
# ============================================================

# client.list_multipart_uploads(bucket: 'my-bucket').each { |u|
#   puts "  #{u[:key]}: upload_id=#{u[:upload_id]} initiated=#{u[:initiated]}"
# }

# ============================================================
# 10. List parts of a multipart upload
# ============================================================

# client.list_parts(
#   bucket: 'my-bucket', key: 'videos/movie.mp4', upload_id: 'xxxxx'
# ).each { |p|
#   puts "  Part #{p[:part_number]}: etag=#{p[:etag]} size=#{p[:size]}"
# }

# ============================================================
# 11. Abort multipart upload
# ============================================================

# client.abort_multipart_upload(
#   bucket: 'my-bucket', key: 'videos/movie.mp4', upload_id: 'xxxxx'
# )

# ============================================================
# 12. Delete object
# ============================================================

# client.delete_object(bucket: 'my-bucket', key: 'old-file.txt')

# ============================================================
# 13. Low-level multipart API (manual lifecycle management)
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
# # Or abort:
# client.multipart_abort(
#   bucket: 'my-bucket', key: 'manual-upload.bin', upload_id: upload_id
# )

# ============================================================
# 14. S3Helper — convenient shortcuts
# ============================================================

# # Auto-detect single/multipart
# S3Helper.upload(
#   client: client, bucket: 'my-bucket',
#   key: 'data/large-file.bin', file_path: '/path/to/large-file.bin',
#   multipart_threshold: 100 * 1024 * 1024
# )
#
# # Download with progress bar
# S3Helper.download(
#   client: client, bucket: 'my-bucket',
#   key: 'data/large-file.bin', destination: '/path/to/downloaded.bin',
#   show_progress: true,
#   resume: true
# )
#
# # Parallel download (multi-thread)
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
#             ↓↓↓ NEW FEATURES: EVENT & LOGGING (for observability) ↓↓↓
#
# ============================================================
# ============================================================


# ============================================================
# 15. Event callbacks — lifecycle hooks with 14+ events
# ============================================================
#
# Callbacks are registered at the CLASS level (apply to every S3MultiBucketClient instance).
# A failing callback does NOT cause upload/download to fail — exceptions are caught & logged at WARN.
#
# List of UPLOAD events:
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
# List of DOWNLOAD events:
#   :download_start          (key, bucket, total_size, total_parts, part_size, resumed)
#   :download_part_start     (part_number, total_parts, thread_id, offset, length)
#   :download_part_complete  (part_number, total_parts, thread_id, bytes, elapsed_ms, throughput)
#   :download_part_retry     (part_number, thread_id, attempt, max_retries, backoff, error)
#   :download_part_failed    (part_number, thread_id, error)
#   :download_complete       (result, elapsed, throughput)
#   :download_failed         (error, state_file_path)
#
# Common events:
#   :thread_start      (thread_id, thread_object_id)
#   :thread_finish     (thread_id, thread_object_id, parts_processed)
#   :log               (level, message, thread_id, timestamp)

# --- 15a. Log when each part completes ---
# S3MultiBucketClient.on(:part_complete) do |pn, total, tid, etag, bytes, ms, speed|
#   puts "  [hook] #{tid} ✓ part #{pn}/#{total} " \
#        "size=#{bytes / 1024 / 1024} MB speed=#{speed} MB/s time=#{ms.round(1)}ms"
# end

# --- 15b. Log on retry ---
# S3MultiBucketClient.on(:part_retry) do |pn, tid, attempt, max, backoff, err|
#   $stderr.puts "  ⚠ #{tid} retry #{attempt}/#{max} part #{pn}: #{err.class} — backoff #{backoff}s"
# end

# --- 15c. Notify on upload complete / failure ---
# S3MultiBucketClient.on(:upload_complete) do |result, elapsed, throughput|
#   puts "  🎉 Completed #{result[:key]} (#{'%.1f' % throughput} MB/s in #{'%.1f' % elapsed}s)"
#   # notify_slack("Upload complete: #{result[:key]} (#{'%.1f' % throughput} MB/s)")
# end
#
# S3MultiBucketClient.on(:upload_failed) do |err, state_path|
#     $stderr.puts "  ❌ Upload failed: #{err.message}"
#   $stderr.puts "     State preserved at: #{state_path || '(none)'}"
#   # notify_pagerduty("Upload failed: #{err.message}, state=#{state_path}")
# end

# --- 15d. Log on resume / state mismatch ---
# S3MultiBucketClient.on(:upload_resume) do |state|
#   total_parts = (state[:total_size].to_f / state[:part_size]).ceil
#   parts_done = state[:parts].is_a?(Array) ? state[:parts].size : state[:parts].size
#   puts "  📂 Resume from state: #{parts_done}/#{total_parts} parts"
#   puts "     session=#{state[:upload_session_id]} resume_count=#{state[:resume_count]}"
# end
#
# S3MultiBucketClient.on(:state_load) do |state, path|
#   puts "  📥 Loaded state #{path}: upload_id=#{state[:upload_id]}"
# end
#
# S3MultiBucketClient.on(:state_mismatch) do |old_state, new_key, new_size|
#   $stderr.puts "  ⚠ State mismatch — aborting old upload id=#{old_state[:upload_id]}"
#   $stderr.puts "     Old key=#{old_state[:key].inspect}, New key=#{new_key.inspect} size=#{new_size}"
# end

# --- 15e. Worker thread lifecycle ---
# S3MultiBucketClient.on(:thread_start)  { |tid, oid| puts "  ▶ #{tid} started (object_id=#{oid})" }
# S3MultiBucketClient.on(:thread_finish) { |tid, oid, count| puts "  ■ #{tid} finished (#{count} parts)" }

# --- 15f. Remove callbacks ---
# cb = S3MultiBucketClient.on(:part_complete) { |*a| puts a.inspect }
# S3MultiBucketClient.off(:part_complete, cb)   # remove a specific callback
# S3MultiBucketClient.clear_callbacks!          # remove all callbacks

# ============================================================
# 16. Progress bar with event :part_complete
# ============================================================
#
# Use events instead of progress_callback to decouple UI from logic:

# require 'io/console'
# bar_width  = 40
# last_print = Time.at(0)
# parts_done = []
#
# S3MultiBucketClient.on(:part_complete) do |pn, total, _tid, _etag, _bytes, _ms, _speed|
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
# client.upload_file_multipart(
#   bucket: 'my-bucket', key: '/huge.bin',
#   file_path: '/path/to/huge.bin',
#   state_file: 'huge.upload.json'
# )

# ============================================================
# 17. Alert on excessive retries or permanent part failure
# ============================================================

# retry_counts = Hash.new(0)
#
# S3MultiBucketClient.on(:part_retry) do |pn, tid, attempt, max, backoff, err|
#   retry_counts[pn] += 1
#   if retry_counts[pn] >= max - 1
#     $stderr.puts "  🔔 Part #{pn} retry #{retry_counts[pn]} times — retries nearly exhausted"
#     # PagerDuty.alert("S3 part #{pn} retry #{retry_counts[pn]}x: #{err.class}")
#   end
# end
#
# S3MultiBucketClient.on(:part_complete) { |pn, *_| retry_counts.delete(pn) }
#
# S3MultiBucketClient.on(:part_failed) do |pn, tid, err, exhausted|
#   if exhausted
#     $stderr.puts "  🔥 Part #{pn} failed permanently: #{err.message}"
#     # PagerDuty.alert("S3 part #{pn} failed: #{err.message}")
#   end
# end

# ============================================================
# 18. Thread-safe logging — DO NOT use puts in worker threads
# ============================================================
#
# When writing callbacks or custom code running in worker threads,
# DO NOT use puts/print directly — output may interleave.
# Instead, use thread_log_*:

# S3MultiBucketClient.on(:part_start) do |pn, total, tid, offset, length|
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
#   #   S3MultiBucketClient.drain_logs(my_logger)     # forward to any logger
#   #
#   # Output format (after drain):
#   #   [2026-06-03 16:38:50.914] INFO -- [thread:t0] [S3] custom: starting part 5 (8388608 bytes)

# ============================================================
# 19. Centralized logging via :log event (Graylog / Loki / UDP)
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
# 20. Debug state file after crash — inspect before resuming
# ============================================================
#
# Useful when the process is kill -9'd or power is lost: the state file may
# still have `in_progress_parts` (parts that were being uploaded) — inspect
# to determine which parts need to be re-uploaded.

# if File.exist?('upload-state.json')
#   state = S3MultiBucketClient::UploadState.from_file('upload-state.json')
#
#   puts "=== State file inspection ==="
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
#   puts "  In-progress parts (from previous crash):"
#   puts "    #{state.in_progress_part_numbers.inspect}"
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
#   if state.file_md5 && File.exist?(state.file_path)
#     require 'digest'
#     current_md5 = Digest::MD5.file(state.file_path).hexdigest
#     if current_md5 == state.file_md5
#       puts "\n  ✓ File MD5 matches — safe to resume"
#     else
#       puts "\n  ✗ File MD5 MISMATCH (expected #{state.file_md5}, got #{current_md5})"
#       puts "    File has changed — delete state and re-upload from scratch."
#     end
#   end
# end

# ============================================================
# 21. Complete example: upload with full observability
# ============================================================

# # 1. Register callbacks
# S3MultiBucketClient.on(:part_complete) { |pn, total, tid, _etag, bytes, ms, speed|
#   puts "  ✓ #{tid} part #{pn}/#{total} #{bytes / 1024 / 1024} MB @ #{speed} MB/s"
# }
# S3MultiBucketClient.on(:part_retry) { |pn, tid, attempt, max, backoff, err|
#   $stderr.puts "  ⚠ #{tid} retry #{attempt}/#{max} part #{pn}: #{err.class}"
# }
# S3MultiBucketClient.on(:upload_resume) { |state|
#   parts = state[:parts].is_a?(Array) ? state[:parts].size : state[:parts].size
#   puts "  📂 Resume: #{parts} parts completed"
# }
# S3MultiBucketClient.on(:upload_complete) { |result, elapsed, throughput|
#   puts "  🎉 Completed #{result[:key]} (#{'%.1f' % throughput} MB/s in #{'%.1f' % elapsed}s)"
# }
#
# # 2. Create client with DEBUG file logger
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
#   puts "  Upload failed: #{result[:error]}"
# else
#   puts "  Parts:    #{result[:parts_uploaded]}"
#   puts "  Elapsed:  #{'%.2f' % result[:elapsed]}s"
#   puts "  Throughput: #{'%.2f' % result[:throughput]} MB/s"
# end

# ============================================================
# 22. Debug download state file — inspect parallel download progress
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
#   puts "    #{dl_state.pending_part_numbers.size <= 50 ? dl_state.pending_part_numbers.inspect : '(too long, see state file)'}"
# end
