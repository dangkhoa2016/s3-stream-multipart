# frozen_string_literal: true

# core/result.rb
#
# Data result objects returned by upload/download operations.
# Supports both method-style (result.key) and hash-style (result[:key]) access.

class S3BaseClient
  UploadResult = Struct.new(:key, :size, :etag, :elapsed, :throughput, :extra, keyword_init: true) do
    def to_h
      super.merge(extra || {})
    end

    def [](key)
      to_h[key]
    end
  end

  DownloadResult = Struct.new(:path, :size, :elapsed, :throughput, :extra, keyword_init: true) do
    def to_h
      super.merge(extra || {})
    end

    def [](key)
      to_h[key]
    end
  end
end
