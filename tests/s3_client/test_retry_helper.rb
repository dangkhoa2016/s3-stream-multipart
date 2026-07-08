# frozen_string_literal: true

require_relative "../test_helper"
require_relative "../../src/s3_client"

class S3RetryHelperTest < Minitest::Test
  def setup
    @client = S3Client.new(
      bucket: "b", region: "us-east-1",
      access_key_id: "AK", secret_access_key: "SK",
      endpoint: "http://127.0.0.1:19999",
      max_retries: 2, retry_delay: 0.01,
      open_timeout: 5, read_timeout: 30,
      logger: Logger.new(File::NULL)
    )
    @fake_client = Object.new
    def @fake_client.transient_errors
      [EOFError, Errno::ECONNRESET]
    end

    def @fake_client.log_warn(*); end
    def @fake_client.log_error(*); end

    def @fake_client.backoff_with_jitter(attempt)
      0.01
    end

    def @fake_client.retry_with_backoff(max_retries:, context: "", on_retry: nil)
      attempt = 0
      begin
        attempt += 1
        yield attempt
      rescue *transient_errors => e
        if attempt <= max_retries
          delay = backoff_with_jitter(attempt)
          on_retry&.call(attempt, max_retries, delay, e)
          sleep(delay)
          retry
        end
        raise
      rescue S3BaseClient::S3Error => e
        retryable = e.code.to_i >= 500 || e.code.to_s == '429'
        if retryable && attempt <= max_retries
          delay = backoff_with_jitter(attempt) * (e.code.to_s == '429' ? 2.0 : 1.0)
          on_retry&.call(attempt, max_retries, delay, e)
          sleep(delay)
          retry
        end
        raise
      end
    end
  end

  def test_retry_with_backoff_class_method_success
    call_count = 0
    result = S3RetryHelper.retry_with_backoff(
      max_retries: 2, backoff_base: 0.01,
      client: @fake_client, context: "test"
    ) do
      call_count += 1
      :ok
    end
    assert_equal :ok, result
    assert_equal 1, call_count
  end

  def test_retry_with_backoff_transient_then_success
    call_count = 0
    result = S3RetryHelper.retry_with_backoff(
      max_retries: 2, backoff_base: 0.01,
      client: @fake_client, context: "test"
    ) do
      call_count += 1
      raise EOFError if call_count < 2

      :ok
    end
    assert_equal :ok, result
    assert_equal 2, call_count
  end

  def test_retry_with_backoff_transient_exhausted
    call_count = 0
    assert_raises(EOFError) do
      S3RetryHelper.retry_with_backoff(
        max_retries: 1, backoff_base: 0.01,
        client: @fake_client, context: "test"
      ) do
        call_count += 1
        raise EOFError
      end
    end
    assert_equal 2, call_count
  end

  def test_retry_with_backoff_s3_error_retryable
    call_count = 0
    result = S3RetryHelper.retry_with_backoff(
      max_retries: 2, backoff_base: 0.01,
      client: @fake_client, context: "test"
    ) do
      call_count += 1
      raise S3BaseClient::S3Error.new("500", "Server Error", nil) if call_count < 2

      :ok
    end
    assert_equal :ok, result
    assert_equal 2, call_count
  end

  def test_retry_with_backoff_s3_error_non_retryable
    call_count = 0
    assert_raises(S3BaseClient::S3Error) do
      S3RetryHelper.retry_with_backoff(
        max_retries: 2, backoff_base: 0.01,
        client: @fake_client, context: "test"
      ) do
        call_count += 1
        raise S3BaseClient::S3Error.new("403", "Forbidden", nil)
      end
    end
    assert_equal 1, call_count
  end

  def test_retry_with_backoff_on_retry_callback
    retries_info = []
    begin
      S3RetryHelper.retry_with_backoff(
        max_retries: 2, backoff_base: 0.01,
        client: @fake_client, context: "test",
        on_retry: ->(a, m, d, e) { retries_info << [a, m, d, e.class] }
      ) do
        raise EOFError
      end
    rescue StandardError
      nil
    end
    refute retries_info.empty?
  end

  def test_retry_with_backoff_super_path
    host = Class.new(S3BaseClient) do
      include S3RetryHelper

      def initialize; end # skip default Object#initialize
      def log_debug(*); end
      def log_warn(*); end
      def log_error(*); end

      def transient_errors
        [EOFError, Errno::ECONNRESET]
      end

      def backoff_with_jitter(attempt)
        0.01
      end
    end.new

    call_count = 0
    result = host.retry_with_backoff(
      max_retries: 2, backoff_base: 0.01,
      client: host, context: "test"
    ) do
      call_count += 1
      :ok
    end
    assert_equal :ok, result
    assert_equal 1, call_count
  end

  def test_retry_with_backoff_instance_method
    host = Class.new do
      include S3RetryHelper

      def log_debug(*); end
      def log_warn(*); end
      def log_error(*); end
    end.new

    call_count = 0
    result = host.retry_with_backoff(
      max_retries: 2, backoff_base: 0.01,
      client: @fake_client, context: "test"
    ) do
      call_count += 1
      :ok
    end
    assert_equal :ok, result
  end
end
