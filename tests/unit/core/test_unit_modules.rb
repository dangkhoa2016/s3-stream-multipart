# frozen_string_literal: true

require "test_helper"
require_relative "../../../src/core/base_client"
require_relative "../../../src/concurrent/thread_tracking"
require_relative "../../../src/extras/retry_helper"
require_relative "../../../src/core/request_executor"
require_relative "../../../src/states/download_state"
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
    def @client.now_iso = "2026-01-01T00:00:00Z"
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
    def @client.backoff_with_jitter(attempt) = 0.001

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

  def backoff_with_jitter(attempt) = 0.001
  def now_mono = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  def log_debug(msg = nil, &); end
  def log_warn(msg = nil, &); end
  def log_error(msg = nil, &); end
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
