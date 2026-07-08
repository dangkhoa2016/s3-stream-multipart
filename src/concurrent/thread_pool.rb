# frozen_string_literal: true

#
# concurrent/thread_pool.rb
#
# S3ThreadPool — shared thread pool lifecycle for parallel upload/download.
# Provides thread creation with HTTP connection, shutdown-safe join, and
# per-part processing via a block.
#
# Locking: pending_mutex is a local variable guarding the pending_list queue.
# It is never held while calling into user code (process_part block runs
# outside the synchronize block).
#
# Include in S3ParallelUploader and S3ParallelDownloader.
# Requires: register_thread, safe_native_thread_id, on_thread_start,
#   on_thread_finish, finish_thread, thread_id, open_http_connection,
#   build_sample_uri, @client (or self for logging)

module S3ThreadPool
  def create_thread_pool(concurrency, pending_parts, &process_part)
    @shutdown = false
    pending_list = pending_parts.dup
    pending_mutex = Mutex.new

    concurrency.times.map do |i|
      Thread.new do
        Thread.current.report_on_exception = false
        tid = thread_id(i)
        Thread.current[:s3_tid] = tid
        parts_done = 0
        native_tid = safe_native_thread_id
        register_thread(tid, native_tid)

        logger = @client || self
        logger.log_debug "  #{tid} started (object_id=#{Thread.current.object_id}, native=#{native_tid || 'N/A'})"
        on_thread_start(tid, nil)

        begin
          open_http_connection_for_thread(tid) do |http|
            on_before_thread_loop(tid, http) if respond_to?(:on_before_thread_loop)

            loop do
              break if @shutdown

              part_num = nil
              pending_mutex.synchronize { part_num = pending_list.shift }
              break unless part_num

              parts_done += 1 if process_part.call(tid, http, part_num, parts_done + 1)
            end
          end
        rescue Interrupt
          # Graceful shutdown on interrupt
        ensure
          finish_thread(tid, parts_done)
          on_thread_finish(tid, parts_done)
        end
      end
    end
  end

  def join_threads(thread_pool)
    # :nocov:
    thread_pool.each(&:join)
  rescue Interrupt
    @shutdown = true
    yield if block_given?
    thread_pool.each do |t|
      t.run
    rescue StandardError
      nil
    end
    thread_pool.each(&:join)
    raise
    # :nocov:
  end

  def open_http_connection_for_thread(tid)
    sample_uri = build_sample_uri
    open_http_connection(sample_uri) { |http| yield http }
  end

  def build_sample_uri
    nil
  end

  def mark_part_done(part_num, tid, parts_done_count)
  end
end
