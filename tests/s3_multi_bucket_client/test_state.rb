# frozen_string_literal: true

require_relative "../test_helper"
require_relative "../../src/s3_multi_bucket_client"

class S3MultiBucketStateTest < Minitest::Test
  include S3TestHelpers

  PORT = 15_689
  BUCKET = "b"
  PART_SIZE = 5 * 1024 * 1024

  def setup
    dir = suite_tmp_dir("multibucket_state")
    @store_dir  = File.join(dir, "store")
    @tmp_dir    = File.join(dir, "tmp")
    @state_file = File.join(dir, "upload.json")
    @server = FakeS3::Server.new(port: PORT, store_dir: @store_dir, tmp_dir: @tmp_dir)
    @server.start_thread

    @client = S3MultiBucketClient.new(
      endpoint: "http://127.0.0.1:#{PORT}", region: "us-east-1",
      access_key_id: "a", secret_access_key: "k",
      logger: Logger.new(File::NULL)
    )

    @src_path, @src_md5 = create_temp_binary_file(12 * 1024 * 1024)
  end

  def teardown
    @server.stop
    File.delete(@src_path) if @src_path && File.exist?(@src_path)
  end

  def test_full_upload_with_state_file
    progress = []
    r = @client.upload_file(
      bucket: BUCKET, key: "big.bin", local_path: @src_path,
      part_size: PART_SIZE, max_threads: 2, state_file: @state_file,
      on_progress: ->(done, total) { progress << [done, total] }
    )

    assert_equal 3, r[:parts_uploaded]
    refute File.exist?(@state_file), "state file should be deleted after success"
    assert_equal progress.last[0], 12 * 1024 * 1024

    dl_md5 = Digest::MD5.file(File.join(@store_dir, BUCKET, "big.bin")).hexdigest
    assert_equal @src_md5, dl_md5
  end

  def test_resume_from_state_file
    upload_id = @client.multipart_start(bucket: BUCKET, key: "big.bin")

    manual_parts = []
    [1, 2].each do |n|
      offset = (n - 1) * PART_SIZE
      data = File.open(@src_path, "rb") do |f|
        f.seek(offset)
        f.read(PART_SIZE)
      end
      etag = @client.multipart_upload_part(
        bucket: BUCKET, key: "big.bin", upload_id: upload_id,
        part_number: n, body: data
      )
      manual_parts << { part_number: n, etag: etag, size: PART_SIZE }
    end

    resume_state = S3MultiBucketClient::UploadState.new(
      upload_id: upload_id, key: "big.bin", bucket: BUCKET,
      local_path: File.expand_path(@src_path), part_size: PART_SIZE,
      total_size: 12 * 1024 * 1024, parts: manual_parts
    )
    resume_state.save_to_file(@state_file)

    progress = []
    r = @client.resume_upload(
      bucket: BUCKET, key: "big.bin", local_path: @src_path,
      state_file: @state_file,
      on_progress: ->(done, total) { progress << [done, total] }
    )

    assert_equal 3, r[:parts_uploaded]
    dl_md5 = Digest::MD5.file(File.join(@store_dir, BUCKET, "big.bin")).hexdigest
    assert_equal @src_md5, dl_md5
  end

  def test_resume_via_resume_state_param
    upload_id = @client.multipart_start(bucket: BUCKET, key: "big.bin")

    manual_parts = []
    [1, 2].each do |n|
      offset = (n - 1) * PART_SIZE
      data = File.open(@src_path, "rb") do |f|
        f.seek(offset)
        f.read(PART_SIZE)
      end
      etag = @client.multipart_upload_part(
        bucket: BUCKET, key: "big.bin", upload_id: upload_id,
        part_number: n, body: data
      )
      manual_parts << { part_number: n, etag: etag, size: PART_SIZE }
    end

    S3MultiBucketClient::UploadState.new(
      upload_id: upload_id, key: "big.bin", bucket: BUCKET,
      local_path: File.expand_path(@src_path), part_size: PART_SIZE,
      total_size: 12 * 1024 * 1024, parts: manual_parts
    )

    progress = []
    r = @client.upload_file(
      bucket: BUCKET, key: "big.bin", local_path: @src_path,
      part_size: PART_SIZE, max_threads: 2,
      on_progress: ->(done, total) { progress << [done, total] }
    )

    assert_equal 3, r[:parts_uploaded]
    dl_md5 = Digest::MD5.file(File.join(@store_dir, BUCKET, "big.bin")).hexdigest
    assert_equal @src_md5, dl_md5
  end
end
