# frozen_string_literal: true

require_relative "../test_helper"
require_relative "../../src/s3_client"

class UploadStateManagerTest < Minitest::Test
  include S3TestHelpers

  PORT = 15_588

  def setup
    dir = suite_tmp_dir("upload_state_mgr")
    @store_dir = File.join(dir, "store")
    @tmp_dir   = File.join(dir, "tmp")
    @server = FakeS3::Server.new(port: PORT, store_dir: @store_dir, tmp_dir: @tmp_dir)
    @server.start_thread

    @client = S3Client.new(
      region: "us-east-1", bucket: "b",
      access_key_id: "a", secret_access_key: "k",
      endpoint: "http://127.0.0.1:#{PORT}", endpoint_style: :path,
      part_size: 5 * 1024 * 1024, max_concurrency: 2,
      logger: Logger.new(File::NULL)
    )
  end

  def teardown
    @server.stop
    cleanup_suite_tmp("upload_state_mgr")
  end

  def test_load_state_nil_path
    assert_nil @client.upload_state_manager.load_state(nil)
  end

  def test_load_state_nonexistent_file
    assert_nil @client.upload_state_manager.load_state("/nonexistent/path.json")
  end

  def test_load_state_corrupt_json
    Dir.mktmpdir do |dir|
      path = File.join(dir, "state.json")
      File.write(path, "not valid json")
      assert_nil @client.upload_state_manager.load_state(path)
    end
  end

  def test_load_state_valid
    Dir.mktmpdir do |dir|
      path = File.join(dir, "state.json")
      File.write(path, JSON.generate({
                                       upload_id: "uid-1", key: "k", part_size: 5_242_880, total_size: 10_485_760,
                                       local_path: "/tmp/f", parts: { "1" => "etag1" }
                                     }))
      state = @client.upload_state_manager.load_state(path)
      assert_equal "uid-1", state.upload_id
      assert_equal "etag1", state.parts[1]
    end
  end

  def test_save_state_skip_stale
    Dir.mktmpdir do |dir|
      path = File.join(dir, "state.json")
      @client.upload_state_manager.save_state(path,
                                              { parts: { 1 => "e1" }, key: "k", part_size: 5_242_880, total_size: 10_485_760, local_path: "/tmp/f", upload_id: "u1", started_at: Time.now.utc.iso8601, upload_session_id: "s1" })
      # Save with fewer parts — should be skipped
      @client.upload_state_manager.save_state(path,
                                              { parts: {}, key: "k", part_size: 5_242_880, total_size: 10_485_760, local_path: "/tmp/f", upload_id: "u1", started_at: Time.now.utc.iso8601, upload_session_id: "s1" })
      restored = JSON.parse(File.read(path), symbolize_names: true)
      assert_equal 1, restored[:parts].size
    end
  end

  def test_cleanup_state_normal
    Dir.mktmpdir do |dir|
      path = File.join(dir, "clean.json")
      File.write(path, "{}")
      @client.upload_state_manager.cleanup_state(path)
      refute File.exist?(path)
    end
  end

  def test_cleanup_state_nonexistent
    @client.upload_state_manager.cleanup_state("/nonexistent/path.json")
  end

  def test_validate_state_mismatch
    state = { upload_id: "old-uid", key: "old_key", part_size: 1, total_size: 1, local_path: "/old" }
    assert_nil @client.upload_state_manager.validate_state(state, key: "new_key", part_size: 5_242_880, total_size: 10_485_760, local_path: "/tmp/f")
  end

  def test_validate_state_nil
    assert_nil @client.upload_state_manager.validate_state(nil, key: "k", part_size: 5_242_880, total_size: 10_485_760, local_path: "/tmp/f")
  end

  def test_validate_state_valid
    state = {
      upload_id: "uid-1", key: "k", part_size: 5_242_880,
      total_size: 10_485_760, local_path: File.expand_path("/tmp/f"),
      parts: { "1" => "e1" }
    }
    result = @client.upload_state_manager.validate_state(state, key: "k", part_size: 5_242_880, total_size: 10_485_760, local_path: "/tmp/f")
    assert_equal "uid-1", result.upload_id
  end

  def test_validate_state_file_changed
    Dir.mktmpdir do |dir|
      local_path = File.join(dir, "file.bin")
      File.write(local_path, "original content")
      orig_size = File.size(local_path)
      orig_mtime = File.mtime(local_path).to_f
      state = {
        upload_id: "uid-1", key: "k", part_size: 5_242_880,
        total_size: orig_size,
        local_path: File.expand_path(local_path),
        parts: {}, file_fingerprint: "#{orig_mtime}-#{orig_size}"
      }
      # Change the file (same size, different content to test fingerprint mismatch)
      sleep(1.1)
      File.write(local_path, "different content")
      assert_nil @client.upload_state_manager.validate_state(state, key: "k", part_size: 5_242_880, total_size: File.size(local_path), local_path: local_path)
    end
  end

  def test_load_state_with_in_progress_parts
    Dir.mktmpdir do |dir|
      path = File.join(dir, "state_ip.json")
      File.write(path, JSON.generate({
                                       upload_id: "uid-1", key: "k", part_size: 5_242_880, total_size: 10_485_760,
                                       local_path: "/tmp/f", parts: {}, in_progress_parts: { "3" => "t0", "5" => "t1" }
                                     }))
      state = @client.upload_state_manager.load_state(path)
      assert_equal 2, state.in_progress_parts.size
      assert_equal "t0", state.in_progress_parts[3]
    end
  end

  def test_cleanup_state_error_path
    @client.upload_state_manager.cleanup_state(nil)
  end

  def test_save_state_without_mutex
    Dir.mktmpdir do |dir|
      path = File.join(dir, "state_no_mutex.json")
      @client.upload_state_manager.save_state(path, {
                                                parts: { 1 => "e1" }, key: "k", part_size: 5_242_880,
                                                total_size: 10_485_760, local_path: "/tmp/f",
                                                upload_id: "u1", started_at: Time.now.utc.iso8601,
                                                upload_session_id: "s1"
                                              })
      assert File.file?(path)
    end
  end
end
