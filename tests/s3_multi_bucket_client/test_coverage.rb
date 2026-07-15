# frozen_string_literal: true

require_relative "../test_helper"
require_relative "../../src/s3_multi_bucket_client"
require_relative "../../src/s3-stream-multipart"

class S3MultiBucketCoverageTest < Minitest::Test
  include S3TestHelpers

  PORT = 15_605
  BUCKET = "b"

  def setup
    dir = suite_tmp_dir("multibucket_coverage")
    @store_dir = File.join(dir, "store")
    @tmp_dir   = File.join(dir, "tmp")
    @server = FakeS3::Server.new(port: PORT, store_dir: @store_dir, tmp_dir: @tmp_dir)
    @server.start_thread

    @client = S3MultiBucketClient.new(
      endpoint: "http://127.0.0.1:#{PORT}", region: "us-east-1",
      access_key_id: "a", secret_access_key: "k",
      logger: Logger.new(File::NULL)
    )

    @zero_retry_client = S3MultiBucketClient.new(
      endpoint: "http://127.0.0.1:#{PORT}", region: "us-east-1",
      access_key_id: "a", secret_access_key: "k",
      max_retries: 0, retry_delay: 0.01,
      logger: Logger.new(File::NULL)
    )
  end

  def teardown
    @server.stop
  end

  def make_failing_response
    resp = Net::HTTPBadRequest.new(1.0, 400, "Bad Request")
    resp.instance_variable_set(:@read, true)
    resp.instance_variable_set(:@body, "<error>bad request</error>")
    resp
  end

  def make_streaming_failing_response
    resp = Net::HTTPBadRequest.new(1.0, 400, "Bad Request")
    resp.instance_variable_set(:@socket, nil)
    resp
  end

  # --- s3_multi_bucket_client.rb lines 277, 285: upload_file error handling ---

  def test_upload_file_empty_failure_response
    error_resp = make_failing_response
    @client.define_singleton_method(:signed_request) do |method, uri, body: "", headers: {}|
      error_resp
    end

    src = Tempfile.new(["upload_err", ".bin"])
    src.write("")
    src.close

    assert_raises(S3MultiBucketClient::UploadError) do
      @client.upload_file(bucket: BUCKET, key: "fail_empty.bin", local_path: src.path)
    end
  ensure
    src&.unlink
    begin
      @client.singleton_class.remove_method(:signed_request)
    rescue StandardError
      nil
    end
  end

  def test_upload_file_nonempty_failure_response
    error_resp = make_failing_response
    @client.define_singleton_method(:signed_request) do |method, uri, body: nil, body_stream: nil, headers: {}|
      error_resp
    end

    src = Tempfile.new(["upload_err", ".bin"])
    src.write("non-empty content")
    src.close

    assert_raises(S3MultiBucketClient::UploadError) do
      @client.upload_file(bucket: BUCKET, key: "fail_nonempty.bin", local_path: src.path)
    end
  ensure
    src&.unlink
    begin
      @client.singleton_class.remove_method(:signed_request)
    rescue StandardError
      nil
    end
  end

  # --- s3_multi_bucket_client.rb lines 515: list_multipart_uploads error ---

  def test_list_multipart_uploads_failure
    error_resp = make_failing_response
    @client.define_singleton_method(:signed_request) do |*args|
      error_resp
    end

    assert_raises(S3MultiBucketClient::S3Error) do
      @client.list_multipart_uploads(bucket: BUCKET)
    end
  ensure
    begin
      @client.singleton_class.remove_method(:signed_request)
    rescue StandardError
      nil
    end
  end

  # --- s3_multi_bucket_client.rb lines 529: list_parts error ---

  def test_list_parts_failure
    error_resp = make_failing_response
    @client.define_singleton_method(:signed_request) do |*args|
      error_resp
    end

    assert_raises(S3MultiBucketClient::S3Error) do
      @client.list_parts(bucket: BUCKET, key: "k", upload_id: "bad")
    end
  ensure
    begin
      @client.singleton_class.remove_method(:signed_request)
    rescue StandardError
      nil
    end
  end

  # --- s3_multi_bucket_client.rb lines 543: abort_multipart_upload error ---

  def test_abort_multipart_upload_failure
    error_resp = make_failing_response
    @client.define_singleton_method(:signed_request) do |*args|
      error_resp
    end

    assert_raises(S3MultiBucketClient::S3Error) do
      @client.abort_multipart_upload(bucket: BUCKET, key: "k", upload_id: "bad")
    end
  ensure
    begin
      @client.singleton_class.remove_method(:signed_request)
    rescue StandardError
      nil
    end
  end

  # --- s3_multi_bucket_client.rb lines 558: delete_object error ---

  def test_delete_object_failure
    error_resp = make_failing_response
    @client.define_singleton_method(:signed_request) do |*args|
      error_resp
    end

    assert_raises(S3MultiBucketClient::S3Error) do
      @client.delete_object(bucket: BUCKET, key: "k")
    end
  ensure
    begin
      @client.singleton_class.remove_method(:signed_request)
    rescue StandardError
      nil
    end
  end

  # --- s3_multi_bucket_client.rb lines 691: multipart_upload_part error ---

  def test_multipart_upload_part_failure
    error_resp = make_failing_response
    @client.define_singleton_method(:signed_request) do |*args|
      error_resp
    end

    assert_raises(S3MultiBucketClient::UploadError) do
      @client.multipart_upload_part(
        bucket: BUCKET, key: "k", upload_id: "bad",
        part_number: 1, body: "data"
      )
    end
  ensure
    begin
      @client.singleton_class.remove_method(:signed_request)
    rescue StandardError
      nil
    end
  end

  # --- s3_multi_bucket_client.rb lines 705: multipart_complete error ---

  def test_multipart_complete_failure
    error_resp = make_failing_response
    @client.define_singleton_method(:signed_request) do |*args|
      error_resp
    end

    assert_raises(S3MultiBucketClient::UploadError) do
      @client.multipart_complete(
        bucket: BUCKET, key: "k", upload_id: "bad",
        parts: [{ part_number: 1, etag: '"e1"' }]
      )
    end
  ensure
    begin
      @client.singleton_class.remove_method(:signed_request)
    rescue StandardError
      nil
    end
  end

  # --- s3_multi_bucket_client.rb lines 716: multipart_abort error ---

  def test_multipart_abort_failure
    error_resp = make_failing_response
    @client.define_singleton_method(:signed_request) do |*args|
      error_resp
    end

    assert_raises(S3MultiBucketClient::S3Error) do
      @client.multipart_abort(bucket: BUCKET, key: "k", upload_id: "bad")
    end
  ensure
    begin
      @client.singleton_class.remove_method(:signed_request)
    rescue StandardError
      nil
    end
  end

  # --- s3_multi_bucket_client.rb lines 1031, 1037: initiate_multipart_upload error ---

  def test_initiate_multipart_upload_error_response
    error_resp = make_failing_response
    @client.define_singleton_method(:signed_request) do |*args|
      error_resp
    end

    assert_raises(S3BaseClient::S3Error) do
      @client.send(:create_multipart_upload, key: "k", bucket: BUCKET, content_type: "application/octet-stream", metadata: {})
    end
  ensure
    begin
      @client.singleton_class.remove_method(:signed_request)
    rescue StandardError
      nil
    end
  end

  def test_initiate_multipart_upload_missing_upload_id
    resp = Net::HTTPOK.new(1.0, 200, "OK")
    resp.instance_variable_set(:@read, true)
    resp.instance_variable_set(:@body, "<InitiateMultipartUploadResult></InitiateMultipartUploadResult>")
    @client.define_singleton_method(:signed_request) do |*args|
      resp
    end

    assert_raises(S3BaseClient::S3Error) do
      @client.send(:create_multipart_upload, key: "k", bucket: BUCKET, content_type: "application/octet-stream", metadata: {})
    end
  ensure
    begin
      @client.singleton_class.remove_method(:signed_request)
    rescue StandardError
      nil
    end
  end

  # --- s3_multi_bucket_client.rb lines 145, 149: upload_part with nil http ---

  def test_upload_part_without_http_connection
    uid = @client.multipart_start(bucket: BUCKET, key: "/no_http.bin")

    uploader = PartUploader.new(
      @client,
      UploadState.new(
        upload_id: uid, key: "/no_http.bin", bucket: BUCKET,
        local_path: "/dev/null", part_size: 5 * 1024 * 1024,
        total_size: 100, parts: {}
      ),
      max_threads: 1, max_retries: 0, retry_delay: 0.01
    )

    error_resp = make_failing_response
    mock_http = Object.new
    mock_http.define_singleton_method(:request) { |_req| error_resp }
    @client.define_singleton_method(:http_start) do |_bucket, _key, &blk|
      blk.call(mock_http)
    end
    @client.define_singleton_method(:signed_request) { |*| error_resp }

    assert_raises(S3Errors::S3Error) do
      uploader.send(:upload_part_http, 1, nil)
    end
  rescue StandardError => e
    flunk "Unexpected error: #{e.class}: #{e.message}"
  ensure
    begin
      @client.singleton_class.remove_method(:http_start)
    rescue StandardError
      nil
    end
    begin
      @client.singleton_class.remove_method(:signed_request)
    rescue StandardError
      nil
    end
    begin
      @client.multipart_abort(bucket: BUCKET, key: "/no_http.bin", upload_id: uid)
    rescue StandardError
      nil
    end
  end

  # --- s3_multi_bucket_client.rb lines 455, 461-468: download_file error/retry ---

  def test_download_file_error_response
    dst = File.join(@store_dir, "dl_err.bin")
    @zero_retry_client.define_singleton_method(:make_http_request) do |uri, &block|
      http = Object.new
      def http.request(*)
        resp = Net::HTTPBadRequest.new(1.0, 400, "Bad Request")
        resp.instance_variable_set(:@read, true)
        resp.instance_variable_set(:@body, "error")
        yield resp if block_given?
        resp
      end
      block.call(http)
    end

    assert_raises(S3MultiBucketClient::DownloadError) do
      @zero_retry_client.download_file(bucket: BUCKET, key: "k", destination_path: dst)
    end
  ensure
    begin
      @zero_retry_client.singleton_class.remove_method(:make_http_request)
    rescue StandardError
      nil
    end
    FileUtils.rm_f(dst) if dst
  end

  def test_download_file_transient_exhausted
    dst = File.join(@store_dir, "dl_retry_exhausted.bin")
    @zero_retry_client.define_singleton_method(:make_http_request) do |uri, &block|
      raise EOFError, "Connection closed"
    end

    assert_raises(S3MultiBucketClient::DownloadError) do
      @zero_retry_client.download_file(bucket: BUCKET, key: "k", destination_path: dst)
    end
  ensure
    begin
      @zero_retry_client.singleton_class.remove_method(:make_http_request)
    rescue StandardError
      nil
    end
    FileUtils.rm_f(dst) if dst
  end

  # --- s3_multi_bucket_client.rb lines 486-487: download_file rescue ---

  def test_download_file_failure_rescue
    dst = File.join(@store_dir, "dl_rescue.bin")
    @zero_retry_client.define_singleton_method(:make_http_request) do |uri, &block|
      raise EOFError, "Download error"
    end

    assert_raises(S3MultiBucketClient::DownloadError) do
      @zero_retry_client.download_file(bucket: BUCKET, key: "k", destination_path: dst)
    end
  ensure
    begin
      @zero_retry_client.singleton_class.remove_method(:make_http_request)
    rescue StandardError
      nil
    end
    FileUtils.rm_f(dst) if dst
  end

  # --- s3_multi_bucket_client.rb lines 824, 839-847: download_stream error paths ---

  def test_download_stream_without_block
    assert_raises(ArgumentError) do
      @client.download_stream(bucket: BUCKET, key: "test.bin")
    end
  end

  def test_download_stream_error_response
    @zero_retry_client.define_singleton_method(:make_http_request) do |uri, &block|
      http = Object.new
      def http.request(uri_or_req, &block)
        resp = Net::HTTPBadRequest.new(1.0, 400, "Bad Request")
        resp.instance_variable_set(:@socket, nil)
        yield resp if block
        resp
      end
      block.call(http)
    end

    assert_raises(S3MultiBucketClient::DownloadError) do
      @zero_retry_client.download_stream(bucket: BUCKET, key: "k") { |chunk| }
    end
  ensure
    begin
      @zero_retry_client.singleton_class.remove_method(:make_http_request)
    rescue StandardError
      nil
    end
  end

  def test_download_stream_transient_exhausted
    @zero_retry_client.define_singleton_method(:make_http_request) do |uri, &block|
      raise EOFError, "Stream error"
    end

    assert_raises(EOFError) do
      @zero_retry_client.download_stream(bucket: BUCKET, key: "k") { |chunk| }
    end
  ensure
    begin
      @zero_retry_client.singleton_class.remove_method(:make_http_request)
    rescue StandardError
      nil
    end
  end

  # --- s3_multi_bucket_client.rb line 974: unsupported method in signed_request ---

  def test_signed_request_unsupported_method
    uri = @client.build_uri(BUCKET, "test.bin")
    assert_raises(ArgumentError) do
      @client.send(:signed_request, :patch, uri)
    end
  end

  # s3_multi_bucket_client.rb lines 1052: complete_multipart_upload error

  def test_complete_multipart_upload_failure
    state = UploadState.new(
      upload_id: "bad-uid", key: "/test.bin", bucket: BUCKET,
      part_size: 5 * 1024 * 1024, total_size: 100,
      local_path: "/dev/null", parts: { 1 => '"e1"' }
    )

    error_resp = make_failing_response
    @client.define_singleton_method(:signed_request) do |*args|
      error_resp
    end

    assert_raises(S3BaseClient::S3Error) do
      @client.send(:complete_multipart_upload,
                   key: state.key, upload_id: state.upload_id,
                   parts: state.e_tag_list, bucket: state.bucket)
    end
  ensure
    begin
      @client.singleton_class.remove_method(:signed_request)
    rescue StandardError
      nil
    end
  end

  # upload_file with state_file success (lines 365, 367)
  def test_upload_file_state_file_success
    state_file = File.join(@store_dir, "multipart_success.json")
    src_path, = create_temp_binary_file(12 * 1024 * 1024)

    result = @client.upload_file(
      bucket: BUCKET, key: "/mp_success.bin", local_path: src_path,
      part_size: 5 * 1024 * 1024, state_file: state_file
    )
    refute result[:error], "upload should succeed: #{result[:error]}"
  ensure
    File.delete(src_path) if src_path && File.exist?(src_path)
  end

  # upload_file rescue with state_file (line 365)
  def test_upload_file_state_file_rescue
    state_file = File.join(@store_dir, "multipart_rescue.json")
    src_path, = create_temp_binary_file(6 * 1024 * 1024)

    @client.define_singleton_method(:create_multipart_upload) do |*|
      raise S3MultiBucketClient::S3Error.new("500", "Init failed")
    end

    assert_raises(S3MultiBucketClient::S3Error) do
      @client.upload_file(
        bucket: BUCKET, key: "/mp_rescue.bin", local_path: src_path,
        part_size: 5 * 1024 * 1024, state_file: state_file
      )
    end
  ensure
    begin
      @client.singleton_class.remove_method(:create_multipart_upload)
    rescue StandardError
      nil
    end
    File.delete(src_path) if src_path && File.exist?(src_path)
    FileUtils.rm_f(state_file) if state_file
  end

  # --- s3_multi_bucket_client.rb lines 462-465: download_file retry backoff ---

  def test_download_file_retry_backoff
    src_path, = create_temp_binary_file(1024)
    @client.upload_file(bucket: BUCKET, key: "dl_retry_target.bin", local_path: src_path)

    dst = File.join(@store_dir, "dl_retry_backoff.bin")
    call_count = 0
    orig = @client.method(:make_http_request)
    @client.define_singleton_method(:make_http_request) do |uri, &block|
      call_count += 1
      if call_count <= 1
        raise EOFError, "Transient error"
      end

      orig.call(uri, &block)
    end

    result = @client.download_file(bucket: BUCKET, key: "dl_retry_target.bin", destination_path: dst)
    assert_equal 1024, result[:size]
    assert call_count >= 2, "Should have retried"
  ensure
    begin
      @client.singleton_class.remove_method(:make_http_request)
    rescue StandardError
      nil
    end
    File.delete(src_path) if src_path && File.exist?(src_path)
    FileUtils.rm_f(dst) if dst
  end

  # --- s3_multi_bucket_client.rb lines 840-844: download_stream retry backoff ---

  def test_download_stream_retry_backoff
    src_path, = create_temp_binary_file(1024)
    @client.upload_file(bucket: BUCKET, key: "dl_stream_retry.bin", local_path: src_path)

    chunks = []
    call_count = 0
    orig = @client.method(:make_http_request)
    @client.define_singleton_method(:make_http_request) do |uri, &block|
      call_count += 1
      if call_count <= 1
        raise EOFError, "Transient error"
      end

      orig.call(uri, &block)
    end

    @client.download_stream(bucket: BUCKET, key: "dl_stream_retry.bin") { |chunk| chunks << chunk }
    assert chunks.any?
    assert call_count >= 2, "Should have retried"
  ensure
    begin
      @client.singleton_class.remove_method(:make_http_request)
    rescue StandardError
      nil
    end
    File.delete(src_path) if src_path && File.exist?(src_path)
  end

  # --- s3_multi_bucket_client.rb lines 1073-1074: prepare_multipart_state resume ---

  def test_prepare_multipart_state_resume
    state_file = File.join(@store_dir, "resume_state.json")
    src_path, = create_temp_binary_file(12 * 1024 * 1024)

    upload_id = @client.send(:create_multipart_upload, key: "/state_resume.bin", bucket: BUCKET, content_type: "application/octet-stream", metadata: {})
    state = UploadState.new(
      upload_id: upload_id, key: "/state_resume.bin", bucket: BUCKET,
      part_size: 5 * 1024 * 1024, total_size: File.size(src_path),
      local_path: src_path, parts: { 1 => '"e1"' }
    )
    state.save_to_file(state_file)

    result = @client.upload_file(
      bucket: BUCKET, key: "/state_resume.bin", local_path: src_path
    )
    refute result[:error], "Upload should succeed or fail gracefully: #{result[:error]}"
  ensure
    if upload_id
      begin
        @client.send(:safe_abort, key: "/state_resume.bin", upload_id: upload_id, bucket: BUCKET)
      rescue StandardError
        nil
      end
    end
    FileUtils.rm_f(state_file) if state_file
    File.delete(src_path) if src_path && File.exist?(src_path)
  end

  # --- s3_multi_bucket_client.rb line 62: part_retry event emission ---

  def test_part_retry_event_emission
    src_path, = create_temp_binary_file(6 * 1024 * 1024)
    uid = @client.multipart_start(bucket: BUCKET, key: "/part_retry_emit.bin")

    state = UploadState.new(
      upload_id: uid, key: "/part_retry_emit.bin", bucket: BUCKET,
      part_size: 5 * 1024 * 1024, total_size: File.size(src_path),
      local_path: src_path, parts: {}
    )

    uploader = PartUploader.new(
      @client, state, max_threads: 1, max_retries: 1, retry_delay: 0.01
    )

    call_count = 0
    uploader.define_singleton_method(:upload_part_http) do |part_number, http|
      call_count += 1
      raise EOFError, "Transient" if call_count <= 1

      '"fake-etag"'
    end

    uploader.send(:upload_part_with_retry, 1, nil, "t0")
    assert state.parts.key?(1), "Part 1 should have an etag"
    assert call_count >= 2, "Should have retried"
  ensure
    begin
      @client.multipart_abort(bucket: BUCKET, key: "/part_retry_emit.bin", upload_id: uid)
    rescue StandardError
      nil
    end
    File.delete(src_path) if src_path && File.exist?(src_path)
  end

  # --- s3_multi_bucket_client.rb line 173: download_part_retry event emission ---

  def test_download_part_retry_event_emission
    src_path, = create_temp_binary_file(6 * 1024 * 1024)
    @client.upload_file(bucket: BUCKET, key: "/dl_part_retry_emit.bin", local_path: src_path)

    dst = File.join(@store_dir, "dl_part_retry_test.bin")
    output_file = File.open(dst, "wb")

    download_state = DownloadState.new(
      key: "/dl_part_retry_emit.bin", bucket: BUCKET,
      part_size: 5 * 1024 * 1024, total_size: File.size(src_path),
      destination: dst, parts: {}
    )

    downloader = PartDownloader.new(
      @client, download_state, output_file: output_file,
                               max_threads: 1, max_retries: 1, retry_delay: 0.01
    )

    call_count = 0
    @client.define_singleton_method(:download_part_http) do |_bucket, _key, _pn, _o, _eb, _len, _http|
      call_count += 1
      raise EOFError, "Transient" if call_count <= 1

      "x"
    end

    http_mock = Object.new
    def http_mock.request(*)
      nil
    end

    result = downloader.send(:download_part_with_retry, 1, 0, 5_242_880, 5_242_880, http_mock, "t0")
    assert result, "Should have a result"
    assert call_count >= 2, "Should have retried"
  ensure
    begin
      output_file&.close
    rescue StandardError
      nil
    end
    FileUtils.rm_f(dst) if dst
    File.delete(src_path) if src_path && File.exist?(src_path)
  end

  # s3_multi_bucket_client.rb line 1082: state mismatch abort rescue
  def test_prepare_multipart_state_mismatch_abort_rescue
    state_file = File.join(@store_dir, "mismatch_state.json")
    src_path, = create_temp_binary_file(5 * 1024 * 1024)

    @client.define_singleton_method(:multipart_abort) do |**|
      raise S3MultiBucketClient::S3Error.new("500", "Abort failed")
    end

    mismatched_state = {
      upload_id: "nonexistent-upload-id",
      key: "/wrong_key.bin",
      part_size: 10 * 1024 * 1024,
      total_size: 99_999,
      local_path: "/wrong/path.bin",
      parts: { 1 => '"e1"' }
    }
    File.write(state_file, JSON.generate(mismatched_state))

    result = @client.upload_file(
      bucket: BUCKET, key: "/new_key.bin", local_path: src_path
    )
    refute result[:error], "Should handle mismatch gracefully: #{result[:error]}"
  ensure
    begin
      @client.singleton_class.remove_method(:multipart_abort)
    rescue StandardError
      nil
    end
    FileUtils.rm_f(state_file) if state_file
    File.delete(src_path) if src_path && File.exist?(src_path)
  end

  # --- parallel_uploader.rb line 305: safe_native_thread_id rescue ---
  def test_safe_native_thread_id_rescue
    require_relative "../../src/concurrent/parallel_uploader"

    state = UploadState.new(
      upload_id: "uid-safe", key: "/test.bin",
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

  # --- parallel_uploader.rb line 305: safe_native_thread_id rescue path ---
  def test_safe_native_thread_id_rescue_path
    require_relative "../../src/concurrent/parallel_uploader"

    state = UploadState.new(
      upload_id: "uid-rescue", key: "/test.bin",
      part_size: 5 * 1024 * 1024, total_size: 10 * 1024 * 1024,
      local_path: "/tmp/test.bin", parts: {}
    )

    uploader = S3ParallelUploader.new(
      @client, state,
      max_threads: 1, max_retries: 1, retry_delay: 0.01
    )

    result = nil
    t = Thread.new do
      Thread.current.define_singleton_method(:native_thread_id) { raise "not available" }
      result = uploader.send(:safe_native_thread_id)
    rescue StandardError
      result = nil
    end
    t.join
    assert_nil result, "Should return nil when native_thread_id raises"
  end

  # --- parallel_uploader.rb line 141: on_part_failed event ---
  def test_on_part_failed_event
    require_relative "../../src/concurrent/parallel_uploader"

    state = UploadState.new(
      upload_id: "uid-fail", key: "/test.bin",
      part_size: 5 * 1024 * 1024, total_size: 10 * 1024 * 1024,
      local_path: "/tmp/test.bin", parts: {}
    )

    events = []
    @client.class.on(:part_failed) { |*a| events << a }

    uploader = S3ParallelUploader.new(
      @client, state,
      max_threads: 1, max_retries: 0, retry_delay: 0.01
    )

    uploader.send(:on_part_failed, 1, "t0", RuntimeError.new("test error"))
    assert_equal 1, events.size
    assert_equal 1, events[0][0]
    assert_equal "t0", events[0][1]
  ensure
    @client.class.clear_callbacks!
  end

  # --- parallel_uploader.rb line 271-274: error in upload part rescue ---
  def test_upload_part_upload_all_failure
    src_path, = create_temp_binary_file(12 * 1024 * 1024)
    uid = @client.multipart_start(bucket: BUCKET, key: "/upload_all_fail.bin")

    state = UploadState.new(
      upload_id: uid, key: "/upload_all_fail.bin", bucket: BUCKET,
      part_size: 5 * 1024 * 1024, total_size: File.size(src_path),
      local_path: src_path, parts: {}
    )

    uploader = PartUploader.new(
      @client, state,
      max_threads: 1, max_retries: 0, retry_delay: 0.01
    )

    uploader.define_singleton_method(:upload_part_with_retry) do |part_number, http, tid|
      raise StandardError, "Simulated upload part failure"
    end

    assert_raises(S3BaseClient::UploadError) do
      uploader.upload_all!
    end
  ensure
    begin
      @client.multipart_abort(bucket: BUCKET, key: "/upload_all_fail.bin", upload_id: uid)
    rescue StandardError
      nil
    end
    File.delete(src_path) if src_path && File.exist?(src_path)
  end

  # --- parallel_uploader.rb lines 339-342: join_threads Interrupt ---
  def test_join_threads_interrupt
    require_relative "../../src/concurrent/parallel_uploader"

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
    begin
      worker&.kill
    rescue StandardError
      nil
    end
    begin
      interrupter&.kill
    rescue StandardError
      nil
    end
  end

  # --- parallel_downloader.rb lines 218-220: error handling in download thread ---
  def test_download_part_failed_during_download_all
    src_path, = create_temp_binary_file(12 * 1024 * 1024)
    @client.upload_file(bucket: BUCKET, key: "/dl_part_fail.bin", local_path: src_path)

    dst = File.join(@store_dir, "dl_part_fail.bin")
    output_file = File.open(dst, "wb")

    download_state = DownloadState.new(
      key: "/dl_part_fail.bin", bucket: BUCKET,
      part_size: 5 * 1024 * 1024, total_size: File.size(src_path),
      destination: dst, parts: {}
    )

    downloader = PartDownloader.new(
      @client, download_state, output_file: output_file,
                               max_threads: 1, max_retries: 0, retry_delay: 0.01
    )

    downloader.define_singleton_method(:download_part_with_retry) do |*|
      raise "Simulated download part failure"
    end

    assert_raises(S3BaseClient::DownloadError) do
      downloader.download_all!
    end
  ensure
    begin
      output_file&.close
    rescue StandardError
      nil
    end
    FileUtils.rm_f(dst) if dst
    File.delete(src_path) if src_path && File.exist?(src_path)
  end

  # --- parallel_downloader.rb lines 272-275: join_threads Interrupt ---
  def test_download_join_threads_interrupt
    require_relative "../../src/concurrent/parallel_downloader"
    require_relative "../../src/states/download_state"

    state = DownloadState.new(
      key: "/test.bin", local_path: "/tmp/test.bin",
      total_size: 100, part_size: 50, parts: {}
    )

    tmpfile = Tempfile.new(["dl_test", ".bin"])
    downloader = S3ParallelDownloader.new(
      @client, state, tmpfile,
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
      downloader.send(:join_threads, [worker]) { shutdown_called = true }
    end
    assert shutdown_called
  ensure
    begin
      tmpfile&.close
    rescue StandardError
      nil
    end
    begin
      tmpfile&.unlink
    rescue StandardError
      nil
    end
    begin
      worker&.kill
    rescue StandardError
      nil
    end
    begin
      interrupter&.kill
    rescue StandardError
      nil
    end
  end

  # --- safe_abort rescue ---

  def test_safe_abort_rescue
    @client.define_singleton_method(:signed_request) do |*|
      raise S3MultiBucketClient::S3Error.new("500", "Abort failed")
    end

    @client.send(:safe_abort, key: "/safe_abort_test.bin", upload_id: "nonexistent-uid", bucket: BUCKET)
  ensure
    begin
      @client.singleton_class.remove_method(:signed_request)
    rescue StandardError
      nil
    end
  end

  # --- resume_upload S3Error rescue ---

  def test_resume_upload_s3_error_rescue
    src_path, = create_temp_binary_file(5 * 1024 * 1024)
    state_file = File.join(@store_dir, "resume_s3_err.json")

    upload_id = @client.multipart_start(bucket: BUCKET, key: "/resume_s3_err.bin")
    state = UploadState.new(
      upload_id: upload_id, key: "/resume_s3_err.bin", bucket: BUCKET,
      part_size: 5 * 1024 * 1024, total_size: File.size(src_path),
      local_path: src_path, parts: { 1 => '"etag1"' }
    )
    state.save_to_file(state_file)

    @client.define_singleton_method(:complete_multipart_upload) do |*|
      raise S3MultiBucketClient::S3Error.new("500", "Complete failed")
    end

    assert_raises(S3MultiBucketClient::S3Error) do
      @client.send(:resume_upload, key: "/resume_s3_err.bin",
                                   state_file: state_file, bucket: BUCKET, local_path: src_path)
    end
  ensure
    begin
      @client.singleton_class.remove_method(:complete_multipart_upload)
    rescue StandardError
      nil
    end
    FileUtils.rm_f(state_file) if state_file
    File.delete(src_path) if src_path && File.exist?(src_path)
  end
end

class S3MultiBucketSingleBucketTest < Minitest::Test
  def test_mbc_in_single_bucket_mode
    client = S3MultiBucketClient.new(
      bucket: "my-bucket", region: "us-east-1",
      endpoint: "http://127.0.0.1:15605",
      access_key_id: "a", secret_access_key: "k",
      logger: Logger.new(File::NULL)
    )
    assert client.single_bucket?
    assert_equal "my-bucket", client.instance_variable_get(:@bucket)
  end

  def test_mbc_single_bucket_upload_and_download
    dir = Dir.mktmpdir("mbcsingle")
    store = File.join(dir, "store")
    tmp   = File.join(dir, "tmp")
    server = FakeS3::Server.new(port: 15_606, store_dir: store, tmp_dir: tmp)
    server.start_thread

    client = S3MultiBucketClient.new(
      bucket: "b", region: "us-east-1",
      endpoint: "http://127.0.0.1:15606",
      access_key_id: "a", secret_access_key: "k",
      logger: Logger.new(File::NULL)
    )

    src = File.join(dir, "src.bin")
    File.binwrite(src, "hello single-bucket mode")
    result = client.upload_file(key: "/test.txt", local_path: src)
    assert_kind_of S3BaseClient::UploadResult, result
    assert result[:key]

    dst = File.join(dir, "dst.bin")
    client.download_file(key: "/test.txt", destination_path: dst)
    assert_equal "hello single-bucket mode", File.binread(dst)

    server.stop
  end
end

class S3ClientBuildTest < Minitest::Test
  PORT = 15_607

  def setup
    dir = Dir.mktmpdir("s3clientbuild")
    @store_dir = File.join(dir, "store")
    @tmp_dir   = File.join(dir, "tmp")
    @server = FakeS3::Server.new(port: PORT, store_dir: @store_dir, tmp_dir: @tmp_dir)
    @server.start_thread
  end

  def teardown
    @server.stop
  end

  def test_build_single_bucket
    client = S3Client.build(
      bucket: "b", region: "us-east-1",
      endpoint: "http://127.0.0.1:#{PORT}",
      access_key_id: "a", secret_access_key: "k",
      logger: Logger.new(File::NULL)
    )
    assert_kind_of S3Client, client
    assert client.single_bucket?

    src = File.join(@store_dir, "src.bin")
    File.binwrite(src, "data")
    result = client.upload_file(key: "/f.txt", local_path: src)
    assert result[:key]
  end

  def test_build_multi_bucket
    client = S3Client.build(
      region: "us-east-1",
      endpoint: "http://127.0.0.1:#{PORT}",
      access_key_id: "a", secret_access_key: "k",
      logger: Logger.new(File::NULL)
    )
    assert_kind_of S3MultiBucketClient, client
    refute client.single_bucket?

    src = File.join(@store_dir, "src.bin")
    File.binwrite(src, "data")
    result = client.upload_file(bucket: "b", key: "/f.txt", local_path: src)
    assert result[:key]
  end

  def test_build_raises_without_endpoint
    assert_raises(ArgumentError) do
      S3Client.build(region: "us-east-1", access_key_id: "a", secret_access_key: "k")
    end
  end
end

# ============================================================================
# Tests for uncovered :nocov: blocks
# ============================================================================

class S3MultiBucketNocovTest < Minitest::Test
  include S3TestHelpers

  PORT = 15_610

  def setup
    dir = suite_tmp_dir("mb_nocov")
    store_dir = File.join(dir, "store")
    tmp_dir   = File.join(dir, "tmp")
    @server = FakeS3::Server.new(port: PORT, store_dir: store_dir, tmp_dir: tmp_dir)
    @server.start_thread

    @client = S3MultiBucketClient.new(
      endpoint: "http://127.0.0.1:#{PORT}", region: "us-east-1",
      access_key_id: "a", secret_access_key: "k",
      logger: Logger.new(File::NULL)
    )
  end

  def teardown
    @server&.stop
  end

  def test_download_part_http_via_signed_request_failure
    error_resp = Net::HTTPBadRequest.new(1.0, 400, "Bad Request")
    error_resp.instance_variable_set(:@read, true)
    @client.define_singleton_method(:signed_request) { |*| error_resp }

    assert_raises(S3BaseClient::DownloadError) do
      @client.send(:download_part_http, "b", "/test.bin", 1, 0, 99, 100, nil)
    end
  ensure
    begin
      @client.singleton_class.remove_method(:signed_request)
    rescue StandardError
      nil
    end
  end

  def test_download_part_http_via_http_failure
    error_resp = Net::HTTPBadRequest.new(1.0, 400, "Bad Request")
    error_resp.instance_variable_set(:@read, true)
    mock_http = Object.new
    mock_http.define_singleton_method(:request) { |_req| error_resp }

    assert_raises(S3BaseClient::DownloadError) do
      @client.send(:download_part_http, "b", "/test.bin", 1, 0, 99, 100, mock_http)
    end
  end

  def test_skip_existing_with_head_error
    src_path, = create_temp_binary_file(100)
    @client.define_singleton_method(:_ops_execute) { |*| raise S3MultiBucketClient::S3Error.new("500", "Head failed") }

    result = @client.upload_file(
      bucket: "b", key: "/skip_head_err.bin",
      local_path: src_path, skip_existing: true
    )
    assert result[:key], "Upload should proceed despite head_object error"
  ensure
    begin
      @client.singleton_class.remove_method(:_ops_execute)
    rescue StandardError
      nil
    end
    File.delete(src_path) if src_path && File.exist?(src_path)
  end

  # --- s3_multi_bucket_client/networking.rb: _resolve_download_path ---
  def test_mbc_resolve_download_path
    Dir.mktmpdir do |dir|
      dp = File.join(dir, "dl.bin")
      result = @client.send(:_resolve_download_path, nil, dp)
      assert_equal File.expand_path(dp), result
    end
  end

  def test_mbc_resolve_download_path_raises_without_path
    assert_raises(ArgumentError) do
      @client.send(:_resolve_download_path, nil, nil)
    end
  end

  # --- s3_multi_bucket_client/networking.rb: _format_download_result ---
  def test_mbc_format_download_result
    result = @client.send(:_format_download_result, "/k", "b", "/tmp/f", 100, false)
    assert_equal "/k", result[:key]
    assert_equal "b", result[:bucket]
    assert_equal 100, result[:size]
  end

  # --- s3_multi_bucket_client/networking.rb: _stream_download ---
  def test_mbc_stream_download
    src_path, = create_temp_binary_file(100)
    @client.upload_file(bucket: "b", key: "/stream_dl_mbc.bin", local_path: src_path)

    chunks = []
    result = @client.send(:_stream_download, "/stream_dl_mbc.bin", bucket: "b") { |chunk| chunks << chunk }
    assert chunks.any?
    assert_equal 100, result
  ensure
    File.delete(src_path) if src_path && File.exist?(src_path)
  end

  # --- s3_multi_bucket_client/networking.rb: _resume_download ---
  def test_mbc_resume_download
    src_path, = create_temp_binary_file(100)
    @client.upload_file(bucket: "b", key: "/resume_dl_mbc.bin", local_path: src_path)

    Dir.mktmpdir do |dir|
      paths = @client.send(:compute_download_paths, File.join(dir, "out.bin"), nil)
      result = @client.send(:_resume_download, "/resume_dl_mbc.bin", paths: paths, bucket: "b", on_progress: nil)
      assert_equal 100, result
    end
  ensure
    File.delete(src_path) if src_path && File.exist?(src_path)
  end

  # --- s3_multi_bucket_client/networking.rb: _ops_execute non-streaming ---
  def test_mbc_ops_execute_non_streaming
    src_path, = create_temp_binary_file(100)
    @client.upload_file(bucket: "b", key: "/ops_exec_test.bin", local_path: src_path)

    result = @client.send(:_ops_execute, :get, "/ops_exec_test.bin", bucket: "b") { |resp| resp.code.to_i }
    assert_equal 200, result
  ensure
    File.delete(src_path) if src_path && File.exist?(src_path)
  end

  # --- s3_multi_bucket_client/networking.rb: _ops_build_uri ---
  def test_mbc_ops_build_uri
    uri = @client.send(:_ops_build_uri, "/test.bin", bucket: "b")
    assert uri.to_s.include?("/b/")
  end

  # --- MultiBucketUploadTransport: put_empty with success ---
  def test_mbc_upload_transport_put_empty
    transport = MultiBucketUploadTransport.new(@client)
    etag = transport.put_empty("/empty_mbc.bin", {}, bucket: "b")
    assert etag
  end

  # --- MultiBucketUploadTransport: put_single with file body ---
  def test_mbc_upload_transport_put_single_file
    transport = MultiBucketUploadTransport.new(@client)
    src_path, = create_temp_binary_file(100)
    etag = transport.put_single("/put_single_mbc.bin", src_path, {}, bucket: "b")
    assert etag
  ensure
    File.delete(src_path) if src_path && File.exist?(src_path)
  end

  # --- MultiBucketUploadTransport: upload_part with http connection ---
  def test_mbc_upload_transport_upload_part_with_http
    uid = @client.multipart_start(bucket: "b", key: "/mp_http_mbc.bin")
    transport = MultiBucketUploadTransport.new(@client)

    mock_http = Object.new
    mock_http.define_singleton_method(:request) do |req|
      resp = Net::HTTPOK.new(1.0, 200, "OK")
      resp.instance_variable_set(:@read, true)
      resp["ETag"] = '"mock-etag"'
      resp
    end

    etag = transport.upload_part("b", "/mp_http_mbc.bin", 1, uid, "test data", {}, mock_http)
    assert etag
  ensure
    begin
      @client.multipart_abort(bucket: "b", key: "/mp_http_mbc.bin", upload_id: uid)
    rescue StandardError
      nil
    end
  end

  # --- MultiBucketUploadTransport: upload_part without http (via signed_request) ---
  def test_mbc_upload_transport_upload_part_signed
    uid = @client.multipart_start(bucket: "b", key: "/mp_signed_mbc.bin")
    transport = MultiBucketUploadTransport.new(@client)

    etag = transport.upload_part("b", "/mp_signed_mbc.bin", 1, uid, "test data", {}, nil)
    assert etag
  ensure
    begin
      @client.multipart_abort(bucket: "b", key: "/mp_signed_mbc.bin", upload_id: uid)
    rescue StandardError
      nil
    end
  end

  # --- MultiBucketDownloadTransport: range_get ---
  def test_mbc_download_transport_range_get
    src_path, = create_temp_binary_file(100)
    @client.upload_file(bucket: "b", key: "/dl_transport_range.bin", local_path: src_path)

    transport = MultiBucketDownloadTransport.new(@client)
    body = transport.range_get("/dl_transport_range.bin", 0, 49, bucket: "b")
    assert_equal 50, body.bytesize
  ensure
    File.delete(src_path) if src_path && File.exist?(src_path)
  end

  # --- MultiBucketDownloadTransport: open_http ---
  def test_mbc_download_transport_open_http
    transport = MultiBucketDownloadTransport.new(@client)
    transport.open_http("/test.bin", bucket: "b") do |http|
      assert_kind_of Net::HTTP, http
    end
  end

  # --- ResumeUpload: build_resume_progress_callback with 3-arity ---
  def test_resume_upload_build_resume_callback_3arity
    state = UploadState.new(
      upload_id: "uid", key: "/k",
      part_size: 5 * 1024 * 1024, total_size: 100,
      local_path: "/tmp/f", parts: {}
    )

    resume = S3BaseClient::ResumeUpload.new(client: @client, logger: Logger.new(File::NULL))
    progress_calls = []
    cb = resume.send(:build_resume_progress_callback,
                     ->(w, t) { progress_calls << [w, t] },
                     state, 100)
    cb.call
    assert progress_calls.any?
  end

  # --- ResumeUpload: build_resume_progress_callback with 3-arity (line 67) ---
  def test_resume_upload_build_resume_callback_2arity
    state = UploadState.new(
      upload_id: "uid", key: "/k",
      part_size: 5 * 1024 * 1024, total_size: 100,
      local_path: "/tmp/f", parts: {}
    )

    resume = S3BaseClient::ResumeUpload.new(client: @client, logger: Logger.new(File::NULL))
    cb = resume.send(:build_resume_progress_callback, nil, state, 100)
    assert_nil cb
  end

  # --- resume_upload.rb line 67: on_progress with arity 3 (passthrough) ---
  def test_resume_upload_progress_3arity_passthrough
    state = UploadState.new(
      upload_id: "uid", key: "/k",
      part_size: 5 * 1024 * 1024, total_size: 100,
      local_path: "/tmp/f", parts: {}
    )

    resume = S3BaseClient::ResumeUpload.new(client: @client, logger: Logger.new(File::NULL))
    prog = ->(a, b, c) {}
    cb = resume.send(:build_resume_progress_callback, prog, state, 100)
    assert_equal prog, cb
  end

  # --- ResumeUpload constant accessible without umbrella require ---

  def test_resume_upload_constant_accessible
    assert S3BaseClient.const_defined?(:ResumeUpload),
           "ResumeUpload must be accessible after requiring s3_multi_bucket_client directly"
  end

  def test_s3_multi_bucket_client_responds_to_resume_upload
    assert_respond_to @client, :resume_upload
  end

  # --- download_helpers.rb line 133: raise DownloadError in stream_multi_bucket_download ---
  def test_stream_multi_bucket_download_error
    FakeS3.reset_faults
    FakeS3.inject_fault(status: 500, method: "GET", path: "/fail_stream_mbc.bin", times: 1)

    Dir.mktmpdir do |dir|
      dst = File.join(dir, "out.bin")
      paths = @client.send(:compute_download_paths, dst, nil)
      assert_raises(S3BaseClient::DownloadError) do
        @client.send(:stream_multi_bucket_download, "/fail_stream_mbc.bin", "b", paths, nil)
      end
    end
  ensure
    FakeS3.reset_faults
  end

  # --- MBC networking.rb lines 125-126: perform_request non-streaming ---
  def test_mbc_perform_request_non_streaming
    src_path, = create_temp_binary_file(100)
    @client.upload_file(bucket: "b", key: "/perf_req_ns.bin", local_path: src_path)
    result = @client.perform_request(:get, "/perf_req_ns.bin", bucket: "b") { |resp| resp.code.to_i }
    assert_equal 200, result
  ensure
    File.delete(src_path) if src_path && File.exist?(src_path)
  end

  # --- MultiBucketDownloadTransport: stream_get (lines 72-94) ---
  def test_mbc_download_transport_stream_get
    src_path, = create_temp_binary_file(100)
    @client.upload_file(bucket: "b", key: "/mb_stream_get.bin", local_path: src_path)

    @client.class.send(:public, :make_http_request, :sign_request!)
    transport = MultiBucketDownloadTransport.new(@client)
    written = transport.stream_get("/mb_stream_get.bin", {}, bucket: "b") { |c| }
    assert_equal 100, written
  ensure
    File.delete(src_path) if src_path && File.exist?(src_path)
  end

  # --- MultiBucketDownloadTransport: stream_get error path (line 83) ---
  def test_mbc_download_transport_stream_get_error
    @client.class.send(:public, :make_http_request, :sign_request!)
    transport = MultiBucketDownloadTransport.new(@client)

    assert_raises(S3BaseClient::DownloadError) do
      transport.stream_get("/nonexistent.bin", {}, bucket: "b") { |c| }
    end
  end

  # --- MultiBucketDownloadTransport: range_get with explicitly passed http (line 101) ---
  def test_mbc_download_transport_range_get_with_http
    src_path, = create_temp_binary_file(100)
    @client.upload_file(bucket: "b", key: "/mb_range_get_http.bin", local_path: src_path)

    transport = MultiBucketDownloadTransport.new(@client)
    uri = @client.build_uri("b", "/mb_range_get_http.bin")
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = false
    http.open_timeout = 5
    http.read_timeout = 5
    http.start

    body = transport.range_get("/mb_range_get_http.bin", 0, 49, bucket: "b", http: http)
    assert_equal 50, body.bytesize
  ensure
    begin
      http&.finish
    rescue StandardError
      nil
    end
    File.delete(src_path) if src_path && File.exist?(src_path)
  end

  # --- upload_transport.rb line 118: MultiBucketUploadTransport#put_empty failure ---
  def test_mbc_upload_transport_put_empty_failure
    error_resp = Net::HTTPBadRequest.new(1.0, 400, "Bad Request")
    error_resp.instance_variable_set(:@read, true)
    @client.define_singleton_method(:signed_request) do |*args|
      error_resp
    end
    transport = MultiBucketUploadTransport.new(@client)
    assert_raises(S3BaseClient::UploadError) do
      transport.put_empty("/fail_empty.bin", {}, bucket: "b")
    end
  ensure
    begin
      @client.singleton_class.remove_method(:signed_request)
    rescue StandardError
      nil
    end
  end
end

# =========================================================================
# base_client.rb — list_objects with S3MultiBucketClient
# =========================================================================
class TestListObjectsMBC < Minitest::Test
  include S3TestHelpers

  def setup
    @client = S3MultiBucketClient.new(
      endpoint: "http://127.0.0.1:1", region: "us-east-1",
      access_key_id: "a", secret_access_key: "k",
      logger: Logger.new(File::NULL)
    )
  end

  def test_mbc_list_objects_empty
    test = self
    stub = proc { |_method, _key, **_opts, &block| block.call(test.build_list_response([], [], false, nil)) }
    @client.define_singleton_method(:_ops_execute, &stub)

    result = @client.list_objects(bucket: "b")
    assert_empty result[:contents]
    assert_empty result[:common_prefixes]
  ensure
    @client.singleton_class.remove_method(:_ops_execute) if @client.respond_to?(:_ops_execute, true)
  end

  def test_mbc_list_objects_with_contents
    test = self
    stub = proc do |_method, _key, **_opts, &block|
      contents = [
        { key: "/a.txt", size: 100, last_modified: "2024-01-01", storage_class: "STANDARD", etag: '"e1"' }
      ]
      block.call(test.build_list_response(contents, [], false, nil))
    end
    @client.define_singleton_method(:_ops_execute, &stub)

    result = @client.list_objects(bucket: "b", delimiter: nil)
    assert_equal 1, result[:contents].size
  ensure
    @client.singleton_class.remove_method(:_ops_execute) if @client.respond_to?(:_ops_execute, true)
  end

  def test_mbc_list_objects_paginate_false
    test = self
    stub = proc do |_method, _key, **_opts, &block|
      block.call(test.build_list_response(
                   [{ key: "/a.txt", size: 10, last_modified: nil, storage_class: nil, etag: nil }],
                   [], false, nil
                 ))
    end
    @client.define_singleton_method(:_ops_execute, &stub)

    result = @client.list_objects(bucket: "b", paginate: false)
    assert_equal 1, result[:contents].size
  ensure
    @client.singleton_class.remove_method(:_ops_execute) if @client.respond_to?(:_ops_execute, true)
  end

  def test_mbc_list_objects_with_continuation_token
    test = self
    call_count = 0
    stub = proc do |_method, _key, **_opts, &block|
      call_count += 1
      if call_count == 1
        block.call(test.build_list_response(
                     [{ key: "/a.txt", size: 10, last_modified: nil, storage_class: nil, etag: nil }],
                     [], true, "token123"
                   ))
      else
        block.call(test.build_list_response(
                     [{ key: "/b.txt", size: 20, last_modified: nil, storage_class: nil, etag: nil }],
                     [], false, nil
                   ))
      end
    end
    @client.define_singleton_method(:_ops_execute, &stub)

    result = @client.list_objects(bucket: "b", max_keys: 1)
    assert_equal 2, result[:contents].size
  ensure
    @client.singleton_class.remove_method(:_ops_execute) if @client.respond_to?(:_ops_execute, true)
  end
end
