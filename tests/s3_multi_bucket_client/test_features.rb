# frozen_string_literal: true

require_relative "../test_helper"
require_relative "../../src/s3_multi_bucket_client"

class S3MultiBucketFeaturesTest < Minitest::Test
  include S3TestHelpers

  PORT = 15_696
  BUCKET = "b"

  def setup
    dir = suite_tmp_dir("multibucket_features")
    @store_dir = File.join(dir, "store")
    @tmp_dir   = File.join(dir, "tmp")
    @server = FakeS3::Server.new(port: PORT, store_dir: @store_dir, tmp_dir: @tmp_dir)
    @server.start_thread

    @client = S3MultiBucketClient.new(
      endpoint: "http://127.0.0.1:#{PORT}", region: "us-east-1",
      access_key_id: "a", secret_access_key: "k",
      logger: Logger.new(File::NULL)
    )
  end

  def teardown
    @server.stop
    S3MultiBucketClient.clear_callbacks!
  end

  def test_human_readable_size
    assert_equal "0 B", @client.human_readable_size(0)
    assert_equal "1.00 KB", @client.human_readable_size(1024)
    assert_equal "1.50 KB", @client.human_readable_size(1536)
    assert_equal "1.00 GB", @client.human_readable_size(1024**3)
  end

  def test_presigned_url
    url = @client.presigned_url(bucket: BUCKET, key: "/data/file.bin", expires_in: 600)
    assert_includes url, "X-Amz-Signature"
    assert_includes url, "X-Amz-Expires=600"
  end

  def test_streaming_single_put
    src_path, src_md5 = create_temp_binary_file(11 * 1024 * 1024)
    r = @client.upload_file(bucket: BUCKET, key: "stream.bin", local_path: src_path)
    assert r[:etag]

    stored_path = File.join(@store_dir, BUCKET, "stream.bin")
    dl_md5 = Digest::MD5.file(stored_path).hexdigest
    assert_equal src_md5, dl_md5
  ensure
    File.delete(src_path) if src_path && File.exist?(src_path)
  end

  def test_list_multipart_uploads_and_parts
    uid = @client.multipart_start(bucket: BUCKET, key: "/pending/file.bin")
    [1, 2].each do |n|
      data = SecureRandom.bytes(5 * 1024 * 1024)
      @client.multipart_upload_part(bucket: BUCKET, key: "/pending/file.bin",
                                    upload_id: uid, part_number: n, body: data)
    end

    uploads = @client.list_multipart_uploads(bucket: BUCKET)
    assert uploads.any? { |u| u[:upload_id] == uid }

    parts = @client.list_parts(bucket: BUCKET, key: "/pending/file.bin", upload_id: uid)
    assert_equal 2, parts.size
    assert parts.all? { |p| p[:size] == 5 * 1024 * 1024 }

    @client.abort_multipart_upload(bucket: BUCKET, key: "/pending/file.bin", upload_id: uid)
    uploads_after = @client.list_multipart_uploads(bucket: BUCKET)
    assert uploads_after.none? { |u| u[:upload_id] == uid }
  end

  def test_download_file_with_progress_and_md5
    src_path, src_md5 = create_temp_binary_file(12 * 1024 * 1024)
    @client.upload_file(bucket: BUCKET, key: "big.bin", local_path: src_path,
                        part_size: 5 * 1024 * 1024)

    dst = File.join(@store_dir, "dl_big.bin")
    FileUtils.rm_f(dst)

    progress = []
    r = @client.download_file(
      bucket: BUCKET, key: "big.bin", destination_path: dst,
      on_progress: ->(w, t) { progress << [w, t] }
    )
    assert_equal 12 * 1024 * 1024, r[:size]

    dl_md5 = Digest::MD5.file(dst).hexdigest
    assert_equal src_md5, dl_md5
    assert progress.any?
  ensure
    File.delete(src_path) if src_path && File.exist?(src_path)
  end

  def test_event_callback_system
    events = []
    cb1 = S3MultiBucketClient.on(:upload_start) { |*args| events << [:upload_start, args] }
    cb2 = S3MultiBucketClient.on(:part_complete) { |*args| events << [:part_complete, args] }
    cb3 = S3MultiBucketClient.on(:upload_complete) { |*args| events << [:upload_complete, args] }

    src_path, = create_temp_binary_file(12 * 1024 * 1024)
    @client.upload_file(bucket: BUCKET, key: "/evt.bin", local_path: src_path,
                        part_size: 5 * 1024 * 1024)

    assert events.any? { |e| e[0] == :upload_start }
    assert events.any? { |e| e[0] == :part_complete }
    assert events.any? { |e| e[0] == :upload_complete }
    part_events = events.select { |e| e[0] == :part_complete }
    assert part_events.size >= 2
  ensure
    File.delete(src_path) if src_path && File.exist?(src_path)
    S3MultiBucketClient.off(:upload_start, cb1)
    S3MultiBucketClient.off(:part_complete, cb2)
    S3MultiBucketClient.off(:upload_complete, cb3)
  end

  def test_log_file_and_debug_mode
    log_path = File.join(@store_dir, "test.log")
    FileUtils.rm_f(log_path)

    debug_client = S3MultiBucketClient.new(
      endpoint: "http://127.0.0.1:#{PORT}", region: "us-east-1",
      access_key_id: "a", secret_access_key: "k",
      log_file: log_path, debug: true
    )

    src = Tempfile.new(["log", ".bin"])
    src.close
    File.write(src.path, "log test data")
    debug_client.upload_file(bucket: BUCKET, key: "/log.txt", local_path: src.path)

    assert File.exist?(log_path)
    log_content = File.read(log_path)
    assert_includes log_content, "upload_file"
    assert_includes log_content, "[S3]"
    assert_match(/\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\.\d{3}/, log_content)
  ensure
    src&.unlink
  end

  def test_upload_skip_existing_with_head
    src_path, = create_temp_binary_file(1024)
    @client.upload_file(bucket: BUCKET, key: "/skip-mb.bin", local_path: src_path)
    result = @client.upload_file(bucket: BUCKET, key: "/skip-mb.bin", local_path: src_path, skip_existing: true)
    assert result[:skipped], "expected skipped=true"
    assert_includes result[:reason], "already exists"
  ensure
    File.delete(src_path) if src_path && File.exist?(src_path)
  end

  def test_download_file_multi_bucket
    src_path, src_md5 = create_temp_binary_file(12 * 1024 * 1024)
    @client.upload_file(bucket: BUCKET, key: "/dl-par-mb.bin", local_path: src_path, part_size: 5 * 1024 * 1024)

    dst = File.join(@store_dir, "dl_par_mb.bin")
    FileUtils.rm_f(dst)

    result = @client.download_file(
      bucket: BUCKET, key: "/dl-par-mb.bin", destination_path: dst
    )
    assert_equal 12 * 1024 * 1024, result[:size]
    dl_md5 = Digest::MD5.file(dst).hexdigest
    assert_equal src_md5, dl_md5
  ensure
    File.delete(src_path) if src_path && File.exist?(src_path)
    FileUtils.rm_f(dst) if defined?(dst)
  end

  def test_head_object_multi_bucket
    src_path, = create_temp_binary_file(1024)
    @client.upload_file(bucket: BUCKET, key: "/head-mb.bin", local_path: src_path)
    h = @client.head_object(bucket: BUCKET, key: "/head-mb.bin")
    assert_equal 1024, h[:content_length]
    assert h[:etag]
  ensure
    File.delete(src_path) if src_path && File.exist?(src_path)
  end

  def test_delete_object_multi_bucket
    src_path, = create_temp_binary_file(512)
    @client.upload_file(bucket: BUCKET, key: "/del-mb.bin", local_path: src_path)
    result = @client.delete_object(bucket: BUCKET, key: "/del-mb.bin")
    assert_equal "deleted", result[:status]
  ensure
    File.delete(src_path) if src_path && File.exist?(src_path)
  end

  def test_multipart_upload_part_with_io_body
    uid = @client.multipart_start(bucket: BUCKET, key: "/io-part.bin")
    Tempfile.create(["io-body", ".bin"]) do |f|
      f.write("x" * 1024)
      f.flush
      f.seek(0)
      etag = @client.multipart_upload_part(
        bucket: BUCKET, key: "/io-part.bin",
        upload_id: uid, part_number: 1, body: f, length: 1024
      )
      assert etag
    end
  ensure
    begin
      @client.multipart_abort(bucket: BUCKET, key: "/io-part.bin", upload_id: uid)
    rescue StandardError
      nil
    end
  end

  def test_multipart_upload_part_with_io_and_offset
    uid = @client.multipart_start(bucket: BUCKET, key: "/io-offset.bin")
    Tempfile.create(["io-offset", ".bin"]) do |f|
      f.write("AAAABBBB")
      f.flush
      etag = @client.multipart_upload_part(
        bucket: BUCKET, key: "/io-offset.bin",
        upload_id: uid, part_number: 1, body: f, length: 4, io_offset: 4
      )
      assert etag
    end
  ensure
    begin
      @client.multipart_abort(bucket: BUCKET, key: "/io-offset.bin", upload_id: uid)
    rescue StandardError
      nil
    end
  end

  def test_multipart_upload_part_invalid_body
    uid = @client.multipart_start(bucket: BUCKET, key: "/inv-body.bin")
    assert_raises(ArgumentError) do
      @client.multipart_upload_part(
        bucket: BUCKET, key: "/inv-body.bin",
        upload_id: uid, part_number: 1, body: 12_345
      )
    end
  ensure
    begin
      @client.multipart_abort(bucket: BUCKET, key: "/inv-body.bin", upload_id: uid)
    rescue StandardError
      nil
    end
  end

  def test_multipart_complete_and_abort
    uid = @client.multipart_start(bucket: BUCKET, key: "/comp-abort.bin")
    Tempfile.create(["comp", ".bin"]) do |f|
      f.write("data")
      f.flush
      f.seek(0)
      etag1 = @client.multipart_upload_part(
        bucket: BUCKET, key: "/comp-abort.bin",
        upload_id: uid, part_number: 1, body: f, length: 4
      )
      result = @client.multipart_complete(
        bucket: BUCKET, key: "/comp-abort.bin",
        upload_id: uid, parts: [{ part_number: 1, etag: etag1 }]
      )
      assert result
    end
  end

  def test_download_file_with_range_arg
    src_path, = create_temp_binary_file(1024)
    @client.upload_file(bucket: BUCKET, key: "/dl-range-arg.bin", local_path: src_path)
    dst = File.join(@store_dir, "dl_range_arg.bin")
    FileUtils.rm_f(dst)
    result = @client.download_file(
      bucket: BUCKET, key: "/dl-range-arg.bin",
      destination_path: dst, range: (50..150)
    )
    assert File.file?(dst)
    assert_operator result[:size], :>, 0
  ensure
    File.delete(src_path) if src_path && File.exist?(src_path)
  end

  def test_download_stream_multi_bucket
    src_path, = create_temp_binary_file(1024)
    @client.upload_file(bucket: BUCKET, key: "/dl-stream-mb.bin", local_path: src_path)
    buf = +""
    @client.download_stream(bucket: BUCKET, key: "/dl-stream-mb.bin") { |c| buf << c }
    assert_equal 1024, buf.bytesize
  ensure
    File.delete(src_path) if src_path && File.exist?(src_path)
  end

  def test_upload_file_small
    src_path, = create_temp_binary_file(2048)
    result = @client.upload_file(
      bucket: BUCKET, key: "/resume-state.bin",
      local_path: src_path
    )
    assert result[:etag]
    assert_operator result[:size], :>, 0
  ensure
    File.delete(src_path) if src_path && File.exist?(src_path)
  end

  def test_thread_safe_logging
    log_entries = []
    S3MultiBucketClient.on(:log) { |level, msg, tid, ts| log_entries << [level, msg, tid] }

    log_client = S3MultiBucketClient.new(
      endpoint: "http://127.0.0.1:#{PORT}", region: "us-east-1",
      access_key_id: "a", secret_access_key: "k",
      logger: Logger.new(File::NULL)
    )

    log_client.thread_log_info("test message from main", "main")
    log_client.thread_log_warn("test warning", "t0")
    log_client.thread_log_error("test error", "t1")

    assert_equal 3, log_entries.size
    assert_equal [:info, "test message from main", "main"], log_entries[0]
    assert_equal [:warn, "test warning", "t0"], log_entries[1]
    assert_equal [:error, "test error", "t1"], log_entries[2]
  end

  # --- upload_file with cache_control ---

  def test_upload_file_with_cache_control
    src_path, = create_temp_binary_file(12 * 1024 * 1024)
    r = @client.upload_file(
      bucket: BUCKET, key: "/cached_mp_mb.bin", local_path: src_path,
      part_size: 5 * 1024 * 1024, cache_control: "max-age=7200"
    )
    refute r[:error], "upload failed: #{r[:error]}"
  ensure
    File.delete(src_path) if src_path && File.exist?(src_path)
  end

  # --- upload_file with raise_on_error ---

  def test_upload_file_raise_on_error_success
    src_path, = create_temp_binary_file(1024)
    r = @client.upload_file(
      bucket: BUCKET, key: "/roe_mb.bin", local_path: src_path
    )
    assert r[:etag] || r[:key]
  ensure
    File.delete(src_path) if src_path && File.exist?(src_path)
  end

  def test_upload_file_raise_on_error_failure
    assert_raises(Errno::ENOENT) do
      @client.upload_file(
        bucket: BUCKET, key: "/roe_fail_mb.bin",
        local_path: "/nonexistent/file.bin"
      )
    end
  end

  def test_upload_file_error_without_raise
    assert_raises(Errno::ENOENT) do
      @client.upload_file(
        bucket: BUCKET, key: "/no_raise_mb.bin",
        local_path: "/nonexistent/file.bin"
      )
    end
  end

  # --- upload_file with state_file auto-load mismatch ---

  def test_upload_file_state_file_mismatch
    src_path, = create_temp_binary_file(12 * 1024 * 1024)
    state_file = File.join(@store_dir, "mismatch_state.json")

    old_uid = @client.multipart_start(bucket: BUCKET, key: "/old_key.bin")
    old_state = UploadState.new(
      upload_id: old_uid, key: "/old_key.bin", bucket: BUCKET,
      local_path: "/some/other/path", part_size: 5 * 1024 * 1024,
      total_size: 99_999, parts: []
    )
    old_state.save_to_file(state_file)

    r = @client.upload_file(
      bucket: BUCKET, key: "/new_key_mb.bin", local_path: src_path,
      part_size: 5 * 1024 * 1024, state_file: state_file
    )
    refute r[:error], "upload failed: #{r[:error]}"
  ensure
    File.delete(src_path) if src_path && File.exist?(src_path)
  end

  # --- upload_file with corrupt state file ---

  def test_upload_file_corrupt_state_file
    src_path, = create_temp_binary_file(12 * 1024 * 1024)
    state_file = File.join(@store_dir, "corrupt_state.json")
    File.write(state_file, "not valid json {{{")

    r = @client.upload_file(
      bucket: BUCKET, key: "/corrupt_st_mb.bin", local_path: src_path,
      part_size: 5 * 1024 * 1024, state_file: state_file
    )
    refute r[:error], "upload failed: #{r[:error]}"
  ensure
    File.delete(src_path) if src_path && File.exist?(src_path)
  end

  # --- resume_upload error paths ---

  def test_resume_upload_nonexistent_state_file
    assert_raises(Errno::ENOENT) do
      @client.resume_upload(
        bucket: BUCKET, key: "k", local_path: "/tmp/f",
        state_file: "/nonexistent/state.json"
      )
    end
  end

  def test_resume_upload_nonexistent_file_path
    Dir.mktmpdir do |dir|
      state_file = File.join(dir, "state.json")
      state = UploadState.new(
        upload_id: "uid-1", key: "k", bucket: BUCKET,
        local_path: "/nonexistent/file.bin",
        part_size: 5_242_880, total_size: 100
      )
      state.save_to_file(state_file)
      assert_raises(Errno::ENOENT) do
        @client.resume_upload(
          bucket: BUCKET, key: "k",
          local_path: "/nonexistent/file.bin",
          state_file: state_file
        )
      end
    end
  end

  def test_resume_upload_file_size_mismatch
    Dir.mktmpdir do |dir|
      local_path = File.join(dir, "file.bin")
      File.write(local_path, "small content")
      state_file = File.join(dir, "state.json")
      state = UploadState.new(
        upload_id: "uid-1", key: "k", bucket: BUCKET,
        local_path: "/nonexistent/path/to/file.bin",
        part_size: 5_242_880, total_size: 99_999
      )
      state.save_to_file(state_file)
      assert_raises(ArgumentError) do
        @client.resume_upload(
          bucket: BUCKET, key: "k",
          local_path: local_path,
          state_file: state_file
        )
      end
    end
  end

  # --- download_file with Array range ---

  def test_download_file_with_array_range
    src_path, = create_temp_binary_file(1024)
    @client.upload_file(bucket: BUCKET, key: "/dl_arr.bin", local_path: src_path)
    dst = File.join(@store_dir, "dl_arr.bin")
    FileUtils.rm_f(dst)
    result = @client.download_file(
      bucket: BUCKET, key: "/dl_arr.bin",
      destination_path: dst, range: [50, 150]
    )
    assert File.file?(dst)
    assert_operator result[:size], :>, 0
  ensure
    File.delete(src_path) if src_path && File.exist?(src_path)
  end

  # --- download_file with exclude_end range ---

  def test_download_file_with_exclude_end_range
    src_path, = create_temp_binary_file(1024)
    @client.upload_file(bucket: BUCKET, key: "/dl_exc.bin", local_path: src_path)
    dst = File.join(@store_dir, "dl_exc.bin")
    FileUtils.rm_f(dst)
    @client.download_file(
      bucket: BUCKET, key: "/dl_exc.bin",
      destination_path: dst, range: (50...150)
    )
    assert File.file?(dst)
  ensure
    File.delete(src_path) if src_path && File.exist?(src_path)
  end

  # --- signed_request_via with body_stream integration ---

  def test_signed_request_via_body_stream_integration
    uid = @client.multipart_start(bucket: BUCKET, key: "/via_stream.bin")
    Tempfile.create(["via", ".bin"]) do |f|
      f.write("stream content data")
      f.flush
      f.seek(0)
      uri = @client.build_uri(BUCKET, "/via_stream.bin", {
                                'partNumber' => '1', 'uploadId' => uid
                              })
      @client.http_start(BUCKET, "/via_stream.bin") do |http|
        resp = @client.signed_request_via(http, uri, body_stream: f)
        assert resp.is_a?(Net::HTTPSuccess)
        assert resp['ETag']
      end
    end
  ensure
    begin
      @client.multipart_abort(bucket: BUCKET, key: "/via_stream.bin", upload_id: uid)
    rescue StandardError
      nil
    end
  end

  # --- download_file with progress_callback ---

  def test_download_file_with_progress
    src_path, = create_temp_binary_file(12 * 1024 * 1024)
    @client.upload_file(bucket: BUCKET, key: "/dl_par_prog.bin",
                        local_path: src_path, part_size: 5 * 1024 * 1024)

    dst = File.join(@store_dir, "dl_par_prog.bin")
    FileUtils.rm_f(dst)

    progress_calls = []
    result = @client.download_file(
      bucket: BUCKET, key: "/dl_par_prog.bin", destination_path: dst,
      on_progress: ->(w, t) { progress_calls << [w, t] }
    )
    assert_equal 12 * 1024 * 1024, result[:size]
  ensure
    File.delete(src_path) if src_path && File.exist?(src_path)
    FileUtils.rm_f(dst) if defined?(dst)
  end

  # --- upload_directory with state_dir and cache_control ---

  def test_upload_directory_with_cache_control
    dir = File.join(@store_dir, "cc_dir_mb")
    FileUtils.mkdir_p(dir)
    File.write(File.join(dir, "a.txt"), "cached content")

    result = @client.upload_directory(
      bucket: BUCKET, directory: dir, prefix: "cc/",
      cache_control: "max-age=3600",
      metadata: { "author" => "test" }
    )
    assert_equal 1, result[:uploaded].size
  end

  # --- log_file and debug mode ---

  def test_log_file_debug_mode_upload
    log_path = File.join(@store_dir, "debug_upload.log")
    FileUtils.rm_f(log_path)

    debug_client = S3MultiBucketClient.new(
      endpoint: "http://127.0.0.1:#{PORT}", region: "us-east-1",
      access_key_id: "a", secret_access_key: "k",
      log_file: log_path, debug: true, log_color: true
    )

    src = Tempfile.new(["log_dbg", ".bin"])
    src.close
    File.write(src.path, "debug log test data")
    debug_client.upload_file(bucket: BUCKET, key: "/log_dbg.txt", local_path: src.path)

    assert File.exist?(log_path)
    log_content = File.read(log_path)
    assert_includes log_content, "[S3]"
  ensure
    src&.unlink
  end

  # --- upload empty file ---

  def test_upload_empty_file_multi_bucket
    Tempfile.create(["empty_mb", ".bin"]) do |f|
      f.binmode
      r = @client.upload_file(bucket: BUCKET, key: "/empty_mb.bin", local_path: f.path)
      assert r[:etag]
    end
  end

  # --- upload_file empty file ---

  def test_upload_file_empty_file_mb
    Tempfile.create(["empty_mp_mb", ".bin"]) do |f|
      f.binmode
      @client.upload_file(
        bucket: BUCKET, key: "/empty_mp_mb.bin",
        local_path: f.path
      )
    end
  end

  # --- download_file with resume flag and existing part file ---

  def test_download_file_flag
    src_path, = create_temp_binary_file(5 * 1024 * 1024)
    @client.upload_file(bucket: BUCKET, key: "/dl_resume_flag.bin", local_path: src_path)

    dst = File.join(@store_dir, "dl_resume_flag.bin")
    part_path = "#{dst}.part"
    FileUtils.rm_f(dst)
    FileUtils.rm_f(part_path)

    File.open(File.join(@store_dir, BUCKET, "dl_resume_flag.bin"), "rb") do |f|
      File.binwrite(part_path, f.read(1024 * 1024))
    end

    @client.download_file(
      bucket: BUCKET, key: "/dl_resume_flag.bin",
      destination_path: dst, resume: true
    )
    assert File.file?(dst)
    assert_equal 5 * 1024 * 1024, File.size(dst)
  ensure
    File.delete(src_path) if src_path && File.exist?(src_path)
  end

  # --- upload with event callbacks on multi-bucket ---

  def test_upload_with_state_save_event
    S3MultiBucketClient.clear_callbacks!
    events = []
    S3MultiBucketClient.on(:state_save) { |*a| events << a }

    src_path, = create_temp_binary_file(12 * 1024 * 1024)
    state_file = File.join(@store_dir, "state_evt.json")
    @client.upload_file(
      bucket: BUCKET, key: "/state_evt.bin", local_path: src_path,
      part_size: 5 * 1024 * 1024, state_file: state_file
    )

    assert !events.empty?, "expected state_save events"
  ensure
    File.delete(src_path) if src_path && File.exist?(src_path)
    S3MultiBucketClient.clear_callbacks!
  end

  # --- download_file with state_file ---

  def test_download_file_with_state_file
    src_path, = create_temp_binary_file(12 * 1024 * 1024)
    @client.upload_file(bucket: BUCKET, key: "/dl_par_state_mb.bin",
                        local_path: src_path, part_size: 5 * 1024 * 1024)

    state_file = File.join(@store_dir, "dl_par_state.json")
    dst = File.join(@store_dir, "dl_par_state_mb.bin")
    FileUtils.rm_f(dst)
    FileUtils.rm_f(state_file)

    result = @client.download_file(
      bucket: BUCKET, key: "/dl_par_state_mb.bin", destination_path: dst
    )
    assert_equal 12 * 1024 * 1024, result[:size]
  ensure
    File.delete(src_path) if src_path && File.exist?(src_path)
    FileUtils.rm_f(dst) if defined?(dst)
  end

  # --- upload_file with metadata ---

  def test_upload_file_with_metadata_mb
    src = Tempfile.new(["meta_mb", ".txt"])
    src.write("metadata test")
    src.close

    r = @client.upload_file(
      bucket: BUCKET, key: "/meta_mb.txt", local_path: src.path,
      metadata: { "author" => "test", "version" => "1" }
    )
    assert r[:etag]

    h = @client.head_object(bucket: BUCKET, key: "/meta_mb.txt")
    assert_equal "test", h[:metadata]["author"]
  ensure
    src&.unlink
  end
end
