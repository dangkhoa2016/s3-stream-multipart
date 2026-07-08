# frozen_string_literal: true

require_relative "../test_helper"
require_relative "../../src/s3-stream-multipart"

class UploadErrorHandlingTest < Minitest::Test
  include S3TestHelpers

  PORT = 15_605

  def setup
    dir = suite_tmp_dir("upload_error_handling")
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

  # --- upload failure with state file ---

  def test_upload_failure_with_state_file
    src_path, = create_temp_binary_file(12 * 1024 * 1024)
    state_file = File.join(@store_dir, "fail_state_save.json")

    call_count = 0
    orig = @client.method(:build_http_request)
    @client.define_singleton_method(:build_http_request) do |method, uri, body, extra_headers, **opts|
      req = orig.call(method, uri, body, extra_headers, **opts)
      if method.to_s.downcase.to_sym == :put
        call_count += 1
        raise "Simulated upload failure" if call_count > 1
      end
      req
    end

    assert_raises(S3BaseClient::UploadError) do
      @client.upload_file(
        local_path: src_path, key: "/fail_state.bin",
        state_file: state_file, part_size: 5 * 1024 * 1024
      )
    end
  ensure
    File.delete(src_path) if src_path && File.exist?(src_path)
    FileUtils.rm_f(state_file) if state_file
  end

  def test_upload_failure_without_state_file
    src_path, = create_temp_binary_file(12 * 1024 * 1024)

    call_count = 0
    orig = @client.method(:build_http_request)
    @client.define_singleton_method(:build_http_request) do |method, uri, body, extra_headers, **opts|
      req = orig.call(method, uri, body, extra_headers, **opts)
      if method.to_s.downcase.to_sym == :put
        call_count += 1
        raise "Simulated upload failure (no state)" if call_count > 1
      end
      req
    end

    assert_raises(S3BaseClient::UploadError) do
      @client.upload_file(
        local_path: src_path, key: "/fail_no_state.bin",
        part_size: 5 * 1024 * 1024
      )
    end
  ensure
    File.delete(src_path) if src_path && File.exist?(src_path)
  end

  def test_resume_upload_failure_rescue
    state_file = File.join(@store_dir, "resume_fail.json")
    abs_local = File.join(@store_dir, "resume_fail_src.bin")
    File.write(abs_local, "test data")
    state_data = {
      upload_id: "bad-upload-id",
      key: "/resume_fail.bin",
      part_size: 5 * 1024 * 1024,
      total_size: File.size(abs_local),
      local_path: abs_local,
      parts: {}
    }
    File.write(state_file, JSON.generate(state_data))

    assert_raises(S3BaseClient::UploadError) do
      @client.resume_upload(state_file: state_file)
    end
  ensure
    FileUtils.rm_f(state_file)
    FileUtils.rm_f(abs_local) if abs_local
  end

  # --- s3_client.rb lines 192-195: head_object error paths in upload_file skip_existing ---

  def test_upload_skip_existing_head_object_404
    src_path, = create_temp_binary_file(1024)
    result = @client.upload_file(local_path: src_path, key: "/skip-404.bin", skip_existing: true)
    assert result[:key], "Should proceed with upload when head_object returns 404"
    assert result[:etag], "Upload should complete"
  ensure
    File.delete(src_path) if src_path && File.exist?(src_path)
  end

  def test_upload_skip_existing_head_object_error
    src_path, = create_temp_binary_file(1024)
    @client.define_singleton_method(:head_object) { |*| raise S3BaseClient::S3Error.new("500", "Internal Error") }
    result = @client.upload_file(local_path: src_path, key: "/skip-500.bin", skip_existing: true)
    assert result[:key], "Should proceed with upload when head_object returns S3Error"
  ensure
    begin
      @client.singleton_class.remove_method(:head_object)
    rescue StandardError
      nil
    end
    File.delete(src_path) if src_path && File.exist?(src_path)
  end

  # --- validate_part_config! exceeds MAX_PARTS (10,000) ---

  def test_validate_part_config_exceeds_max_parts
    err = assert_raises(ArgumentError) do
      @client.send(:validate_part_config!, 5 * 1024 * 1024, 60 * 1024 * 1024 * 1024)
    end
    assert_match(/exceeds 10,000 parts/, err.message)
  end

  # --- upload_file with part_size + progress_callback + small file ---

  def test_upload_multipart_small_file_with_part_size_and_progress
    Tempfile.create(["small_part", ".bin"]) do |f|
      f.write("x" * 10_000)
      f.flush
      progress = []
      r = @client.upload_file(
        local_path: f.path, key: "/small_part_prog.bin",
        part_size: 5 * 1024 * 1024,
        on_progress: ->(done, total) { progress << [done, total] }
      )
      assert r[:etag]
      assert progress.include?([10_000, 10_000]),
             "expected final progress callback for small file with part_size"
    end
  end

  # --- Multipart upload with full on_progress (2-arity callback) ---

  def test_multipart_upload_with_2arity_callback
    src_path, = create_temp_binary_file(6 * 1024 * 1024)
    progress = []
    result = @client.upload_file(
      local_path: src_path, key: "/mp_2arity_cb.bin",
      part_size: 5 * 1024 * 1024,
      on_progress: ->(done, total) { progress << [done, total] }
    )
    assert result[:etag]
    assert progress.any?
  ensure
    File.delete(src_path) if src_path && File.exist?(src_path)
  end

  # --- Upload with skip_existing to hit head_object ---

  def test_upload_skip_existing_file_exists
    src_path, = create_temp_binary_file(100)
    @client.upload_file(local_path: src_path, key: "/skip_exists.bin")
    result = @client.upload_file(local_path: src_path, key: "/skip_exists.bin", skip_existing: true)
    assert result[:key], "Should skip because file exists"
    assert_nil result[:etag], "Should not upload when file exists"
  ensure
    File.delete(src_path) if src_path && File.exist?(src_path)
  end

  # --- upload_transport.rb: SingleBucketUploadTransport ---

  def test_single_bucket_upload_transport_put_empty
    transport = SingleBucketUploadTransport.new(@client)
    etag = transport.put_empty("/empty_sbc.bin", {}, bucket: nil)
    assert etag
  end

  def test_single_bucket_upload_transport_put_single_string
    transport = SingleBucketUploadTransport.new(@client)
    etag = transport.put_single("/put_single_str.bin", "hello", {}, bucket: nil)
    assert etag
  end

  def test_single_bucket_upload_transport_put_single_file
    transport = SingleBucketUploadTransport.new(@client)
    src_path, = create_temp_binary_file(100)
    etag = transport.put_single("/put_single_file.bin", src_path, {}, bucket: nil)
    assert etag
  ensure
    File.delete(src_path) if src_path && File.exist?(src_path)
  end

  # --- upload_logic.rb:85: resume_existing_upload via setup_multipart_upload_state ---

  def test_setup_multipart_upload_state_resumes_existing
    src_path, src_md5 = create_temp_binary_file(12 * 1024 * 1024)
    state_file = File.join(@store_dir, "auto_resume_state.json")
    key = "/auto_resume_85.bin"
    part_size = 5 * 1024 * 1024

    uid = @client.multipart_start(key: key)

    (1..2).each do |n|
      offset = (n - 1) * part_size
      data = File.binread(src_path, part_size, offset)
      @client.multipart_upload_part(key: key, upload_id: uid, part_number: n, body: data)
    end

    parts = @client.list_parts(key: key, upload_id: uid)
    etags = parts.to_h { |p| [p[:part_number], p[:etag]] }

    state = {
      upload_id: uid, key: key, bucket: "b",
      part_size: part_size, total_size: 12 * 1024 * 1024,
      local_path: src_path, parts: etags,
      completed: false, upload_session_id: "resume_85",
      started_at: Time.now.utc.iso8601
    }
    File.write(state_file, JSON.generate(state))

    result = @client.upload_file(
      local_path: src_path, key: key,
      state_file: state_file, part_size: part_size
    )
    assert result[:etag]

    stored = File.join(@store_dir, "b/auto_resume_85.bin")
    assert File.exist?(stored)
    dl_md5 = Digest::MD5.file(stored).hexdigest
    assert_equal src_md5, dl_md5
  ensure
    File.delete(src_path) if src_path && File.exist?(src_path)
  end
end
