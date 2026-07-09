# frozen_string_literal: true

require "test_helper"
require_relative "../../../src/core/base_client"
require_relative "../../../src/core/xml_helpers"
require_relative "../../../src/core/constants"
require_relative "../../../src/s3_client"
require_relative "../../../src/concurrent/thread_tracking"
require_relative "../../../src/extras/retry_helper"
require_relative "../../../src/core/request_executor"
require_relative "../../../src/states/download_state"
require_relative "../../../src/states/upload_state"
require_relative "../../../src/concurrent/part_geometry"
require_relative "../../../src/concurrent/progress_tracker"
# ==========================================================================
# 6.1a — DownloadState direct unit tests
# ==========================================================================
class DownloadStateUnitTest < Minitest::Test
  def test_new_with_basic_params
    state = DownloadState.new(
      key: "/test.bin", local_path: "/tmp/test.bin",
      part_size: 5 * 1024 * 1024, total_size: 20 * 1024 * 1024, parts: {}
    )
    assert_equal "/test.bin", state.key
    assert_equal "/tmp/test.bin", state.local_path
    assert_equal 5 * 1024 * 1024, state.part_size
    assert_equal 20 * 1024 * 1024, state.total_size
    assert_equal 4, state.total_parts
    assert_equal 0, state.completed_parts_count
    refute state.completed
  end

  def test_to_h_roundtrip
    state = DownloadState.new(
      key: "/dl.bin", local_path: "/tmp/dl.bin",
      part_size: 1024, total_size: 4096,
      parts: { 1 => 1024, 2 => 1024 }
    )
    hash = state.to_h
    assert_equal "/dl.bin", hash[:key]
    assert_equal 4096, hash[:total_size]
    assert_equal 2, hash[:parts].size

    restored = DownloadState.new(hash)
    assert_equal state.key, restored.key
    assert_equal state.total_parts, restored.total_parts
    assert_equal state.completed_parts_count, restored.completed_parts_count
  end

  def test_to_json_and_from_json
    state = DownloadState.new(
      key: "/j.bin", local_path: "/tmp/j.bin",
      part_size: 512, total_size: 2048, parts: {}
    )
    json = state.to_json
    assert json.is_a?(String)
    assert json.include?("/j.bin")

    restored = DownloadState.from_json(json)
    assert_equal "/j.bin", restored.key
    assert_equal 2048, restored.total_size
  end

  def test_save_and_load_file
    Dir.mktmpdir do |dir|
      path = File.join(dir, "dl_state.json")
      state = DownloadState.new(
        key: "/save.bin", local_path: "/tmp/save.bin",
        part_size: 1024, total_size: 4096, parts: { 1 => 1024 }
      )
      state.save_to_file(path)
      assert File.exist?(path)

      loaded = DownloadState.from_file(path)
      assert_equal "/save.bin", loaded.key
      assert_equal 1, loaded.completed_parts_count
    end
  end

  def test_bytes_downloaded
    state = DownloadState.new(
      key: "/b.bin", local_path: "/tmp/b.bin",
      part_size: 1000, total_size: 3000,
      parts: { 1 => 1000, 2 => 1000 }
    )
    assert_equal 2000, state.bytes_downloaded
  end

  def test_progress_percentage
    state = DownloadState.new(
      key: "/p.bin", local_path: "/tmp/p.bin",
      part_size: 1000, total_size: 4000,
      parts: { 1 => 1000, 2 => 1000 }
    )
    assert_equal 50.0, state.progress_percentage
  end

  def test_progress_percentage_zero_total
    state = DownloadState.new(
      key: "/z.bin", local_path: "/tmp/z.bin",
      part_size: 1000, total_size: 0, parts: {}
    )
    assert_equal 0, state.progress_percentage
  end
end

