# frozen_string_literal: true

#
# concurrent/parallel_downloader.rb
#
# S3ParallelDownloader — base class for parallel download workers.
# Mirrors S3ParallelUploader's architecture: thread pool, work distribution,
# progress tracking, interrupt handling, and error collection.
#
# Locking order (all independent — no nesting):
#   @mutex         — @completed_count
#   @rename_mutex  — atomic rename via DownloadStateManager
#   @save_batch_mtx — @parts_since_save
#   @tracking_mtx  — @in_progress_parts, @thread_states (from S3ThreadTracking)
#
# Subclasses must implement:
#   - download_part_with_retry(part_hash, http, tid) → tempfile path
#   - open_http_connection(sample_uri) → yields Net::HTTP (or nil)
#   - build_result → final result string (e.g. merged file path)
#   - log_prefix → string prefix for log messages (e.g. "PartDownloader")

require_relative "parallel_transfer"

class S3ParallelDownloader < S3ParallelTransfer
  def initialize(client, download_state, output_file = nil, max_threads:, max_retries:, retry_delay:,
                 on_progress: nil, state_file: nil,
                 state_save_frequency: PARALLEL_SAVE_FREQUENCY,
                 progress_callback: nil)
    super(client, download_state,
          max_threads: max_threads, max_retries: max_retries,
          retry_delay: retry_delay, on_progress: on_progress || progress_callback,
          state_file: state_file, state_save_frequency: state_save_frequency)
    @output_file = output_file
  end

  # Main entry point: download all pending parts in parallel.
  #
  # Builds a work queue from parts not yet marked as downloaded, spawns a
  # thread pool, distributes work, and collects results or errors.  On
  # interrupt it cooperatively shuts down all threads before re-raising.
  #
  # @return [String] the value returned by #build_result (e.g. merged file path)
  # @raise  [S3BaseClient::DownloadError] if any part downloads failed
  def download_all!
    total_parts      = @state.total_parts
    downloaded_set   = @state.parts.keys.to_set(&:to_i)
    pending_parts    = (1..total_parts).reject { |n| downloaded_set.include?(n) }

    return build_result if pending_parts.empty?

    @client.log_info "[PLAN] total_parts=#{total_parts} pending=#{pending_parts.length} " \
                     "pre_downloaded=#{downloaded_set.size} concurrency=#{@max_threads} " \
                     "part_size=#{@client.human_readable_size(@state.part_size)}"

    results = Array.new(total_parts)
    pre_fill_results(results, downloaded_set, total_parts)

    progress_mtx = Mutex.new
    downloaded_bytes = calculate_pre_downloaded_bytes(downloaded_set)
    total_size       = @state.total_size
    download_t0      = @client.now_mono
    pct = total_size.positive? ? (downloaded_bytes.to_f / total_size * 100).round(2) : 0
    @progress_callback&.call(downloaded_bytes, total_size, pct)

    errors       = []
    errors_mutex = Mutex.new

    thread_pool = create_thread_pool(total_parts, results, progress_mtx,
                                     downloaded_bytes, total_size, download_t0,
                                     errors, errors_mutex,
                                     pending_parts)

    join_threads(thread_pool)

    raise_download_errors(errors) unless errors.empty?

    @client.log_info "PartDownloader: all #{pending_parts.length} pending parts downloaded"
    build_result
  end

  protected

  # Upload a single part with retry logic.
  #
  # @param part_number [Integer] the 1-based part number
  # @param http        [Net::HTTP, nil] the persistent HTTP connection (or nil)
  # @param tid         [String] the thread identifier (e.g. "t0")
  # @return [String] path to the downloaded tempfile
  def download_part_with_retry(*_args)
    raise NotImplementedError, "#{self.class}#download_part_with_retry must be implemented"
  end

  # Open a persistent HTTP connection for a worker thread.
  #
  # Subclasses must yield a connected Net::HTTP instance (or +nil+ when
  # the subclass manages connections differently).
  #
  # @param sample_uri [URI, nil] a representative URI to connect to
  # @yieldparam http [Net::HTTP, nil] the open connection
  # :nocov:
  def open_http_connection(sample_uri)
    yield nil
  end

  def build_result
    raise NotImplementedError, "#{self.class}#build_result must be implemented"
  end
  # :nocov:

  # Prefix for log messages.
  #
  # @return [String]
  def log_prefix
    "PartDownloader"
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
  # @param parts_done_count [Integer] number of parts downloaded by this thread
  def on_thread_finish(tid, parts_done_count)
    @client.emit_event(:thread_finish, tid, Thread.current.object_id, parts_done_count)
  end

  # Called immediately before downloading an individual part.
  #
  # @param part_number [Integer] the 1-based part number
  # @param total_parts [Integer] total number of parts for the download
  # @param tid         [String]  the thread identifier
  # @param offset      [Integer] byte offset of this part
  # @param length      [Integer] byte length of this part
  def on_part_start(part_number, total_parts, tid, offset, length)
    @client.emit_event(:download_part_start, part_number, total_parts, tid, offset, length)
  end

  # Called after a part is successfully downloaded.
  #
  # @param part_number [Integer] the 1-based part number
  # @param total_parts [Integer] total number of parts
  # @param tid         [String]  the thread identifier
  # @param etag        [String]  the S3 ETag (or tempfile path)
  # @param length      [Integer] byte length of the part
  # @param part_ms     [Float]   elapsed time in milliseconds
  # @param throughput  [Float]   throughput in MB/s
  def on_part_complete(part_number, total_parts, tid, etag, length, part_ms, throughput)
    @client.emit_event(:download_part_complete, part_number, total_parts, tid, etag, length, part_ms, throughput)
  end

  # Called when a part download raises an exception.
  #
  # @param part_number [Integer] the 1-based part number
  # @param tid         [String]  the thread identifier
  # @param error       [StandardError] the exception that was raised
  def on_part_failed(part_number, tid, error)
    @client.emit_event(:download_part_failed, part_number, tid, error)
  end

  # Called once all pending parts have been downloaded successfully.
  def on_download_complete
  end

  def save_state_after_part(_part_number, _bytes_written, _tid)
  end

  # @param downloaded_set [Set<Integer>] set of downloaded part numbers
  # @return [Integer] total bytes already downloaded
  # :nocov:
  def calculate_pre_downloaded_bytes(downloaded_set)
    downloaded_set.sum do |i|
      offset = (i - 1) * @state.part_size
      [@state.part_size, @state.total_size - offset].compact.min
    end
  end
  # :nocov:

  # Invoke the optional progress callback with the given byte counts.
  #
  # @param downloaded_bytes [Integer] bytes downloaded so far
  # @param total_size       [Integer] total file size in bytes
  # :nocov:
  def progress_callback_bytes(downloaded_bytes, total_size)
    @progress_callback&.call(downloaded_bytes, total_size)
  end
  # :nocov:

  # Report part progress via the progress callback.
  #
  # Subclasses override to call #progress_callback_bytes with the
  # current aggregated byte count.
  def report_part_progress
  end

  private

  def pre_fill_results(results, downloaded_set, total_parts)
    (1..total_parts).each do |i|
      results[i - 1] = { part_number: i, tempfile: @state.parts[i] } if downloaded_set.include?(i)
    end
  end

  def create_thread_pool(total_parts, results, progress_mtx,
                         downloaded_bytes, total_size, upload_t0,
                         errors, errors_mutex,
                         pending_parts)
    super(@max_threads, pending_parts) do |tid, http, part_num, parts_done_count|
      offset, length = calculate_part_offset_and_length(part_num)
      end_byte = offset + length - 1
      mark_part_in_progress(part_num, tid)

      @client.log_debug "[PART START] #{tid} → part #{part_num}/#{total_parts} " \
                        "bytes=#{offset}-#{end_byte}"
      on_part_start(part_num, total_parts, tid, offset, length)

      t_part = @client.now_mono
      begin
        tempfile = download_part_with_retry(part_num, offset, end_byte, length, http, tid)

        part_ms = (@client.now_mono - t_part) * 1000
        part_throughput = part_ms.positive? ? (length.to_f / 1024 / 1024 / (part_ms / 1000)).round(2) : 0

        @mutex.synchronize { @completed_count += 1 }

        results[part_num - 1] = { part_number: part_num, tempfile: tempfile }

        @client.log_debug "[PART DONE]  #{tid} ✓ part #{part_num}/#{total_parts} " \
                          "size=#{@client.human_readable_size(length)} " \
                          "time=#{part_ms.round(1)}ms speed=#{part_throughput} MB/s"
        on_part_complete(part_num, total_parts, tid, tempfile, length, part_ms, part_throughput)

        mark_part_done(part_num, tid, parts_done_count)

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

  def raise_download_errors(errors)
    raise S3BaseClient::DownloadError,
          "Failed to download #{errors.length} parts: #{errors.map { |e| "Part #{e[:part]}: #{e[:error]}" }.join(', ')}"
  end
end
