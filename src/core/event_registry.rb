# frozen_string_literal: true

#
# core/event_registry.rb
#
# Shared module for class-level event callback registry.
# Extend into S3Client and S3MultiBucketClient so each class gets its own
# isolated set of callbacks, log queue, and mutex.
#
# Supported events (both clients share the same event names):
#   :upload_start       (local_path, key, size, total_parts, part_size, resumed)
#   :upload_resume      (state)
#   :part_start         (part_number, total_parts, thread_id, offset, length)
#   :part_retry         (part_number, thread_id, attempt, max_retries, backoff, error)
#   :part_complete      (part_number, total_parts, thread_id, etag, bytes, elapsed_ms, throughput)
#   :part_failed        (part_number, thread_id, error, exhausted)
#   :state_save         (state_snapshot, completed_count, total_parts, thread_id)
#   :state_load         (state, path)
#   :state_mismatch     (old_state, new_key, new_size)
#   :upload_complete    (result, elapsed, throughput)
#   :upload_failed      (error, state_preserved_path)
#   :thread_start       (thread_id, thread_object_id)
#   :thread_finish      (thread_id, thread_object_id, parts_processed)
#   :log                (level, message, thread_id, timestamp)
#   :download_start         (key, total_size, total_parts, part_size, resumed)
#   :download_part_start    (part_number, total_parts, thread_id, offset, length)
#   :download_part_complete (part_number, total_parts, thread_id, bytes, elapsed_ms, throughput)
#   :download_part_retry    (part_number, thread_id, attempt, max_retries, backoff, error)
#   :download_part_failed   (part_number, thread_id, error)
#   :download_complete      (result, elapsed, throughput)
#   :download_failed        (error, state_file_path)

module S3EventRegistry
  # Set up per-class instance variables when the module is extended.
  #
  # @param mod [Class] the extending class (e.g. S3Client)
  # @return [void]
  def self.extended(mod)
    mod.instance_variable_set(:@event_callbacks, Hash.new { |h, k| h[k] = [] })
    mod.instance_variable_set(:@log_queue,       Queue.new)
    mod.instance_variable_set(:@registry_mutex,  Mutex.new)
  end

  # @return [Hash{Symbol => Array<Proc>}] registered event callbacks
  attr_reader :event_callbacks

  # @return [Queue] thread-safe log message queue
  attr_reader :log_queue

  # @return [Mutex] mutex protecting the callback registry
  attr_reader :registry_mutex

  # Register a callback for a specific event.
  #
  # @param event  [Symbol] the event name (e.g. :part_complete)
  # @param block  [Proc] the callback block
  #
  # @raise [ArgumentError] if no block is given
  #
  # @return [Proc] the registered callback (for later use with #off)
  #
  # @example Register a part completion callback
  #   S3Client.on(:part_complete) { |pn, total, tid, ...| puts "..." }
  def on(event, &block)
    raise ArgumentError, "block required" unless block

    @registry_mutex.synchronize { @event_callbacks[event.to_sym] << block }
    block
  end

  # Unregister a previously registered callback.
  #
  # @param event    [Symbol] the event name
  # @param callback [Proc] the callback returned from #on
  # @return [void]
  def off(event, callback)
    @registry_mutex.synchronize { @event_callbacks[event.to_sym].delete(callback) }
  end

  # Clear all registered callbacks (useful for tests).
  #
  # @return [void]
  def clear_callbacks!
    @registry_mutex.synchronize { @event_callbacks.clear }
  end

  # Drain queued log messages from worker threads and forward to a logger.
  #
  # Non-blocking: returns immediately when queue is empty.
  # The logger's own formatter adds the timestamp/severity; we only prefix [thread:tid].
  #
  # @param logger [Logger, nil] the logger instance (nil suppresses output)
  # @return [Integer] number of messages drained
  def drain_logs(logger)
    count = 0
    loop do
      entry = @log_queue.pop(true)
      level, msg, tid, _ts = entry
      tagged = "[thread:#{tid}] [S3] #{msg}"
      case level
      when :debug then logger&.debug(tagged)
      when :info then logger&.info(tagged)
      when :warn  then logger&.warn(tagged)
      when :error then logger&.error(tagged)
      end
      count += 1
    end
  rescue ThreadError
    # Queue empty — normal termination
    count
  end
end
