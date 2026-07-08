# frozen_string_literal: true

#
# concurrent/parallel_uploader.rb
#
# S3ParallelUploader — base class for parallel multipart upload workers.
# Handles thread pool creation, work distribution, progress tracking,
# interrupt handling, and error collection.
#
# Locking order (all independent — no nesting):
#   @mutex         — @completed_count, report_part_progress
#   @rename_mutex  — atomic rename via UploadStateManager
#   @save_batch_mtx — @parts_since_save
#   @tracking_mtx  — @in_progress_parts, @thread_states (from S3ThreadTracking)
#
# Subclasses must implement:
#   - upload_part_with_retry(part_number, http, tid) → etag
#   - save_state_after_part(part_number, etag, tid)
#   - open_http_connection(sample_uri) → yields Net::HTTP (or nil if not needed)
#   - build_result → final result (e.g. part_list or e_tag_list)
#   - log_prefix → string prefix for log messages (e.g. "PartUploader")
#
# Optional overrides:
#   - on_thread_start(tid, http) — called after thread starts and HTTP is open
#   - on_thread_finish(tid, parts_done_count) — called in ensure block
#   - on_part_start(part_number, total_parts, tid, offset, length)
#   - on_part_complete(part_number, total_parts, tid, etag, length, part_ms, throughput)
#   - on_part_failed(part_number, tid, error)
#   - on_upload_complete
#   - on_before_thread_loop — called before entering the work loop inside each thread

require_relative "parallel_transfer"
require_relative "progress_tracker"

