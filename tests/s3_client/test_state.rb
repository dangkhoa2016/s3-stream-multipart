# frozen_string_literal: true

require_relative "../test_helper"
require_relative "../../src/s3_client"

class S3ClientStateTest < Minitest::Test
  include S3TestHelpers

  PORT = 15_589

  def setup
    dir = suite_tmp_dir("s3client_state")
    @store_dir = File.join(dir, "store")
    @tmp_dir   = File.join(dir, "tmp")
    @state_file = File.join(dir, "upload.json")
    @server = FakeS3::Server.new(port: PORT, store_dir: @store_dir, tmp_dir: @tmp_dir)
    @server.start_thread

    @client = S3Client.new(
      region: "us-east-1", bucket: "b", access_key_id: "a", secret_access_key: "k",
      endpoint: "http://127.0.0.1:#{PORT}", endpoint_style: :path,
      part_size: 5 * 1024 * 1024, max_concurrency: 2,
      logger: Logger.new(File::NULL)
    )

    @src_path, @src_md5 = create_temp_binary_file(6 * 1024 * 1024)
  end

  def teardown
    @server.stop
    File.delete(@src_path) if @src_path && File.exist?(@src_path)
  end

  def test_full_upload_with_state_file
    progress = []
    r = @client.upload_file(
      local_path: @src_path, key: "/big.bin", state_file: @state_file,
      on_progress: ->(w, t) { progress << [w, t] }
    )

    assert_equal 2, r[:parts].size
    refute File.exist?(@state_file), "state file should be deleted after success"
    assert_equal [6 * 1024 * 1024, 6 * 1024 * 1024], progress.last

    dl_md5 = Digest::MD5.file(File.join(@store_dir, "b/big.bin")).hexdigest
    assert_equal @src_md5, dl_md5
  end

  def test_resume_from_partial_state
    upload_id = @client.send(:create_multipart_upload, key: "/big.bin",
                                                       content_type: "application/octet-stream",
                                                       metadata: {}, cache_control: nil)

    manual_parts = {}
    offset = 0
    data = File.open(@src_path, "rb") do |f|
      f.seek(offset)
      f.read(5 * 1024 * 1024)
    end
    etag = @client.send(:upload_part, key: "/big.bin", upload_id: upload_id,
                                      part_number: 1, body: data)
    manual_parts[1] = etag

    File.write(@state_file, JSON.pretty_generate({
                                                   upload_id: upload_id, key: "/big.bin",
                                                   part_size: 5 * 1024 * 1024, total_size: 6 * 1024 * 1024,
                                                   local_path: File.expand_path(@src_path), parts: manual_parts
                                                 }))

    progress = []
    r = @client.resume_upload(state_file: @state_file,
                              on_progress: ->(w, t) { progress << [w, t] })

    assert_equal 2, r[:parts].size
    assert_equal [5 * 1024 * 1024, 6 * 1024 * 1024], progress.first
    assert_equal [6 * 1024 * 1024, 6 * 1024 * 1024], progress.last
    refute File.exist?(@state_file), "state file should be deleted after resume"

    assert_equal manual_parts[1], r[:parts][0][:etag], "part 1 etag mismatch"

    dl_md5 = Digest::MD5.file(File.join(@store_dir, "b/big.bin")).hexdigest
    assert_equal @src_md5, dl_md5
  end

  def test_resume_from_partial_state_with_compute_md5
    md5_client = S3Client.new(
      region: "us-east-1", bucket: "b", access_key_id: "a", secret_access_key: "k",
      endpoint: "http://127.0.0.1:#{PORT}", endpoint_style: :path,
      part_size: 5 * 1024 * 1024, max_concurrency: 2,
      compute_md5: true,
      logger: Logger.new(File::NULL)
    )

    upload_id = md5_client.send(:create_multipart_upload, key: "/big_md5.bin",
                                                          content_type: "application/octet-stream",
                                                          metadata: {}, cache_control: nil)

    manual_parts = {}
    data = File.open(@src_path, "rb") { |f| f.read(5 * 1024 * 1024) }
    etag = md5_client.send(:upload_part, key: "/big_md5.bin", upload_id: upload_id,
                                         part_number: 1, body: data)
    manual_parts[1] = etag

    File.write(@state_file, JSON.pretty_generate({
                                                   upload_id: upload_id, key: "/big_md5.bin",
                                                   part_size: 5 * 1024 * 1024, total_size: 6 * 1024 * 1024,
                                                   local_path: File.expand_path(@src_path), parts: manual_parts
                                                 }))

    r = md5_client.resume_upload(state_file: @state_file)
    assert_equal 2, r[:parts].size
  end

  def test_state_mismatch_fresh_upload
    File.write(@state_file, JSON.pretty_generate({
                                                   upload_id: "stale-id-12345", key: "/big.bin",
                                                   part_size: 999, total_size: 6 * 1024 * 1024,
                                                   local_path: File.expand_path(@src_path), parts: {}
                                                 }))

    r = @client.upload_file(local_path: @src_path, key: "/big.bin", state_file: @state_file)
    assert_equal 2, r[:parts].size
    refute_equal "stale-id-12345", r[:upload_id]
    refute File.exist?(@state_file)

    dl_md5 = Digest::MD5.file(File.join(@store_dir, "b/big.bin")).hexdigest
    assert_equal @src_md5, dl_md5
  end
end
