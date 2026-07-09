# frozen_string_literal: true

class S3BaseClient
  # Downloads a single file via streaming GET.
  # Used by DownloadService for all download operations.
  class SinglePartDownload
    def initialize(client:, logger: nil)
      @client = client
      @logger = logger
    end

    def call(key:, destination_path:, range: nil, on_progress: nil, bucket: nil)
      headers = {}
      headers["Range"] = "bytes=#{range.first}-#{range.last}" if range

      @logger&.info "download_file: key=#{key.inspect} -> #{destination_path}"
      FileUtils.mkdir_p(File.dirname(destination_path))
      t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)

      written = with_download_error_handling do
        run_single_download(key, destination_path, headers, on_progress, bucket)
      end

      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0
      throughput = elapsed.positive? ? (written.to_f / 1024 / 1024 / elapsed) : 0.0
      @logger&.info "download complete: #{written} bytes in #{format('%.3f', elapsed)}s"

      S3BaseClient::DownloadResult.new(
        path: destination_path, size: written,
        elapsed: elapsed, throughput: throughput,
        extra: { key: key, destination: destination_path }
      )
    end

    private

    def with_download_error_handling
      yield
    rescue S3BaseClient::DownloadError, S3BaseClient::S3Error
      raise
    rescue StandardError => e
      @logger&.error "download_file failed: #{e.message}"
      raise S3BaseClient::DownloadError, "Download failed: #{e.message}"
    end

    def run_single_download(key, destination_path, headers, on_progress, bucket)
      written = 0
      File.open(destination_path, "wb") do |out|
        @client.perform_request(:get, key, headers: headers, streaming: true, bucket: bucket) do |resp|
          total = resp["Content-Length"]&.to_i
          resp.read_body do |chunk|
            out.write(chunk)
            written += chunk.bytesize
            if on_progress
              if on_progress.arity == 3 || on_progress.arity < 0
                pct = total&.positive? ? (written.to_f / total * 100).round(2) : 0
                on_progress.call(written, total || 0, pct)
              else
                on_progress.call(written, total)
              end
            end
          end
          written
        end
      end
    end
  end
end
