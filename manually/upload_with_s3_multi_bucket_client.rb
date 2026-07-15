require_relative '../src/s3_multi_bucket_client'
require 'fileutils'
require 'logger'


# Validate required environment variables
required_vars = %w[S3_ENDPOINT S3_REGION S3_BUCKET S3_ACCESS_KEY_ID S3_SECRET_ACCESS_KEY LOCAL_FILE_PATH S3_OBJECT_KEY]
missing_vars = required_vars.reject { |v| ENV[v] && !ENV[v].empty? }

if missing_vars.any?
  puts "ERROR: Missing required environment variables:"
  missing_vars.each { |v| puts "  - #{v}" }
  puts ""
  puts "Please set these variables before running the script."
  exit 1
end

# Log file configuration
log_file = ENV['S3_LOG_FILE'] || File.join(__dir__, 'upload_with_s3_multi_bucket_client.log')
# Default DEBUG to log maximum detail to file
debug_mode = ENV.fetch('S3_DEBUG', 'true') == 'true'

# Validate file exists
unless File.file?(ENV['LOCAL_FILE_PATH'])
  puts "ERROR: File not found: #{ENV['LOCAL_FILE_PATH']}"
  exit 1
end

local_path = File.expand_path(ENV['LOCAL_FILE_PATH'])
file_size  = File.size(local_path)

# ============================================================
# Setup 2 logger:
#   - file_logger: DEBUG level, lưu MỌI chi tiết ra file log
#   - console_logger: INFO level, in ra màn hình các thông điệp quan trọng
# ============================================================

file_logger = Logger.new(log_file)
file_logger.level = Logger::DEBUG
file_logger.formatter = proc do |severity, datetime, _progname, msg|
  "[#{datetime.strftime('%Y-%m-%d %H:%M:%S.%L')}] #{severity.ljust(5)} -- #{msg}\n"
end

console_logger = Logger.new($stdout)
console_logger.level = Logger::INFO
console_logger.formatter = proc do |severity, datetime, _progname, msg|
  ts   = "\e[32m[#{datetime.strftime('%H:%M:%S')}]\e[0m"
  lvl  = case severity
         when "INFO"  then "\e[34m#{severity.ljust(5)}\e[0m"
         when "WARN"  then "\e[33m#{severity.ljust(5)}\e[0m"
         when "ERROR", "FATAL" then "\e[31m#{severity.ljust(5)}\e[0m"
         else "\e[2m#{severity.ljust(5)}\e[0m"
         end
  colored_msg = msg.to_s.sub(/\[S3\]\s*(.+?)(?=:\s|\s→|\s—|$)/) do
    action = $1
    "[S3] \e[2m#{action}\e[0m"
  end
  "#{ts} #{lvl} #{colored_msg}\n"
end

# Multi-logger: forwards to both file and console.
# S3MultiBucketClient.setup_logger always calls logger.formatter= and logger.level= when
# receiving an external logger. If forwarded to inner loggers, it would override
# each logger's formatter/level. -> Make it no-op here.
class MultiLogger
  def initialize(*loggers)
    @loggers = loggers
    @level   = loggers.map(&:level).min || Logger::INFO
    @formatter = loggers.first&.formatter
  end

  %i[debug info warn error fatal].each do |m|
    define_method(m) { |msg = nil, &block| @loggers.each { |l| l.send(m, msg, &block) } }
  end

  def level=(lvl);     @level = lvl; end
  def level;           @level;       end
  def formatter=(fmt); @formatter = fmt; end
  def formatter;       @formatter; end
end

combined_logger = MultiLogger.new(file_logger, console_logger)

# ============================================================
# ANSI color helpers cho console output
# ============================================================
module C
  def self.r(s); "\e[31m#{s}\e[0m"; end  # red
  def self.g(s); "\e[32m#{s}\e[0m"; end  # green
  def self.y(s); "\e[33m#{s}\e[0m"; end  # yellow
  def self.b(s); "\e[34m#{s}\e[0m"; end  # blue
  def self.m(s); "\e[35m#{s}\e[0m"; end  # magenta
  def self.c(s); "\e[36m#{s}\e[0m"; end  # cyan
  def self.bold(s); "\e[1m#{s}\e[0m"; end
end

# ============================================================
# Human-readable size helper
# ============================================================
def hr_size(bytes)
  return "0 B" if bytes.nil? || bytes.zero?
  units = %w[B KB MB GB TB PB]
  exp   = [(Math.log(bytes.to_f) / Math.log(1024)).to_i, units.size - 1].min
  format("%.2f %s", bytes.to_f / (1024**exp), units[exp])
