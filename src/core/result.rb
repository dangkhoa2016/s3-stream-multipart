# frozen_string_literal: true

# core/result.rb
#
# Data result objects returned by upload/download operations.
# Supports both method-style (result.key) and hash-style (result[:key]) access.

class S3BaseClient
  # Result of an upload operation.
  # @attr key [String] S3 object key
  # @attr size [Integer] file size in bytes
  # @attr etag [String] ETag returned by S3
  # @attr elapsed [Float] elapsed time in seconds
  # @attr throughput [Float] throughput in MB/s
  # @attr extra [Hash] additional metadata (upload_id, parts, etc.)
  UploadResult = Data.define(:key, :size, :etag, :elapsed, :throughput, :extra) do
    def to_h
      members.to_h { |m| [m, public_send(m)] }
             .merge(extra || {})
    end

    def [](key)
      to_h[key]
    end
  end

  # Result of a download operation.
  # @attr path [String] local file path
  # @attr size [Integer] bytes downloaded
  # @attr elapsed [Float] elapsed time in seconds
  # @attr throughput [Float] throughput in MB/s
  # @attr extra [Hash] additional metadata (key, destination, etc.)
  DownloadResult = Data.define(:path, :size, :elapsed, :throughput, :extra) do
    def to_h
      members.to_h { |m| [m, public_send(m)] }
             .merge(extra || {})
    end

    def [](key)
      to_h[key]
    end
  end
end
