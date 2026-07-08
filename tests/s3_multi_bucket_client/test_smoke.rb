# frozen_string_literal: true

require_relative "../test_helper"
require_relative "../../src/s3_multi_bucket_client"
require_relative "../support/shared_examples"

class S3MultiBucketSmokeTest < Minitest::Test
  include S3TestHelpers
  include SharedSmokeTests

  PORT = 15_667
  BUCKET = "fake-bucket"

  def bucket_name = BUCKET
  def client = @client

  def setup
    dir = suite_tmp_dir("multibucket_smoke")
    @store_dir = File.join(dir, "store")
    @tmp_dir   = File.join(dir, "tmp")
    @server = FakeS3::Server.new(port: PORT, store_dir: @store_dir, tmp_dir: @tmp_dir)
    @server.start_thread

    @client = S3MultiBucketClient.new(
      endpoint: "http://127.0.0.1:#{PORT}",
      region: "us-east-1",
      access_key_id: "AKIAFAKE",
      secret_access_key: "secretfake",
      open_timeout: 5, read_timeout: 30,
      logger: Logger.new(File::NULL)
    )
  end

  def teardown
    @server.stop
  end

  def test_multipart_upload_20mb
    src_path, = create_temp_binary_file(6 * 1024 * 1024)
    progress_calls = []

    result = @client.upload_file(
      bucket: BUCKET, key: "big/file.bin", local_path: src_path,
      part_size: 5 * 1024 * 1024, max_threads: 3,
      content_type: "application/octet-stream",
      metadata: { "user" => "alice", "env" => "test" },
      on_progress: ->(done, total) { progress_calls << [done, total] }
    )

    assert_equal 2, result[:parts_uploaded]
    assert progress_calls.each_cons(2).all? { |a, b| a[0] <= b[0] }, "progress not monotonic"
    assert_equal progress_calls.last[0], 6 * 1024 * 1024
  ensure
    File.delete(src_path) if src_path && File.exist?(src_path)
  end

  def test_download_full
    src_path, src_md5 = create_temp_binary_file(5 * 1024 * 1024)
    @client.upload_file(bucket: BUCKET, key: "dl/full.bin", local_path: src_path)

    dst = Tempfile.new(["dst", ".bin"])
    dst.close
    progress = []
    @client.download_file(
      bucket: BUCKET, key: "dl/full.bin", destination_path: dst.path,
      on_progress: ->(done, total) { progress << [done, total] }
    )

    dl_md5 = Digest::MD5.file(dst.path).hexdigest
    assert_equal src_md5, dl_md5
    assert !progress.empty?
  ensure
    File.delete(src_path) if src_path && File.exist?(src_path)
    dst&.unlink
  end

  def test_stream_download
    src_path, = create_temp_binary_file(3 * 1024 * 1024)
    data_in = File.binread(src_path)
    @client.upload_file(bucket: BUCKET, key: "dl/stream.bin", local_path: src_path)

    buf = +""
    written = @client.download_stream(bucket: BUCKET, key: "dl/stream.bin") { |chunk| buf << chunk }
    assert_equal data_in, buf
    assert_equal data_in.bytesize, written
  ensure
    File.delete(src_path) if src_path && File.exist?(src_path)
  end

  def test_head_object
    src = Tempfile.new(["head", ".txt"])
    src.write("head test content")
    src.close

    @client.upload_file(
      bucket: BUCKET, key: "head/file.txt", local_path: src.path,
      content_type: "text/plain", metadata: { "author" => "bob", "version" => "2" }
    )

    info = @client.head_object(bucket: BUCKET, key: "head/file.txt")
    assert_equal 17, info[:content_length]
    assert_equal "text/plain", info[:content_type]
    assert info[:etag]
    assert info[:last_modified]
    assert_equal "STANDARD", info[:storage_class]
    assert_equal "bob", info[:metadata]["author"]
    assert_equal "2", info[:metadata]["version"]
  ensure
    src&.unlink
  end

  def test_delete_object
    src = Tempfile.new(["del", ".txt"])
    src.write("delete me")
    src.close

    @client.upload_file(bucket: BUCKET, key: "del/file.txt", local_path: src.path)
    result = @client.delete_object(bucket: BUCKET, key: "del/file.txt")
    assert_equal "deleted", result[:status]

    err = assert_raises(S3MultiBucketClient::S3Error) do
      @client.head_object(bucket: BUCKET, key: "del/file.txt")
    end
    assert_equal "404", err.code.to_s
  ensure
    src&.unlink
  end

  def test_small_file_upload
    small = Tempfile.new(["small", ".bin"])
    small.close
    File.write(small.path, "hello world")

    r = @client.upload_file(
      bucket: BUCKET, key: "small.txt", local_path: small.path,
      content_type: "text/plain"
    )
    assert r[:etag]

    data_back = File.binread(File.join(@store_dir, BUCKET, "small.txt"))
    assert_equal "hello world", data_back
  ensure
    small&.unlink
  end

  def test_multipart_abort
    uid = @client.multipart_start(bucket: BUCKET, key: "will/abort.bin")
    result = @client.abort_multipart_upload(bucket: BUCKET, key: "will/abort.bin", upload_id: uid)
    assert_equal "aborted", result[:status]
  end

  def test_presigned_url_get
    url = @client.presigned_url(bucket: BUCKET, key: "file.txt", method: :get, expires_in: 3600)
    assert_includes url, "X-Amz-Signature"
    assert_includes url, "X-Amz-Algorithm"
  end

  def test_presigned_url_put
    url = @client.presigned_url(bucket: BUCKET, key: "upload.bin", method: :put, expires_in: 600)
    assert_includes url, "X-Amz-Signature"
  end

  def test_presigned_url_with_query
    url = @client.presigned_url(
      bucket: BUCKET, key: "file.txt",
      query: { "response-content-disposition" => 'attachment; filename="dl.txt"' }
    )
    assert_includes url, "response-content-disposition"
    assert_includes url, "X-Amz-Signature"
  end

  def test_low_level_multipart_start_and_abort
    upload_id = @client.multipart_start(
      bucket: BUCKET, key: "llm/file.bin",
      content_type: "application/octet-stream",
      metadata: { "source" => "test" }
    )
    assert upload_id
    assert !upload_id.empty?
    @client.multipart_abort(bucket: BUCKET, key: "llm/file.bin", upload_id: upload_id)
  end

  def test_low_level_multipart_upload_and_complete
    upload_id = @client.multipart_start(bucket: BUCKET, key: "llm2/file.bin")

    part1_data = SecureRandom.bytes(5 * 1024 * 1024)
    part2_data = SecureRandom.bytes(3 * 1024 * 1024)

    etag1 = @client.multipart_upload_part(
      bucket: BUCKET, key: "llm2/file.bin",
      upload_id: upload_id, part_number: 1, body: part1_data
    )
    etag2 = @client.multipart_upload_part(
      bucket: BUCKET, key: "llm2/file.bin",
      upload_id: upload_id, part_number: 2, body: part2_data
    )
    assert etag1
    assert etag2

    @client.multipart_complete(
      bucket: BUCKET, key: "llm2/file.bin",
      upload_id: upload_id,
      parts: [{ part_number: 1, etag: etag1 }, { part_number: 2, etag: etag2 }]
    )

    dst = Tempfile.new(["llm_verify", ".bin"])
    dst.close
    @client.download_file(bucket: BUCKET, key: "llm2/file.bin", destination_path: dst.path)
    data_out = File.binread(dst.path)
    assert_equal part1_data + part2_data, data_out
  ensure
    dst&.unlink
  end

  def test_list_multipart_uploads
    upload_id = @client.multipart_start(bucket: BUCKET, key: "list/file.bin")
    uploads = @client.list_multipart_uploads(bucket: BUCKET)
    assert_kind_of Array, uploads
    assert !uploads.empty?
    found = uploads.find { |u| u[:upload_id] == upload_id }
    assert found
    @client.multipart_abort(bucket: BUCKET, key: "list/file.bin", upload_id: upload_id)
  end

  def test_s3helper_upload_small
    src = Tempfile.new(["helper", ".txt"])
    src.write("small file for helper")
    src.close

    result = S3Helper.upload(
      client: @client, bucket: BUCKET, key: "helper/small.txt",
      local_path: src.path
    )
    assert result[:etag]
  ensure
    src&.unlink
  end

  def test_s3helper_download
    src_path, src_md5 = create_temp_binary_file(1024 * 1024)
    @client.upload_file(bucket: BUCKET, key: "helper/dl.bin", local_path: src_path)

    dst = Tempfile.new(["helper_out", ".bin"])
    dst.close
    S3Helper.download(
      client: @client, bucket: BUCKET, key: "helper/dl.bin",
      destination: dst.path, show_progress: false
    )

    dl_md5 = Digest::MD5.file(dst.path).hexdigest
    assert_equal src_md5, dl_md5
  ensure
    File.delete(src_path) if src_path && File.exist?(src_path)
    dst&.unlink
  end

  def test_download_file_full
    src_path, src_md5 = create_temp_binary_file(4 * 1024 * 1024)
    @client.upload_file(bucket: BUCKET, key: "dl/full_2.bin", local_path: src_path)

    dst = Tempfile.new(["dst", ".bin"])
    dst.close
    result = @client.download_file(
      bucket: BUCKET, key: "dl/full_2.bin", destination_path: dst.path
    )
    assert_equal 4 * 1024 * 1024, result[:size]
    dl_md5 = Digest::MD5.file(dst.path).hexdigest
    assert_equal src_md5, dl_md5
  ensure
    File.delete(src_path) if src_path && File.exist?(src_path)
    dst&.unlink
  end

  def test_upload_with_cache_control
    src = Tempfile.new(["cache", ".txt"])
    src.write("cached content")
    src.close

    @client.upload_file(
      bucket: BUCKET, key: "cached/file.txt",
      local_path: src.path, cache_control: "max-age=3600"
    )

    meta_path = File.join(@store_dir, BUCKET, "cached/file.txt.meta")
    assert File.exist?(meta_path), "meta file should exist"
    meta = JSON.parse(File.read(meta_path), symbolize_names: true)
    assert_equal "max-age=3600", meta[:cache_control]
  ensure
    src&.unlink
  end
end
