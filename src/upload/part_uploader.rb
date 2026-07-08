# frozen_string_literal: true

#
# upload/part_uploader.rb
#
# PartUploader — standalone, client-agnostic class for parallel multipart
# uploads.  Works with any S3 client that responds to:
#
#   upload_transport.upload_part(bucket, key, part_number, upload_id, chunk, headers, http) -> etag
#   sse_headers                                         -> Hash
#   emit_event(name, *args)
#   log_debug / log_info / log_error (message)
#   now_mono                                            -> Float
#   human_readable_size(bytes)                          -> String
#

require_relative "../concurrent/parallel_uploader"

class PartUploader < S3ParallelUploader
  def initialize(client, upload_state, max_retries:, retry_delay:, max_threads: nil,
                 on_progress: nil, state_file: nil,
                 state_save_frequency: PARALLEL_SAVE_FREQUENCY,
                 local_path: nil, total_size: nil,
                 max_concurrency: nil)
    super(client, upload_state,
      max_threads: max_threads || max_concurrency,
      max_retries: max_retries,
      retry_delay: retry_delay,
      on_progress: on_progress,
      state_file: state_file,
      state_save_frequency: state_save_frequency)
  end

  protected

  def upload_part_with_retry(part_number, http, tid)
    retry_with_backoff(
      max_retries: @max_retries, backoff_base: @retry_delay,
      client: @client, context: "Part #{part_number}",
      on_retry: lambda { |attempt, max, delay, e|
        @client.emit_event(:part_retry, part_number, tid, attempt, max, delay, e)
      }
    ) do
      etag = upload_part_http(part_number, http)
      @mutex.synchronize do
        @state.parts[part_number] = etag unless @state.parts.key?(part_number)
      end
      etag
    end
  end

  def open_http_connection(_sample_uri = nil)
    yield nil
  end

  def build_result
    @state.e_tag_list
  end

  def emit_initial_progress(uploaded_bytes, uploaded_set, total_size)
    return unless @progress_callback

    completed = uploaded_set.size
    return unless completed.positive?

    total_parts = @state.total_parts
    pct = total_parts.positive? ? (completed.to_f / total_parts * 100).round(2) : 0
    @progress_callback.call(completed, total_parts, pct)
  end

  def report_part_progress
    return unless @progress_callback

    completed = @state.parts.size
    total_parts = @state.total_parts
    pct = total_parts.positive? ? (completed.to_f / total_parts * 100).round(2) : 0
    @progress_callback.call(completed, total_parts, pct)
  end

  def save_state_after_part(part_number, etag, tid)
    return unless @state_file

    @state.last_updated_at = @client.now_iso
    @state.last_part_completed_at = @client.now_iso
    @state.in_progress_parts = @in_progress_parts.dup
    @state.thread_states = @thread_states.each_with_object({}) { |(k, v), h| h[k] = v.merge(parts_done: v[:parts_done].dup) }

    should_save = @save_batch_mtx.synchronize do
      @parts_since_save += 1
      @parts_since_save >= @state_save_frequency
    end

    return unless should_save || part_number == @state.total_parts

    @save_batch_mtx.synchronize { @parts_since_save = 0 }
    @rename_mutex.synchronize do
      @state.save_to_file(@state_file)
    end
    @client.log_debug "[STATE SAVED] #{@state_file}: #{@state.completed_parts_count}/#{@state.total_parts} parts " \
                      "(#{@state.progress_percentage}%)"
    @client.emit_event(:state_save, @state.to_h, @state.completed_parts_count, @state.total_parts, tid) if @state_file
  end

  def mark_part_done(part_num, tid, parts_done_count)
    @tracking_mtx.synchronize do
      @in_progress_parts.delete(part_num)
      @thread_states[tid][:current_part] = nil
      @thread_states[tid][:parts_done] << part_num
      @thread_states[tid][:parts_count] = parts_done_count
      @thread_states[tid][:status] = "idle"
    end
  end

  private

  def upload_part_http(part_number, http)
    offset, length = calculate_part_offset_and_length(part_number)

    File.open(@state.local_path, 'rb') do |file|
      chunk = file.pread(length, offset)
      @client.upload_transport.upload_part(@state.bucket, @state.key, part_number,
                                           @state.upload_id, chunk, @client.sse_headers, http)
    end
  rescue EOFError
    @client.upload_transport.upload_part(@state.bucket, @state.key, part_number,
                                         @state.upload_id, nil, @client.sse_headers, http)
  end
end
