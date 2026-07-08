# frozen_string_literal: true

require_relative "../test_helper"
require_relative "../../src/s3-stream-multipart"

class S3ClientOpsTest < Minitest::Test
  include S3TestHelpers

  PORT = 15_607

  def setup
    dir = suite_tmp_dir("s3client_ops")
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

  # --- parallel_download_runner.rb rescue block ---

  def test_download_error_handling
    dst = File.join(@store_dir, "download_nonexistent.bin")

    err = assert_raises(S3BaseClient::S3Error) do
      @client.download_file(
        key: "/nonexistent.bin", local_path: dst
      )
    end

    assert_equal "404", err.code
  ensure
    FileUtils.rm_f(dst) if dst
  end

  # --- s3_client.rb operations ---

  def test_head_object_not_found
    err = assert_raises(S3BaseClient::S3Error) do
      @client.head_object("/nonexistent_file.bin")
    end
    assert_equal "404", err.code
  end

  def test_download_creates_directories
    src_path, = create_temp_binary_file(1024)
    @client.upload_file(local_path: src_path, key: "/test_dir.bin")

    dst = File.join(@store_dir, "deep", "nested", "dir", "file.bin")
    refute Dir.exist?(File.dirname(dst)), "Directory should not exist yet"

    @client.download_file(key: "/test_dir.bin", local_path: dst)

    assert File.exist?(dst), "File should be downloaded"
    assert Dir.exist?(File.dirname(dst)), "Directories should be created"
  ensure
    File.delete(src_path) if src_path && File.exist?(src_path)
    FileUtils.rm_rf(File.join(@store_dir, "deep")) if File.exist?(File.join(@store_dir, "deep"))
  end

  def test_list_parts_empty
    uid = @client.multipart_start(key: "/empty_parts.bin")
    parts = @client.list_parts(key: "/empty_parts.bin", upload_id: uid)
    assert_empty parts, "Should return empty array when no parts uploaded"
  ensure
    begin
      @client.multipart_abort(key: "/empty_parts.bin", upload_id: uid)
    rescue StandardError
      nil
    end
  end

  def test_multipart_complete_delegation
    uid = @client.multipart_start(key: "/mp_complete_direct.bin")
    data = "test data"
    etag = @client.send(:upload_part, key: "/mp_complete_direct.bin",
                                      upload_id: uid, part_number: 1, body: data)
    result = @client.multipart_complete(
      key: "/mp_complete_direct.bin", upload_id: uid,
      parts: [{ part_number: 1, etag: etag }]
    )
    assert result
  ensure
    begin
      @client.multipart_abort(key: "/mp_complete_direct.bin", upload_id: uid)
    rescue StandardError
      nil
    end
  end

  def test_safe_abort_with_nonexistent_key
    @client.send(:safe_abort, key: "/nonexistent_key_for_abort.bin", upload_id: "nonexistent_upload_id")
  end

  def test_safe_abort_failure_rescue
    @client.define_singleton_method(:perform_request) do |method, key, **|
      raise "Simulated abort failure"
    end
    @client.send(:safe_abort, key: "/key.bin", upload_id: "id")
  ensure
    begin
      @client.singleton_class.remove_method(:perform_request)
    rescue StandardError
      nil
    end
  end

  def test_download_file_basic
    src_path, = create_temp_binary_file(1024)
    @client.upload_file(local_path: src_path, key: "/dl_rescue.bin")

    result = @client.download_file(
      key: "/dl_rescue.bin", local_path: File.join(@store_dir, "dl_rescue.bin")
    )
    assert_equal 1024, result[:size]
  ensure
    File.delete(src_path) if src_path && File.exist?(src_path)
    FileUtils.rm_f(File.join(@store_dir, "dl_rescue.bin"))
  end

  def test_cleanup_state_delete_failure
    @client.upload_state_manager.cleanup_state(@store_dir)
  end

  # --- parallel_downloader.rb line 79: download_part_with_retry NotImplementedError ---

  def test_parallel_downloader_not_implemented
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

    assert_raises(NotImplementedError) do
      downloader.send(:download_part_with_retry, 1, 0, 49, 50, nil, "t0")
    end
  ensure
    tmpfile&.close
    tmpfile&.unlink
  end

  # --- download with state file ---

  def test_download_with_state_file_complete
    src_path, = create_temp_binary_file(6 * 1024 * 1024)
    @client.upload_file(local_path: src_path, key: "/dl_state_complete.bin", part_size: 5 * 1024 * 1024)

    File.join(@store_dir, "dl_state_complete.json")
    dst = File.join(@store_dir, "dl_state_complete.bin")

    result = @client.download_file(
      key: "/dl_state_complete.bin", local_path: dst
    )
    assert_equal 6 * 1024 * 1024, result[:size]
  ensure
    File.delete(src_path) if src_path && File.exist?(src_path)
    FileUtils.rm_f(dst) if dst
  end

  # --- state_base.rb lines 102, 106: default normalize_value / normalize_array_value ---

  def test_state_base_normalize_value_default
    require_relative "../../src/states/state_base"

    state = StateBase.new(parts: { 1 => "raw_value" })
    assert_equal "raw_value", state.parts[1]
  end

  def test_state_base_normalize_array_value_default
    require_relative "../../src/states/state_base"

    state = StateBase.new(parts: [{ part_number: 1, etag: "e1" }])
    assert_equal "e1", state.parts[1]
  end

  # --- bulk_uploader.rb lines 213-214, 216: head_object error paths ---

  def test_bulk_skip_existing_head_object_404
    dir = File.join(@store_dir, "s404")
    FileUtils.mkdir_p(dir)
    File.write(File.join(dir, "f.bin"), "hello")

    @client.define_singleton_method(:head_object) { |*| raise S3BaseClient::S3Error.new("404", "Not Found") }

    result = @client.upload_directory(directory: dir, prefix: "s404/", skip_existing: true)
    assert_equal 1, result[:uploaded].size
  ensure
    begin
      @client.singleton_class.remove_method(:head_object)
    rescue StandardError
      nil
    end
  end

  def test_bulk_skip_existing_head_object_error
    dir = File.join(@store_dir, "e500")
    FileUtils.mkdir_p(dir)
    File.write(File.join(dir, "f.bin"), "hello")

    @client.define_singleton_method(:head_object) { |*| raise S3BaseClient::S3Error.new("500", "Internal Error") }

    result = @client.upload_directory(directory: dir, prefix: "e500/", skip_existing: true)
    assert_equal 1, result[:failed].size, "Should record failure for head_object error"
  ensure
    begin
      @client.singleton_class.remove_method(:head_object)
    rescue StandardError
      nil
    end
  end

  # --- s3_client.rb line 70: download_part_retry event ---

  def test_download_part_retry_event
    require_relative "../../src/concurrent/parallel_downloader"
    require_relative "../../src/states/download_state"
    require_relative "../../src/extras/retry_helper"

    retry_events = []
    S3Client.on(:download_part_retry) { |*a| retry_events << a }

    state = DownloadState.new(
      key: "/test.bin", local_path: "/tmp/test.bin",
      total_size: 100, part_size: 50, parts: {}
    )

    tmpfile = Tempfile.new(["dl_retry", ".bin"])
    downloader = PartDownloader.new(
      @client, state, output_file: tmpfile,
                      max_threads: 1, max_retries: 1, retry_delay: 0.01
    )

    @client.define_singleton_method(:download_part_http) do |*|
      raise EOFError, "Transient error"
    end

    assert_raises(S3BaseClient::DownloadError) do
      downloader.download_all!
    end

    assert retry_events.any?,
           "download_part_retry events should be emitted: #{retry_events.inspect}"
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
    S3Client.clear_callbacks!
  end

  # --- download_helpers.rb lines 223-225: run_parallel_download error rescue ---

  def test_download_helpers_parallel_download_error
    Dir.mktmpdir do |tmpdir|
      local_path = File.join(tmpdir, "dl.bin")
      state_file = File.join(tmpdir, "dl_state.json")
      assert_raises(S3BaseClient::DownloadError) do
        @client.send(:run_parallel_download,
                     key: "/nonexistent", local_path: local_path, total_size: 100,
                     part_size: 5 * 1024 * 1024, max_threads: 1, max_retries: 0, retry_delay: 0.01,
                     on_progress: nil, state_file: state_file)
      end
    end
  end
end
