# frozen_string_literal: true

require_relative "../test_helper"
require_relative "../../src/s3_client"

class RequestExecutorTest < Minitest::Test
  def setup
    @client = S3Client.new(
      bucket: "b", region: "us-east-1",
      access_key_id: "AK", secret_access_key: "SK",
      endpoint: "http://127.0.0.1:19999",
      max_retries: 2,
      open_timeout: 5, read_timeout: 30,
      logger: Logger.new(File::NULL)
    )
  end

  def test_execute_with_retry_success
    result = @client.send(:execute_with_retry, "GET", URI("http://example.com/"), max_attempts: 3) do
      OpenStruct.new(code: "200")
    end
    assert_equal "200", result.code
  end

  def test_execute_with_retry_transient_error_then_success
    call_count = 0
    result = @client.send(:execute_with_retry, "GET", URI("http://example.com/"), max_attempts: 3) do
      call_count += 1
      raise EOFError if call_count < 2

      OpenStruct.new(code: "200")
    end
    assert_equal "200", result.code
    assert_equal 2, call_count
  end

  def test_execute_with_retry_transient_error_exhausted
    call_count = 0
    assert_raises(EOFError) do
      @client.send(:execute_with_retry, "GET", URI("http://example.com/"), max_attempts: 2) do
        call_count += 1
        raise EOFError
      end
    end
    assert_equal 2, call_count
  end

  def test_execute_with_retry_s3_server_error_retry
    call_count = 0
    result = @client.send(:execute_with_retry, "GET", URI("http://example.com/"), max_attempts: 3) do
      call_count += 1
      if call_count < 3
        resp = OpenStruct.new(code: "500")
        def resp.[](key)
          key == "x-amz-request-id" ? "req-1" : nil
        end
        raise S3BaseClient::S3Error.new(resp.code, "Server Error", resp["x-amz-request-id"])
      end
      OpenStruct.new(code: "200")
    end

    assert_equal "200", result.code
    assert_equal 3, call_count
  end

  def test_execute_with_retry_s3_429_retry
    call_count = 0
    result = @client.send(:execute_with_retry, "GET", URI("http://example.com/"), max_attempts: 3) do
      call_count += 1
      if call_count < 3
        resp = OpenStruct.new(code: "429")
        def resp.[](key)
          key == "x-amz-request-id" ? "req-2" : nil
        end
        raise S3BaseClient::S3Error.new(resp.code, "Too Many Requests", resp["x-amz-request-id"])
      end
      OpenStruct.new(code: "200")
    end
    assert_equal "200", result.code
    assert_equal 3, call_count
  end

  def test_execute_with_retry_s3_error_non_retryable
    call_count = 0
    assert_raises(S3BaseClient::S3Error) do
      @client.send(:execute_with_retry, "GET", URI("http://example.com/"), max_attempts: 2) do
        call_count += 1
        resp = OpenStruct.new(code: "403")
        def resp.[](key)
          key == "x-amz-request-id" ? "req-3" : nil
        end
        raise S3BaseClient::S3Error.new(resp.code, "Forbidden", resp["x-amz-request-id"])
      end
    end
    assert_equal 1, call_count
  end

  def test_execute_with_retry_s3_500_result_retry
    call_count = 0
    result = @client.send(:execute_with_retry, "GET", URI("http://example.com/"), max_attempts: 3) do
      call_count += 1
      if call_count < 3
        resp = OpenStruct.new(code: "500", message: "Internal Server Error")
        def resp.[](key)
          key == "x-amz-request-id" ? "req-500" : nil
        end
        resp
      else
        OpenStruct.new(code: "200")
      end
    end
    assert_equal "200", result.code
    assert_equal 3, call_count
  end

  def test_execute_with_retry_s3_429_result_retry
    call_count = 0
    result = @client.send(:execute_with_retry, "GET", URI("http://example.com/"), max_attempts: 3) do
      call_count += 1
      if call_count < 2
        resp = OpenStruct.new(code: "429", message: "Too Many Requests")
        def resp.[](key)
          key == "x-amz-request-id" ? "req-429" : nil
        end
        resp
      else
        OpenStruct.new(code: "200")
      end
    end
    assert_equal "200", result.code
  end
end
