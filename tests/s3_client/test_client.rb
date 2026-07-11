# frozen_string_literal: true

require_relative "../test_helper"
require_relative "../../src/s3_client"

class S3ClientTest < Minitest::Test
  include S3TestHelpers

  PORT = 15_599

  def setup
    dir = suite_tmp_dir("s3client")
    @store_dir = File.join(dir, "store")
    @tmp_dir   = File.join(dir, "tmp")
    @server = FakeS3::Server.new(port: PORT, store_dir: @store_dir, tmp_dir: @tmp_dir)
    @server.start_thread

    @client = S3Client.new(
      bucket: "b",
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
    cleanup_suite_tmp("s3client")
  end

  def test_client_creation_with_all_params
    c = S3Client.new(
      bucket: "b",
      endpoint: "https://s3.amazonaws.com", region: "us-west-2",
      access_key_id: "AK", secret_access_key: "SK",
      session_token: "TOKEN", open_timeout: 10, read_timeout: 120,
      logger: Logger.new(File::NULL)
    )
    assert_kind_of S3Client, c
    assert_equal "us-west-2", c.region
  end

  def test_rejects_empty_access_key
    assert_raises(ArgumentError) do
      S3Client.new(
        bucket: "b",
        endpoint: "https://s3.amazonaws.com", region: "us-east-1",
        access_key_id: "", secret_access_key: "SK",
        logger: Logger.new(File::NULL)
      )
    end
  end

  def test_rejects_empty_secret_key
    assert_raises(ArgumentError) do
      S3Client.new(
        bucket: "b",
        endpoint: "https://s3.amazonaws.com", region: "us-east-1",
        access_key_id: "AK", secret_access_key: "",
        logger: Logger.new(File::NULL)
      )
    end
  end

  def test_rejects_empty_bucket
    assert_raises(ArgumentError) do
      S3Client.new(
        bucket: "",
        endpoint: "https://s3.amazonaws.com", region: "us-east-1",
        access_key_id: "AK", secret_access_key: "SK",
        logger: Logger.new(File::NULL)
      )
    end
  end

  def test_human_readable_size
    assert_equal "0 B", @client.human_readable_size(0)
    assert_equal "1.00 KB", @client.human_readable_size(1024)
    assert_equal "1.00 MB", @client.human_readable_size(1024 * 1024)
    assert_equal "1.00 GB", @client.human_readable_size(1024 * 1024 * 1024)
    assert_equal "1.00 TB", @client.human_readable_size(1024 * 1024 * 1024 * 1024)
    assert_equal "0 B", @client.human_readable_size(nil)
  end

  def test_monotonic_clock
    t1 = @client.now_mono
    sleep 0.01
    t2 = @client.now_mono
    assert t2 > t1
  end

  def test_transient_errors
    errors = @client.transient_errors
    assert_kind_of Array, errors
    assert_includes errors, Net::OpenTimeout
    assert_includes errors, Errno::ECONNRESET
    assert_includes errors, EOFError
    assert_includes errors, SocketError
  end

  def test_s3error_with_code_and_request_id
    body = "<Error><Code>NoSuchBucket</Code><Message>Not Found</Message><BucketName>mybucket</BucketName></Error>"
    err = S3Client::S3Error.new("404", "Not Found", "req-123", body)
    assert_equal "404", err.code
    assert_equal "req-123", err.request_id
    assert_equal "NoSuchBucket", err.s3_code
    assert_equal "Not Found", err.s3_message
    assert_equal "mybucket", err.s3_bucket
    assert_includes err.message, "404"
    assert_includes err.message, "req-123"
    assert_includes err.message, "NoSuchBucket"
    assert_includes err.message, "mybucket"
  end

  def test_s3error_without_optional_fields
    err = S3Client::S3Error.new("500", "Server Error")
    assert_equal "500", err.code
    assert_nil err.request_id
    assert_nil err.s3_code
    assert_nil err.s3_message
    assert_nil err.s3_bucket
    assert_includes err.message, "500"
  end

  def test_s3error_body_truncated_at_500
    long_body = "x" * 1000
    err = S3Client::S3Error.new("500", "Error", nil, long_body)
    assert_includes err.message, "500"
    refute_includes err.message, "x" * 500
  end

  def test_uri_building_basic
    uri = @client.send(:build_uri, "file.txt")
    assert_includes uri.to_s, "/b/file.txt"
  end

  def test_uri_building_with_query
    uri = @client.send(:build_uri, "file.txt", query: { uploads: nil, partNumber: "1" })
    assert_includes uri.to_s, "uploads"
    assert_includes uri.to_s, "partNumber=1"
  end

  def test_parse_multipart_uploads_xml
    xml = <<~XML
      <?xml version="1.0"?>
      <ListMultipartUploadsResult>
        <Upload><UploadId>uid-1</UploadId><Key>f1.txt</Key><Initiated>2024-01-01T00:00:00Z</Initiated><StorageClass>STANDARD</StorageClass></Upload>
        <Upload><UploadId>uid-2</UploadId><Key>f2.txt</Key><Initiated>2024-01-02T00:00:00Z</Initiated><StorageClass>STANDARD</StorageClass></Upload>
      </ListMultipartUploadsResult>
    XML
    uploads = @client.send(:parse_multipart_uploads_xml, xml)
    assert_equal 2, uploads.length
    assert_equal "uid-1", uploads[0][:upload_id]
    assert_equal "f2.txt", uploads[1][:key]
  end

  def test_parse_parts_xml
    xml = <<~XML
      <?xml version="1.0"?>
      <ListPartsResult>
        <Part><PartNumber>1</PartNumber><ETag>"e1"</ETag><Size>5242880</Size><LastModified>2024-01-01T00:00:00Z</LastModified></Part>
        <Part><PartNumber>2</PartNumber><ETag>"e2"</ETag><Size>3145728</Size><LastModified>2024-01-01T00:00:00Z</LastModified></Part>
      </ListPartsResult>
    XML
    parts = @client.send(:parse_parts_xml, xml)
    assert_equal 2, parts.length
    assert_equal 1, parts[0][:part_number]
    assert_equal '"e2"', parts[1][:etag]
    assert_equal 3_145_728, parts[1][:size]
  end

  def test_constants
    assert_equal 5 * 1024 * 1024, S3Client::MIN_PART_SIZE
    assert_equal 10 * 1024 * 1024, S3Client::DEFAULT_PART_SIZE
    assert_equal 5 * 1024 * 1024 * 1024, S3Client::MAX_PART_SIZE
    assert_equal 4, S3Client::DEFAULT_MAX_THREADS
    assert_equal 3, S3Client::DEFAULT_MAX_RETRIES
    assert_equal 0.25, S3Client::DEFAULT_RETRY_DELAY
    assert_equal 64 * 1024, S3Client::READ_CHUNK_BYTES
  end

  def test_concurrent_counter_increment
    counter = 0
    mutex = Mutex.new
    threads = 10.times.map do
      Thread.new { 100.times { mutex.synchronize { counter += 1 } } }
    end
    threads.each(&:join)
    assert_equal 1000, counter
  end

  def test_queue_based_work_distribution
    queue = Queue.new
    20.times { |i| queue << i }
    results = []
    mutex = Mutex.new

    threads = 4.times.map do
      Thread.new do
        loop do
          item = begin
            queue.pop(true)
          rescue StandardError
            nil
          end
          break unless item

          mutex.synchronize { results << item }
        end
      end
    end
    threads.each(&:join)
    assert_equal 20, results.length
    assert_equal (0..19).to_a, results.sort
  end

  def test_chunked_file_reading
    temp = Tempfile.new(["mem", ".bin"])
    10.times { temp.write("x" * (1024 * 1024)) }
    temp.close

    total_read = 0
    chunk_count = 0
    File.open(temp.path, "rb") do |f|
      while (chunk = f.read(1024 * 1024))
        total_read += chunk.bytesize
        chunk_count += 1
      end
    end

    assert_equal 10 * 1024 * 1024, total_read
    assert_equal 10, chunk_count
  ensure
    temp&.unlink
  end

  # --- resolve_style + build_endpoint ---

  def test_resolve_style_auto_with_custom_endpoint
    style = @client.send(:resolve_style, :auto, "http://minio.local:9000")
    assert_equal :path, style
  end

  def test_resolve_style_auto_without_endpoint
    style = @client.send(:resolve_style, :auto, nil)
    assert_equal :virtual_hosted, style
  end

  def test_resolve_style_explicit
    style = @client.send(:resolve_style, :path, nil)
    assert_equal :path, style
  end

  def test_build_endpoint_with_custom
    ep = @client.send(:build_endpoint, "http://minio.local:9000", "us-east-1", "b", :path)
    assert_equal "http://minio.local:9000", ep
  end

  def test_build_endpoint_aws_path_style
    ep = @client.send(:build_endpoint, nil, "us-west-2", "b", :path)
    assert_equal "https://s3.us-west-2.amazonaws.com", ep
  end

  def test_build_endpoint_aws_virtual_hosted
    ep = @client.send(:build_endpoint, nil, "us-west-2", "b", :virtual_hosted)
    assert_equal "https://b.s3.us-west-2.amazonaws.com", ep
  end

  def test_build_endpoint_trailing_slash_removed
    ep = @client.send(:build_endpoint, "http://minio.local:9000/", "us-east-1", "b", :path)
    assert_equal "http://minio.local:9000", ep
  end

  # --- upload_file validation errors ---

  def test_upload_file_nonexistent_path
    assert_raises(Errno::ENOENT) do
      @client.upload_file(local_path: "/nonexistent/file.bin", key: "test")
    end
  end

  def test_upload_file_part_size_too_small
    Tempfile.create(["small_ps", ".bin"]) do |f|
      f.write("x" * 1024)
      f.flush
      assert_raises(ArgumentError) do
        @client.upload_file(local_path: f.path, key: "test", part_size: 1024)
      end
    end
  end

  def test_upload_file_too_many_parts
    Tempfile.create(["big", ".bin"]) do |f|
      # 10MB file with 1KB part size = 10240 parts > 10000 max
      f.write("x" * 10 * 1024 * 1024)
      f.flush
      assert_raises(ArgumentError) do
        @client.upload_file(local_path: f.path, key: "test", part_size: 1024)
      end
    end
  end

  # --- empty file upload ---

  def test_upload_empty_file
    Tempfile.create(["empty", ".bin"]) do |f|
      f.binmode
      result = @client.upload_file(local_path: f.path, key: "/empty.bin",
                                   content_type: "application/octet-stream")
      assert result[:etag]
      assert_equal [], result[:parts]
    end
  end

  # --- upload_file resume_state via UploadState ---

  def test_upload_file_small_file_with_threshold
    Tempfile.create(["small", ".bin"]) do |f|
      f.write("x" * 1024)
      f.flush
      result = @client.upload_file(
        local_path: f.path, key: "/small.bin"
      )
      assert result[:etag]
    end
  end

  # --- concurrent counter ---

  def test_parallel_counter_synchronization
    counter = 0
    mutex = Mutex.new
    threads = 5.times.map do
      Thread.new { 200.times { mutex.synchronize { counter += 1 } } }
    end
    threads.each(&:join)
    assert_equal 1000, counter
  end

  # --- download_stream without block ---

  def test_download_stream_no_block
    assert_raises(ArgumentError) do
      @client.download_stream(key: "/anything.bin")
    end
  end

  # --- resume_upload error paths ---

  def test_resume_upload_nonexistent_state_file
    assert_raises(Errno::ENOENT) do
      @client.resume_upload(state_file: "/nonexistent/state.json")
    end
  end

  def test_resume_upload_invalid_state
    Dir.mktmpdir do |dir|
      path = File.join(dir, "bad_state.json")
      File.write(path, JSON.generate({ key: "k", parts: {} }))
      assert_raises(ArgumentError) do
        @client.resume_upload(state_file: path)
      end
    end
  end

  def test_resume_upload_file_size_changed
    Dir.mktmpdir do |dir|
      local_path = File.join(dir, "file.bin")
      File.write(local_path, "original")
      state_file = File.join(dir, "state.json")
      File.write(state_file, JSON.generate({
                                             upload_id: "uid-1", key: "k", part_size: 5_242_880,
                                             total_size: 999, local_path: local_path, parts: {}
                                           }))
      assert_raises(ArgumentError) do
        @client.resume_upload(state_file: state_file)
      end
    end
  end

  def test_resume_upload_file_not_found
    Dir.mktmpdir do |dir|
      state_file = File.join(dir, "state.json")
      File.write(state_file, JSON.generate({
                                             upload_id: "uid-1", key: "k", part_size: 5_242_880,
                                             total_size: 100, local_path: "/nonexistent/file.bin", parts: {}
                                           }))
      assert_raises(Errno::ENOENT) do
        @client.resume_upload(state_file: state_file)
      end
    end
  end

  # --- upload_file with empty file ---

  def test_upload_file_empty_file
    Tempfile.create(["empty_multipart", ".bin"]) do |f|
      f.binmode
      result = @client.upload_file(
        local_path: f.path, key: "/empty_multipart.bin"
      )
      assert result[:etag]
    end
  end

  # --- upload_file with cache_control ---

  def test_upload_file_with_cache_control
    src_path, = create_temp_binary_file(1024)
    r = @client.upload_file(
      local_path: src_path, key: "/cached.bin",
      cache_control: "max-age=3600"
    )
    assert r[:etag]
  ensure
    File.delete(src_path) if src_path && File.exist?(src_path)
  end

  # --- safe_abort error path ---

  def test_safe_abort_handles_error
    @client.send(:safe_abort, key: "/nonexistent/key", upload_id: "fake-upload-id")
  end

  # --- build_http_request with string body ---

  def test_build_http_request_string_body
    uri = URI("http://example.com/test")
    req = @client.send(:build_http_request, :put, uri, "hello world",
                       { "content-type" => "text/plain" })
    assert_equal "hello world", req.body
    assert_equal "text/plain", req["Content-Type"]
  end

  # --- build_http_request empty body ---

  def test_build_http_request_empty_body
    uri = URI("http://example.com/test")
    req = @client.send(:build_http_request, :get, uri, nil, {})
    assert_nil req.body
  end

  # --- build_http_request get/delete/head methods ---

  def test_build_http_request_get
    uri = URI("http://example.com/test")
    req = @client.send(:build_http_request, :get, uri, nil, {})
    assert_kind_of Net::HTTP::Get, req
  end

  def test_build_http_request_delete
    uri = URI("http://example.com/test")
    req = @client.send(:build_http_request, :delete, uri, nil, {})
    assert_kind_of Net::HTTP::Delete, req
  end

  def test_build_http_request_head
    uri = URI("http://example.com/test")
    req = @client.send(:build_http_request, :head, uri, nil, {})
    assert_kind_of Net::HTTP::Head, req
  end

  def test_build_http_request_post
    uri = URI("http://example.com/test")
    req = @client.send(:build_http_request, :post, uri, "xml body", {})
    assert_kind_of Net::HTTP::Post, req
  end

  # --- build_uri variations ---

  def test_build_uri_virtual_hosted_style
    client = S3Client.new(
      bucket: "my-bucket", region: "us-west-2",
      access_key_id: "AK", secret_access_key: "SK",
      endpoint_style: :virtual_hosted,
      logger: Logger.new(File::NULL)
    )
    uri = client.send(:build_uri, "test/file.txt")
    assert_includes uri.to_s, "my-bucket.s3"
    assert_includes uri.to_s, "/test/file.txt"
  end

  def test_build_uri_path_style_aws
    client = S3Client.new(
      bucket: "my-bucket", region: "us-west-2",
      access_key_id: "AK", secret_access_key: "SK",
      endpoint_style: :path,
      logger: Logger.new(File::NULL)
    )
    uri = client.send(:build_uri, "test/file.txt")
    assert_includes uri.to_s, "s3.us-west-2.amazonaws.com"
    assert_includes uri.to_s, "/my-bucket/test/file.txt"
  end

  def test_build_uri_path_style_custom_endpoint
    client = S3Client.new(
      bucket: "my-bucket", region: "us-east-1",
      access_key_id: "AK", secret_access_key: "SK",
      endpoint: "http://minio.local:9000",
      endpoint_style: :path,
      logger: Logger.new(File::NULL)
    )
    uri = client.send(:build_uri, "test/file.txt")
    assert_includes uri.to_s, "http://minio.local:9000"
    assert_includes uri.to_s, "/my-bucket/test/file.txt"
  end

  def test_build_uri_empty_key
    assert_raises(ArgumentError) do
      @client.send(:build_uri, "")
    end
  end

  def test_build_uri_with_leading_slash
    uri = @client.send(:build_uri, "/leading/slash.txt")
    assert_includes uri.to_s, "/leading/slash.txt"
  end
end
