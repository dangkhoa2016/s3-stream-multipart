# frozen_string_literal: true

#
# download/part_downloader.rb
#
# PartDownloader — standalone, client-agnostic class for parallel multipart
# downloads.  Works with any S3 client that responds to:
#
#   download_part_http(bucket, key, part_number, offset, end_byte, length, http) -> String body
#   emit_event(name, *args)
#   log_debug / log_info / log_error (message)
#   now_mono                                        -> Float
#   human_readable_size(bytes)                      -> String
#

require_relative "../concurrent/parallel_downloader"

class PartDownloader < S3ParallelDownloader
  def initialize(client, download_state, output_file: nil, max_threads: 4,
                 on_progress: nil, state_file: nil,
                 max_retries: 3, retry_delay: 0.25)
    super(client, download_state, output_file,
          max_threads: max_threads,
          max_retries: max_retries,
          retry_delay: retry_delay,
          on_progress: on_progress,
          state_file: state_file)
  end

  protected

  def download_part_with_retry(part_number, offset, end_byte, length, http, tid)
    retry_with_backoff(
      max_retries: @max_retries, backoff_base: @retry_delay,
      client: @client, context: "DL part #{part_number}",
      on_retry: lambda { |attempt, max, delay, e|
        @client.emit_event(:download_part_retry, part_number, tid, attempt, max, delay, e)
      }
    ) do
      body = @client.download_part_http(@state.bucket, @state.key, part_number,
                                        offset, end_byte, length, http)
      @output_file.pwrite(body, offset)
      @output_file.path
    end
  end

  def open_http_connection(_sample_uri = nil)
    @client.client_open_http(@state.bucket, @state.key) { |http| yield http }
  end

  def build_result
    @state.parts.values.first || @state.local_path
  end
end