# ==========================================================================
# 6.1d — ThreadTracking direct unit tests
# ==========================================================================
class ThreadTrackingUnitTest < Minitest::Test
  def setup
    @host = Object.new
    @host.instance_variable_set(:@tracking_mtx, Mutex.new)
    @host.instance_variable_set(:@in_progress_parts, {})
    @host.instance_variable_set(:@thread_states, {})
    @host.extend(S3ThreadTracking)

    @client = Object.new
    def @client.log_debug(msg); end

    def @client.now_iso
      "2026-01-01T00:00:00Z"
    end
    @host.instance_variable_set(:@client, @client)
  end

  def test_register_thread
    @host.register_thread("t0", 12_345)
    states = @host.instance_variable_get(:@thread_states)
    assert_equal "started", states["t0"][:status]
    assert_equal 12_345, states["t0"][:native_thread_id]
    assert states["t0"][:started_at]
  end

  def test_mark_part_in_progress
    @host.register_thread("t0", nil)
    @host.mark_part_in_progress(5, "t0")
    states = @host.instance_variable_get(:@thread_states)
    parts = @host.instance_variable_get(:@in_progress_parts)
    assert_equal "uploading", states["t0"][:status]
    assert_equal 5, states["t0"][:current_part]
    assert_equal "t0", parts[5]
  end

  def test_mark_part_error
    @host.register_thread("t0", nil)
    @host.mark_part_in_progress(3, "t0")
    @host.mark_part_error(3, "t0")
    states = @host.instance_variable_get(:@thread_states)
    parts = @host.instance_variable_get(:@in_progress_parts)
    assert_equal "error", states["t0"][:status]
    refute parts.key?(3)
  end

  def test_finish_thread
    @host.register_thread("t0", nil)
    @host.finish_thread("t0", 5)
    states = @host.instance_variable_get(:@thread_states)
    assert_equal "finished", states["t0"][:status]
    assert states["t0"][:finished_at]
  end

  def test_safe_native_thread_id
    tid = @host.safe_native_thread_id
    assert(tid.nil? || tid.is_a?(Integer))
  end
end

# ==========================================================================
# 6.1f — RetryHelper direct unit tests
# ==========================================================================
class RetryHelperUnitTest < Minitest::Test
  include S3RetryHelper

  def setup
    @client = Object.new
    def @client.log_debug(msg); end
    def @client.log_warn(msg); end
    def @client.log_info(msg); end
    def @client.log_error(msg); end

    def @client.backoff_with_jitter(attempt)
      0.001
    end

    def @client.transient_errors
      [EOFError, Errno::ECONNRESET, IOError]
    end
    [EOFError, Errno::ECONNRESET, IOError]
    def @client.retry_with_backoff(max_retries:, context: "", on_retry: nil, &block)
      attempt = 0
      begin
        attempt += 1
        block.call(attempt)
      rescue EOFError, Errno::ECONNRESET, IOError => e
        if attempt <= max_retries
          delay = backoff_with_jitter(attempt)
          log_warn "↻ #{context} transient #{e.class}: #{e.message} — retry #{attempt}/#{max_retries} in #{'%.2f' % delay}s"
          on_retry&.call(attempt, max_retries, delay, e)
          sleep(delay)
          retry
        end
        log_error "✗ #{context} exhausted #{max_retries} retries: #{e.class}: #{e.message}"
        raise
      rescue S3BaseClient::S3Error => e
        retryable = e.code.to_i >= 500 || e.code.to_s == '429'
        if retryable && attempt <= max_retries
          multiplier = e.code.to_s == '429' ? 2.0 : 1.0
          delay = backoff_with_jitter(attempt) * multiplier
          log_warn "↻ #{context} S3 #{e.code}: #{e.message} — retry #{attempt}/#{max_retries} in #{'%.2f' % delay}s"
          on_retry&.call(attempt, max_retries, delay, e)
          sleep(delay)
          retry
        end
        raise
      end
    end
  end

  def test_succeeds_on_first_attempt
    result = S3RetryHelper.retry_with_backoff(max_retries: 3, backoff_base: 0.001,
                                              client: @client, context: "test") do
      "success"
    end
    assert_equal "success", result
  end

  def test_retries_on_transient_error_then_succeeds
    attempts = 0
    result = S3RetryHelper.retry_with_backoff(max_retries: 3, backoff_base: 0.001,
                                              client: @client, context: "test") do
      attempts += 1
      raise EOFError, "transient" if attempts < 3

      "recovered"
    end
    assert_equal "recovered", result
    assert_equal 3, attempts
  end

  def test_retries_on_s3_500_error
    attempts = 0
    result = S3RetryHelper.retry_with_backoff(max_retries: 2, backoff_base: 0.001,
                                              client: @client, context: "test") do
      attempts += 1
      raise S3BaseClient::S3Error.new("500", "Server Error") if attempts < 2

      "ok"
    end
    assert_equal "ok", result
    assert_equal 2, attempts
  end

  def test_retries_on_s3_429_error
    attempts = 0
    result = S3RetryHelper.retry_with_backoff(max_retries: 2, backoff_base: 0.001,
                                              client: @client, context: "test") do
      attempts += 1
      raise S3BaseClient::S3Error.new("429", "Too Many Requests") if attempts < 2

      "ok"
    end
    assert_equal "ok", result
  end

  def test_raises_after_exhaustion
    assert_raises(EOFError) do
      S3RetryHelper.retry_with_backoff(max_retries: 2, backoff_base: 0.001,
                                       client: @client, context: "test") do
        raise EOFError, "persistent"
      end
    end
  end

  def test_raises_non_retryable_immediately
    attempts = 0
    assert_raises(ArgumentError) do
      retry_with_backoff(max_retries: 3, backoff_base: 0.001,
                         client: @client, context: "test") do
        attempts += 1
        raise ArgumentError, "bad input"
      end
    end
    assert_equal 1, attempts
  end

  def test_on_retry_callback
    retries_seen = []
    attempts = 0
    retry_with_backoff(max_retries: 2, backoff_base: 0.001,
                       client: @client, context: "test",
                       on_retry: lambda { |attempt, max, delay, e|
                         retries_seen << attempt
                       }) do
      attempts += 1
      raise EOFError, "transient" if attempts < 3

      "ok"
    end
    assert_equal [1, 2], retries_seen
  end

  def test_s3_4xx_not_retried
    attempts = 0
    assert_raises(S3BaseClient::S3Error) do
      retry_with_backoff(max_retries: 3, backoff_base: 0.001,
                         client: @client, context: "test") do
        attempts += 1
        raise S3BaseClient::S3Error.new("403", "Forbidden")
      end
    end
    assert_equal 1, attempts
  end
