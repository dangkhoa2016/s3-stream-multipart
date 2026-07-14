# frozen_string_literal: true

require_relative "../test_helper"
require_relative "../../src/s3-stream-multipart"

class UploadStateManagerEdgeTest < Minitest::Test
  include S3TestHelpers

  PORT = 15_606

  def setup
    dir = suite_tmp_dir("upload_state_mgr_edge")
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

  # --- upload_state_manager.rb line 137: cleanup_state rescue ---

  def test_cleanup_state_rescue
    @client.upload_state_manager.cleanup_state(nil)
    @client.upload_state_manager.cleanup_state("/nonexistent/path/to/state.json")
  end

  # --- upload_state.rb line 90: save_to_file fsync rescue ---

  def test_upload_state_save_to_file
    state = UploadState.new(
      upload_id: "uid-test", key: "/test.bin",
      part_size: 5 * 1024 * 1024, total_size: 10 * 1024 * 1024,
      local_path: "/tmp/test.bin"
    )
    state_file = File.join(@store_dir, "fsync_test.json")
    state.save_to_file(state_file)
    assert File.exist?(state_file)
  ensure
    FileUtils.rm_f(state_file) if state_file
  end

  # --- upload_state_manager.rb : validate_state with MD5 mismatch ---

  def test_validate_state_md5_mismatch
    state_file = File.join(@store_dir, "md5_state.json")
    abs_local = File.expand_path(File.join(@store_dir, "md5_src.bin"))
    File.write(abs_local, "original content")

    state = {
      upload_id: "uid-md5",
      key: "/md5_test.bin",
      part_size: 5 * 1024 * 1024,
      total_size: File.size(abs_local),
      local_path: abs_local,
      parts: {},
      file_fingerprint: "1000.0-100"
    }

    File.write(state_file, JSON.generate(state))

    loaded = @client.upload_state_manager.load_state(state_file)
    result = @client.upload_state_manager.validate_state(
      loaded, key: "/md5_test.bin",
              part_size: 5 * 1024 * 1024,
              total_size: File.size(abs_local),
              local_path: abs_local
    )
    assert_nil result, "State should be invalid due to MD5 mismatch"
  ensure
    FileUtils.rm_f(state_file) if state_file
    FileUtils.rm_f(abs_local) if abs_local
  end

  # --- validate_state with key/part_size/total_size mismatch ---

  def test_validate_state_parameter_mismatch
    state_file = File.join(@store_dir, "param_mismatch.json")
    abs_local = File.expand_path(File.join(@store_dir, "param_src.bin"))
    File.write(abs_local, "some content")

    state = {
      upload_id: "uid-param",
      key: "/different_key.bin",
      part_size: 10 * 1024 * 1024,
      total_size: 99_999,
      local_path: "/different/path.bin",
      parts: {}
    }

    File.write(state_file, JSON.generate(state))
    loaded = @client.upload_state_manager.load_state(state_file)
    result = @client.upload_state_manager.validate_state(
      loaded, key: "/test_key.bin",
              part_size: 5 * 1024 * 1024,
              total_size: 100,
              local_path: abs_local
    )
    assert_nil result, "State should be invalid due to parameter mismatch"
  ensure
    FileUtils.rm_f(state_file) if state_file
    FileUtils.rm_f(abs_local) if abs_local
  end

  # --- upload_state_manager.rb line 55, 58: load_and_validate ---

  def test_upload_state_manager_load_and_validate_matching
    Dir.mktmpdir do |tmpdir|
      state_file = File.join(tmpdir, "state.json")
      local_path = File.expand_path("/tmp/fake_path.bin")
      state_data = {
        upload_id: "test-uid", key: "/test_key.bin",
        part_size: 5 * 1024 * 1024, total_size: 6 * 1024 * 1024,
        local_path: local_path, parts: {}, completed: false
      }
      File.write(state_file, JSON.generate(state_data))

      result = @client.upload_state_manager.load_and_validate(
        state_file, key: "/test_key.bin",
                    part_size: 5 * 1024 * 1024, total_size: 6 * 1024 * 1024,
                    local_path: "/tmp/fake_path.bin"
      )
      assert result
      assert_equal "test-uid", result.upload_id
    end
  end

  def test_upload_state_manager_load_and_validate_corrupt_json
    Dir.mktmpdir do |tmpdir|
      state_file = File.join(tmpdir, "corrupt.json")
      File.write(state_file, "not valid json at all {{{")

      result = @client.upload_state_manager.load_and_validate(
        state_file, key: "/k",
                    part_size: 5 * 1024 * 1024, total_size: 100, local_path: "/tmp/f"
      )
      assert_nil result
    end
  end

  # --- upload_state_manager.rb: save_state with EISDIR ---

  def test_upload_state_manager_save_state_eisdir
    state_file = File.join(@store_dir, "eisdir_save.json")
    dirname = File.dirname(state_file)
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

  def test_upload_state_manager_save_state_fsync_standard_error
    state_file = File.join(@store_dir, "fsync_save.json")
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
    dir = @store_dir

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

  # --- upload_state_manager.rb: validate_state with fingerprint ---

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

  # --- upload_state_manager.rb: load_and_validate edge cases ---

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

  # --- upload_state_manager.rb: sync_dir with EISDIR ---

  def test_upload_state_manager_sync_dir_eisdir
    @client.upload_state_manager.send(:sync_dir, "/nonexistent")
  end

  # --- validate_state with nil ---

  def test_validate_state_with_nil
    assert_nil @client.upload_state_manager.validate_state(nil, key: "/k", part_size: 5 * 1024 * 1024, total_size: 100, local_path: "/tmp/f")
  end

  # --- load_and_validate rescue Errno::ENOENT ---

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
end
