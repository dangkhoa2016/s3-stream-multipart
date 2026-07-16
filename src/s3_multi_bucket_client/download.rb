# frozen_string_literal: true

# s3_multi_bucket_client/download.rb — download operations for S3MultiBucketClient.
# Reopens S3MultiBucketClient to define download methods.

require_relative "../download/part_downloader"
require_relative "../download/download_service"
require_relative "../extras/bulk_downloader"

class S3MultiBucketClient
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

  # =========================================================================
  # BULK DOWNLOAD
  # =========================================================================

  def download_directory(bucket:, local_directory:, prefix: "", delimiter: nil,
                         exclude: [], max_files: 4,
                         on_file_start: nil, on_file_complete: nil, on_file_error: nil)
    S3BulkDownloader.new(
      client: self, local_directory: local_directory, prefix: prefix,
      delimiter: delimiter, bucket: bucket, exclude: exclude,
      max_files: max_files,
      on_file_start: on_file_start, on_file_complete: on_file_complete,
      on_file_error: on_file_error
    ).run!
  end
end
