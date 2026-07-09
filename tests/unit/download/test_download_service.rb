# frozen_string_literal: true

require "test_helper"
require_relative "../../../src/core/base_client"
require_relative "../../../src/core/result"
require_relative "../../../src/download/download_service"

module Download
  class TestDownloadService < Minitest::Test
    def test_requires_destination
      client = Object.new
      service = S3BaseClient::DownloadService.new(client: client, logger: nil)
      assert_raises(ArgumentError) do
        service.call(key: "test.txt")
      end
    end
  end
end