end

# ==========================================================================
# 6.1e — RequestExecutor direct unit tests
# ==========================================================================
class RequestExecutorUnitTest < Minitest::Test
  include RequestExecutor

  def transient_errors
    [EOFError, Errno::ECONNRESET]
  end

  def backoff_with_jitter(attempt)
    0.001
  end

  def now_mono
    Process.clock_gettime(Process::CLOCK_MONOTONIC)
  end

  def log_debug(msg = nil, &block); end
  def log_warn(msg = nil, &block); end
  def log_error(msg = nil, &block); end
  def log_response_details(resp); end
  def emit_event(*args); end

  # execute_with_retry delegates to retry_with_backoff
  def retry_with_backoff(max_retries:, context: "", on_retry: nil)
    attempt = 0
    begin
      attempt += 1
      yield attempt
    rescue *transient_errors => e
      if attempt <= max_retries
        delay = backoff_with_jitter(attempt)
        sleep(delay)
        retry
      end
      raise
    rescue S3BaseClient::S3Error => e
      if (e.code.to_i >= 500 || e.code.to_s == '429') && attempt <= max_retries
        delay = backoff_with_jitter(attempt) * (e.code.to_s == '429' ? 2.0 : 1.0)
        sleep(delay)
        retry
      end
      raise
    end
  end

  def test_succeeds_on_first_attempt
    result = execute_with_retry("GET", URI("http://example.com"), max_attempts: 3) do
      resp = Net::HTTPResponse.new("1.1", "200", "OK")
      resp
    end
    assert_equal "200", result.code
  end

  def test_retries_transient_then_succeeds
    attempts = 0
    result = execute_with_retry("GET", URI("http://example.com"), max_attempts: 3) do
      attempts += 1
      raise EOFError, "transient" if attempts < 2

      resp = Net::HTTPResponse.new("1.1", "200", "OK")
      resp
    end
    assert_equal "200", result.code
    assert_equal 2, attempts
  end

  def test_raises_after_max_attempts
    assert_raises(EOFError) do
      execute_with_retry("GET", URI("http://example.com"), max_attempts: 2) do
        raise EOFError, "persistent"
      end
    end
  end

  def test_non_transient_raises_immediately
    attempts = 0
    assert_raises(ArgumentError) do
      execute_with_retry("GET", URI("http://example.com"), max_attempts: 5) do
        attempts += 1
        raise ArgumentError, "bad"
      end
    end
    assert_equal 1, attempts
  end
