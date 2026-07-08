# frozen_string_literal: true

require "test_helper"
require_relative "../../../src/core/base_client"
require_relative "../../../src/core/result"
require_relative "../../../src/download/single_part_download"

module Download
  class TestSinglePartDownload < Minitest::Test
    def test_class_exists
      client = Object.new
      def client.perform_request(*); end
      service = S3BaseClient::SinglePartDownload.new(client: client, logger: nil)
      assert_respond_to service, :call
    end
  end
end
