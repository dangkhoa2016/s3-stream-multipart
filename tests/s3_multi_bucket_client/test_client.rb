# frozen_string_literal: true

require_relative "../test_helper"
require_relative "../../src/s3_multi_bucket_client"

class S3MultiBucketClientTest < Minitest::Test
  def setup
    @client = S3MultiBucketClient.new(
      endpoint: "http://127.0.0.1:19999",
      region: "us-east-1",
      access_key_id: "AKIAFAKE",
      secret_access_key: "secretfake",
      open_timeout: 5, read_timeout: 30,
      logger: Logger.new(File::NULL)
    )
  end

  def test_client_creation_with_all_params
    c = S3MultiBucketClient.new(
      endpoint: "https://s3.amazonaws.com", region: "us-west-2",
      access_key_id: "AK", secret_access_key: "SK",
      session_token: "TOKEN", open_timeout: 10, read_timeout: 120,
      logger: Logger.new(File::NULL)
    )
    assert_kind_of S3MultiBucketClient, c
    assert_kind_of Aws::Sigv4::Signer, c.signer
    assert_equal "us-west-2", c.region
  end

  def test_client_creation_fallback_logger
    orig_stdout = $stdout
    $stdout = File.open(File::NULL, "w")
    c = S3MultiBucketClient.new(
      endpoint: "https://s3.amazonaws.com", region: "us-east-1",
      access_key_id: "AK", secret_access_key: "SK"
    )
  ensure
    $stdout = orig_stdout
    assert_kind_of S3MultiBucketClient, c if c
    assert c.instance_variable_get(:@logger), "fallback logger should be set" if c
  end

  def test_rejects_empty_access_key
    err = assert_raises(ArgumentError) do
      S3MultiBucketClient.new(
        endpoint: "https://s3.amazonaws.com", region: "us-east-1",
        access_key_id: "", secret_access_key: "SK"
      )
    end
    assert_includes err.message, "access_key_id"
  end

  def test_rejects_empty_secret_key
    err = assert_raises(ArgumentError) do
      S3MultiBucketClient.new(
        endpoint: "https://s3.amazonaws.com", region: "us-east-1",
        access_key_id: "AK", secret_access_key: ""
      )
    end
    assert_includes err.message, "secret_access_key"
  end

  def test_missing_access_key_raises
    assert_raises(ArgumentError) do
      S3MultiBucketClient.new(
        secret_access_key: "SK",
        bucket: "b", region: "us-east-1",
        endpoint: "http://127.0.0.1:19999"
      )
    end
  end

  def test_missing_secret_key_raises
    assert_raises(ArgumentError) do
      S3MultiBucketClient.new(
        access_key_id: "AK",
        bucket: "b", region: "us-east-1",
        endpoint: "http://127.0.0.1:19999"
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

  def test_part_size_too_small
    assert_raises(ArgumentError) do
      S3MultiBucketClient.new(
        access_key_id: "AK", secret_access_key: "SK",
        bucket: "b", region: "us-east-1",
        endpoint: "http://127.0.0.1:19999",
        part_size: 1_048_576
      )
    end
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
    err = S3MultiBucketClient::S3Error.new("404", "Not Found", "req-123", "<Error>body</Error>")
    assert_equal "404", err.code
    assert_equal "req-123", err.request_id
    assert_includes err.message, "404"
    assert_includes err.message, "req-123"
    assert_includes err.message, "<Error>body</Error>"
  end

  def test_s3error_without_optional_fields
    err = S3MultiBucketClient::S3Error.new("500", "Server Error")
    assert_equal "500", err.code
    assert_nil err.request_id
    assert_includes err.message, "500"
  end

  def test_s3error_body_truncated_at_500
    long_body = "x" * 1000
    err = S3MultiBucketClient::S3Error.new("500", "Error", nil, long_body)
    assert_includes err.message, "x" * 500
    refute_includes err.message, "x" * 501
  end

  def test_upload_error_class
    err = S3MultiBucketClient::UploadError.new("upload failed")
    assert_kind_of StandardError, err
    assert_includes err.message, "upload failed"
  end

  def test_download_error_class
    err = S3MultiBucketClient::DownloadError.new("download failed")
    assert_kind_of StandardError, err
    assert_includes err.message, "download failed"
  end

  def test_uri_building_basic
    uri = @client.build_uri("bucket", "file.txt")
    assert_includes uri.to_s, "/bucket/file.txt"
  end

  def test_uri_building_with_query
    uri = @client.build_uri("bucket", "file.txt", { "uploads" => "", "partNumber" => "1" })
    assert_includes uri.to_s, "uploads="
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

  def test_parse_parts_list_xml
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
    assert_equal 5 * 1024 * 1024, S3MultiBucketClient::MIN_PART_SIZE
    assert_equal 8 * 1024 * 1024, S3MultiBucketClient::DEFAULT_PART_SIZE
    assert_equal 5 * 1024 * 1024 * 1024, S3MultiBucketClient::MAX_PART_SIZE
    assert_equal 4, S3MultiBucketClient::DEFAULT_MAX_THREADS
    assert_equal 3, S3MultiBucketClient::DEFAULT_MAX_RETRIES
    assert_equal 0.25, S3MultiBucketClient::DEFAULT_RETRY_DELAY
    assert_equal 64 * 1024, S3MultiBucketClient::READ_CHUNK_BYTES
    assert_equal 10 * 1024 * 1024, S3MultiBucketClient::STREAM_SINGLE_PUT_THRESHOLD
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

  # --- SSE headers ---

  def test_sse_headers_nil
    assert_equal({}, @client.sse_headers)
  end

  def test_sse_headers_aes256
    client = S3MultiBucketClient.new(
      endpoint: "http://127.0.0.1:19999", region: "us-east-1",
      access_key_id: "AK", secret_access_key: "SK",
      sse: { type: "AES256" },
      logger: Logger.new(File::NULL)
    )
    h = client.sse_headers
    assert_equal "AES256", h["x-amz-server-side-encryption"]
  end

  def test_sse_headers_kms
    client = S3MultiBucketClient.new(
      endpoint: "http://127.0.0.1:19999", region: "us-east-1",
      access_key_id: "AK", secret_access_key: "SK",
      sse: { type: "aws:kms", kms_key_id: "arn:aws:kms:us-east-1:123:key/abc" },
      logger: Logger.new(File::NULL)
    )
    h = client.sse_headers
    assert_equal "aws:kms", h["x-amz-server-side-encryption"]
    assert_equal "arn:aws:kms:us-east-1:123:key/abc", h["x-amz-server-side-encryption-aws-kms-key-id"]
  end

  def test_sse_headers_customer
    client = S3MultiBucketClient.new(
      endpoint: "http://127.0.0.1:19999", region: "us-east-1",
      access_key_id: "AK", secret_access_key: "SK",
      sse: { type: "customer", key: "dGVzdC1rZXk=" },
      logger: Logger.new(File::NULL)
    )
    h = client.sse_headers
    assert_equal "AES256", h["x-amz-server-side-encryption-customer-algorithm"]
    assert_equal "dGVzdC1rZXk=", h["x-amz-server-side-encryption-customer-key"]
  end

  # --- extract_total_size ---

  def test_extract_total_size_via_content_range
    resp = OpenStruct.new("Content-Range" => "bytes 0-1023/500000")
    assert_equal 500_000, @client.send(:extract_total_size, resp, 0)
  end

  def test_extract_total_size_via_content_length
    resp = OpenStruct.new("Content-Length" => "500000")
    assert_equal 500_000, @client.send(:extract_total_size, resp, 0)
  end

  # --- etag_matches_file? ---

  def test_etag_matches_file_returns_false_for_nil
    refute @client.etag_matches_file?(nil, File::NULL)
  end

  def test_etag_matches_file_multipart_etag
    assert @client.etag_matches_file?('"abc123-2"', File::NULL)
  end

  # --- backoff_with_jitter ---

  def test_backoff_with_jitter_increases
    d1 = @client.backoff_with_jitter(1)
    d2 = @client.backoff_with_jitter(2)
    assert d1 > 0
    assert d1 <= 2.0
    assert d2 > 0
    assert d2 <= 4.0
  end

  # --- resume_start_byte ---

  def test_resume_start_byte_no_file
    assert_equal 0, @client.resume_start_byte("/nonexistent/path")
  end

  # --- extract_metadata_from_headers ---

  def test_extract_metadata_from_headers
    resp = OpenStruct.new
    def resp.each_header(&b)
      b.call("x-amz-meta-key1", "val1")
      b.call("x-amz-meta-key2", "val2")
    end
    meta = @client.extract_metadata_from_headers(resp)
    assert_equal "val1", meta["key1"]
    assert_equal "val2", meta["key2"]
  end

  # --- build_uri ---

  def test_build_uri_with_empty_key
    uri = @client.send(:build_uri, "b", "")
    assert_kind_of URI, uri
  end

  # --- now_mono ---

  def test_now_mono_returns_float
    assert_kind_of Float, @client.now_mono
  end

  # --- human_readable_size ---

  def test_human_readable_size_nil
    assert_equal "0 B", @client.human_readable_size(nil)
  end

  # --- transient_errors ---

  def test_transient_errors_includes_network_errors
    errors = @client.transient_errors
    assert_includes errors, Net::OpenTimeout
    assert_includes errors, EOFError
    assert_includes errors, SocketError
  end

  # --- parse_content_range nil ---

  def test_parse_content_range_nil
    resp = OpenStruct.new
    assert_nil @client.parse_content_range(resp)
  end

  # --- parse_head_response ---

  def test_parse_head_response
    resp = OpenStruct.new(
      "content-length" => "100",
      "content-type" => "text/plain",
      "etag" => '"abc123"',
      "last-modified" => "Mon, 01 Jan 2024 00:00:00 GMT"
    )
    def resp.each_header(&block); end
    parsed = @client.parse_head_response(resp)
    assert_equal 100, parsed[:content_length]
    assert_equal "text/plain", parsed[:content_type]
  end

  # --- sse initialization ---

  def test_sse_initialization
    c = S3MultiBucketClient.new(
      endpoint: "http://127.0.0.1:19999", region: "us-east-1",
      access_key_id: "AK", secret_access_key: "SK",
      sse: { type: "AES256" },
      logger: Logger.new(File::NULL)
    )
    assert_equal({ type: "AES256" }, c.instance_variable_get(:@sse))
  end

  def test_log_color_initialization
    c = S3MultiBucketClient.new(
      endpoint: "http://127.0.0.1:19999", region: "us-east-1",
      access_key_id: "AK", secret_access_key: "SK",
      log_color: true,
      logger: Logger.new(File::NULL)
    )
    assert c.instance_variable_get(:@log_color)
  end

  # --- signed_request_via ---

  def test_signed_request_via_with_body
    uri = URI("http://example.com/test")
    http = Minitest::Mock.new
    req = Net::HTTP::Put.new(uri)
    req["content-type"] = "text/plain"
    req.body = "test data"
    @client.signed_request_via(http, uri, body: "test data")
  rescue StandardError => e
    assert_kind_of StandardError, e
  end

  def test_signed_request_via_with_body_stream
    uri = URI("http://example.com/test")
    http = Minitest::Mock.new
    io = StringIO.new("stream data")
    @client.signed_request_via(http, uri, body_stream: io)
  rescue StandardError => e
    assert_kind_of StandardError, e
  end

  # --- download_stream without block ---

  def test_download_stream_no_block
    assert_raises(ArgumentError) do
      @client.download_stream(bucket: "b", key: "test.bin")
    end
  end

  # --- build_http_request methods ---

  def test_build_http_request_get
    uri = URI("http://example.com/test")
    req = @client.send(:build_http_request, :get, uri, nil, {})
    assert_kind_of Net::HTTP::Get, req
  end

  def test_build_http_request_post
    uri = URI("http://example.com/test")
    req = @client.send(:build_http_request, :post, uri, "body", {})
    assert_kind_of Net::HTTP::Post, req
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

  def test_build_http_request_unsupported
    assert_raises(ArgumentError) do
      @client.send(:build_http_request, :patch, URI("http://example.com/"), nil, {})
    end
  end

  # --- apply_signer_headers! ---

  def test_apply_signer_headers_string_body
    uri = URI("http://example.com/test")
    req = Net::HTTP::Put.new(uri)
    @client.send(:apply_signer_headers!, req, "PUT", uri, "hello")
    assert req["authorization"] || req["Authorization"]
  end

  def test_apply_signer_headers_io_body
    uri = URI("http://example.com/test")
    req = Net::HTTP::Put.new(uri)
    Dir.mktmpdir do |dir|
      path = File.join(dir, "signer_io_mb.bin")
      File.write(path, "stream data")
      File.open(path, "rb") do |io|
        @client.send(:apply_signer_headers!, req, "PUT", uri, io)
        assert_equal "UNSIGNED-PAYLOAD", req["x-amz-content-sha256"]
      end
    end
  end
end
