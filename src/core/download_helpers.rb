# frozen_string_literal: true

require_relative "constants"
require_relative "errors"

module S3DownloadHelpers
  include S3Constants
  include S3Errors

  PartPaths = Struct.new(:local_path, :part_path, :start_byte, keyword_init: true)

  def compute_download_paths(local_path, destination_path, resume: false)
    resolved = _resolve_download_path(local_path, destination_path)
    part_path = "#{resolved}.part"
    start_byte = resume && File.exist?(part_path) ? File.size(part_path) : 0
    PartPaths.new(local_path: resolved, part_path: part_path, start_byte: start_byte)
  end

  def rename_part_to_final(part_path, local_path)
    File.rename(part_path, local_path)
  end

  def build_download_file_result(key, bucket, local_path, size, resumed, elapsed: nil)
    _format_download_result(key, bucket, local_path, size, resumed, elapsed: elapsed)
  end

  def load_download_state(state_file, key:, part_size:, total_size:)
    return nil unless state_file && File.file?(state_file)

    loaded = DownloadState.from_file(state_file)
    if loaded.key == key && loaded.part_size == part_size && loaded.total_size == total_size
      loaded.resume_count = (loaded.resume_count || 0) + 1
      loaded.resumed_at = now_iso
      log_info "[DL STATE LOADED] progress=#{loaded.completed_parts_count}/#{loaded.total_parts} " \
               "resume_count=#{loaded.resume_count}"
      loaded
    else
      log_warn "[DL STATE MISMATCH] starting fresh"
      File.delete(state_file) if File.exist?(state_file)
      nil
    end
  rescue JSON::ParserError, Errno::ENOENT => e
    log_warn "[DL STATE LOAD FAILED] #{e.message}"
    nil
  end

  def setup_download_state(key, local_path, total_size, part_size, state_file, session_id, state_extra)
    state = load_download_state(state_file, key: key, part_size: part_size, total_size: total_size)
    state ||= DownloadState.new(
      { key: key, local_path: local_path, total_size: total_size,
        part_size: part_size, parts: {},
        started_at: now_iso,
        download_session_id: session_id }.merge(state_extra)
    )
    state.save_to_file(state_file) if state_file
    state
  end

  def build_part_downloader(state, output_file, max_threads:, max_retries:, retry_delay:,
                            on_progress:, state_file:, **downloader_opts)
    PartDownloader.new(
      self, state, output_file: output_file,
                   max_threads: max_threads,
                   max_retries: max_retries,
                   retry_delay: retry_delay,
                   on_progress: on_progress,
                   state_file: state_file,
                   **downloader_opts
    )
  end

  def stream_write_chunks(resp, part_path, mode, start_byte, on_progress)
    total = parse_content_range(resp)
    written = start_byte
    File.open(part_path, mode) do |file|
      resp.read_body do |chunk|
        file.write(chunk)
        written += chunk.bytesize
        on_progress&.call(written, total)
      end
    end
    written
  end

  def stream_single_bucket_download(key, paths, on_progress)
    log_info "download start: key=#{key.inspect} -> #{paths.local_path.inspect}"
    t0 = now_mono

    headers = build_resume_headers(paths.start_byte)
    mode = paths.start_byte.positive? ? "ab" : "wb"

    written = perform_request(:get, key, headers: headers, streaming: true) do |resp|
      log_debug "download: status=#{resp.code} " \
                "content_range=#{resp['Content-Range'].inspect} " \
                "total=#{parse_content_range(resp).inspect}"
      stream_write_chunks(resp, paths.part_path, mode, paths.start_byte, on_progress)
    end

    elapsed = now_mono - t0
    throughput = elapsed.positive? ? (written.to_f / 1024 / 1024 / elapsed) : 0
    elapsed_info = paths.start_byte.positive? ? " (resumed from #{paths.start_byte})" : ""
    log_info "download completed: #{paths.local_path.inspect} " \
             "#{human_readable_size(written)}#{elapsed_info} " \
             "#{format_progress(elapsed, throughput)}"
    written
  end

  def stream_multi_bucket_download(key, bucket, paths, on_progress)
    uri = build_uri(resolve_bucket(bucket), key)
    headers = build_resume_headers(paths.start_byte)

    log_info "download start: key=#{key.inspect} -> #{paths.local_path.inspect}"
    t0 = now_mono

    mode = paths.start_byte.positive? ? "ab" : "wb"
    written = nil

    retry_with_backoff(max_retries: @max_retries,
                       context: "download #{key}") do
      make_http_request(uri) do |http|
        request = Net::HTTP::Get.new(uri)
        headers.each { |k, v| request[k] = v }
        request['Content-Length'] = '0'
        sign_request!(request, 'GET', uri, nil)

        http.request(request) do |response|
          case response
          when Net::HTTPSuccess, Net::HTTPPartialContent
            log_debug "download: status=#{response.code} " \
                      "total=#{parse_content_range(response).inspect}"
            written = stream_write_chunks(response, paths.part_path, mode, paths.start_byte, on_progress)
          else
            raise DownloadError, "Download failed: #{response.code} #{response.message}"
          end
        end
      end
    end

    elapsed = now_mono - t0
    throughput = elapsed.positive? ? (written.to_f / 1024 / 1024 / elapsed) : 0
    elapsed_info = paths.start_byte.positive? ? " (resumed from #{paths.start_byte})" : ""
    log_info "download completed: #{paths.local_path.inspect} " \
             "#{human_readable_size(written)}#{elapsed_info} " \
             "#{format_progress(elapsed, throughput)}"
    written
  end

  def download_stream(key:, bucket: nil, range: nil)
    raise ArgumentError, "block required" unless block_given?

    log_info "download_stream start: key=#{key.inspect} " \
             "range=#{range ? "#{range.first}-#{range.last}" : 'full'}"
    t0 = now_mono

    headers = {}
    headers["Range"] = "bytes=#{range.first}-#{range.last}" if range

    written = _stream_download(key, bucket: bucket, headers: headers) { |chunk| yield chunk }

    elapsed = now_mono - t0
    log_info "download_stream completed: key=#{key.inspect} bytes=#{written} " \
             "elapsed=#{format_elapsed(elapsed)}s"
    written
  end

  def run_parallel_download(
    key:, local_path:, total_size:, part_size:, max_threads:, max_retries:,
    retry_delay:, on_progress:, state_file:,
    state_extra: {}, result_extra: {}, downloader_opts: {}
  )
    log_info "download start: key=#{key.inspect} -> #{local_path.inspect} " \
             "part_size=#{human_readable_size(part_size)} max_threads=#{max_threads}"
    t0 = now_mono

    total_parts = total_size.positive? ? (total_size.to_f / part_size).ceil : 0
    session_id = SecureRandom.hex(8)

    log_info "download: total_size=#{human_readable_size(total_size)} " \
             "total_parts=#{total_parts} session=#{session_id}"

    state = setup_download_state(key, local_path, total_size, part_size, state_file, session_id, state_extra)

    FileUtils.mkdir_p(File.dirname(local_path))

    emit_event(:download_start, key, total_size, total_parts, part_size, state.parts.size.positive?)

    File.open(local_path, 'wb') do |output_file|
      output_file.truncate(total_size) if total_size.positive?

      downloader = build_part_downloader(
        state, output_file,
        max_threads: max_threads,
        max_retries: max_retries,
        retry_delay: retry_delay,
        on_progress: on_progress,
        state_file: state_file,
        **downloader_opts
      )

      downloader.download_all!
    end

    state.completed = true
    state.completed_at = now_iso
    state.last_updated_at = state.completed_at
    state.save_to_file(state_file) if state_file
    File.delete(state_file) if state_file && File.exist?(state_file)

    elapsed = now_mono - t0
    throughput = elapsed.positive? ? (total_size.to_f / 1024 / 1024 / elapsed) : 0
    result = ::S3BaseClient::DownloadResult.new(
      path: local_path, size: total_size, elapsed: elapsed,
      throughput: throughput,
      extra: { key: key, destination: local_path,
               parts_downloaded: state.completed_parts_count,
               session_id: session_id }.merge(result_extra)
    )
    log_info "[DOWNLOAD COMPLETE] key=#{key.inspect} parts=#{state.completed_parts_count} " \
             "#{format_progress(elapsed, throughput)}"
    emit_event(:download_complete, result.to_h, elapsed, throughput)
    result
  rescue StandardError => e
    log_error "download failed: #{e.class}: #{e.message}"
    emit_event(:download_failed, e, state_file)
    raise
  end
end
