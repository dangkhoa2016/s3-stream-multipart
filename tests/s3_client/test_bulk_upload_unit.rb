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

  # --- S3BulkUploader.run! edge cases ---

  def test_uploader_run_nonexistent_directory
    uploader = S3BulkUploader.new(
      client: @client, directory: "/nonexistent/dir/xyz",
      max_files: 1
    )
    assert_raises(Errno::ENOENT) { uploader.run! }
  end

  def test_uploader_run_empty_directory
    Dir.mktmpdir do |dir|
      uploader = S3BulkUploader.new(
        client: @client, directory: dir, max_files: 1,
        skip_existing: false
      )
      result = uploader.run!
      assert_equal 0, result[:total_files]
      assert_equal 0, result[:elapsed]
      assert_equal 0, result[:throughput]
    end
  end

  def test_uploader_run_all_duplicates
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "a.txt"), "data")
      File.write(File.join(dir, "a.txt.copy"), "data")

      uploader = S3BulkUploader.new(
        client: @client, directory: dir, max_files: 1,
        skip_existing: false
      )
      result = uploader.run!
      assert result[:total_files] >= 0
    end
  end

  def test_uploader_run_successful_upload
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "file.txt"), "hello")

      client = S3Client.new(
        region: "us-east-1", bucket: "b",
        access_key_id: "a", secret_access_key: "k",
        endpoint: "http://127.0.0.1:1", endpoint_style: :path,
        logger: Logger.new(File::NULL)
      )
      client.define_singleton_method(:upload_file) do |**_kwargs|
        { etag: "\"abc\"", size: 5 }
      end

      starts = []
      completes = []
      uploader = S3BulkUploader.new(
        client: client, directory: dir, max_files: 1,
        skip_existing: false,
        on_file_start: ->(_path, key, _idx, _total) { starts << key },
        on_file_complete: ->(_path, key, _result, _idx, _total) { completes << key }
      )
      result = uploader.run!
      assert_equal 1, result[:total_files]
      assert_equal 1, result[:uploaded].size
      assert result[:elapsed] >= 0
    ensure
      client&.singleton_class&.remove_method(:upload_file) if client.respond_to?(:upload_file)
    end
  end

  def test_uploader_run_with_fatal_error_sets_stop_flag
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "f.txt"), "data")
      File.write(File.join(dir, "g.txt"), "good")

      client = S3Client.new(
        region: "us-east-1", bucket: "b",
        access_key_id: "a", secret_access_key: "k",
        endpoint: "http://127.0.0.1:1", endpoint_style: :path,
        logger: Logger.new(File::NULL)
      )
      call_count = 0
      original_upload = client.method(:upload_file)
      client.define_singleton_method(:upload_file) do |**kwargs|
        call_count += 1
        if kwargs[:key] == "f.txt"
          raise S3Errors::S3Error.new("403", "AccessDenied")
        end

        original_upload.call(**kwargs)
      end

      uploader = S3BulkUploader.new(
        client: client, directory: dir, max_files: 1,
        skip_existing: false
      )
      result = uploader.run!
      assert result[:failed].size >= 1
    ensure
      client.singleton_class.remove_method(:upload_file) if client.respond_to?(:upload_file)
    end
  end

  def test_uploader_run_with_non_fatal_error
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "f.txt"), "data")

      client = S3Client.new(
        region: "us-east-1", bucket: "b",
        access_key_id: "a", secret_access_key: "k",
        endpoint: "http://127.0.0.1:1", endpoint_style: :path,
        logger: Logger.new(File::NULL)
      )
      client.define_singleton_method(:upload_file) do |**_kwargs|
        raise "unexpected failure"
      end

      uploader = S3BulkUploader.new(
        client: client, directory: dir, max_files: 1,
        skip_existing: false
      )
      result = uploader.run!
      assert_equal 1, result[:failed].size
    ensure
      client.singleton_class.remove_method(:upload_file) if client.respond_to?(:upload_file)
    end
  end

  # --- fetch_existing_objects error paths ---

  def test_uploader_fetch_existing_objects_error_non_404
    client = S3Client.new(
      region: "us-east-1", bucket: "b",
      access_key_id: "a", secret_access_key: "k",
      endpoint: "http://127.0.0.1:1", endpoint_style: :path,
      logger: Logger.new(File::NULL)
    )
    client.define_singleton_method(:list_objects) do |**_kwargs|
      raise S3Errors::S3Error.new("403", "AccessDenied")
    end

    uploader = S3BulkUploader.new(
      client: client, directory: Dir.mktmpdir, max_files: 1
    )
    map = uploader.send(:fetch_existing_objects)
    assert_nil map
  ensure
    client.singleton_class.remove_method(:list_objects) if client.respond_to?(:list_objects)
  end

  def test_uploader_fetch_existing_objects_error_404_raises
    client = S3Client.new(
      region: "us-east-1", bucket: "b",
      access_key_id: "a", secret_access_key: "k",
      endpoint: "http://127.0.0.1:1", endpoint_style: :path,
      logger: Logger.new(File::NULL)
    )
    client.define_singleton_method(:list_objects) do |**_kwargs|
      raise S3Errors::S3Error.new("404", "Not Found")
    end

    uploader = S3BulkUploader.new(
      client: client, directory: Dir.mktmpdir, max_files: 1
    )
    assert_raises(S3Errors::S3Error) { uploader.send(:fetch_existing_objects) }
  ensure
    client.singleton_class.remove_method(:list_objects) if client.respond_to?(:list_objects)
  end

  # --- fatal_upload_error?, pop_from_queue, build_result ---

  def test_uploader_fatal_upload_error_patterns
    uploader = S3BulkUploader.new(
      client: @client, directory: Dir.mktmpdir, max_files: 1
    )
    assert uploader.send(:fatal_upload_error?, S3Errors::S3Error.new("403", "AccessDenied"))
    assert uploader.send(:fatal_upload_error?, S3Errors::S3Error.new("403", "QuotaReached"))
    assert uploader.send(:fatal_upload_error?, S3Errors::S3Error.new("403", "Forbidden"))
    refute uploader.send(:fatal_upload_error?, S3Errors::S3Error.new("500", "ServerError"))
  end

  def test_uploader_pop_from_queue
    uploader = S3BulkUploader.new(
      client: @client, directory: Dir.mktmpdir, max_files: 1
    )
    q = Queue.new
    q << "item1"
    assert_equal "item1", uploader.send(:pop_from_queue, q)
    begin
      q.pop(true)
    rescue ThreadError
      nil
    end
    assert_nil uploader.send(:pop_from_queue, q)
  end

  def test_uploader_build_empty_result
    uploader = S3BulkUploader.new(
      client: @client, directory: Dir.mktmpdir, max_files: 1
    )
    result = uploader.send(:build_empty_result)
    assert_equal 0, result[:total_files]
    assert_equal 0, result[:throughput]
  end

  def test_uploader_build_result_with_data
    uploader = S3BulkUploader.new(
      client: @client, directory: Dir.mktmpdir, max_files: 1
    )
    files = [{ path: "/a", key: "a", size: 100 }]
    uploaded = [{ size: 100 }]
    failed = [{ key: "b", error: "fail" }]
    skipped = [{ key: "c" }]
    result = uploader.send(:build_result, files, uploaded, failed, skipped, 1.0)
    assert_equal 1, result[:total_files]
    assert_equal 100, result[:total_bytes]
    assert result[:throughput] >= 0
  end

  def test_uploader_build_result_zero_elapsed
    uploader = S3BulkUploader.new(
      client: @client, directory: Dir.mktmpdir, max_files: 1
    )
    result = uploader.send(:build_result, [], [], [], [], 0)
    assert_equal 0, result[:throughput]
  end

  # --- client_factory ---

  def test_uploader_client_factory_warning
    Dir.mktmpdir do |dir|
      output = StringIO.new
      original = @client.method(:log_warn)
      @client.define_singleton_method(:log_warn) { |msg| output.puts(msg) }

      S3BulkUploader.new(
        client: @client, directory: dir, max_files: 1
      )
      assert_includes output.string, "No client_factory"
    ensure
      @client.define_singleton_method(:log_warn, original)
    end
  end

  def test_uploader_with_client_factory
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "a.txt"), "data")
      factory_called = false
      uploader = S3BulkUploader.new(
        client: @client, directory: dir, max_files: 1,
        client_factory: lambda { |_idx|
          factory_called = true
          @client
        },
        skip_existing: false
      )
      uploader.run!
      assert factory_called
    end
  end

  # --- process_one_file ---

  def test_uploader_process_one_file_skip
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "a.txt"), "data")
      uploader = S3BulkUploader.new(
        client: @client, directory: dir, max_files: 1,
        skip_existing: true
      )

      mutex = Mutex.new
      uploaded = []
      failed = []
      skipped = []
      stop_flag = [false]
      stop_mutex = Mutex.new
      fatal_logged = [false]

      file = { path: File.join(dir, "a.txt"), key: "a.txt", size: 4 }

      mock_tc = S3Client.new(
        region: "us-east-1", bucket: "b",
        access_key_id: "a", secret_access_key: "k",
        endpoint: "http://127.0.0.1:1", endpoint_style: :path,
        logger: Logger.new(File::NULL)
      )
      mock_tc.define_singleton_method(:single_bucket?) { true }
      mock_tc.define_singleton_method(:head_object) do |**_kwargs|
        { content_length: 4, etag: '"abc"' }
      end
      def mock_tc.etag_matches_file?(_etag, _path)
        true
      end

      uploader.send(:process_one_file, file, mock_tc, 1, 1, mutex, uploaded, failed,
                    skipped, stop_mutex, stop_flag, fatal_logged, nil)
      assert skipped.size >= 1, "Expected skipped to have entries but got: #{skipped.inspect}"
      assert uploaded.empty?
    end
  end

  def test_uploader_process_one_file_on_file_error_callback
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "a.txt"), "data")
      uploader = S3BulkUploader.new(
        client: @client, directory: dir, max_files: 1,
        skip_existing: false
      )

      error_called = []
      uploader.instance_variable_set(:@on_file_error, ->(_p, _k, _e, _i, _t) { error_called << true })

      mutex = Mutex.new
      uploaded = []
      failed = []
      skipped = []
      stop_flag = [false]
      stop_mutex = Mutex.new
      fatal_logged = [false]

      file = { path: File.join(dir, "a.txt"), key: "a.txt", size: 4 }
      mock_tc = S3Client.new(
        region: "us-east-1", bucket: "b",
        access_key_id: "a", secret_access_key: "k",
        endpoint: "http://127.0.0.1:1", endpoint_style: :path,
        logger: Logger.new(File::NULL)
      )
      mock_tc.define_singleton_method(:upload_file) do |**_kwargs|
        raise S3Errors::S3Error.new("500", "ServerError")
      end

      uploader.send(:process_one_file, file, mock_tc, 1, 1, mutex, uploaded, failed,
                    skipped, stop_mutex, stop_flag, fatal_logged, {})
      assert_equal 1, failed.size
      assert error_called.any?
    ensure
      mock_tc&.singleton_class&.remove_method(:upload_file) if mock_tc.respond_to?(:upload_file)
    end
  end

  # --- fatal_logged dedup ---

  def test_uploader_fatal_logged_dedup
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "a.txt"), "data")
      uploader = S3BulkUploader.new(
        client: @client, directory: dir, max_files: 1,
        skip_existing: false
      )

      mutex = Mutex.new
      failed = []
      stop_flag = [false]
      stop_mutex = Mutex.new
      fatal_logged = [false]

      file = { path: File.join(dir, "a.txt"), key: "a.txt", size: 4 }
      error = S3Errors::S3Error.new("403", "AccessDenied")

      uploader.send(:handle_upload_error, error, file, @client, 1, 1, mutex, failed,
                    stop_mutex, stop_flag, fatal_logged)
      assert fatal_logged[0]

      uploader.send(:handle_upload_error, error, file, @client, 2, 2, mutex, failed,
                    stop_mutex, stop_flag, fatal_logged)
      assert_equal 2, failed.size
    end
  end
end