class S3ParallelUploader < S3ParallelTransfer
  include S3ProgressTracker

  def initialize(client, upload_state, max_threads:, max_retries:, retry_delay:,
                 on_progress: nil, state_file: nil,
                 state_save_frequency: PARALLEL_SAVE_FREQUENCY,
                 progress_callback: nil)
    super
  end

  # Main entry point: upload all pending parts in parallel.
  #
  # Builds a work queue from parts not yet marked as uploaded, spawns a thread
  # pool, distributes work, and collects results or errors.  On interrupt it
  # cooperatively shuts down all threads before re-raising.
  #
  # @return [Object] the value returned by #build_result (e.g. part_list or e_tag_list)
  # @raise  [S3BaseClient::UploadError] if any part uploads failed
  def upload_all!
    total_parts    = @state.total_parts
    uploaded_set   = @state.parts.keys.to_set(&:to_i)
    pending_parts  = (1..total_parts).reject { |n| uploaded_set.include?(n) }

    return build_result if pending_parts.empty?

    log_plan(total_parts, pending_parts, uploaded_set)
    emit_upload_start(uploaded_set)

    results = Array.new(total_parts)
    pre_fill_results(results, uploaded_set, total_parts)

    total_size     = @state.total_size
    upload_t0      = @client.now_mono
    emit_initial_progress(0, uploaded_set, total_size)

    errors       = []
    errors_mutex = Mutex.new

    thread_pool = create_thread_pool(total_parts, results,
                                     total_size, upload_t0,
                                     errors, errors_mutex,
                                     pending_parts)

    join_threads(thread_pool)

    raise_upload_errors(errors) unless errors.empty?

    @client.log_info "#{log_prefix}: all #{pending_parts.length} pending parts uploaded"
    on_upload_complete
    build_result
  end

  protected

  # --- Template methods (subclasses MUST implement) ---

  # Upload a single part with retry logic.
  #
  # @param part_number [Integer] the 1-based part number
  # @param http        [Net::HTTP, nil] the persistent HTTP connection (or nil)
  # @param tid         [String] the thread identifier (e.g. "t0")
  # @return [String] the ETag returned by S3 for the uploaded part
  def upload_part_with_retry(part_number, http, tid)
    raise NotImplementedError, "#{self.class}#upload_part_with_retry must be implemented"
  end

  # Persist state after a successful part upload.
  #
  # @param part_number [Integer] the 1-based part number
  # @param etag        [String]  the ETag returned by S3
  # @param tid         [String]  the thread identifier
  def save_state_after_part(part_number, etag, tid)
  end

  # Open a persistent HTTP connection for a worker thread.
  #
  # Subclasses must yield a connected Net::HTTP instance (or +nil+ when
  # the subclass manages connections differently).
  #
  # @param sample_uri [URI, nil] a representative URI to connect to
  # @yieldparam http [Net::HTTP, nil] the open connection
  def open_http_connection(sample_uri)
    yield nil
  end

  # Build the final result returned by #upload_all!.
  #
  # @return [Object] typically an Array of part hashes or an Array of ETag strings
  def build_result
    raise NotImplementedError, "#{self.class}#build_result must be implemented"
  end

  # Prefix for log messages.
  #
  # @return [String]
  def log_prefix
    "PartUploader"
  end

  # --- Template methods (subclasses MAY override) ---

  # Called after a worker thread starts.
  #
  # @param tid  [String]      the thread identifier
  # @param http [Net::HTTP, nil] the HTTP connection (or nil)
  def on_thread_start(tid, http)
    @client.emit_event(:thread_start, tid, Thread.current.object_id)
  end

  # Called in the +ensure+ block when a worker thread finishes.
  #
  # @param tid              [String]  the thread identifier
  # @param parts_done_count [Integer] number of parts uploaded by this thread
  def on_thread_finish(tid, parts_done_count)
    @client.emit_event(:thread_finish, tid, Thread.current.object_id, parts_done_count)
  end

  # Called immediately before uploading an individual part.
  #
  # @param part_number [Integer] the 1-based part number
  # @param total_parts [Integer] total number of parts for the upload
  # @param tid         [String]  the thread identifier
  # @param offset      [Integer] byte offset of this part in the file
  # @param length      [Integer] byte length of this part
  def on_part_start(part_number, total_parts, tid, offset, length)
    @client.emit_event(:part_start, part_number, total_parts, tid, offset, length)
  end

  # Called after a part is successfully uploaded.
  #
  # @param part_number [Integer] the 1-based part number
  # @param total_parts [Integer] total number of parts
  # @param tid         [String]  the thread identifier
  # @param etag        [String]  the S3 ETag
  # @param length      [Integer] byte length of the part
  # @param part_ms     [Float]   elapsed time for the upload in milliseconds
  # @param throughput  [Float]   throughput in MB/s for this single part
  def on_part_complete(part_number, total_parts, tid, etag, length, part_ms, throughput)
    @client.emit_event(:part_complete, part_number, total_parts, tid, etag, length, part_ms, throughput)
  end

  # Called when a part upload raises an exception.
  #
  # @param part_number [Integer] the 1-based part number
  # @param tid         [String]  the thread identifier
  # @param error       [StandardError] the exception that was raised
  def on_part_failed(part_number, tid, error)
    @client.emit_event(:part_failed, part_number, tid, error, false)
  end

  # Called once all pending parts have been uploaded successfully.
  def on_upload_complete
  end

  # Emit initial progress for parts that were already uploaded in a prior run.
  #
  # @param uploaded_bytes [Integer] total bytes already uploaded
  # @param uploaded_set   [Set<Integer>] set of part numbers already uploaded
  # @param total_size     [Integer] total file size in bytes
  def emit_initial_progress(uploaded_bytes, uploaded_set, total_size)
  end

  # Called once inside each worker thread before entering the work loop.
  #
  # @param tid  [String]      the thread identifier
  # @param http [Net::HTTP, nil] the HTTP connection (or nil)
  def on_before_thread_loop(tid, http)
  end

  # --- Helpers ---

  # Report part progress via the progress callback.
  def report_part_progress
  end

  private

  def log_plan(total_parts, pending_parts, uploaded_set)
    @client.log_info "[PLAN] total_parts=#{total_parts} pending=#{pending_parts.length} " \
                     "pre_uploaded=#{uploaded_set.size} concurrency=#{@max_threads} " \
                     "part_size=#{@client.human_readable_size(@state.part_size)}"
    @client.log_info "[PLAN] pending parts: #{pending_parts.inspect}" if pending_parts.length <= 50
  end

  def emit_upload_start(uploaded_set)
    @client.emit_event(:upload_start, file_path_for_event, @state.key, @state.total_size,
                       @state.total_parts, @state.part_size, uploaded_set.size.positive?)
  end

  def file_path_for_event
    @state.local_path
  end

  def pre_fill_results(results, uploaded_set, total_parts)
    (1..total_parts).each do |i|
      results[i - 1] = { part_number: i, etag: @state.parts[i] } if uploaded_set.include?(i)
    end
  end

  def create_thread_pool(total_parts, results,
                         total_size, upload_t0,
                         errors, errors_mutex,
                         pending_parts)
    super(@max_threads, pending_parts) do |tid, http, part_num, parts_done_count|
      offset, length = calculate_part_offset_and_length(part_num)
      byte_range = "#{offset}-#{offset + length - 1}"

      mark_part_in_progress(part_num, tid)

      @client.log_info "[PART START] #{tid} → part #{part_num}/#{total_parts} " \
                       "bytes=#{byte_range} size=#{@client.human_readable_size(length)} " \
                       "(#{((part_num.to_f / total_parts) * 100).round(1)}%)"
      on_part_start(part_num, total_parts, tid, offset, length)

      t_part = @client.now_mono
      begin
        etag = upload_part_with_retry(part_num, http, tid)

        part_ms = (@client.now_mono - t_part) * 1000
        part_throughput = part_ms.positive? ? (length.to_f / 1024 / 1024 / (part_ms / 1000)).round(2) : 0

        @mutex.synchronize { @completed_count += 1 }

        results[part_num - 1] = { part_number: part_num, etag: etag }

        log_part_complete(tid, part_num, total_parts, length, part_ms, part_throughput, etag,
                          total_size, upload_t0)
        on_part_complete(part_num, total_parts, tid, etag, length, part_ms, part_throughput)

        mark_part_done(part_num, tid, parts_done_count)
        save_state_after_part(part_num, etag, tid)
        @mutex.synchronize { report_part_progress }

        true
      rescue StandardError => e
        mark_part_error(part_num, tid)
        on_part_failed(part_num, tid, e)
        errors_mutex.synchronize { errors << { part: part_num, error: e.message } }
        @client.log_error "[PART FAILED] #{tid} part #{part_num}: #{e.class}: #{e.message}"
        false
      end
    end
  end

  def thread_id(index) = "t#{index}"

  def raise_upload_errors(errors)
    raise S3BaseClient::UploadError,
          "Failed to upload #{errors.length} parts: #{errors.map { |e| "Part #{e[:part]}: #{e[:error]}" }.join(', ')}"
  end
end
