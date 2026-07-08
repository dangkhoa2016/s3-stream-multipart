# frozen_string_literal: true

# core/errors.rb
#
# Error classes for S3 client operations.
module S3Errors
  # Structured error class with code, request_id, and parsed S3 XML details.
  class S3Error < StandardError
    attr_reader :code, :request_id, :s3_code, :s3_message, :s3_bucket

    def initialize(code, message, request_id = nil, body = nil)
      @code = code
      @request_id = request_id
      @s3_code, @s3_message, @s3_bucket = parse_xml_body(body)
      detail = build_detail_message
      super("[S3 #{code}] #{message}#{" (req=#{request_id})" if request_id}#{detail}")
    end

    private

    def parse_xml_body(body)
      return [nil, nil, nil] unless body.is_a?(String) && !body.empty?

      code    = body[%r{<Code>([^<]+)</Code>}, 1]
      message = body[%r{<Message>([^<]+)</Message>}, 1]
      bucket  = body[%r{<BucketName>([^<]+)</BucketName>}, 1]
      [code, message, bucket]
    end

    def build_detail_message
      parts = []
      parts << @s3_code if @s3_code
      parts << @s3_message if @s3_message && @s3_message != @s3_code
      parts << "bucket: #{@s3_bucket}" if @s3_bucket
      parts.empty? ? "" : " — #{parts.join(', ')}"
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
