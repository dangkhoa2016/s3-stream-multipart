# frozen_string_literal: true

require "test_helper"
require_relative "../../../src/core/base_client"
require_relative "../../../src/core/result"
require_relative "../../../src/upload/empty_upload"

module Upload
  class TestEmptyUpload < Minitest::Test
    def test_call_returns_upload_result
      client = new_mock
      service = S3BaseClient::EmptyUpload.new(client: client, logger: Logger.new(File::NULL))

      result = service.call(
        key: "empty.txt",
        content_type: "text/plain",
        metadata: {},
        cache_control: nil,
        on_progress: nil,
        t0: Process.clock_gettime(Process::CLOCK_MONOTONIC),
        state_file: nil, bucket: nil, session: {}
      )

      assert_kind_of S3BaseClient::UploadResult, result
      assert_equal 0, result.size
      assert_equal "etag-empty", result.etag
    end

    private

    def new_mock
      client = Object.new
      client.define_singleton_method(:put_single_object) { |*| "etag-empty" }
      client.define_singleton_method(:respond_to?) { |*| true }
      um = Object.new
      um.define_singleton_method(:cleanup_state) { |*| nil }
      client.define_singleton_method(:upload_state_manager) { um }
      client
    end
  end
end
