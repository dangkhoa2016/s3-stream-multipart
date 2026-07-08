# frozen_string_literal: true

require "test_helper"
require_relative "../../../src/core/base_client"
require_relative "../../../src/core/result"
require_relative "../../../src/upload/upload_service"

module Upload
  class TestUploadService < Minitest::Test
    def test_class_exists
      client = Object.new
      def client.part_size = 10_485_760
      service = S3BaseClient::UploadService.new(client: client, logger: Logger.new(File::NULL))
      assert_respond_to service, :call
    end
  end
end
