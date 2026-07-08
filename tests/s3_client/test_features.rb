# frozen_string_literal: true

require_relative "../test_helper"
require_relative "../../src/s3-upload"

class S3ClientFeaturesTest < Minitest::Test
  include S3TestHelpers

  PORT = 15_596

  def setup
    dir = suite_tmp_dir("s3client_features")
    @store_dir = File.join(dir, "store")
    @tmp_dir   = File.join(dir, "tmp")
    @server = FakeS3::Server.new(port: PORT, store_dir: @store_dir, tmp_dir: @tmp_dir)
    @server.start_thread

    @client = S3Client.new(
      region: "us-east-1", bucket: "b", access_key_id: "a", secret_access_key: "k",
      endpoint: "http://127.0.0.1:#{PORT}", endpoint_style: :path,
      part_size: 5 * 1024 * 1024, max_concurrency: 2,
      logger: Logger.new(File::NULL)
    )
  end

  def teardown
    @server.stop
  end

  def test_human_readable_size
    assert_equal "0 B", @client.human_readable_size(0)
    assert_equal "1.00 KB", @client.human_readable_size(1024)
    assert_equal "1.50 KB", @client.human_readable_size(1536)
    assert_equal "1.00 GB", @client.human_readable_size(1024**3)
    assert_equal "2.50 TB", @client.human_readable_size((2.5 * (1024**4)).to_i)
  end

  def test_presigned_url
    url = @client.presigned_url(key: "/data/file.bin", expires_in: 600)
    assert_includes url, "X-Amz-Signature"
    assert_includes url, "X-Amz-Expires=600"
    assert_includes url, "/data/file.bin"
  end

  def test_streaming_single_put
    src_path, src_md5 = create_temp_binary_file(6 * 1024 * 1024)
    r = @client.upload_file(local_path: src_path, key: "/stream.bin", part_size: 20 * 1024 * 1024)
    assert_equal 1, r[:parts].size

    dl_md5 = Digest::MD5.file(File.join(@store_dir, "b/stream.bin")).hexdigest
    assert_equal src_md5, dl_md5
  ensure
    File.delete(src_path) if src_path && File.exist?(src_path)
  end

  def test_list_multipart_uploads_and_parts
    uid = @client.multipart_start(key: "/pending/file.bin")
    [1, 2].each do |n|
      data = SecureRandom.bytes(5 * 1024 * 1024)
      @client.multipart_upload_part(key: "/pending/file.bin", upload_id: uid,
                                    part_number: n, body: data)
    end

    uploads = @client.list_multipart_uploads
    assert uploads.any? { |u| u[:upload_id] == uid }

    parts = @client.list_parts(key: "/pending/file.bin", upload_id: uid)
    assert_equal 2, parts.size
    assert parts.all? { |p| p[:size] == 5 * 1024 * 1024 }

    @client.multipart_abort(key: "/pending/file.bin", upload_id: uid)
    uploads_after = @client.list_multipart_uploads
    assert uploads_after.none? { |u| u[:upload_id] == uid }
  end

  def test_download_file_with_progress_and_md5
    src_path, src_md5 = create_temp_binary_file(6 * 1024 * 1024)
    @client.upload_file(local_path: src_path, key: "/big.bin", part_size: 5 * 1024 * 1024)

    dst = File.join(@store_dir, "dl_big.bin")
    FileUtils.rm_f(dst)

    progress = []
    r = @client.download_file(key: "/big.bin", local_path: dst,
                              on_progress: ->(w, t) { progress << [w, t] })
    assert_equal 6 * 1024 * 1024, r[:size]
    assert File.exist?(dst)

    dl_md5 = Digest::MD5.file(dst).hexdigest
    assert_equal src_md5, dl_md5
    assert progress.any?
  ensure
    File.delete(src_path) if src_path && File.exist?(src_path)
  end

  def test_s3helper_upload
    src_path, src_md5 = create_temp_binary_file(6 * 1024 * 1024)
    r = S3Helper.upload(client: @client, key: "/huge.bin", local_path: src_path,
                        multipart_threshold: 5 * 1024 * 1024)
    assert r[:parts].size >= 2

    dl_md5 = Digest::MD5.file(File.join(@store_dir, "b/huge.bin")).hexdigest
    assert_equal src_md5, dl_md5
  ensure
    File.delete(src_path) if src_path && File.exist?(src_path)
  end

  def test_s3helper_download
    src_path, src_md5 = create_temp_binary_file(6 * 1024 * 1024)
    S3Helper.upload(client: @client, key: "/huge2.bin", local_path: src_path,
                    multipart_threshold: 5 * 1024 * 1024)

    dst = File.join(@store_dir, "dl_huge.bin")
    FileUtils.rm_f(dst)

    require "stringio"
    old_stderr = $stderr
    $stderr = StringIO.new
    S3Helper.download(client: @client, key: "/huge2.bin", local_path: dst)
    stderr_out = $stderr.string
    $stderr = old_stderr

    assert_includes stderr_out, "100.0%"
    dl_md5 = Digest::MD5.file(dst).hexdigest
    assert_equal src_md5, dl_md5
  ensure
    File.delete(src_path) if src_path && File.exist?(src_path)
  end

  def test_s3helper_download_with_progress
    src_path, src_md5 = create_temp_binary_file(6 * 1024 * 1024)
    S3Helper.upload(client: @client, key: "/huge3.bin", local_path: src_path,
                    multipart_threshold: 5 * 1024 * 1024)

    dst = File.join(@store_dir, "dl_huge3.bin")
    FileUtils.rm_f(dst)

    r = S3Helper.download(client: @client, key: "/huge3.bin", local_path: dst,
                          show_progress: false)
    assert_equal 6 * 1024 * 1024, r[:size]

    dl_md5 = Digest::MD5.file(dst).hexdigest
    assert_equal src_md5, dl_md5
  ensure
    File.delete(src_path) if src_path && File.exist?(src_path)
  end

  def test_upload_skip_existing
    src_path, = create_temp_binary_file(1024)
    @client.upload_file(local_path: src_path, key: "/skip.bin")
    result = @client.upload_file(local_path: src_path, key: "/skip.bin", skip_existing: true)
    assert result[:skipped]
    assert_includes result[:reason], "already exists"
  ensure
    File.delete(src_path) if src_path && File.exist?(src_path)
  end

  def test_head_object_integration
    src_path, = create_temp_binary_file(1024)
    @client.upload_file(local_path: src_path, key: "/head-int.bin")
    h = @client.head_object("/head-int.bin")
    assert_equal 1024, h[:content_length]
    assert h[:etag]
  ensure
    File.delete(src_path) if src_path && File.exist?(src_path)
  end

  def test_list_multipart_uploads_pagination
    uid = @client.multipart_start(key: "/list-test.bin")
    uploads = @client.list_multipart_uploads(prefix: "/list-test")
    assert uploads.any? { |u| u[:upload_id] == uid }
  ensure
    begin
      @client.multipart_abort(key: "/list-test.bin", upload_id: uid)
    rescue StandardError
      nil
    end
  end

  def test_download_file
    src_path, src_md5 = create_temp_binary_file(6 * 1024 * 1024)
    @client.upload_file(local_path: src_path, key: "/dl-parallel.bin", part_size: 5 * 1024 * 1024)

    dst = File.join(@store_dir, "dl_parallel_copy.bin")
    FileUtils.rm_f(dst)

    result = @client.download_file(
      key: "/dl-parallel.bin", local_path: dst
    )
    assert_equal 6 * 1024 * 1024, result[:size]
    dl_md5 = Digest::MD5.file(dst).hexdigest
    assert_equal src_md5, dl_md5
  ensure
    File.delete(src_path) if src_path && File.exist?(src_path)
    FileUtils.rm_f(dst) if defined?(dst)
  end

  def test_download_file_with_state_file
    src_path, = create_temp_binary_file(6 * 1024 * 1024)
    @client.upload_file(local_path: src_path, key: "/dl-par-state.bin", part_size: 5 * 1024 * 1024)

    state_file = File.join(@store_dir, "dl_state.json")
    dst = File.join(@store_dir, "dl_parallel_state.bin")
    FileUtils.rm_f(dst)
    FileUtils.rm_f(state_file)

    result = @client.download_file(
      key: "/dl-par-state.bin", local_path: dst
    )
    assert_equal 6 * 1024 * 1024, result[:size]
  ensure
    File.delete(src_path) if src_path && File.exist?(src_path)
    FileUtils.rm_f(dst) if defined?(dst)
  end

  def test_download_file_with_md5_verification
    src_path, src_md5 = create_temp_binary_file(6 * 1024 * 1024)
    @client.upload_file(local_path: src_path, key: "/dl_evt.bin", part_size: 5 * 1024 * 1024)

    dst = File.join(@store_dir, "dl_evt_copy.bin")
    FileUtils.rm_f(dst)

    result = @client.download_file(
      key: "/dl_evt.bin", local_path: dst
    )
    assert_equal 6 * 1024 * 1024, result[:size]

    dl_md5 = Digest::MD5.file(dst).hexdigest
    assert_equal src_md5, dl_md5
  ensure
    File.delete(src_path) if src_path && File.exist?(src_path)
    FileUtils.rm_f(dst) if defined?(dst)
  end

  # --- upload_file with cache_control ---

  def test_upload_file_with_metadata
    src_path, = create_temp_binary_file(6 * 1024 * 1024)
    r = @client.upload_file(
      local_path: src_path, key: "/cached_mp.bin",
      part_size: 5 * 1024 * 1024,
      metadata: { "author" => "test" }
    )
    assert r[:etag]
  ensure
    File.delete(src_path) if src_path && File.exist?(src_path)
  end

  # --- upload_file with raise_on_error ---

  def test_upload_file_raise_on_error_success
    src_path, = create_temp_binary_file(1024)
    r = @client.upload_file(
      local_path: src_path, key: "/roe.bin"
    )
    assert r[:etag]
  ensure
    File.delete(src_path) if src_path && File.exist?(src_path)
  end

  def test_upload_file_raise_on_error_failure
    assert_raises(Errno::ENOENT) do
      @client.upload_file(
        local_path: "/nonexistent/file.bin", key: "/roe_fail.bin"
      )
    end
  end

  def test_upload_file_error_without_raise
    Tempfile.create(["err_no_raise", ".bin"]) do |f|
      f.write("x" * 1024)
      f.flush
      assert_raises(ArgumentError) do
        @client.upload_file(
          local_path: f.path, key: "/no_raise.bin",
          part_size: 1024
        )
      end
    end
  end

  # --- upload_file with UploadState ---

  def test_upload_file_with_upload_state
    src_path, = create_temp_binary_file(6 * 1024 * 1024)
    r = @client.upload_file(
      local_path: src_path, key: "/resume_obj.bin",
      part_size: 5 * 1024 * 1024
    )
    assert r[:etag]
  ensure
    File.delete(src_path) if src_path && File.exist?(src_path)
  end

  # --- multipart_upload_part with IO body ---

  def test_multipart_upload_part_io_body
    uid = @client.multipart_start(key: "/io_part.bin")
    Tempfile.create(["io", ".bin"]) do |f|
      f.write("x" * 1024)
      f.flush
      f.seek(0)
      etag = @client.multipart_upload_part(
        key: "/io_part.bin", upload_id: uid,
        part_number: 1, body: f, length: 1024
      )
      assert etag
    end
  ensure
    begin
      @client.multipart_abort(key: "/io_part.bin", upload_id: uid)
    rescue StandardError
      nil
    end
  end

  def test_multipart_upload_part_io_with_offset
    uid = @client.multipart_start(key: "/io_off.bin")
    Tempfile.create(["io_off", ".bin"]) do |f|
      f.write("AAAABBBB")
      f.flush
      etag = @client.multipart_upload_part(
        key: "/io_off.bin", upload_id: uid,
        part_number: 1, body: f, length: 4, io_offset: 4
      )
      assert etag
    end
  ensure
    begin
      @client.multipart_abort(key: "/io_off.bin", upload_id: uid)
    rescue StandardError
      nil
    end
  end

  def test_multipart_upload_part_invalid_body_type
    uid = @client.multipart_start(key: "/inv.bin")
    assert_raises(ArgumentError) do
      @client.multipart_upload_part(
        key: "/inv.bin", upload_id: uid,
        part_number: 1, body: 12_345
      )
    end
  ensure
    begin
      @client.multipart_abort(key: "/inv.bin", upload_id: uid)
    rescue StandardError
      nil
    end
  end

  # --- multipart_start with cache_control and metadata ---

  def test_multipart_start_with_cache_control
    uid = @client.multipart_start(
      key: "/cc_start.bin",
      cache_control: "max-age=3600",
      metadata: { "source" => "test" }
    )
    assert uid
  ensure
    begin
      @client.multipart_abort(key: "/cc_start.bin", upload_id: uid)
    rescue StandardError
      nil
    end
  end

  # --- upload_directory with cache_control and metadata ---

  def test_upload_directory_with_cache_control
    dir = File.join(TEST_TMP, "s3client_features", "cc_dir")
    FileUtils.mkdir_p(dir)
    File.write(File.join(dir, "a.txt"), "cached content")

    result = @client.upload_directory(
      directory: dir, prefix: "cc/",
      cache_control: "max-age=3600",
      metadata: { "author" => "test" }
    )
    assert_equal 1, result[:uploaded].size
  end

  # --- download_file with progress_callback ---

  def test_download_file_with_progress
    src_path, = create_temp_binary_file(6 * 1024 * 1024)
    @client.upload_file(local_path: src_path, key: "/dl_prog.bin", part_size: 5 * 1024 * 1024)

    dst = File.join(@store_dir, "dl_prog.bin")
    FileUtils.rm_f(dst)

    progress_calls = []
    result = @client.download_file(
      key: "/dl_prog.bin", local_path: dst,
      on_progress: ->(w, t) { progress_calls << [w, t] }
    )
    assert_equal 6 * 1024 * 1024, result[:size]
  ensure
    File.delete(src_path) if src_path && File.exist?(src_path)
    FileUtils.rm_f(dst) if defined?(dst)
  end

  # --- upload_file with progress_callback on small file ---

  def test_upload_file_progress_callback_small_file
    Tempfile.create(["prog_small", ".bin"]) do |f|
      f.write("x" * 1024)
      f.flush
      progress = []
      r = @client.upload_file(
        local_path: f.path, key: "/prog_small.bin",
        on_progress: ->(done, total) { progress << [done, total] }
      )
      assert r[:etag]
      assert !progress.empty?, "progress_callback should have been called"
    end
  end

  # --- upload_file with progress_callback on empty file ---

  def test_upload_file_progress_callback_empty
    Tempfile.create(["prog_empty", ".bin"]) do |f|
      f.binmode
      progress = []
      r = @client.upload_file(
        local_path: f.path, key: "/prog_empty.bin",
        on_progress: ->(done, total) { progress << [done, total] }
      )
      assert r[:etag]
      assert progress.any?
    end
  end

  # --- upload_file with progress_callback on large file ---

  def test_upload_file_progress_callback_large
    src_path, = create_temp_binary_file(6 * 1024 * 1024)
    progress = []
    r = @client.upload_file(
      local_path: src_path, key: "/prog_large.bin",
      part_size: 5 * 1024 * 1024,
      on_progress: ->(done, total) { progress << [done, total] }
    )
    assert r[:etag]
    assert !progress.empty?, "progress_callback should have been called"
    assert progress.last[0] >= progress.last[1], "bytes uploaded should >= total"
  ensure
    File.delete(src_path) if src_path && File.exist?(src_path)
  end

  # --- upload_file without resume_state ---

  def test_upload_file_without_resume_state
    src_path, = create_temp_binary_file(6 * 1024 * 1024)
    r = @client.upload_file(
      local_path: src_path, key: "/resume_nsf.bin",
      part_size: 5 * 1024 * 1024
    )
    assert r[:etag]
  ensure
    File.delete(src_path) if src_path && File.exist?(src_path)
  end

  # --- abort_multipart_upload public method ---

  def test_abort_multipart_upload_public
    uid = @client.multipart_start(key: "/abort_pub.bin")
    result = @client.abort_multipart_upload(key: "/abort_pub.bin", upload_id: uid)
    assert_equal "aborted", result[:status]
    assert_equal uid, result[:upload_id]
  end

  # --- put_single_object with IO body via streaming single PUT ---

  def test_streaming_single_put_large_file
    src_path, src_md5 = create_temp_binary_file(6 * 1024 * 1024)
    r = @client.upload_file(
      local_path: src_path, key: "/stream_io.bin",
      part_size: 10 * 1024 * 1024
    )
    assert r[:etag]
    dl_md5 = Digest::MD5.file(File.join(@store_dir, "b/stream_io.bin")).hexdigest
    assert_equal src_md5, dl_md5
  ensure
    File.delete(src_path) if src_path && File.exist?(src_path)
  end

  # --- upload with state_file and compute_md5 ---

  def test_upload_with_state_and_compute_md5
    dir = suite_tmp_dir("s3client_features")
    @store_dir_md5 = File.join(dir, "store_md5")
    @tmp_dir_md5 = File.join(dir, "tmp_md5")

    md5_client = S3Client.new(
      region: "us-east-1", bucket: "b", access_key_id: "a", secret_access_key: "k",
      endpoint: "http://127.0.0.1:15596", endpoint_style: :path,
      part_size: 5 * 1024 * 1024, max_concurrency: 2,
      compute_md5: true,
      logger: Logger.new(File::NULL)
    )

    src_path, = create_temp_binary_file(6 * 1024 * 1024)
    state_file = File.join(dir, "md5_state.json")
    r = md5_client.upload_file(
      local_path: src_path, key: "/md5_test.bin",
      state_file: state_file
    )
    assert_equal 2, r[:parts].size
  ensure
    File.delete(src_path) if src_path && File.exist?(src_path)
  end

  # --- upload with event callbacks ---

  def test_upload_with_full_event_callbacks
    S3Client.clear_callbacks!
    events = []
    S3Client.on(:upload_start) { |*a| events << [:start, a] }
    S3Client.on(:part_complete) { |*a| events << [:part, a] }
    S3Client.on(:upload_complete) { |*a| events << [:complete, a] }
    S3Client.on(:state_save) { |*a| events << [:state, a] }
    S3Client.on(:thread_start) { |*a| events << [:thread_start, a] }
    S3Client.on(:thread_finish) { |*a| events << [:thread_finish, a] }

    src_path, = create_temp_binary_file(6 * 1024 * 1024)
    state_file = File.join(@store_dir, "evt_state.json")
    @client.upload_file(
      local_path: src_path, key: "/evt_full.bin",
      part_size: 5 * 1024 * 1024, state_file: state_file
    )

    assert events.any? { |e| e[0] == :start }
    assert events.any? { |e| e[0] == :part }
    assert events.any? { |e| e[0] == :complete }
    assert events.any? { |e| e[0] == :thread_start }
    assert events.any? { |e| e[0] == :thread_finish }
  ensure
    File.delete(src_path) if src_path && File.exist?(src_path)
    S3Client.clear_callbacks!
  end

  # --- upload_file with state_file cleanup ---

  def test_upload_file_with_state_file_cleanup
    src_path, src_md5 = create_temp_binary_file(12 * 1024 * 1024)
    state_file = File.join(@store_dir, "state_cleanup.json")
    FileUtils.rm_f(state_file)

    r = @client.upload_file(
      local_path: src_path, key: "/state_cleanup.bin",
      part_size: 5 * 1024 * 1024, state_file: state_file
    )
    assert r[:etag]

    refute File.exist?(state_file), "state file should be cleaned up"

    dl_md5 = Digest::MD5.file(File.join(@store_dir, "b/state_cleanup.bin")).hexdigest
    assert_equal src_md5, dl_md5
  ensure
    File.delete(src_path) if src_path && File.exist?(src_path)
  end

  def test_resume_upload_from_partial_state
    dir = suite_tmp_dir("resume_int")
    src_path, src_md5 = create_temp_binary_file(12 * 1024 * 1024)
    state_file = File.join(dir, "resume_state.json")
    part_size = 5 * 1024 * 1024
    key = "/resume_int.bin"

    uid = @client.multipart_start(key: key)

    part1_data = File.binread(src_path, part_size, 0)
    part2_data = File.binread(src_path, part_size, part_size)
    etag1 = @client.multipart_upload_part(
      key: key, upload_id: uid, part_number: 1, body: part1_data
    )
    etag2 = @client.multipart_upload_part(
      key: key, upload_id: uid, part_number: 2, body: part2_data
    )

    state = {
      upload_id: uid,
      key: key,
      bucket: "b",
      part_size: part_size,
      total_size: 12 * 1024 * 1024,
      local_path: src_path,
      parts: { 1 => etag1, 2 => etag2 },
      completed: false,
      upload_session_id: "rsm_int_001",
      started_at: Time.now.utc.iso8601
    }
    File.write(state_file, JSON.generate(state))

    r = @client.resume_upload(state_file: state_file)
    assert r[:etag]

    stored = File.join(@store_dir, "b/resume_int.bin")
    assert File.exist?(stored), "completed file should exist on FakeS3"
    dl_md5 = Digest::MD5.file(stored).hexdigest
    assert_equal src_md5, dl_md5, "file content should match"

    refute File.exist?(state_file), "state file should be removed after resume"
  ensure
    File.delete(src_path) if src_path && File.exist?(src_path)
    cleanup_suite_tmp("resume_int")
  end
end
