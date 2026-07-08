# frozen_string_literal: true

#
# concurrent/thread_tracking.rb
#
# S3ThreadTracking — shared thread state tracking for parallel upload workers.
# Manages per-thread status, part in-progress tracking, and lifecycle events.
#
# Include in S3ParallelUploader (or any class with @tracking_mtx,
# @in_progress_parts, @thread_states, @client).
#
# Provides identical tracking logic used by PartUploader.

module S3ThreadTracking
  # Safely retrieve the native thread ID of the current thread.
  #
  # @return [Integer, nil] the native thread ID, or nil if unavailable
  def safe_native_thread_id
    Thread.current.native_thread_id
  rescue StandardError
    nil
  end

  # Register a new thread in the tracking system.
  #
  # @param tid        [String] logical thread identifier
  # @param native_tid [Integer, nil] native OS thread ID
  # @return [void]
  def register_thread(tid, native_tid)
    @tracking_mtx.synchronize do
      @thread_states[tid] = {
        status: "started", current_part: nil, parts_done: [],
        started_at: @client.now_iso, parts_count: 0,
        thread_object_id: Thread.current.object_id,
        native_thread_id: native_tid
      }
    end
  end

  # Mark a part as in-progress for a given thread.
  #
  # @param part_num [Integer] the part number
  # @param tid      [String] logical thread identifier
  # @return [void]
  def mark_part_in_progress(part_num, tid)
    @tracking_mtx.synchronize do
      @in_progress_parts[part_num] = tid
      @thread_states[tid][:status] = "uploading"
      @thread_states[tid][:current_part] = part_num
    end
  end

  # Mark a part as failed for a given thread.
  #
  # @param part_num [Integer] the part number
  # @param tid      [String] logical thread identifier
  # @return [void]
  def mark_part_error(part_num, tid)
    @tracking_mtx.synchronize do
      @in_progress_parts.delete(part_num)
      @thread_states[tid][:status] = "error"
    end
  end

  # Mark a thread as finished.
  #
  # @param tid              [String] logical thread identifier
  # @param parts_done_count [Integer] number of parts processed by this thread
  # @return [void]
  def finish_thread(tid, parts_done_count)
    @tracking_mtx.synchronize do
      @thread_states[tid][:status] = "finished"
      @thread_states[tid][:finished_at] = @client.now_iso
    end
    logger = respond_to?(:log_debug) ? self : @client
    logger.log_debug "  #{tid} finished (#{parts_done_count} parts processed)"
  end

  # Update tracking after a part completes: remove from in-progress set
  # and record the part in the thread's completed list.
  #
  # @param part_number     [Integer] the part number
  # @param tid             [String]  logical thread identifier
  # @param parts_done_count [Integer] total parts completed by this thread
end
