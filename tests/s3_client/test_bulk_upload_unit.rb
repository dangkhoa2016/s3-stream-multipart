# frozen_string_literal: true

require_relative "../test_helper"
require_relative "../../src/s3_client"
require_relative "../../src/extras/bulk_uploader"
require_relative "../../src/extras/directory_scanner"
require_relative "../../src/extras/bulk_upload_worker"

class S3BulkUploaderUnitTest < Minitest::Test
  include S3TestHelpers

  PORT = 15_586

  def setup
    dir = suite_tmp_dir("bulk_unit")
    @store_dir = File.join(dir, "store")
    @tmp_dir   = File.join(dir, "tmp")
    @server = FakeS3::Server.new(port: PORT, store_dir: @store_dir, tmp_dir: @tmp_dir)
    @server.start_thread

    @client = S3Client.new(
      region: "us-east-1", bucket: "b",
      access_key_id: "a", secret_access_key: "k",
      endpoint: "http://127.0.0.1:#{PORT}", endpoint_style: :path,
      logger: Logger.new(File::NULL)
    )

    @src_dir = File.join(dir, "src")
    FileUtils.mkdir_p(@src_dir)
    File.write(File.join(@src_dir, "a.txt"), "file a")
    File.write(File.join(@src_dir, "b.txt"), "file b")
  end

  def teardown
    @server.stop
    cleanup_suite_tmp("bulk_unit")
  end

  def test_bulk_upload_basic
    result = @client.upload_directory(directory: @src_dir, prefix: "bulk/")
    assert_equal 2, result[:uploaded].size
    assert_equal 0, result[:failed].size
  end

  def test_bulk_upload_with_pattern
    @client.upload_directory(directory: @src_dir, pattern: "*.txt", prefix: "bulk/")
  end

  def test_bulk_upload_with_exclude
    result = @client.upload_directory(directory: @src_dir, pattern: "*.txt", exclude: ["a.txt"], prefix: "bulk/")
    assert_equal 1, result[:uploaded].size
  end

  def test_bulk_upload_empty_directory
    empty_dir = File.join(@store_dir, "empty")
    FileUtils.mkdir_p(empty_dir)
    result = @client.upload_directory(directory: empty_dir, prefix: "empty/")
    assert_equal 0, result[:total_files]
  end

  def test_bulk_upload_skip_existing
    @client.upload_directory(directory: @src_dir, prefix: "skip/")
    result = @client.upload_directory(directory: @src_dir, prefix: "skip/", skip_existing: true)
    assert_equal 2, result[:skipped].size
  end

  def test_bulk_upload_multipart_threshold
    dir = File.join(@store_dir, "big_files")
    FileUtils.mkdir_p(dir)
    File.write(File.join(dir, "big.bin"), "x" * 5_000_000)

    result = @client.upload_directory(
      directory: dir, prefix: "big/", multipart_threshold: 1
    )
    assert_equal 1, result[:uploaded].size
  end

  def test_bulk_upload_with_callbacks
    starts = []
    completes = []
    @client.upload_directory(
      directory: @src_dir, prefix: "cb/",
      on_file_start: ->(path, key, idx, total) { starts << [path, key, idx, total] },
      on_file_complete: ->(path, key, res, idx, total) { completes << [path, key, res[:etag], idx, total] }
    )
    assert_equal 2, starts.size
    assert_equal 2, completes.size
  end

  def test_bulk_upload_nonexistent_directory
    assert_raises(Errno::ENOENT) do
      @client.upload_directory(directory: "/nonexistent/dir", prefix: "/")
    end
  end

  def test_directory_scanner_detect_content_type
    scanner = DirectoryScanner.new(@src_dir)
    assert_equal "text/html", scanner.detect_content_type("f.html")
    assert_equal "text/plain", scanner.detect_content_type("f.txt")
    assert_equal "application/octet-stream", scanner.detect_content_type("f.unknown")
  end

  def test_directory_scanner_normalize_prefix
    assert_equal "", DirectoryScanner.new(@src_dir, prefix: "").prefix
    assert_equal "", DirectoryScanner.new(@src_dir, prefix: nil).prefix
    assert_equal "pre/", DirectoryScanner.new(@src_dir, prefix: "pre").prefix
    assert_equal "pre/", DirectoryScanner.new(@src_dir, prefix: "pre/").prefix
  end

  def test_bulk_upload_worker_state_file_for
    worker = BulkUploadWorker.new(client: @client, state_dir: "/tmp/states")
    path = worker.send(:state_file_for, "my/long/key.txt")
    assert_includes path, "my--long--key.txt"
    assert_includes path, ".s3state.json"
  end

  def test_directory_scanner_deduplicate
    scanner = DirectoryScanner.new(@src_dir)
    files = [
      { path: "/a.txt", key: "dup", size: 10 },
      { path: "/b.txt", key: "dup", size: 20 }
    ]
    unique, skipped = scanner.deduplicate(files)
    assert_equal 1, unique.size
    assert_equal 1, skipped.size
    assert_includes skipped[0][:reason], "duplicate"
  end

  def test_upload_bulk_via_helper
    result = S3Helper.upload_bulk(client: @client, directory: @src_dir, prefix: "hlp-bulk/")
    assert_equal 2, result[:uploaded].size
  end

  def test_bulk_upload_worker_state_file_for_long_key
    worker = BulkUploadWorker.new(client: @client, state_dir: "/tmp/states")
    long_key = "#{'a/' * 80}file.txt"
    path = worker.send(:state_file_for, long_key)
    assert path.length <= 200, "path too long: #{path.length}"
    assert_includes path, ".s3state.json"
  end

  def test_bulk_upload_worker_state_file_for_special_chars
    worker = BulkUploadWorker.new(client: @client, state_dir: "/tmp/states")
    path = worker.send(:state_file_for, "key with spaces/special@chars.bin")
    assert_includes path, ".s3state.json"
  end

  def test_bulk_uploader_with_state_dir
    state_dir = File.join(@store_dir, "states")
    uploader = S3BulkUploader.new(
      client: @client, directory: @src_dir, prefix: "st/",
      state_dir: state_dir, multipart_threshold: 1
    )
    result = uploader.run!
    assert_equal 2, result[:uploaded].size
    assert File.directory?(state_dir)
  end

  def test_bulk_uploader_with_cache_control
    uploader = S3BulkUploader.new(
      client: @client, directory: @src_dir, prefix: "cc/",
      cache_control: "max-age=3600",
      metadata: { "author" => "test" }
    )
    result = uploader.run!
    assert_equal 2, result[:uploaded].size
  end

  def test_bulk_uploader_on_file_error_callback
    errors = []
    uploader = S3BulkUploader.new(
      client: @client, directory: "/nonexistent_dir_test", prefix: "err/",
      on_file_error: ->(path, key, e, idx, total) { errors << [key, e.message] }
    )
    assert_raises(Errno::ENOENT) { uploader.run! }
  end

  def test_bulk_uploader_on_file_error_callback_triggered
    errors = []
    dir = File.join(@store_dir, "err_files")
    FileUtils.mkdir_p(dir)
    fpath = File.join(dir, "broken.txt")
    File.write(fpath, "data")
    File.chmod(0o000, fpath)

    uploader = S3BulkUploader.new(
      client: @client, directory: dir, prefix: "err/",
      on_file_error: ->(path, key, e, idx, total) { errors << [key, e.message] }
    )

    result = uploader.run!
    assert_equal 1, result[:failed].size
    assert_equal 1, errors.size
  ensure
    File.chmod(0o644, fpath) if fpath && File.exist?(fpath)
  end

  def test_bulk_uploader_state_dir_resume_log
    dir = File.join(@store_dir, "resume_files")
    FileUtils.mkdir_p(dir)
    big_file = File.join(dir, "big.bin")
    File.write(big_file, "x" * 2_000_000)

    state_dir = File.join(@store_dir, "resume_states")
    FileUtils.mkdir_p(state_dir)

    safe_key = "st--big.bin"
    state_file = File.join(state_dir, "#{safe_key}.s3state.json")
    File.write(state_file, '{"upload_id":"old"}')

    uploader = S3BulkUploader.new(
      client: @client, directory: dir, prefix: "st/",
      state_dir: state_dir, multipart_threshold: 1
    )
    result = uploader.run!
    assert_equal 1, result[:uploaded].size
  end

  def test_bulk_uploader_max_files_clamping
    uploader = S3BulkUploader.new(
      client: @client, directory: @src_dir, max_files: 0
    )
    assert_equal 1, uploader.instance_variable_get(:@max_files)

    uploader2 = S3BulkUploader.new(
      client: @client, directory: @src_dir, max_files: 100
    )
    assert_equal 32, uploader2.instance_variable_get(:@max_files)
  end
end
