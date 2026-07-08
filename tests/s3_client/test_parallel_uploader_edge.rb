# frozen_string_literal: true

require_relative "../test_helper"
require_relative "../../src/s3-stream-multipart"

class ParallelUploaderEdgeTest < Minitest::Test
  include S3TestHelpers

  PORT = 15_604

  def setup
    dir = suite_tmp_dir("parallel_uploader_edge")
    @store_dir = File.join(dir, "store")
    @tmp_dir   = File.join(dir, "tmp")
    @server = FakeS3::Server.new(port: PORT, store_dir: @store_dir, tmp_dir: @tmp_dir)
    @server.start_thread

    @client = S3Client.new(
      region: "us-east-1", bucket: "b", access_key_id: "a", secret_access_key: "k",
      endpoint: "http://127.0.0.1:#{PORT}", endpoint_style: :path,
      part_size: 5 * 1024 * 1024, max_concurrency: 1,
      max_retries: 2, retry_delay: 0.01,
      compute_md5: true,
      logger: Logger.new(File::NULL)
    )
  end

  def teardown
    @server.stop
  end

  # --- parallel_uploader.rb line 109: open_http_connection ---

  def test_parallel_uploader_open_http_connection
    require_relative "../../src/concurrent/parallel_uploader"

    state = UploadState.new(
      upload_id: "uid", key: "/test.bin",
      part_size: 5 * 1024 * 1024, total_size: 10 * 1024 * 1024,
      local_path: "/tmp/test.bin", parts: {}
    )

    uploader = S3ParallelUploader.new(
      @client, state,
      max_threads: 1, max_retries: 1, retry_delay: 0.01
    )

    uploader.send(:open_http_connection, nil) { |http| assert_nil http }
  end

  # --- parallel_uploader.rb line 114: build_result NotImplementedError ---

  def test_parallel_uploader_build_result_not_implemented
    require_relative "../../src/concurrent/parallel_uploader"

    state = UploadState.new(
      upload_id: "uid", key: "/test.bin",
      part_size: 5 * 1024 * 1024, total_size: 10 * 1024 * 1024,
      local_path: "/tmp/test.bin", parts: {}
    )

    uploader = S3ParallelUploader.new(
      @client, state,
      max_threads: 1, max_retries: 1, retry_delay: 0.01
    )

    assert_raises(NotImplementedError) do
      uploader.send(:build_result)
    end
  end

  # --- parallel_uploader.rb line 99: upload_part_with_retry NotImplementedError ---

  def test_parallel_uploader_upload_part_not_implemented
    require_relative "../../src/concurrent/parallel_uploader"

    state = UploadState.new(
      upload_id: "uid", key: "/test.bin",
      part_size: 5 * 1024 * 1024, total_size: 10 * 1024 * 1024,
      local_path: "/tmp/test.bin", parts: {}
    )

    uploader = S3ParallelUploader.new(
      @client, state,
      max_threads: 1, max_retries: 1, retry_delay: 0.01
    )

    assert_raises(NotImplementedError) do
      uploader.send(:upload_part_with_retry, 1, nil, "t0")
    end
  end

  # --- parallel_uploader.rb line 305: safe_native_thread_id ---

  def test_parallel_uploader_safe_native_thread_id
    require_relative "../../src/concurrent/parallel_uploader"

    state = UploadState.new(
      upload_id: "uid", key: "/test.bin",
      part_size: 5 * 1024 * 1024, total_size: 10 * 1024 * 1024,
      local_path: "/tmp/test.bin", parts: {}
    )

    uploader = S3ParallelUploader.new(
      @client, state,
      max_threads: 1, max_retries: 1, retry_delay: 0.01
    )

    tid = uploader.send(:safe_native_thread_id)
    assert tid.nil? || tid.is_a?(Integer)
  end

  # --- parallel_uploader.rb on_part_failed + rescue in thread ---

  def test_part_upload_failure_in_thread
    events = []
    S3Client.on(:part_failed) { |*a| events << a }

    src_path, = create_temp_binary_file(12 * 1024 * 1024)

    call_count = 0
    orig = @client.method(:build_http_request)
    @client.define_singleton_method(:build_http_request) do |method, uri, body, extra_headers, **opts|
      req = orig.call(method, uri, body, extra_headers, **opts)
      if method.to_s.downcase.to_sym == :put
        call_count += 1
        raise "Simulated part failure" if call_count > 1
      end
      req
    end

    assert_raises(S3BaseClient::UploadError) do
      @client.upload_file(
        local_path: src_path, key: "/thread_fail.bin",
        part_size: 5 * 1024 * 1024
      )
    end

    assert events.size >= 1, "part_failed event should fire"
  ensure
    File.delete(src_path) if src_path && File.exist?(src_path)
    S3Client.clear_callbacks!
  end

  # --- thread_pool.rb: join_threads with Interrupt ---

  def test_join_threads_interrupt_handler
    require_relative "../../src/concurrent/parallel_uploader"
    require_relative "../../src/concurrent/parallel_downloader"

    state = UploadState.new(
      upload_id: "uid-int", key: "/test.bin",
      part_size: 5 * 1024 * 1024, total_size: 10 * 1024 * 1024,
      local_path: "/tmp/test.bin", parts: {}
    )

    uploader = S3ParallelUploader.new(
      @client, state,
      max_threads: 1, max_retries: 1, retry_delay: 0.01
    )

    worker = Thread.new { sleep 60 }
    worker.report_on_exception = false
    shutdown_called = false
    interrupter = Thread.new do
      sleep 0.05
      Thread.main.raise(Interrupt)
    end
    assert_raises(Interrupt) do
      uploader.send(:join_threads, [worker]) { shutdown_called = true }
    end
    assert shutdown_called
  ensure
    begin; worker&.kill; rescue StandardError; nil; end
    begin; interrupter&.kill; rescue StandardError; nil; end
  end
end
