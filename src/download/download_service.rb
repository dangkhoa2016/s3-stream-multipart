# frozen_string_literal: true

class S3BaseClient
  # Orchestrates file downloads from S3-compatible storage.
  # Delegates to SinglePartDownload for all downloads.
  class DownloadService
    def initialize(client:, logger: nil)
      @client = client
      @logger = logger
    end

    def call(key:, destination_path: nil, local_path: nil,
             range: nil, on_progress: nil,
             bucket: nil)
      dest = destination_path || local_path
      raise ArgumentError, "destination_path or local_path required" unless dest

      SinglePartDownload.new(client: @client, logger: @logger).call(
        key: key, destination_path: dest,
        range: range, on_progress: on_progress, bucket: bucket
      )
    end
  end
end
