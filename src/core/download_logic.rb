# frozen_string_literal: true

module S3DownloadLogic
  include S3Errors

  def normalize_download_opts(local_path: nil, destination_path: nil,
                              on_progress: nil)
    path = destination_path || local_path
    raise ArgumentError, "missing keyword: destination_path or local_path" unless path

    [File.expand_path(path), on_progress]
  end

  def log_download_start(key, destination_path, headers)
    range_str = headers["Range"] || "full"
    log_info "download_file start: key=#{key.inspect} -> #{destination_path.inspect} " \
             "range=#{range_str}"
  end

  def log_download_complete(key, destination_path, written, t0)
    elapsed = now_mono - t0
    throughput = elapsed.positive? ? (written.to_f / 1024 / 1024 / elapsed) : 0
    log_info "download_file completed: key=#{key.inspect} bytes=#{written} " \
             "(#{human_readable_size(written)}) #{format_progress(elapsed, throughput)}"
    { elapsed: elapsed, throughput: throughput }
  end

  def with_download_error_handling
    yield
  rescue DownloadError, S3Error
    raise
  rescue StandardError => e
    log_error "download_file failed: #{e.message}"
    raise DownloadError, "Download failed: #{e.message}"
  end
end
