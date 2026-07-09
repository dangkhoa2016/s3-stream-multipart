# frozen_string_literal: true

require "test_helper"
require_relative "../../../src/core/base_client"
require_relative "../../../src/upload/resume_upload"

module Upload
  class TestResumeUpload < Minitest::Test
    def test_class_exists
      service = S3BaseClient::ResumeUpload.new(
        client: Object.new, logger: Logger.new(File::NULL)
      )
      assert_respond_to service, :call
    end
  end
end