end

# ---------------------------------------------------------------------------
# Minimal host for testing XML parsing helpers
# ---------------------------------------------------------------------------
class XmlHost
  include S3Constants
  include S3Errors
  include S3XmlHelpers
end

# =========================================================================
# xml_helpers.rb — parse_list_objects_xml
# =========================================================================
class TestParseListObjectsXml < Minitest::Test
  def setup
    @host = XmlHost.new
  end

  def test_parse_list_objects_with_contents
    xml = <<~XML
      <?xml version="1.0" encoding="UTF-8"?>
      <ListBucketResult>
        <Contents>
          <Key>file1.txt</Key>
          <Size>1024</Size>
          <LastModified>2024-01-01T00:00:00Z</LastModified>
          <StorageClass>STANDARD</StorageClass>
          <ETag>"abc123"</ETag>
        </Contents>
        <Contents>
          <Key>file2.txt</Key>
          <Size>2048</Size>
          <LastModified>2024-01-02T00:00:00Z</LastModified>
          <StorageClass>STANDARD</StorageClass>
          <ETag>"def456"</ETag>
        </Contents>
      </ListBucketResult>
    XML
    result = @host.send(:parse_list_objects_xml, xml)
    assert_equal 2, result[:contents].size
    assert_equal "file1.txt", result[:contents][0][:key]
    assert_equal 1024, result[:contents][0][:size]
    assert_equal "file2.txt", result[:contents][1][:key]
    assert_equal 2048, result[:contents][1][:size]
    assert result[:common_prefixes].empty?
  end

  def test_parse_list_objects_with_common_prefixes
    xml = <<~XML
      <?xml version="1.0" encoding="UTF-8"?>
      <ListBucketResult>
        <CommonPrefixes>
          <Prefix>folder1/</Prefix>
        </CommonPrefixes>
        <CommonPrefixes>
          <Prefix>folder2/</Prefix>
        </CommonPrefixes>
        <IsTruncated>false</IsTruncated>
      </ListBucketResult>
    XML
    result = @host.send(:parse_list_objects_xml, xml)
    assert_equal 2, result[:common_prefixes].size
    assert_equal "folder1/", result[:common_prefixes][0]
    assert_equal "folder2/", result[:common_prefixes][1]
    assert result[:contents].empty?
  end

  def test_parse_list_objects_truncated_with_next_token
    xml = <<~XML
      <?xml version="1.0" encoding="UTF-8"?>
      <ListBucketResult>
        <IsTruncated>true</IsTruncated>
        <NextContinuationToken>abc123token</NextContinuationToken>
      </ListBucketResult>
    XML
    result = @host.send(:parse_list_objects_xml, xml)
    assert result[:is_truncated]
    assert_equal "abc123token", result[:next_continuation_token]
  end

  def test_parse_list_objects_not_truncated
    xml = <<~XML
      <?xml version="1.0" encoding="UTF-8"?>
      <ListBucketResult>
        <IsTruncated>false</IsTruncated>
      </ListBucketResult>
    XML
    result = @host.send(:parse_list_objects_xml, xml)
    refute result[:is_truncated]
    assert_nil result[:next_continuation_token]
  end

  def test_parse_list_objects_empty
    xml = '<?xml version="1.0" encoding="UTF-8"?><ListBucketResult></ListBucketResult>'
    result = @host.send(:parse_list_objects_xml, xml)
    assert_empty result[:contents]
    assert_empty result[:common_prefixes]
    assert result[:is_truncated] == false
  end
end

# ---------------------------------------------------------------------------
# Minimal host for testing Logging module with color constants
# ---------------------------------------------------------------------------
class LoggingHost
  include S3Logging

  LOG_COLORS = {
    "INFO" => "\e[32m",
    "WARN" => "\e[33m",
    "ERROR" => "\e[31m",
    "DEBUG" => "\e[36m"
  }.freeze
  LOG_COLOR_RESET = "\e[0m"
  LOG_COLOR_GREEN = "\e[32m"
  LOG_COLOR_DIM   = "\e[2m"
  LOG_KEYWORD_REGEX = /\b(WARN|ERROR|INFO|DEBUG)\b/

  attr_reader :logger

  def initialize
    setup_logger(nil, debug: true, log_color: true, log_format: :text)
  end