end

# ============================================================
# Show log file path (config already displayed by upload.sh)
# ============================================================
puts "Log file: #{log_file}"
puts ""

# ============================================================
# Global stats collector — used by multiple callbacks
# ============================================================
stats = {
  parts_done:     0,
  total_parts:    0,
  bytes_uploaded: 0,
  total_bytes:    file_size,
  t0:             nil,
  retries:        Hash.new(0),      # {part_number => retry_count}
  thread_stats:   Hash.new { |h, k| h[k] = { parts: 0, bytes: 0 } },
  session_id:     nil,
  resumed:        false,
  resumed_from:   0
}

PART_SIZE   = (ENV['S3_PART_SIZE_MB'] || '8').to_i * 1024 * 1024
MAX_THREADS = (ENV['S3_MAX_THREADS'] || '4').to_i
MAX_RETRIES = (ENV['S3_MAX_RETRIES'] || '3').to_i

begin
  puts C.bold("Initializing S3MultiBucketClient...")

  client = S3MultiBucketClient.new(
    endpoint:          ENV['S3_ENDPOINT'],
    region:            ENV['S3_REGION'],
    access_key_id:     ENV['S3_ACCESS_KEY_ID'],
    secret_access_key: ENV['S3_SECRET_ACCESS_KEY'],
    session_token:     ENV['S3_SESSION_TOKEN'],
    logger:            combined_logger,
    debug:             debug_mode
  )

  puts C.g("✓ S3MultiBucketClient initialized")
  puts ""

  # ==========================================================
  # Register event callbacks — print to console with colors + log details via client.log_*
  # ==========================================================

  # --- :upload_start ---
  S3MultiBucketClient.on(:upload_start) do |fp, key, size, total_parts, part_size, resumed|
    stats[:t0] = Time.now
    stats[:total_parts] = total_parts
    stats[:total_bytes] = size
    stats[:resumed] = resumed
    mode = resumed ? C.y("RESUME") : C.g("FRESH")
    puts C.bold("╔═══ Upload #{mode} started ═══")
    puts "║ key:        #{key}"
    puts "║ bucket:     #{ENV['S3_BUCKET']}"
    puts "║ size:       #{hr_size(size)} (#{total_parts} parts × #{hr_size(part_size)})"
    puts "║ threads:    #{MAX_THREADS}"
    puts "╚" + "═" * 40
    client.log_info("[CALLBACK] upload_start: key=#{key} bucket=#{ENV['S3_BUCKET']} size=#{size} total_parts=#{total_parts} resumed=#{resumed}")
  end

  # --- :upload_resume ---
  S3MultiBucketClient.on(:upload_resume) do |state|
    state_hash = state.is_a?(Hash) ? state : state.to_h
    total_parts = (state_hash[:total_size].to_f / state_hash[:part_size]).ceil
    parts = state_hash[:parts]
    done = parts.is_a?(Array) ? parts.size : parts.size
    pending = total_parts - done
    stats[:resumed_from] = done
    in_progress = (state_hash[:in_progress_parts] || {}).keys.sort
    puts C.bold("📂 Resume from state:")
    puts "   session:      #{state_hash[:upload_session_id]}"
    puts "   upload_id:    #{state_hash[:upload_id].to_s[0, 24]}..."
    puts "   progress:     #{done}/#{total_parts} parts (#{hr_size(done * state_hash[:part_size])}/#{hr_size(state_hash[:total_size])})"
    puts "   pending:      #{pending} parts"
    puts "   in_progress:  #{in_progress.inspect}  (from previous crash)"
    puts "   resume_count: #{state_hash[:resume_count]}"
    puts "   file_md5:     #{state_hash[:file_md5] || 'N/A'}"
    puts "   started_at:   #{state_hash[:started_at]}"
    puts "   last_updated: #{state_hash[:last_updated_at]}"
    client.log_info("[CALLBACK] upload_resume: session=#{state_hash[:upload_session_id]} done=#{done}/#{total_parts} pending=#{pending} in_progress=#{in_progress.inspect}")
  end

  # --- :thread_start / :thread_finish ---
  S3MultiBucketClient.on(:thread_start) do |tid, oid|
    client.log_debug("[CALLBACK] thread_start: #{tid} object_id=#{oid}")
  end

  S3MultiBucketClient.on(:thread_finish) do |tid, oid, count|
    puts "   ■ #{tid} finished (#{count} parts)"
    client.log_info("[CALLBACK] thread_finish: #{tid} object_id=#{oid} parts_processed=#{count}")
  end

  # --- :part_start (only log at DEBUG — too noisy for INFO) ---
  S3MultiBucketClient.on(:part_start) do |pn, total, tid, offset, length|
    client.log_debug("[CALLBACK] part_start: #{tid} → part #{pn}/#{total} offset=#{offset} length=#{length}")
  end

  # --- :part_complete ---
  S3MultiBucketClient.on(:part_complete) do |pn, total, tid, etag, bytes, ms, speed|
    stats[:parts_done] += 1
    stats[:bytes_uploaded] += bytes
    stats[:thread_stats][tid][:parts] += 1
    stats[:thread_stats][tid][:bytes] += bytes
    stats[:retries].delete(pn)

    elapsed = stats[:t0] ? Time.now - stats[:t0] : 0
    pct = stats[:bytes_uploaded].to_f / stats[:total_bytes] * 100
    throughput = elapsed.positive? ? stats[:bytes_uploaded].to_f / elapsed / 1024 / 1024 : 0
    eta = throughput.positive? ? (stats[:total_bytes] - stats[:bytes_uploaded]) / (throughput * 1024 * 1024) : 0

    puts "  ✓ #{C.c(tid)} part #{C.bold(pn)}/#{total} " \
         "#{hr_size(bytes)} " \
         "#{format('%.1f', ms)}ms @ #{C.g(format('%.2f', speed))} MB/s " \
         "| #{C.y(format('%.1f', pct))}% " \
         "avg=#{format('%.2f', throughput)} MB/s " \
         "ETA=#{C.b(format('%ds', eta.round))}"

    client.log_info("[CALLBACK] #{C.m('part_complete')}: #{tid} part=#{pn}/#{total} bytes=#{bytes} " \
                    "time=#{ms.round(1)}ms speed=#{speed} MB/s etag=#{etag.to_s[0, 20].inspect} " \
                    "progress=#{format('%.2f', pct)}% avg=#{format('%.2f', throughput)} MB/s ETA=#{format('%.1f', eta)}s")
  end

  # --- :part_retry ---
  S3MultiBucketClient.on(:part_retry) do |pn, tid, attempt, max, backoff, err|
    stats[:retries][pn] += 1
    puts "  #{C.y("⚠")} #{C.c(tid)} retry #{attempt}/#{max} part #{pn}: " \
         "#{err.class}: #{err.message[0, 80]} — backoff #{backoff}s"
    client.log_warn("[CALLBACK] part_retry: #{tid} part=#{pn} attempt=#{attempt}/#{max} " \
                    "backoff=#{backoff}s error=#{err.class}: #{err.message}")
  end

  # --- :part_failed ---
  S3MultiBucketClient.on(:part_failed) do |pn, tid, err, exhausted|
    if exhausted
      puts "  #{C.r("✗")} #{C.c(tid)} FAIL part #{pn}: #{err.class}: #{err.message[0, 80]}"
      client.log_error("[CALLBACK] part_failed (exhausted): #{tid} part=#{pn} #{err.class}: #{err.message}")
    else
      client.log_warn("[CALLBACK] part_failed (will retry): #{tid} part=#{pn} #{err.class}: #{err.message}")
    end
  end

  # --- :state_save ---
  S3MultiBucketClient.on(:state_save) do |snapshot, completed, total, tid|
    state_hash = snapshot.is_a?(Hash) ? snapshot : snapshot.to_h
    in_prog = (state_hash[:in_progress_parts] || {}).keys.sort
    client.log_debug("[CALLBACK] state_save: #{completed}/#{total} parts in_progress=#{in_prog.inspect} tid=#{tid}")
  end

  # --- :state_load ---
  S3MultiBucketClient.on(:state_load) do |state, path|
    state_hash = state.is_a?(Hash) ? state : state.to_h
    parts = state_hash[:parts]
    parts_count = parts.is_a?(Array) ? parts.size : parts.size
    total = (state_hash[:total_size].to_f / state_hash[:part_size]).ceil
    puts C.bold("📥 Loaded state: #{path}")
    puts "   upload_id: #{state_hash[:upload_id].to_s[0, 24]}..."
    puts "   session:   #{state_hash[:upload_session_id] || 'N/A'}"
    puts "   parts:     #{parts_count} / #{total}"
    client.log_info("[CALLBACK] state_load: path=#{path} upload_id=#{state_hash[:upload_id]} parts=#{parts_count}")
  end

  # --- :state_mismatch ---
  S3MultiBucketClient.on(:state_mismatch) do |old_state, new_key, new_size|
    old_hash = old_state.is_a?(Hash) ? old_state : old_state.to_h
    puts C.r("⚠ STATE MISMATCH — aborting old upload")
    puts "   Old: key=#{old_hash[:key].inspect} size=#{old_hash[:total_size]} session=#{old_hash[:upload_session_id]}"
    puts "   New: key=#{new_key.inspect} size=#{new_size}"
    client.log_warn("[CALLBACK] state_mismatch: old_upload_id=#{old_hash[:upload_id]} " \
                    "old_key=#{old_hash[:key].inspect} new_key=#{new_key.inspect}")
  end

  # --- :upload_complete ---
  S3MultiBucketClient.on(:upload_complete) do |result, elapsed, throughput|
    elapsed_total = stats[:t0] ? Time.now - stats[:t0] : elapsed
    puts ""
    puts C.bold(C.g("╔═══ Upload COMPLETE ═══"))
    puts "║ key:        #{result[:key]}"
    puts "║ bucket:     #{ENV['S3_BUCKET']}"
    puts "║ upload_id:  #{result[:upload_id]}"
    puts "║ parts:      #{result[:parts_uploaded]}"
    puts "║ size:       #{hr_size(result[:size])}"
    puts "║ elapsed:    #{format('%.3f', elapsed_total)}s"
    puts "║ throughput: #{C.g(format('%.2f MB/s', throughput))}"
    puts "║ session:    #{result[:session_id] || stats[:session_id]}"
    if stats[:resumed]
      puts "║ resumed_from: #{stats[:resumed_from]} parts"
    end
    puts "╚" + "═" * 40

    # Thread summary
    puts ""
    puts C.bold("Thread stats:")
    stats[:thread_stats].sort.each do |tid, info|
      puts "   #{tid}: #{info[:parts]} parts, #{hr_size(info[:bytes])}"
    end

    # Retry summary
    if stats[:retries].any?
      puts ""
      puts C.bold("Retry summary:")
      puts "   #{stats[:retries].size} parts had retries"
      puts "   total retry attempts: #{stats[:retries].values.sum}"
    end

    client.log_info("[CALLBACK] upload_complete: key=#{result[:key]} bucket=#{ENV['S3_BUCKET']} " \
                    "parts=#{result[:parts_uploaded]} elapsed=#{format('%.3f', elapsed_total)}s " \
                    "throughput=#{format('%.2f', throughput)} MB/s session=#{result[:session_id]}")
  end

  # --- :upload_failed ---
  S3MultiBucketClient.on(:upload_failed) do |err, state_path|
    puts ""
    puts C.bold(C.r("╔═══ Upload FAILED ═══"))
    puts "║ error:  #{err.class}: #{err.message[0, 120]}"
    puts "║ state:  #{state_path ? "preserved at #{state_path}" : 'not preserved'}"
    if stats[:parts_done].positive?
      puts "║ progress: #{stats[:parts_done]}/#{stats[:total_parts]} parts before failure"
    end
    puts "╚" + "═" * 40
    client.log_error("[CALLBACK] upload_failed: #{err.class}: #{err.message} state=#{state_path}")
  end

  # --- :log (custom log from worker threads) ---
  S3MultiBucketClient.on(:log) do |level, msg, tid, ts|
    client.log_debug("[CALLBACK:log] level=#{level} thread=#{tid} msg=#{msg}")
  end

  puts C.g("✓ #{S3MultiBucketClient.event_callbacks.values.map(&:size).sum} event callbacks registered")
  puts ""

  # ==========================================================
  # Pre-upload: inspect state file if exists (useful for resume)
  # ==========================================================
  state_file_path = File.join(__dir__, 'upload-streaming-state.json')
  if File.exist?(state_file_path)
    begin
      saved = S3MultiBucketClient::UploadState.from_file(state_file_path)
      puts C.bold("🔍 Existing state file detected:")
      puts "   path:           #{state_file_path}"
      puts "   session:        #{saved.upload_session_id || 'N/A'}"
      puts "   upload_id:      #{saved.upload_id ? saved.upload_id[0, 24] + '...' : 'N/A'}"
      puts "   progress:       #{saved.summary}"
      puts "   started_at:     #{saved.started_at || 'N/A'}"
      puts "   last_updated:   #{saved.last_updated_at || 'N/A'}"
      puts "   resume_count:   #{saved.resume_count}"
      puts "   file_md5:       #{saved.file_md5 || 'N/A'}"
      puts "   completed:      #{saved.part_list.map { |p| p[:part_number] }.inspect}"
      in_prog = saved.in_progress_part_numbers
      puts "   in_progress:    #{in_prog.inspect}  #{C.y('(will be re-uploaded)') if in_prog.any?}"
      puts "   pending:        #{saved.pending_part_numbers.size} parts"
      if saved.thread_states.any?
        puts "   threads (crash):"
        saved.thread_states.each do |tid, info|
          puts "     #{tid}: status=#{info[:status]} current=#{info[:current_part] || 'none'} done=#{(info[:parts_done] || []).size}"
        end
      end

      # Verify MD5
      if saved.file_md5
        require 'digest'
        current_md5 = Digest::MD5.file(local_path).hexdigest rescue nil
        if current_md5
          if current_md5 == saved.file_md5
            puts "   ✓ File MD5 matches — safe to resume"
          else
            puts C.r("   ✗ File MD5 MISMATCH (expected #{saved.file_md5}, got #{current_md5})")
            puts "     Client will start a fresh upload."
          end
        end
      end
      puts ""
    rescue => e
      puts C.r("  ⚠ Could not inspect state file: #{e.message}")
    end
  end

  # ==========================================================
  # Start upload
  # ==========================================================
  puts C.bold("Starting upload...")
  stats[:t0] = Time.now

  progress_cb = proc { |written, total|
    client.log_debug("[PROGRESS] #{written}/#{total} bytes")
  }

  result = client.upload_file(
    bucket:      ENV['S3_BUCKET'],
    key:         ENV['S3_OBJECT_KEY'],
    local_path:  ENV['LOCAL_FILE_PATH'],
    part_size:   PART_SIZE,
    max_threads: MAX_THREADS,
    max_retries: MAX_RETRIES,
    content_type: ENV['S3_CONTENT_TYPE'] || 'application/octet-stream',
    on_progress: progress_cb,
    state_file:  state_file_path
  )

  stats[:session_id] = result[:session_id]

  puts ""
  puts "=" * 70
  puts C.g("✓ Script finished successfully")
  puts "=" * 70
  puts "Result keys: #{result.to_h.keys.inspect}"
  puts "Full log: #{log_file}"
  puts ""

