# frozen_string_literal: true

# core/errors.rb
#
# Error classes for S3 client operations.
module S3Errors
  # Structured error class with code, request_id, and body excerpt.
  class S3Error < StandardError
    attr_reader :code, :request_id

    def initialize(code, message, request_id = nil, body = nil)
      @code = code
      @request_id = request_id
      excerpt = body.is_a?(String) && !body.empty? ? " :: #{body[0, 500]}" : ""
      super("[S3 #{code}] #{message}#{" (req=#{request_id})" if request_id}#{excerpt}")
    end
  end

  # Raised when parallel upload fails to complete all parts.
  class UploadError < StandardError; end

  # Raised when a resumable operation fails in non-raising mode.
  class ResumableUploadError < UploadError; end

  # Raised when parallel download fails to complete all parts.
  class DownloadError < StandardError; end

  # Raised when an upload or download state file is invalid or corrupted.
  class S3StateError < StandardError; end
end
