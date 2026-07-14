# frozen_string_literal: true

require_relative "../test_helper"
require_relative "../../src/s3-stream-multipart"

class UploadResilienceTest < Minitest::Test
  include S3TestHelpers

  PORT = 15_603

  def setup
    dir = suite_tmp_dir("upload_resilience")
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

  # --- compute_upload_session_metadata: file metadata computation error rescue ---

  def test_file_metadata_computation_error
    src_path, = create_temp_binary_file(6 * 1024 * 1024)
    state_file = File.join(@store_dir, "metadata_state.json")

    r = with_stubbed(Digest::MD5, :file, ->(*) { raise Errno::EACCES, "Permission denied" }) do
      @client.upload_file(
        local_path: src_path, key: "/metadata_err.bin",
        state_file: state_file
      )
    end
    assert r[:etag], "Upload should succeed even if MD5 computation fails"
  ensure
    File.delete(src_path) if src_path && File.exist?(src_path)
  end

  # --- PartUploader retry in upload_part_with_retry ---

  def test_upload_part_via_transient_retry
    src_path, = create_temp_binary_file(12 * 1024 * 1024)

    call_count = 0
    orig_build_http_request = @client.method(:build_http_request)
    @client.define_singleton_method(:build_http_request) do |method, uri, body, extra_headers, **opts|
      req = orig_build_http_request.call(method, uri, body, extra_headers, **opts)
      if method.to_s.downcase.to_sym == :put
        call_count += 1
        raise EOFError, "Simulated transient EOF" if call_count <= 2
      end
      req
    end

    r = @client.upload_file(
      local_path: src_path, key: "/transient_retry.bin",
      part_size: 5 * 1024 * 1024
    )
    assert r[:etag], "Upload should succeed after transient retry"
    assert call_count >= 3, "Should have retried at least once (call_count=#{call_count})"
  ensure
    File.delete(src_path) if src_path && File.exist?(src_path)
  end

  def test_upload_part_via_s3error_retry
    src_path, = create_temp_binary_file(12 * 1024 * 1024)

    call_count = 0
    orig_build_http_request = @client.method(:build_http_request)
    @client.define_singleton_method(:build_http_request) do |method, uri, body, extra_headers, **opts|
      req = orig_build_http_request.call(method, uri, body, extra_headers, **opts)
      if method.to_s.downcase.to_sym == :put
        call_count += 1
        raise S3BaseClient::S3Error.new("500", "Server error", "req-1") if call_count <= 2
      end
      req
    end

    r = @client.upload_file(
      local_path: src_path, key: "/s3error_retry.bin",
      part_size: 5 * 1024 * 1024
    )
    assert r[:etag], "Upload should succeed after S3 500 retry"
    assert call_count >= 3, "Should have retried at least once (call_count=#{call_count})"
  ensure
    File.delete(src_path) if src_path && File.exist?(src_path)
  end

  def test_upload_part_via_retry_exhausted
    src_path, = create_temp_binary_file(12 * 1024 * 1024)

    orig = @client.method(:build_http_request)
    @client.define_singleton_method(:build_http_request) do |method, uri, body, extra_headers, **opts|
      if method.to_s.downcase.to_sym == :put
        raise EOFError, "Persistent EOF"
      end

      orig.call(method, uri, body, extra_headers, **opts)
    end

    assert_raises(S3BaseClient::UploadError) do
      @client.upload_file(
        local_path: src_path, key: "/retry_exhausted.bin",
        part_size: 5 * 1024 * 1024
      )
    end
  ensure
    File.delete(src_path) if src_path && File.exist?(src_path)
  end

  # --- PartUploader Interrupt during upload ---

  def test_upload_interrupt_in_main_thread
    src_path, = create_temp_binary_file(12 * 1024 * 1024)
    barrier = Queue.new
    call_count = 0

    orig = @client.method(:ensure_success!)
    @client.define_singleton_method(:ensure_success!) do |resp|
      call_count += 1
      if call_count == 2
        barrier << :started
        sleep 2
      end
      orig.call(resp)
    end

    interrupter = Thread.new do
      Timeout.timeout(5) do
        barrier.pop
        sleep 0.1
        Thread.main.raise(Interrupt)
      end
    rescue Timeout::Error
      # ignore
    end

    assert_raises(Interrupt) do
      @client.upload_file(
        local_path: src_path, key: "/interrupt_test.bin",
        part_size: 5 * 1024 * 1024
      )
    end
  ensure
    begin
      interrupter&.kill
    rescue StandardError
      nil
    end
    begin
      @client.singleton_class.remove_method(:ensure_success!)
    rescue StandardError
      nil
    end
    File.delete(src_path) if src_path && File.exist?(src_path)
  end

  # --- PartUploader upload_part_with_retry retry paths ---

  def test_part_upload_with_retry_exhausted
    uid = @client.send(:create_multipart_upload, key: "/exhausted_direct.bin",
                                                 content_type: "application/octet-stream", metadata: {})
    src_path, = create_temp_binary_file(5 * 1024 * 1024)

    state = UploadState.new(
      upload_id: uid, key: "/exhausted_direct.bin",
      part_size: 5 * 1024 * 1024, total_size: 5 * 1024 * 1024,
      local_path: src_path
    )

    call_count = 0
    @client.upload_transport.define_singleton_method(:upload_part) do |*|
      call_count += 1
      raise EOFError, "Persistent transport error"
    end

    uploader = PartUploader.new(
      @client, state,
      max_threads: 1, max_retries: 3, retry_delay: 0.001,
      local_path: src_path, total_size: 5 * 1024 * 1024
    )

    assert_raises(EOFError) do
      uploader.send(:upload_part_with_retry, 1, nil, "t0")
    end
    assert call_count > 1, "Should have retried and exhausted"
  ensure
    File.delete(src_path) if src_path && File.exist?(src_path)
    begin
      @client.send(:safe_abort, key: "/exhausted_direct.bin", upload_id: uid)
    rescue StandardError
      nil
    end
  end

  def test_part_upload_with_retry_transient_then_success
    uid = @client.send(:create_multipart_upload, key: "/transient_direct.bin",
                                                 content_type: "application/octet-stream", metadata: {})
    src_path, = create_temp_binary_file(5 * 1024 * 1024)

    state = UploadState.new(
      upload_id: uid, key: "/transient_direct.bin",
      part_size: 5 * 1024 * 1024, total_size: 5 * 1024 * 1024,
      local_path: src_path
    )

    call_count = 0
    @client.upload_transport.define_singleton_method(:upload_part) do |*|
      call_count += 1
      if call_count <= 2
        raise EOFError, "Transient error #{call_count}"
      end

      '"mock-etag-retry"'
    end

    uploader = PartUploader.new(
      @client, state,
      max_threads: 1, max_retries: 5, retry_delay: 0.001,
      local_path: src_path, total_size: 5 * 1024 * 1024
    )

    etag = uploader.send(:upload_part_with_retry, 1, nil, "t0")
    assert etag
    assert call_count >= 3, "Should have retried (call_count=#{call_count})"
  ensure
    File.delete(src_path) if src_path && File.exist?(src_path)
    begin
      @client.send(:safe_abort, key: "/transient_direct.bin", upload_id: uid)
    rescue StandardError
      nil
    end
  end

  def test_part_upload_with_retry_s3error_then_success
    uid = @client.send(:create_multipart_upload, key: "/s3error_direct.bin",
                                                 content_type: "application/octet-stream", metadata: {})
    src_path, = create_temp_binary_file(5 * 1024 * 1024)

    state = UploadState.new(
      upload_id: uid, key: "/s3error_direct.bin",
      part_size: 5 * 1024 * 1024, total_size: 5 * 1024 * 1024,
      local_path: src_path
    )

    http_mock = Object.new
    call_count = 0
    http_mock.define_singleton_method(:request) do |req|
      call_count += 1
      if call_count <= 2
        resp = Net::HTTPServiceUnavailable.new(1.0, 503, "Service Unavailable")
        resp.instance_variable_set(:@read, true)
      else
        resp = Net::HTTPOK.new(1.0, 200, "OK")
        resp.instance_variable_set(:@read, true)
        resp["ETag"] = '"mock-etag-s3error"'
      end
      resp
    end

    uploader = PartUploader.new(
      @client, state,
      max_threads: 1, max_retries: 5, retry_delay: 0.001,
      local_path: src_path, total_size: 5 * 1024 * 1024
    )

    etag = uploader.send(:upload_part_with_retry, 1, http_mock, "t0")
    assert etag
  ensure
    File.delete(src_path) if src_path && File.exist?(src_path)
    begin
      @client.send(:safe_abort, key: "/s3error_direct.bin", upload_id: uid)
    rescue StandardError
      nil
    end
  end

  # --- upload_state.rb line 90: save_to_file fsync rescue ---

  def test_upload_state_save_to_file_fsync_rescue
    state = UploadState.new(
      upload_id: "uid-fsync", key: "/test.bin",
      part_size: 5 * 1024 * 1024, total_size: 10 * 1024 * 1024,
      local_path: "/tmp/test.bin"
    )
    state_file = File.join(@store_dir, "fsync_rescue.json")

    dirname = File.dirname(state_file)
    raised = false
    original_open = File.method(:open)

    with_stubbed(File, :open, lambda { |path, *args, &block|
      if path == dirname
        raised = true
        raise Errno::EISDIR, "Is a directory"
      end
      original_open.call(path, *args, &block)
    }) do
      state.save_to_file(state_file)
    end

    assert File.exist?(state_file), "File should be saved despite fsync error"
    assert raised, "EISDIR should have been raised"
  ensure
    FileUtils.rm_f(state_file) if state_file
  end

  # --- Upload with retry on 500 S3 error (full multipart path) ---

  def test_full_multipart_with_transient_error
    src_path, = create_temp_binary_file(12 * 1024 * 1024)
    call_count = 0
    orig = @client.method(:build_http_request)
    @client.define_singleton_method(:build_http_request) do |method, uri, body, extra_headers, **opts|
      req = orig.call(method, uri, body, extra_headers, **opts)
      if method.to_s.downcase.to_sym == :put
        call_count += 1
        if call_count == 1
          resp = Net::HTTPServiceUnavailable.new(1.0, 503, "Service Unavailable")
          resp.instance_variable_set(:@read, true)
          raise S3BaseClient::S3Error.new("503", "Service Unavailable")
        end
      end
      req
    end

    result = @client.upload_file(
      local_path: src_path, key: "/mp_503_retry.bin",
      part_size: 5 * 1024 * 1024
    )
    assert result[:etag], "Upload should succeed after 503 retry"
  ensure
    begin
      @client.singleton_class.remove_method(:build_http_request)
    rescue StandardError
      nil
    end
    File.delete(src_path) if src_path && File.exist?(src_path)
  end
end
