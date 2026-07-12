# frozen_string_literal: true

require_relative "../test_helper"
require_relative "../../src/s3_client"

class S3EventRegistryTest < Minitest::Test
  def setup
    S3Client.clear_callbacks!
    @client = S3Client.new(
      bucket: "b", region: "us-east-1",
      access_key_id: "AK", secret_access_key: "SK",
      endpoint: "http://127.0.0.1:19999",
      open_timeout: 5, read_timeout: 30,
      logger: Logger.new(File::NULL)
    )
  end

  def test_on_requires_block
    assert_raises(ArgumentError) { S3Client.on(:upload_start) }
  end

  def test_on_and_emit
    events = []
    S3Client.on(:upload_start) { |*a| events << a }
    @client.emit_event(:upload_start, "file", "key", 100, 2, 50, false)
    assert_equal 1, events.size
    assert_equal ["file", "key", 100, 2, 50, false], events.first
  end

  def test_off
    events = []
    cb = S3Client.on(:upload_start) { events << 1 }
    S3Client.off(:upload_start, cb)
    @client.emit_event(:upload_start)
    assert events.empty?
  end

  def test_multiple_callbacks
    results = []
    S3Client.on(:upload_start) { results << 1 }
    S3Client.on(:upload_start) { results << 2 }
    @client.emit_event(:upload_start)
    assert_equal [1, 2], results
  end

  def test_clear_callbacks
    S3Client.on(:upload_start) { flunk "should not be called" }
    S3Client.clear_callbacks!
    @client.emit_event(:upload_start)
  end

  def test_drain_logs_debug
    S3Client.log_queue.clear
    S3Client.log_queue << [:debug, "debug msg", "t1", Time.now.iso8601]
    assert_equal 1, S3Client.drain_logs(Logger.new(File::NULL))
  end

  def test_drain_logs_warn
    S3Client.log_queue.clear
    S3Client.log_queue << [:warn, "warn msg", "t2", Time.now.iso8601]
    assert_equal 1, S3Client.drain_logs(Logger.new(File::NULL))
  end

  def test_drain_logs_error
    S3Client.log_queue.clear
    S3Client.log_queue << [:error, "error msg", "t3", Time.now.iso8601]
    assert_equal 1, S3Client.drain_logs(Logger.new(File::NULL))
  end

  def test_drain_logs_unknown_level
    S3Client.log_queue.clear
    S3Client.log_queue << [:unknown_level, "fallback", "t4", Time.now.iso8601]
    assert_equal 1, S3Client.drain_logs(Logger.new(File::NULL))
  end

  def test_drain_logs_empty
    S3Client.log_queue.clear
    assert_equal 0, S3Client.drain_logs(Logger.new(File::NULL))
  end

  def test_drain_logs_info_default
    S3Client.log_queue.clear
    S3Client.log_queue << [:info, "info msg", "t5", Time.now.iso8601]
    assert_equal 1, S3Client.drain_logs(Logger.new(File::NULL))
  end

  def test_drain_logs_with_nil_logger
    S3Client.log_queue.clear
    S3Client.log_queue << [:info, "msg", "t0", Time.now.iso8601]
    assert_equal 1, S3Client.drain_logs(nil)
  end

  def test_on_returns_block
    cb = proc { |_a| }
    result = S3Client.on(:upload_start, &cb)
    assert_equal cb, result
  end

  def test_drain_logs_all_levels
    q = S3Client.instance_variable_get(:@log_queue)
    q << [:info,  "info msg",  "t0", Time.now]
    q << [:debug, "debug msg", "t1", Time.now]
    q << [:warn,  "warn msg",  "t2", Time.now]
    q << [:error, "error msg", "t3", Time.now]

    logger = Logger.new(File::NULL)
    count = S3Client.drain_logs(logger)
    assert_equal 4, count
    assert q.empty?
  end
end
