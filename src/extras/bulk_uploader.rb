# frozen_string_literal: true

#
# extras/bulk_uploader.rb
#
# Parallel bulk upload of a local directory to S3.
# Delegates directory scanning to DirectoryScanner and per-file upload
# to BulkUploadWorker. This class orchestrates the thread pool and callbacks.
#

require_relative "directory_scanner"
require_relative "bulk_upload_worker"

class S3BulkUploader
  DEFAULT_PATTERN      = "**/*"
  DEFAULT_MAX_FILES    = 4
  DEFAULT_MULTIPART_THRESHOLD = 100 * 1024 * 1024
  FATAL_UPLOAD_PATTERNS = %w[QuotaReached AccessDenied Forbidden].freeze

  attr_reader :client, :directory, :prefix

  def initialize(client:, directory:, prefix: "",
                 bucket: nil,
                 pattern: DEFAULT_PATTERN,
                 exclude: [],
                 max_files: DEFAULT_MAX_FILES,
                 multipart_threshold: DEFAULT_MULTIPART_THRESHOLD,
                 on_file_start: nil,
                 on_file_complete: nil,
                 on_file_error: nil,
                 content_type: nil,
                 metadata: {},
                 cache_control: nil,
                 skip_existing: true,
                 resume: true,
                 state_dir: nil,
                 client_factory: nil)
    @client              = client
    @directory           = File.expand_path(directory)
    @prefix              = DirectoryScanner.new(directory, prefix: prefix).prefix
    @bucket              = bucket
    @pattern             = pattern
    @exclude             = Array(exclude)
    @max_files           = max_files.to_i.clamp(1, S3BaseClient::MAXIMUM_CONCURRENCY)
    @multipart_threshold = multipart_threshold
    @on_file_start       = on_file_start
    @on_file_complete    = on_file_complete
    @on_file_error       = on_file_error
    @content_type        = content_type
    @metadata            = metadata
    @cache_control       = cache_control
    @skip_existing       = skip_existing
    @resume              = resume
    @state_dir           = state_dir ? File.expand_path(state_dir) : nil
    @client_factory = client_factory
    unless @client_factory
      @client.log_warn "[BULK] No client_factory provided — sharing a single client across threads " \
                       "(not recommended for thread safety)"
    end
    FileUtils.mkdir_p(@state_dir) if @state_dir

    @scanner = DirectoryScanner.new(directory, prefix: prefix, pattern: pattern, exclude: exclude)
    @worker  = BulkUploadWorker.new(
      client: client, bucket: bucket,
      multipart_threshold: multipart_threshold,
      content_type: content_type, metadata: metadata,
      cache_control: cache_control,
      state_dir: @state_dir, skip_existing: skip_existing,
      resume: @resume
    )
  end

  def run!
    raise Errno::ENOENT, @directory unless File.directory?(@directory)

    files = @scanner.scan
    return build_empty_result if files.empty?

    files, dup_skipped = @scanner.deduplicate(files)
    return build_result(files, [], [], dup_skipped, 0) if files.empty?

    existing_map = @skip_existing ? fetch_existing_objects : {}

    t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    uploaded, failed, skipped = upload_files_parallel(files, dup_skipped, existing_map)
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0

    build_result(files, uploaded, failed, skipped, elapsed)
  end

  private

  def fetch_existing_objects
    @client.log_info "[BULK] Fetching existing objects from S3 (prefix: #{@prefix.inspect})..."
    t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)

    opts = { delimiter: nil, max_keys: 1000, paginate: true }
    opts[:prefix] = @prefix if @prefix && !@prefix.empty?
    opts[:bucket] = @bucket if @bucket

    result = @client.list_objects(**opts)
    map = {}
    result[:contents].each do |obj|
      map[obj[:key]] = { size: obj[:size], etag: obj[:etag] }
    end

    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0
    @client.log_info "[BULK] Fetched #{map.size} existing objects in #{elapsed.round(2)}s"
    map
  rescue S3Errors::S3Error => e
    raise if e.code.to_s.start_with?("404")

    @client.log_info "[BULK] Could not list existing objects (#{e.message}), falling back to per-file checks"
    nil
  end

  def upload_files_parallel(files, initial_skipped, existing_map)
    uploaded = []
    failed   = []
    skipped  = initial_skipped.dup
    mutex    = Mutex.new
    queue    = Queue.new
    total    = files.size
    index_counter = 0
    index_mutex   = Mutex.new
    stop_flag     = [false]
    stop_mutex    = Mutex.new
    fatal_logged  = [false]

    files.each { |f| queue << f }

    threads = @max_files.times.map do |thread_idx|
      Thread.new do
        tc = @client_factory ? @client_factory.call(thread_idx) : @client
        while (file = pop_from_queue(queue))
          break if stop_mutex.synchronize { stop_flag[0] }

          idx = index_mutex.synchronize { index_counter += 1 }
          process_one_file(file, tc, idx, total, mutex, uploaded, failed, skipped, stop_mutex, stop_flag, fatal_logged, existing_map)
        end
      end
    end

    threads.each(&:join)
    [uploaded, failed, skipped]
  end

  def process_one_file(file, tc, idx, total, mutex, uploaded, failed, skipped, stop_mutex, stop_flag, fatal_logged, existing_map)
    if (skip_entry = @worker.skip_check(file, thread_client: tc, existing_map: existing_map))
      tc.log_info "[BULK] SKIP #{file[:key]}: #{skip_entry[:reason]}"
      mutex.synchronize { skipped << skip_entry }
      return
    end

    @on_file_start&.call(file[:path], file[:key], idx, total)

    result = @worker.upload(file, thread_client: tc)

    mutex.synchronize { uploaded << result }
    @on_file_complete&.call(file[:path], file[:key], result, idx, total)
  rescue S3BaseClient::UploadError, StandardError => e
    handle_upload_error(e, file, tc, idx, total, mutex, failed, stop_mutex, stop_flag, fatal_logged)
  end

  def fatal_upload_error?(error)
    msg = error.message.to_s
    FATAL_UPLOAD_PATTERNS.any? { |pat| msg.include?(pat) }
  end

  def handle_upload_error(e, file, tc, idx, total, mutex, failed, stop_mutex, stop_flag, fatal_logged)
    entry = { path: file[:path], key: file[:key], error: e.message }
    mutex.synchronize { failed << entry }
    @on_file_error&.call(file[:path], file[:key], e, idx, total)
    return unless fatal_upload_error?(e)

    unless fatal_logged[0]
      tc.log_error "[BULK] Fatal error (#{e.message}) — aborting remaining uploads."
      fatal_logged[0] = true
    end
    stop_mutex.synchronize { stop_flag[0] = true }
  end

  def pop_from_queue(queue)
    queue.pop(true)
  rescue ThreadError
    nil
  end

  def build_empty_result
    {
      uploaded: [], failed: [], skipped: [],
      total_files: 0, total_bytes: 0,
      elapsed: 0, throughput: 0
    }
  end

  def build_result(files, uploaded, failed, skipped, elapsed)
    total_bytes = uploaded.sum { |r| r[:size] || 0 }
    throughput = elapsed.positive? ? (total_bytes.to_f / 1024 / 1024 / elapsed) : 0

    {
      uploaded: uploaded,
      failed: failed,
      skipped: skipped,
      total_files: files.size,
      total_bytes: total_bytes,
      elapsed: elapsed,
      throughput: throughput.round(2)
    }
  end
end