end

# =========================================================================
# logging.rb — setup_logger edge cases
# =========================================================================
class TestSetupLoggerEdgeCases < Minitest::Test
  def test_setup_logger_with_log_file
    Dir.mktmpdir do |dir|
      log_path = File.join(dir, "test.log")
      S3Client.new(
        bucket: "b", region: "us-east-1",
        access_key_id: "a", secret_access_key: "k",
        log_file: log_path
      )
      assert File.exist?(log_path)
    end
  end

  def test_setup_logger_json_format
    client = S3Client.new(
      bucket: "b", region: "us-east-1",
      access_key_id: "a", secret_access_key: "k",
      log_format: :json,
      logger: Logger.new(File::NULL)
    )
    assert client.instance_variable_get(:@logger)
  end

  def test_setup_logger_color_format
    client = S3Client.new(
      bucket: "b", region: "us-east-1",
      access_key_id: "a", secret_access_key: "k",
      log_color: true,
      logger: Logger.new(File::NULL)
    )
    assert client.instance_variable_get(:@logger)
  end

  def test_thread_log_methods
    client = S3Client.new(
      bucket: "b", region: "us-east-1",
      access_key_id: "a", secret_access_key: "k",
      logger: Logger.new(File::NULL)
    )
    client.send(:thread_log_info, "test info")
    client.send(:thread_log_debug, "test debug")
    client.send(:thread_log_warn, "test warn")
    client.send(:thread_log_error, "test error")
    client.send(:thread_log_info, "test info", "t1")
    client.send(:thread_log_debug, "test debug", "t1")
    client.send(:thread_log_warn, "test warn", "t1")
    client.send(:thread_log_error, "test error", "t1")
  end

  def test_log_response_details_301_color
    host = LoggingHost.new
    resp = Net::HTTPResponse.new("1.1", 301, "Moved Permanently")
    resp.instance_variable_set(:@read, true)
    resp.instance_variable_set(:@body, "")
    resp["X-Request-Id"] = "test-123"
    host.send(:log_response_details, resp)
  end

  def test_log_response_details_400_color
    host = LoggingHost.new
    resp = Net::HTTPResponse.new("1.1", 400, "Bad Request")
    resp.instance_variable_set(:@read, true)
    resp.instance_variable_set(:@body, "")
    resp["X-Request-Id"] = "test-123"
    host.send(:log_response_details, resp)
  end

  def test_log_response_details_500_color
    host = LoggingHost.new
    resp = Net::HTTPResponse.new("1.1", 500, "Internal Server Error")
    resp.instance_variable_set(:@read, true)
    resp.instance_variable_set(:@body, "")
    resp["X-Request-Id"] = "test-123"
    host.send(:log_response_details, resp)
  end

  def test_log_response_details_200
    host = LoggingHost.new
    resp = Net::HTTPResponse.new("1.1", 200, "OK")
    resp.instance_variable_set(:@read, true)
    resp.instance_variable_set(:@body, "hello")
    resp["X-Request-Id"] = "test-123"
    host.send(:log_response_details, resp)
  end

  def test_log_response_details_long_body
    host = LoggingHost.new
    resp = Net::HTTPResponse.new("1.1", 200, "OK")
    resp.instance_variable_set(:@read, true)
    resp.instance_variable_set(:@body, "x" * 1000)
    host.send(:log_response_details, resp)
  end

  def test_log_request_details_debug_off
    host = Object.new
    host.instance_variable_set(:@debug_mode, false)
    host.instance_variable_set(:@logger, Logger.new(File::NULL))
    host.extend(S3Logging)

    uri = URI("http://example.com/test?foo=bar")
    host.send(:log_request_details, "PUT", uri, 100)
  end

  def test_log_info_warn_error_debug
    client = S3Client.new(
      bucket: "b", region: "us-east-1",
      access_key_id: "a", secret_access_key: "k",
      logger: Logger.new(File::NULL)
    )
    client.log_info("info")
    client.log_warn("warn")
    client.log_error("error")
    client.log_debug("debug")
  end

  def test_thread_log_without_logger
    client = S3Client.new(
      bucket: "b", region: "us-east-1",
      access_key_id: "a", secret_access_key: "k",
      logger: nil
    )
    client.send(:thread_log, :info, "msg")
    client.send(:thread_log_info, "msg")
    client.send(:thread_log_debug, "msg")
    client.send(:thread_log_warn, "msg")
    client.send(:thread_log_error, "msg")
  end
