# frozen_string_literal: true

require "test_helper"
require_relative "../../../src/core/base_client"
require_relative "../../../src/upload/multipart_upload"

module Upload
  class TestMultipartUpload < Minitest::Test
    def test_class_exists
      service = S3BaseClient::MultipartUpload.new(
        client: Object.new, logger: Logger.new(File::NULL)
      )
      assert_respond_to service, :call
    end
  end
end
