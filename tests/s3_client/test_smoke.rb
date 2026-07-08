# frozen_string_literal: true

require_relative "../test_helper"
require_relative "../../src/s3_client"
require_relative "../support/shared_examples"

class S3ClientSmokeTest < Minitest::Test
  include S3TestHelpers
  include SharedSmokeTests

  PORT = 15_567

  def bucket_name
    nil
  end

  def client
    @client
  end

  def setup
    dir = suite_tmp_dir("s3client_smoke")
    @store_dir = File.join(dir, "store")
    @tmp_dir   = File.join(dir, "tmp")
    @server = FakeS3::Server.new(port: PORT, store_dir: @store_dir, tmp_dir: @tmp_dir)
    @server.start_thread

    @client = S3Client.new(
      region: "us-east-1", bucket: "fake-bucket",
      access_key_id: "AKIAFAKE", secret_access_key: "secretfake",
      endpoint: "http://127.0.0.1:#{PORT}", endpoint_style: :path,
      part_size: 5 * 1024 * 1024, max_concurrency: 3, max_retries: 2,
      open_timeout: 5, read_timeout: 30,
      logger: Logger.new(File::NULL)
    )
  end

  def teardown
    @server.stop
  end

  def test_multipart_upload
    src_path, src_md5 = create_temp_binary_file(6 * 1024 * 1024)
    progress_calls = []

    result = @client.upload_file(
      local_path: src_path, key: "/big/file.bin",
      content_type: "application/octet-stream",
      metadata: { "user" => "alice", "env" => "test" },
      on_progress: ->(w, t) { progress_calls << [w, t] }
    )

    assert_equal 2, result[:parts].size
    assert progress_calls.each_cons(2).all? { |a, b| a[0] <= b[0] }, "progress not monotonic"
    assert_equal [6 * 1024 * 1024, 6 * 1024 * 1024], progress_calls.last

    dl_md5 = Digest::MD5.file(File.join(@store_dir, "fake-bucket/big/file.bin")).hexdigest
    assert_equal src_md5, dl_md5
  ensure
    File.delete(src_path) if src_path && File.exist?(src_path)
  end

  def test_download_full
    src_path, src_md5 = create_temp_binary_file(6 * 1024 * 1024)
    @client.upload_file(local_path: src_path, key: "/dl/full.bin")

    dst = Tempfile.new(["dst", ".bin"])
    dst.close
    @client.download_file(key: "/dl/full.bin", local_path: dst.path)

    dl_md5 = Digest::MD5.file(dst.path).hexdigest
    assert_equal src_md5, dl_md5
  ensure
    File.delete(src_path) if src_path && File.exist?(src_path)
    dst&.unlink
  end

  def test_range_download
    src_path, = create_temp_binary_file(6 * 1024 * 1024)
    data_in = File.binread(src_path)
    @client.upload_file(local_path: src_path, key: "/dl/range.bin")

    dst = Tempfile.new(["dst2", ".bin"])
    dst.close
    @client.download_file(key: "/dl/range.bin", local_path: dst.path, range: (100..(100 + 1024 - 1)))

    slice = File.binread(dst.path)
    assert_equal data_in.byteslice(100, 1024), slice
  ensure
    File.delete(src_path) if src_path && File.exist?(src_path)
    dst&.unlink
  end

  def test_stream_download
    src_path, = create_temp_binary_file(6 * 1024 * 1024)
    data_in = File.binread(src_path)
    @client.upload_file(local_path: src_path, key: "/dl/stream.bin")

    buf = +""
    @client.download_stream(key: "/dl/stream.bin") { |chunk| buf << chunk }
    assert_equal data_in, buf
  ensure
    File.delete(src_path) if src_path && File.exist?(src_path)
  end

  def test_head_object
    src_path, = create_temp_binary_file(5 * 1024 * 1024)
    @client.upload_file(local_path: src_path, key: "/head/file.bin")

    h = @client.head_object("/head/file.bin")
    assert_equal 5 * 1024 * 1024, h[:content_length]
    assert h[:etag]
  ensure
    File.delete(src_path) if src_path && File.exist?(src_path)
  end

  def test_delete_object
    src_path, = create_temp_binary_file(1024)
    @client.upload_file(local_path: src_path, key: "/del/file.bin")

    code = @client.delete_object("/del/file.bin")
    assert_equal 204, code
  ensure
    File.delete(src_path) if src_path && File.exist?(src_path)
  end

  def test_small_file_upload
    small = Tempfile.new(["small", ".bin"])
    small.binmode
    small.write("hello world")
    small.flush

    @client.upload_file(local_path: small.path, key: "/small.txt", content_type: "text/plain")

    data_back = File.binread(File.join(@store_dir, "fake-bucket/small.txt"))
    assert_equal "hello world", data_back
  ensure
    small&.unlink
  end

  def test_stream_chunks
    small = Tempfile.new(["small", ".bin"])
    small.binmode
    small.write("hello world")
    small.flush
    @client.upload_file(local_path: small.path, key: "/chunks.txt")

    prog = []
    @client.download_stream(key: "/chunks.txt") do |chunk|
      prog << chunk.bytesize
      sleep 0.001
    end
    assert_equal "hello world".bytesize, prog.sum
  ensure
    small&.unlink
  end

  def test_multipart_abort
    uid = @client.multipart_start(key: "/will/abort.bin")
    abort_code = @client.multipart_abort(key: "/will/abort.bin", upload_id: uid)
    assert_equal 204, abort_code
  end
end
