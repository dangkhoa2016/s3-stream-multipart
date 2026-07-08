# frozen_string_literal: true

#
# concurrent/progress_tracker.rb
#
# S3ProgressTracker — mixin providing ETA, throughput, and percentage
# calculations for parallel upload/download workers.
#
# Included by S3ParallelUploader and S3ParallelDownloader.
# Expects the host to define:
#   - @client          (has now_mono, human_readable_size, log_info, ...)
#   - @state           (has total_size, parts, part_size, bytes_uploaded)
#   - @progress_callback (optional proc)
#

module S3ProgressTracker
  # Calculate global throughput in MB/s.
  def global_throughput(bytes, elapsed_seconds)
    elapsed_seconds.positive? ? (bytes.to_f / elapsed_seconds / 1024 / 1024) : 0
  end

  # Calculate ETA in seconds from remaining bytes and throughput.
  def eta_seconds(remaining_bytes, throughput)
    throughput.positive? ? (remaining_bytes.to_f / (throughput * 1024 * 1024)) : 0
  end

  # Calculate progress percentage.
  def progress_pct(completed, total)
    total.positive? ? (completed.to_f / total * 100).round(2) : 0
  end

  # Sum the byte sizes of all already-transferred parts.
  def calculate_pre_transferred_bytes(completed_set)
    completed_set.sum do |i|
      offset = (i - 1) * @state.part_size
      [@state.part_size, @state.total_size - offset].compact.min
    end
  end

  # Current bytes transferred (uploaded or downloaded).
  def current_transferred_bytes
    @state.bytes_uploaded
  end

  # Build a structured progress log message for a completed part.
  def log_part_complete(tid, part_num, total_parts, length, part_ms, part_throughput, etag,
                        total_size, t0)
    transferred = current_transferred_bytes
    pct = progress_pct(transferred, total_size)
    elapsed = @client.now_mono - t0
    t_global = global_throughput(transferred, elapsed)
    remaining = total_size - transferred
    eta = eta_seconds(remaining, t_global)

    @client.log_info "[PART DONE]  #{tid} ✓ part #{part_num}/#{total_parts} " \
                     "size=#{@client.human_readable_size(length)} " \
                     "time=#{part_ms.round(1)}ms speed=#{part_throughput} MB/s " \
                     "etag=#{etag[0, 20].inspect} | " \
                     "progress=#{@client.human_readable_size(transferred)}/#{@client.human_readable_size(total_size)} (#{pct}%) " \
                     "avg=#{format('%.2f', t_global)} MB/s ETA=#{format('%.1f', eta)}s"
  end
end
