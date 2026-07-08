# frozen_string_literal: true

require "test_helper"
require_relative "../../../src/core/base_client"
require_relative "../../../src/core/result"
require_relative "../../../src/upload/single_part_upload"

module Upload
  class TestSinglePartUpload < Minitest::Test
    def test_call_returns_upload_result
      client = new_mock
      service = S3BaseClient::SinglePartUpload.new(client: client, logger: Logger.new(File::NULL))

      result = service.call(
        key: "small.txt", local_path: "/tmp/test.bin", size: 1024,
        content_type: "text/plain", metadata: {}, cache_control: nil,
        on_progress: nil,
        t0: Process.clock_gettime(Process::CLOCK_MONOTONIC),
        state_file: nil, bucket: nil, session: {}
      )

      assert_kind_of S3BaseClient::UploadResult, result
      assert_equal "etag-small", result.etag
      assert result.throughput > 0
    end

    private

    def new_mock
      client = Object.new
      client.define_singleton_method(:put_single_object) do |key, path, content_type:, metadata:, cache_control:, bucket:|
        "etag-small"
      end
      client.define_singleton_method(:respond_to?) { |*| true }
      um = Object.new
      um.define_singleton_method(:cleanup_state) { |*| nil }
      client.define_singleton_method(:upload_state_manager) { um }
      client
    end
  end
end