end

# =========================================================================
# PartGeometry — calculate_part_offset_and_length, calculate_part_geometry
# =========================================================================
class PartGeometryUnitTest < Minitest::Test
  def setup
    @state = OpenStruct.new(part_size: 1000, total_size: 3500)
    @host = Object.new
    @host.instance_variable_set(:@state, @state)
    @host.extend(S3PartGeometry)
  end

  def test_calculate_part_offset_and_length_middle
    offset, length = @host.calculate_part_offset_and_length(2)
    assert_equal 1000, offset
    assert_equal 1000, length
  end

  def test_calculate_part_offset_and_length_last
    offset, length = @host.calculate_part_offset_and_length(4)
    assert_equal 3000, offset
    assert_equal 500, length
  end

  def test_calculate_part_offset_and_length_custom_params
    offset, length = @host.calculate_part_offset_and_length(3, 500, 2000)
    assert_equal 1000, offset
    assert_equal 500, length
  end

  def test_calculate_part_geometry
    offset, length, end_byte = @host.calculate_part_geometry(1)
    assert_equal 0, offset
    assert_equal 1000, length
    assert_equal 999, end_byte
  end

  def test_calculate_part_geometry_last_part
    offset, length, end_byte = @host.calculate_part_geometry(4)
    assert_equal 3000, offset
    assert_equal 500, length
    assert_equal 3499, end_byte
  end
end

# =========================================================================
# ProgressTracker — global_throughput, eta_seconds, progress_pct, etc.
# =========================================================================
class ProgressTrackerUnitTest < Minitest::Test
  def setup
    @state = OpenStruct.new(
      part_size: 1000,
      total_size: 3000,
      bytes_uploaded: 2000,
      parts: { 1 => "etag1", 2 => "etag2" }
    )

    mock_client = Object.new
    mock_client.define_singleton_method(:now_mono) { Process.clock_gettime(Process::CLOCK_MONOTONIC) }
    mock_client.define_singleton_method(:human_readable_size) do |s|
      return "0 B" if s.nil? || s.zero?

      "%0.2f KB" % (s / 1024.0)
    end
    mock_client.define_singleton_method(:log_info) { |_msg| }

    @host = Object.new
    @host.instance_variable_set(:@state, @state)
    @host.instance_variable_set(:@client, mock_client)
    @host.extend(S3ProgressTracker)
  end

  def test_global_throughput
    result = @host.global_throughput(1024 * 1024, 1.0)
    assert_in_delta 1.0, result, 0.01
  end

  def test_global_throughput_zero_elapsed
    result = @host.global_throughput(100, 0)
    assert_equal 0, result
  end

  def test_eta_seconds
    result = @host.eta_seconds(1024 * 1024, 1.0)
    assert_in_delta 1.0, result, 0.01
  end

  def test_eta_seconds_zero_throughput
    result = @host.eta_seconds(1000, 0)
    assert_equal 0, result
  end

  def test_progress_pct
    assert_equal 50.0, @host.progress_pct(1, 2)
    assert_equal 0, @host.progress_pct(0, 0)
  end

  def test_calculate_pre_transferred_bytes
    result = @host.calculate_pre_transferred_bytes(Set.new([1, 2]))
    assert_equal 2000, result
  end

  def test_calculate_pre_transferred_bytes_with_partial_last
    @state.total_size = 2500
    result = @host.calculate_pre_transferred_bytes(Set.new([1, 2]))
    assert_equal 2000, result
  end

  def test_current_transferred_bytes
    assert_equal 2000, @host.current_transferred_bytes
  end

  def test_log_part_complete
    t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    @host.log_part_complete("t0", 1, 3, 1000, 500.0, 2.0, "abcdef1234567890abcdef", 3000, t0)
  end
end
