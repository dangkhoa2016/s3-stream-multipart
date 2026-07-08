# frozen_string_literal: true

# s3_multi_bucket_client/download.rb — download operations for S3MultiBucketClient.
# Reopens S3MultiBucketClient to define download methods.

require_relative "../download/part_downloader"

class S3MultiBucketClient
  # Download a part via HTTP — called by PartDownloader.
  # @return [String] response body
  def download_part_http(bucket, key, part_number, offset, end_byte, length, http)
    @download_transport.range_get(key, offset, end_byte, bucket: bucket)
  end

  # Open a persistent HTTP connection — called by PartDownloader.
  def client_open_http(bucket, key, &)
    @download_transport.open_http(key, bucket:, &)
  end

  # =========================================================================
  # STREAMING DOWNLOAD
  # =========================================================================

  def download_file(
    key:, bucket: nil, destination_path: nil, local_path: nil,
    chunk_size: DOWNLOAD_CHUNK_SIZE,
    on_progress: nil,
    resume: false,
    range: nil
  )
    DownloadService.new(client: self, logger: @logger).call(
      key: key, destination_path: destination_path, local_path: local_path,
      range: range, on_progress: on_progress,
      bucket: bucket
    )
  end
end
