# frozen_string_literal: true

class S3BaseClientDefaultTest < Minitest::Test
  include S3TestHelpers

  PORT = 15_609 + (Process.pid % 100) + rand(10)

  def setup
    @dir = Dir.mktmpdir("s3base_default")
    @store_dir = File.join(@dir, "store")
    tmp_dir = File.join(@dir, "tmp")
    server = FakeS3::Server.new(port: PORT, store_dir: @store_dir, tmp_dir: tmp_dir)
    server.start_thread
    @server = server

    @client = S3Client.new(
      region: "us-east-1", bucket: "b", access_key_id: "a", secret_access_key: "k",
      endpoint: "http://127.0.0.1:#{PORT}", endpoint_style: :path,
      part_size: 5 * 1024 * 1024, max_concurrency: 1,
      logger: Logger.new(File::NULL)
    )
  end

  def teardown
    @server&.stop
  end

  def test_single_bucket_returns_false_by_default
    test_client = Class.new(S3BaseClient)
    assert_equal false, test_client.new.single_bucket?
  end

  def test_download_part_http_error_response
    error_resp = Net::HTTPBadRequest.new(1.0, 400, "Bad Request")
    error_resp.instance_variable_set(:@read, true)
    mock_http = Object.new
    mock_http.define_singleton_method(:request) { |_req| error_resp }

    assert_raises(S3BaseClient::DownloadError) do
      @client.send(:download_part_http, "b", "/test.bin", 1, 0, 99, 100, mock_http)
    end
  end

  def test_upload_state_manager_save_state_eisdir
    state_file = File.join(@dir, "eisdir_save.json")
    dirname = @dir
    state_hash = {
      upload_id: "eisdir-test", key: "/test.bin",
      part_size: 5 * 1024 * 1024, total_size: 100,
      parts: {}, in_progress_parts: {}, thread_states: {}
    }

    raised = false
    original_open = File.method(:open)

    with_stubbed(File, :open, lambda { |path, *args, &block|
      if path == dirname
        raised = true
        raise Errno::EISDIR, "Is a directory"
      end
      original_open.call(path, *args, &block)
    }) do
      @client.upload_state_manager.save_state(state_file, state_hash)
    end

    assert raised, "EISDIR should have been raised during dir sync"
    assert File.exist?(state_file), "State file should exist despite EISDIR"
  end

  def test_upload_state_manager_validate_state_md5_match
    src_path, = create_temp_binary_file(100)
    state_hash = {
      upload_id: "md5-test", key: "/md5_match.bin",
      part_size: 5 * 1024 * 1024, total_size: 100,
      local_path: src_path,
      file_fingerprint: "#{File.mtime(src_path).to_f}-100",
      parts: {}, in_progress_parts: {}, thread_states: {}
    }

    result = @client.upload_state_manager.validate_state(state_hash,
                                                         key: "/md5_match.bin",
                                                         part_size: 5 * 1024 * 1024,
                                                         total_size: 100,
                                                         local_path: src_path)
    assert_kind_of UploadState, result, "Should return valid state when fingerprint matches"
  ensure
    File.delete(src_path) if src_path && File.exist?(src_path)
  end

  def test_upload_state_manager_save_state_fsync_standard_error
    state_file = File.join(@dir, "fsync_save.json")
    state_hash = {
      upload_id: "fsync-test", key: "/test.bin",
      part_size: 5 * 1024 * 1024, total_size: 100,
      parts: {}, in_progress_parts: {}, thread_states: {}
    }

    raised = false
    mock_dir = Object.new
    mock_dir.define_singleton_method(:fsync) do
      raised = true
      raise Errno::EISDIR, "Is a directory"
    end
    original_open = File.method(:open)
    dir = @dir

    with_stubbed(File, :open, lambda { |path, *args, &block|
      if path == dir
        block.call(mock_dir)
      else
        original_open.call(path, *args, &block)
      end
    }) do
      @client.upload_state_manager.save_state(state_file, state_hash)
    end

    assert raised, "fsync should have raised EISDIR caught by inner rescue"
    assert File.exist?(state_file), "State file should exist despite fsync error"
  end

  def test_upload_state_manager_validate_state_fingerprint_error
    src_path, = create_temp_binary_file(100)
    state_hash = {
      upload_id: "fp-error-test", key: "/fp_error.bin",
      part_size: 5 * 1024 * 1024, total_size: 100,
      local_path: src_path,
      file_fingerprint: "1000.0-100",
      parts: {}, in_progress_parts: {}, thread_states: {}
    }

    with_stubbed(File, :mtime, ->(path) { raise Errno::ENOENT, "File not found" }) do
      result = @client.upload_state_manager.validate_state(state_hash,
                                                           key: "/fp_error.bin",
                                                           part_size: 5 * 1024 * 1024,
                                                           total_size: 100,
                                                           local_path: src_path)
      assert_kind_of UploadState, result,
                     "Should return valid state when fingerprint computation fails (proceed optimistically)"
    end
  ensure
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

  # --- download_helpers.rb: compute_download_paths ---
  def test_compute_download_paths
    paths = @client.send(:compute_download_paths, "/tmp/test.bin", nil)
    assert_equal "/tmp/test.bin", paths.local_path
    assert_equal "/tmp/test.bin.part", paths.part_path
    assert_equal 0, paths.start_byte
  end

  def test_compute_download_paths_with_destination
    paths = @client.send(:compute_download_paths, nil, "/tmp/dest.bin")
    assert_equal "/tmp/dest.bin", paths.local_path
  end

  def test_rename_part_to_final
    Dir.mktmpdir do |dir|
      part = File.join(dir, "f.part")
      final = File.join(dir, "f.bin")
      File.write(part, "data")
      @client.send(:rename_part_to_final, part, final)
      assert File.exist?(final)
      refute File.exist?(part)
    end
  end

  def test_build_download_file_result
    result = @client.send(:build_download_file_result, "/k", "b", "/tmp/f.bin", 100, false)
    assert_equal "/k", result[:key]
    assert_equal 100, result[:size]
    refute result[:resumed]
  end

  # --- download_helpers.rb: setup_download_state ---
  def test_setup_download_state_no_state_file
    state = @client.send(:setup_download_state, "/k", "/tmp/f", 1000, 500, nil, "sess1", {})
    assert_kind_of DownloadState, state
    assert_equal "/k", state.key
    assert_equal 1000, state.total_size
    assert_equal "sess1", state.download_session_id
  end

  def test_setup_download_state_with_state_file
    dir = Dir.mktmpdir("dl_state_setup")
    begin
      state_file = File.join(dir, "state.json")
      state = @client.send(:setup_download_state, "/k", "/tmp/f", 1000, 500, state_file, "sess2", {})
      assert_kind_of DownloadState, state
      assert File.exist?(state_file), "state file should be created"
    ensure
      FileUtils.rm_rf(dir)
    end
  end

  # --- upload_logic.rb: resume_existing_upload ---
  def test_resume_existing_upload
    state = { upload_id: "uid", key: "/k", part_size: 5 * 1024 * 1024, total_size: 100, parts: {}, upload_session_id: "s1" }
    @client.send(:resume_existing_upload, state, 3)
    assert_equal 1, state[:resume_count]
    assert state[:resumed_at]
  end

  # --- upload_logic.rb: create_new_upload_state ---
  def test_create_new_upload_state
    src_path, = create_temp_binary_file(100)
    dir = Dir.mktmpdir("new_state")
    begin
      state_file = File.join(dir, "state.json")
      session = { upload_session_id: "s1", started_at: "2026-01-01", file_mtime: "1234.0", file_fingerprint: "1234.0-100" }
      result = @client.send(:create_new_upload_state, "/k", 5 * 1024 * 1024, 100, src_path, "application/octet-stream", {}, nil, state_file, session: session)
      assert_equal "s1", result[:upload_session_id]
      assert File.exist?(state_file), "state file should be created"
    ensure
      FileUtils.rm_rf(dir)
      File.delete(src_path) if src_path && File.exist?(src_path)
    end
  end

  # --- download_logic.rb ---
  def test_normalize_download_opts
    path, cb = @client.send(:normalize_download_opts, local_path: "/tmp/f", on_progress: nil)
    assert path
    assert_nil cb
  end

  def test_normalize_download_opts_with_destination
    path, = @client.send(:normalize_download_opts, destination_path: "/tmp/dest")
    assert path
  end

  def test_normalize_download_opts_raises_without_path
    assert_raises(ArgumentError) do
      @client.send(:normalize_download_opts)
    end
  end

  def test_normalize_download_opts_with_progress_callback
    pr = -> {}
    _, cb = @client.send(:normalize_download_opts, local_path: "/tmp/f", on_progress: pr)
    assert_equal pr, cb
  end

  # --- download_transport.rb: SingleBucketDownloadTransport ---
  def test_single_bucket_stream_get
    src_path, = create_temp_binary_file(100)
    @client.upload_file(local_path: src_path, key: "/stream_get_test.bin")

    chunks = []
    transport = SingleBucketDownloadTransport.new(@client)
    transport.stream_get("/stream_get_test.bin", {}, bucket: nil) { |chunk| chunks << chunk }

    assert chunks.any?
    total = chunks.sum(&:bytesize)
    assert_equal 100, total
  ensure
    File.delete(src_path) if src_path && File.exist?(src_path)
  end

  def test_single_bucket_range_get
    src_path, = create_temp_binary_file(100)
    @client.upload_file(local_path: src_path, key: "/range_get_test.bin")

    transport = SingleBucketDownloadTransport.new(@client)
    body = transport.range_get("/range_get_test.bin", 0, 49, bucket: nil)

    assert_equal 50, body.bytesize
  ensure
    File.delete(src_path) if src_path && File.exist?(src_path)
  end

  def test_single_bucket_open_http
    transport = SingleBucketDownloadTransport.new(@client)
    transport.open_http("/test.bin", bucket: nil) do |http|
      assert_kind_of Net::HTTP, http
    end
  end

  # --- download_transport.rb: abstract methods ---
  def test_download_transport_stream_get_raises
    assert_raises(NotImplementedError) do
      transport = Object.new
      transport.extend(DownloadTransport)
      transport.stream_get("/k", {}, bucket: nil) { |c| }
    end
  end

  def test_download_transport_range_get_raises
    assert_raises(NotImplementedError) do
      transport = Object.new
      transport.extend(DownloadTransport)
      transport.range_get("/k", 0, 99, bucket: nil)
    end
  end

  def test_download_transport_open_http_raises
    assert_raises(NotImplementedError) do
      transport = Object.new
      transport.extend(DownloadTransport)
      transport.open_http("/k", bucket: nil) { |h| }
    end
  end

  # --- upload_transport.rb: abstract methods ---
  def test_upload_transport_upload_part_raises
    assert_raises(NotImplementedError) do
      transport = Object.new
      transport.extend(UploadTransport)
      transport.upload_part("b", "/k", 1, "uid", "data", {}, nil)
    end
  end

  def test_upload_transport_put_single_raises
    assert_raises(NotImplementedError) do
      transport = Object.new
      transport.extend(UploadTransport)
      transport.put_single("/k", "body", {}, bucket: nil)
    end
  end

  def test_upload_transport_put_empty_raises
    assert_raises(NotImplementedError) do
      transport = Object.new
      transport.extend(UploadTransport)
      transport.put_empty("/k", {}, bucket: nil)
    end
  end

  # --- single_part_download.rb: 3-arity progress callback ---
  def test_single_part_download_with_3_arity_progress
    src_path, = create_temp_binary_file(100)
    @client.upload_file(local_path: src_path, key: "/dl_3arity_prog.bin")

    Dir.mktmpdir do |tmpdir|
      dst = File.join(tmpdir, "dl_3arity.bin")
      progress = []
      @client.download_file(
        key: "/dl_3arity_prog.bin",
        local_path: dst,
        on_progress: ->(written, total, pct) { progress << [written, total, pct] }
      )

      assert progress.any?
      assert_equal 3, progress.last.size
      assert_equal 100, progress.last[0]
    end
  ensure
    File.delete(src_path) if src_path && File.exist?(src_path)
  end

  # --- single_part_download.rb: with_download_error_handling rescue ---
  def test_single_part_download_error_rescue
    client = Object.new
    def client.perform_request(method, key, headers:, streaming:, bucket:)
      raise "unexpected error"
    end

    def client.log_debug(msg); end
    def client.log_error(msg); end
    def client.log_info(msg); end
    logger = Logger.new(File::NULL)

    downloader = S3BaseClient::SinglePartDownload.new(client: client, logger: logger)

    Dir.mktmpdir do |dir|
      assert_raises(S3BaseClient::DownloadError) do
        downloader.call(key: "/k", destination_path: File.join(dir, "f.bin"))
      end
    end
  end

  # --- upload_state_manager.rb: load_and_validate ---
  def test_upload_state_manager_load_and_validate_nil_path
    result = @client.upload_state_manager.load_and_validate(nil, key: "/k", part_size: 5 * 1024 * 1024, total_size: 100, local_path: "/tmp/f")
    assert_nil result
  end

  def test_upload_state_manager_load_and_validate_missing_file
    result = @client.upload_state_manager.load_and_validate("/nonexistent/path", key: "/k", part_size: 5 * 1024 * 1024, total_size: 100, local_path: "/tmp/f")
    assert_nil result
  end

  def test_upload_state_manager_load_and_validate_mismatch
    dir = Dir.mktmpdir("lav_mismatch")
    begin
      state_file = File.join(dir, "state.json")
      File.write(state_file, JSON.generate({
                                             upload_id: "uid", key: "/different", part_size: 10 * 1024 * 1024, total_size: 999, local_path: "/other", parts: {}
                                           }))
      result = @client.upload_state_manager.load_and_validate(state_file, key: "/k", part_size: 5 * 1024 * 1024, total_size: 100, local_path: "/tmp/f")
      assert_nil result
    ensure
      FileUtils.rm_rf(dir)
    end
  end

  def test_upload_state_manager_load_and_validate_corrupt_json
    dir = Dir.mktmpdir("lav_corrupt")
    begin
      state_file = File.join(dir, "state.json")
      File.write(state_file, "not valid json")
      result = @client.upload_state_manager.load_and_validate(state_file, key: "/k", part_size: 5 * 1024 * 1024, total_size: 100, local_path: "/tmp/f")
      assert_nil result
    ensure
      FileUtils.rm_rf(dir)
    end
  end

  # --- upload_state_manager.rb: sync_dir with EISDIR ---
  def test_upload_state_manager_sync_dir_eisdir
    @client.upload_state_manager.send(:sync_dir, "/nonexistent")
  end

  # --- utils.rb ---
  def test_format_throughput
    assert_equal "1.23", @client.send(:format_throughput, 1.234)
  end

  def test_format_progress
    result = @client.send(:format_progress, 1.5, 2.5)
    assert_includes result, "1.500"
    assert_includes result, "2.50"
  end

  # --- xml_helpers.rb: extract_etag with missing ETag ---
  def test_extract_etag_not_found
    xml = "<CompleteMultipartUploadResult><Bucket>b</Bucket></CompleteMultipartUploadResult>"
    assert_raises(S3BaseClient::S3Error) do
      @client.send(:extract_etag, xml)
    end
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

  # --- base_client.rb line 258: max_concurrency clamped warning ---
  def test_max_concurrency_clamped
    client = S3Client.new(
      region: "us-east-1", bucket: "b", access_key_id: "a", secret_access_key: "k",
      endpoint: "http://127.0.0.1:#{PORT}", endpoint_style: :path,
      max_concurrency: 999,
      logger: Logger.new(File::NULL)
    )
    assert_operator client.max_concurrency, :<=, S3BaseClient::MAXIMUM_CONCURRENCY
  end

  # --- download_helpers.rb: stream_write_chunks ---
  def test_stream_write_chunks_with_progress
    Dir.mktmpdir do |dir|
      part_path = File.join(dir, "test.part")
      resp = Net::HTTPSuccess.new(1.0, 200, "OK")
      resp.instance_variable_set(:@read, true)
      resp["Content-Range"] = "bytes 0-99/100"
      def resp.read_body
        yield "x" * 50
        yield "x" * 50
      end

      progress = []
      written = @client.send(:stream_write_chunks, resp, part_path, "wb", 0, ->(w, t) { progress << [w, t] })
      assert_equal 100, written
      assert progress.include?([50, 100])
      assert progress.include?([100, 100])
    end
  end

  # --- download_helpers.rb: stream_single_bucket_download ---
  def test_stream_single_bucket_download
    src_path, = create_temp_binary_file(100)
    @client.upload_file(local_path: src_path, key: "/stream_single_dl.bin")

    progress = []
    Dir.mktmpdir do |dir|
      paths = @client.send(:compute_download_paths, File.join(dir, "out.bin"), nil)
      written = @client.send(:stream_single_bucket_download, "/stream_single_dl.bin", paths, ->(w, t) { progress << [w, t] })
      assert_equal 100, written
      assert progress.any?
    end
  ensure
    File.delete(src_path) if src_path && File.exist?(src_path)
  end

  # --- download_helpers.rb: run_parallel_download ---
  def test_run_parallel_download_small_file
    src_path, = create_temp_binary_file(100)
    @client.upload_file(local_path: src_path, key: "/parallel_run_dl.bin")

    progress = []
    Dir.mktmpdir do |dir|
      dst = File.join(dir, "out.bin")
      result = @client.send(:run_parallel_download,
                            key: "/parallel_run_dl.bin", local_path: dst,
                            total_size: 100, part_size: 5 * 1024 * 1024,
                            max_threads: 1, max_retries: 1, retry_delay: 0.01,
                            on_progress: ->(w, t, p) { progress << [w, t, p] },
                            state_file: nil, state_extra: {}, result_extra: {})
      assert_kind_of S3BaseClient::DownloadResult, result
      assert File.exist?(dst)
    end
  ensure
    File.delete(src_path) if src_path && File.exist?(src_path)
  end

  # --- download_helpers.rb: run_parallel_download with state file ---
  def test_run_parallel_download_with_state_file
    src_path, = create_temp_binary_file(100)
    @client.upload_file(local_path: src_path, key: "/parallel_run_dl_state.bin")

    Dir.mktmpdir do |dir|
      dst = File.join(dir, "out.bin")
      state_file = File.join(dir, "dl_state.json")
      result = @client.send(:run_parallel_download,
                            key: "/parallel_run_dl_state.bin", local_path: dst,
                            total_size: 100, part_size: 5 * 1024 * 1024,
                            max_threads: 1, max_retries: 1, retry_delay: 0.01,
                            on_progress: nil,
                            state_file: state_file, state_extra: {}, result_extra: {})
      assert_kind_of S3BaseClient::DownloadResult, result
      assert File.exist?(dst)
    end
  ensure
    File.delete(src_path) if src_path && File.exist?(src_path)
  end

  # --- upload_state_manager.rb: validate_state with matching ---
  def test_validate_state_with_nil
    assert_nil @client.upload_state_manager.validate_state(nil, key: "/k", part_size: 5 * 1024 * 1024, total_size: 100, local_path: "/tmp/f")
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

  # --- upload_transport.rb: SingleBucketUploadTransport#put_empty block ---
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

  # --- upload_state_manager.rb:66-67: load_and_validate rescue Errno::ENOENT ---

  def test_load_and_validate_rescue_enoent
    with_stubbed(File, :file?, ->(*) { true }) do
      result = @client.upload_state_manager.load_and_validate(
        "/nonexistent/state.json", key: "/k",
                                   part_size: 5 * 1024 * 1024, total_size: 100,
                                   local_path: "/tmp/f"
      )
      assert_nil result
    end
  end

  # --- xml_helpers.rb: extract_etag with valid XML ---
  def test_extract_etag_success
    xml = "<CompleteMultipartUploadResult><ETag>\"abc123\"</ETag></CompleteMultipartUploadResult>"
    result = @client.send(:extract_etag, xml)
    assert_equal "\"abc123\"", result
  end

  # --- s3_client/networking.rb: _resume_download ---
  def test_resume_download_single_bucket
    src_path, = create_temp_binary_file(100)
    @client.upload_file(local_path: src_path, key: "/resume_sbc.bin")

    Dir.mktmpdir do |dir|
      paths = @client.send(:compute_download_paths, File.join(dir, "out.bin"), nil)
      result = @client.send(:_resume_download, "/resume_sbc.bin", paths: paths, on_progress: nil)
      assert_equal 100, result
    end
  ensure
    File.delete(src_path) if src_path && File.exist?(src_path)
  end

  # --- SingleBucketDownloadTransport: range_get with HTTP connection ---
  def test_single_bucket_range_get_with_http
    src_path, = create_temp_binary_file(100)
    @client.upload_file(local_path: src_path, key: "/range_get_http_test.bin")

    transport = SingleBucketDownloadTransport.new(@client)
    uri = @client.build_uri("/range_get_http_test.bin")
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = false
    http.open_timeout = 5
    http.read_timeout = 5
    http.start

    body = transport.range_get("/range_get_http_test.bin", 0, 49, bucket: nil, http: http)
    assert_equal 50, body.bytesize
  ensure
    begin
      http&.finish
    rescue StandardError
      nil
    end
    File.delete(src_path) if src_path && File.exist?(src_path)
  end
end