rescue S3MultiBucketClient::S3Error => e
  puts ""
  puts "=" * 70
  puts C.r("✗ S3 Error Occurred")
  puts "=" * 70
  puts "Error code:    #{e.code}"
  puts "Error message: #{e.message}"
  puts "Request ID:    #{e.request_id}"
  puts ""

  case e.code
  when 'InvalidAccessKeyId', 'SignatureDoesNotMatch'
    puts "AUTHENTICATION ERROR:"
    puts "  - Check your AWS Access Key ID and Secret Access Key"
    puts "  - Ensure the credentials are correct and not expired"
  when 'NoSuchBucket'
    puts "BUCKET ERROR:"
    puts "  - Bucket '#{ENV['S3_BUCKET']}' does not exist"
  when 'AccessDenied'
    puts "PERMISSION ERROR:"
    puts "  - IAM user does not have write permissions for this bucket"
  else
    puts "Check the full log for details: #{log_file}"
  end
  puts ""
  exit 1

rescue S3MultiBucketClient::UploadError => e
  puts ""
  puts "=" * 70
  puts C.r("✗ Upload Error")
  puts "=" * 70
  puts "Error: #{e.message}"
  puts "Full log: #{log_file}"
  exit 1

rescue Errno::ENOENT => e
  puts ""
  puts C.r("✗ File Not Found: #{e.message}")
  exit 1

rescue ArgumentError => e
  puts ""
  puts C.r("✗ Configuration Error: #{e.message}")
  exit 1

rescue => e
  puts ""
  puts "=" * 70
  puts C.r("✗ Unexpected Error")
  puts "=" * 70
  puts "Error class:   #{e.class}"
  puts "Error message: #{e.message}"
  puts "Backtrace:"
  puts e.backtrace[0..10].map { |l| "  #{l}" }.join("\n")
  puts ""
  puts "Full log: #{log_file}"
  exit 1
ensure
  S3MultiBucketClient.clear_callbacks!
end
