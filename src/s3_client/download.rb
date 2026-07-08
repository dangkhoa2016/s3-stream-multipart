# frozen_string_literal: true

# s3_client/download.rb — download operations for S3Client.
# Reopens S3Client to define download methods.

require_relative "../download/part_downloader"

class S3Client
  # Download a part via HTTP — called by PartDownloader.
  # @return [String] response body
  def download_part_http(bucket, key, part_number, offset, end_byte, length, http)
    @download_transport.range_get(key, offset, end_byte, bucket: bucket)
  end

  # Open a persistent HTTP connection — called by PartDownloader.
  def client_open_http(bucket, key, &block)
    @download_transport.open_http(key, bucket: bucket, &block)
  end

  # =========================================================================
  # DOWNLOAD — streams chunks to file, does NOT buffer entire body
  # =========================================================================

  def download_file(key:, local_path: nil, destination_path: nil, bucket: nil,
                    range: nil, on_progress: nil)
    DownloadService.new(client: self, logger: @logger).call(
      key: key, destination_path: destination_path, local_path: local_path,
      range: range, on_progress: on_progress,
      bucket: bucket
    )
  end
end
