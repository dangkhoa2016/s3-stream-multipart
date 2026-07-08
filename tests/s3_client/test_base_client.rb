# frozen_string_literal: true

require_relative "../test_helper"
require_relative "../../src/s3_client"

class S3ClientBaseTest < Minitest::Test
  def setup
    @client = S3Client.new(
      bucket: "b", region: "us-east-1",
      access_key_id: "AKIAFAKE", secret_access_key: "secretfake",
      endpoint: "http://127.0.0.1:19999",
      open_timeout: 5, read_timeout: 30,
      logger: Logger.new(File::NULL)
    )
  end

  # --- SSE headers ---

  def test_sse_headers_nil
    assert_equal({}, @client.sse_headers)
  end

  def test_sse_headers_aes256
    client = S3Client.new(
      bucket: "b", region: "us-east-1",
      access_key_id: "AK", secret_access_key: "SK",
      endpoint: "http://127.0.0.1:19999",
      sse: { type: "AES256" },
      logger: Logger.new(File::NULL)
    )
    h = client.sse_headers
    assert_equal "AES256", h["x-amz-server-side-encryption"]
  end

  def test_sse_headers_kms
    client = S3Client.new(
      bucket: "b", region: "us-east-1",
      access_key_id: "AK", secret_access_key: "SK",
      endpoint: "http://127.0.0.1:19999",
      sse: { type: "aws:kms", kms_key_id: "arn:aws:kms:us-east-1:123:key/abc" },
      logger: Logger.new(File::NULL)
    )
    h = client.sse_headers
    assert_equal "aws:kms", h["x-amz-server-side-encryption"]
    assert_equal "arn:aws:kms:us-east-1:123:key/abc", h["x-amz-server-side-encryption-aws-kms-key-id"]
  end

  def test_sse_headers_customer
    client = S3Client.new(
      bucket: "b", region: "us-east-1",
      access_key_id: "AK", secret_access_key: "SK",
      endpoint: "http://127.0.0.1:19999",
      sse: { type: "customer", key: "dGVzdC1rZXk=", key_md5: "dGVzdC1tZDU=" },
      logger: Logger.new(File::NULL)
    )
    h = client.sse_headers
    assert_equal "AES256", h["x-amz-server-side-encryption-customer-algorithm"]
    assert_equal "dGVzdC1rZXk=", h["x-amz-server-side-encryption-customer-key"]
    assert_equal "dGVzdC1tZDU=", h["x-amz-server-side-encryption-customer-key-MD5"]
  end

  def test_sse_headers_unknown_type
    client = S3Client.new(
      bucket: "b", region: "us-east-1",
      access_key_id: "AK", secret_access_key: "SK",
      endpoint: "http://127.0.0.1:19999",
      sse: { type: "unknown" },
      logger: Logger.new(File::NULL)
    )
    assert_equal({}, client.sse_headers)
  end

  # --- etag_matches_file? ---

  def test_etag_matches_file_returns_false_for_nil
    refute @client.etag_matches_file?(nil, File::NULL)
  end

  def test_etag_matches_file_multipart_etag
    assert @client.etag_matches_file?('"abc123-2"', File::NULL)
  end

  def test_etag_matches_file_single_put
    Tempfile.create(["etag_test", ".bin"]) do |f|
      f.write("hello world")
      f.flush
      md5 = Digest::MD5.file(f.path).hexdigest
      assert @client.etag_matches_file?(md5, f.path)
      refute @client.etag_matches_file?("wrong_etag_value", f.path)
    end
  end

  # --- extract_total_size ---

  def test_extract_total_size_from_content_range
    resp = OpenStruct.new("Content-Range" => "bytes 0-1023/146515")
    assert_equal 146_515, @client.send(:extract_total_size, resp, 0)
  end

  def test_extract_total_size_from_content_length
    resp = OpenStruct.new("Content-Length" => "1000")
    assert_equal 1000, @client.send(:extract_total_size, resp, 0)
  end

  def test_extract_total_size_nil
    resp = OpenStruct.new
    assert_nil @client.send(:extract_total_size, resp, 0)
  end

  # --- backoff_with_jitter ---

  def test_backoff_with_jitter
    delay = @client.backoff_with_jitter(1)
    assert delay > 0
    assert delay <= 2.0

    delay2 = @client.backoff_with_jitter(2)
    assert delay2 > 0
    assert delay2 <= 4.0
  end

  # --- resume_start_byte ---

  def test_resume_start_byte_no_part_file
    assert_equal 0, @client.resume_start_byte("/nonexistent/path")
  end

  def test_resume_start_byte_with_part_file
    Tempfile.create(["resume", ".part"]) do |f|
      f.write("x" * 5000)
      f.flush
      part_path = f.path
      local_path = part_path.sub(/\.part$/, "")
      assert_equal 5000, @client.resume_start_byte(local_path)
    end
  end

  # --- build_resume_headers ---

  def test_build_resume_headers_positive
    h = @client.build_resume_headers(1000)
    assert_equal "bytes=1000-", h["Range"]
  end

  def test_build_resume_headers_zero
    h = @client.build_resume_headers(0)
    assert_equal({}, h)
  end

  # --- parse_content_range ---

  def test_parse_content_range_with_range
    resp = OpenStruct.new("content-range" => "bytes 0-1023/146515")
    assert_equal 146_515, @client.parse_content_range(resp)
  end

  def test_parse_content_range_without_range
    resp = OpenStruct.new("content-length" => "50000")
    assert_equal 50_000, @client.parse_content_range(resp)
  end

  def test_parse_content_range_nil
    resp = OpenStruct.new
    assert_nil @client.parse_content_range(resp)
  end

  # --- extract_upload_id / extract_etag error paths ---

  def test_extract_upload_id_missing
    err = assert_raises(S3Client::S3Error) do
      @client.send(:extract_upload_id, "<xml></xml>")
    end
    assert_includes err.message, "Did not find UploadId"
  end

  def test_extract_etag_missing
    err = assert_raises(S3Client::S3Error) do
      @client.send(:extract_etag, "<xml></xml>")
    end
    assert_includes err.message, "Did not find ETag"
  end

  # --- compute_upload_session_metadata ---

  def test_compute_upload_session_metadata
    Tempfile.create(["meta", ".bin"]) do |f|
      f.write("test data")
      f.flush
      meta = @client.send(:compute_upload_session_metadata, f.path, 9)
      assert meta[:upload_session_id]
      assert meta[:file_fingerprint]
    end
  end

  # --- parse_head_response ---

  def test_parse_head_response_with_metadata
    resp = OpenStruct.new(
      "content-length" => "100",
      "content-type" => "text/plain",
      "etag" => '"abc123"',
      "last-modified" => "Mon, 01 Jan 2024 00:00:00 GMT",
      "x-amz-storage-class" => "STANDARD_IA"
    )
    def resp.each_header(&block); end
    parsed = @client.parse_head_response(resp)
    assert_equal 100, parsed[:content_length]
    assert_equal "text/plain", parsed[:content_type]
    assert_equal "abc123", parsed[:etag]
    assert_equal "STANDARD_IA", parsed[:storage_class]
  end

  # --- load_download_state ---

  def test_load_download_state_no_file
    assert_nil @client.send(:load_download_state, nil, key: "k", part_size: 5_242_880, total_size: 10_485_760)
    assert_nil @client.send(:load_download_state, "/nonexistent/state.json", key: "k", part_size: 5_242_880, total_size: 10_485_760)
  end

  def test_load_download_state_mismatch
    Dir.mktmpdir do |dir|
      state_file = File.join(dir, "dl_state.json")
      File.write(state_file, JSON.generate({
                                             key: "wrong_key", part_size: 5_242_880, total_size: 10_485_760, parts: {}
                                           }))
      assert_nil @client.send(:load_download_state, state_file, key: "k", part_size: 5_242_880, total_size: 10_485_760)
      refute File.exist?(state_file), "stale state should be deleted"
    end
  end

  # --- extract_metadata_from_headers ---

  def test_extract_metadata_from_headers
    resp = OpenStruct.new
    resp.instance_variable_set(:@headers, {})
    def resp.each_header(&b)
      b.call("x-amz-meta-author", "bob")
      b.call("x-amz-meta-version", "2")
      b.call("content-type", "text/plain")
    end
    meta = @client.extract_metadata_from_headers(resp)
    assert_equal "bob", meta["author"]
    assert_equal "2", meta["version"]
    assert_nil meta["content-type"]
  end

  # --- encode_path ---

  def test_encode_path
    result = @client.send(:encode_path, "my dir/file.txt")
    assert_includes result, "%20"
  end

  def test_encode_path_with_tilde
    result = @client.send(:encode_path, "~/file.txt")
    assert_includes result, "~"
  end

  # --- ensure_success! ---

  def test_ensure_success_raises_on_non_success
    resp = OpenStruct.new(code: "404", message: "Not Found")
    def resp.[](key)
      key == "x-amz-request-id" ? "req-404" : nil
    end
    err = assert_raises(S3BaseClient::S3Error) do
      @client.send(:ensure_success!, resp)
    end
    assert_includes err.message, "404"
  end

  def test_ensure_success_passes_on_success
    resp = OpenStruct.new(code: "200")
    def resp.is_a?(klass)
      klass == Net::HTTPSuccess ? true : super
    end
    @client.send(:ensure_success!, resp)
  end

  # --- extract_total_size nil ---

  def test_extract_total_size_nil_response
    resp = OpenStruct.new
    assert_nil @client.send(:extract_total_size, resp, 0)
  end

  # --- transient_errors ---

  def test_transient_errors_includes_network_errors
    errors = @client.transient_errors
    assert_includes errors, Net::OpenTimeout
    assert_includes errors, Net::ReadTimeout
    assert_includes errors, Errno::ECONNRESET
    assert_includes errors, EOFError
    assert_includes errors, SocketError
  end

  # --- build_http_request stream body ---

  def test_build_http_request_stream_body_adds_unsigned_payload
    uri = URI("http://example.com/k")
    req = @client.send(:build_http_request, :put, uri, StringIO.new("data"),
                       { "content-type" => "text/plain" }, stream: true, content_length: 4)
    assert_equal "UNSIGNED-PAYLOAD", req["x-amz-content-sha256"]
    assert req["content-length"]
  end

  def test_build_http_request_unsupported_method
    assert_raises(ArgumentError) do
      @client.send(:build_http_request, :options, URI("http://example.com/"), nil, {})
    end
  end

  # --- encode_query string passthrough ---

  def test_encode_query_string_passthrough
    result = @client.send(:encode_query, "raw=query")
    assert_equal "raw=query", result
  end

  # --- compute_upload_session_metadata rescue ---

  def test_compute_upload_session_metadata_nonexistent_file
    meta = @client.send(:compute_upload_session_metadata, "/nonexistent", 0)
    assert meta[:upload_session_id]
  end

  # --- load_download_state rescue ---

  def test_load_download_state_corrupt_file
    Dir.mktmpdir do |dir|
      path = File.join(dir, "state.json")
      File.write(path, "not json")
      assert_nil @client.send(:load_download_state, path, key: "k", part_size: 5_242_880, total_size: 10_485_760)
    end
  end

  # --- human_readable_size edge cases ---

  def test_human_readable_size_nil
    assert_equal "0 B", @client.human_readable_size(nil)
  end

  def test_human_readable_size_exact_units
    assert_equal "1.00 KB", @client.human_readable_size(1024)
    assert_equal "1.00 MB", @client.human_readable_size(1024 * 1024)
    assert_equal "1.00 GB", @client.human_readable_size(1024**3)
  end

  # --- parse_multipart_uploads_xml ---

  def test_parse_multipart_uploads_xml
    xml = %(<?xml version="1.0"?><ListMultipartUploadsResult><Upload><Key>k</Key><UploadId>uid-1</UploadId><Initiated>2024-01-01T00:00:00Z</Initiated><StorageClass>STANDARD</StorageClass></Upload></ListMultipartUploadsResult>)
    result = @client.send(:parse_multipart_uploads_xml, xml)
    assert_equal 1, result.size
    assert_equal "uid-1", result[0][:upload_id]
  end

  def test_parse_multipart_uploads_xml_empty
    xml = %(<?xml version="1.0"?><ListMultipartUploadsResult></ListMultipartUploadsResult>)
    assert_equal [], @client.send(:parse_multipart_uploads_xml, xml)
  end

  # --- parse_parts_xml ---

  def test_parse_parts_xml
    xml = %(<?xml version="1.0"?><ListPartsResult><Part><PartNumber>1</PartNumber><ETag>e1</ETag><Size>100</Size><LastModified>2024-01-01T00:00:00Z</LastModified></Part></ListPartsResult>)
    result = @client.send(:parse_parts_xml, xml)
    assert_equal 1, result.size
    assert_equal "e1", result[0][:etag]
  end

  def test_parse_parts_xml_empty
    xml = %(<?xml version="1.0"?><ListPartsResult></ListPartsResult>)
    assert_equal [], @client.send(:parse_parts_xml, xml)
  end

  # --- build_complete_multipart_xml ---

  def test_build_complete_multipart_xml
    parts = [{ part_number: 1, etag: "e1" }, { part_number: 2, etag: "e2" }]
    xml = @client.send(:build_complete_multipart_xml, parts)
    assert_includes xml, "<PartNumber>1</PartNumber>"
    assert_includes xml, "<ETag>e1</ETag>"
    assert_includes xml, "<PartNumber>2</PartNumber>"
    assert_includes xml, "<ETag>e2</ETag>"
  end

  # --- now_mono ---

  def test_now_mono_returns_float
    assert_kind_of Float, @client.now_mono
  end

  # --- generate_presigned_url ---

  def test_generate_presigned_url
    uri = URI("http://example.com/k")
    url = @client.send(:generate_presigned_url, uri, method: :get, expires_in: 3600)
    assert_includes url, "X-Amz-Signature"
  end

  # --- extract_metadata_from_headers no metadata ---

  def test_extract_metadata_from_headers_no_metadata
    resp = OpenStruct.new
    def resp.each_header(&block); end
    assert_equal({}, @client.extract_metadata_from_headers(resp))
  end

  # --- setup_logger with log_color ---

  def test_setup_logger_log_color
    client = S3Client.new(
      bucket: "b", region: "us-east-1",
      access_key_id: "AK", secret_access_key: "SK",
      endpoint: "http://127.0.0.1:19999",
      log_color: true,
      logger: Logger.new(File::NULL)
    )
    client.log_info "test UPLOAD message with ✓ and ✗ and ↻ and already exists"
    assert client.instance_variable_get(:@log_color)
  end

  def test_setup_logger_with_log_file
    Dir.mktmpdir do |dir|
      log_path = File.join(dir, "test.log")
      client = S3Client.new(
        bucket: "b", region: "us-east-1",
        access_key_id: "AK", secret_access_key: "SK",
        endpoint: "http://127.0.0.1:19999",
        log_file: log_path
      )
      client.log_info "file log test"
      assert File.exist?(log_path)
    end
  end

  # --- log_request_details / log_response_details ---

  def test_log_request_details_debug_mode
    client = S3Client.new(
      bucket: "b", region: "us-east-1",
      access_key_id: "AK", secret_access_key: "SK",
      endpoint: "http://127.0.0.1:19999",
      debug: true,
      logger: Logger.new(File::NULL)
    )
    client.log_request_details("GET", URI("http://example.com/test"), 100)
  end

  def test_log_request_details_non_debug
    @client.log_request_details("GET", URI("http://example.com/test"), 100)
  end

  def test_log_response_details_debug_mode
    client = S3Client.new(
      bucket: "b", region: "us-east-1",
      access_key_id: "AK", secret_access_key: "SK",
      endpoint: "http://127.0.0.1:19999",
      debug: true,
      logger: Logger.new(File::NULL)
    )
    resp = OpenStruct.new(code: "200", message: "OK", body: "short body")
    def resp.each_header(&b)
      b.call("content-type", "text/plain")
    end
    client.log_response_details(resp)
  end

  def test_log_response_details_long_body
    client = S3Client.new(
      bucket: "b", region: "us-east-1",
      access_key_id: "AK", secret_access_key: "SK",
      endpoint: "http://127.0.0.1:19999",
      debug: true,
      logger: Logger.new(File::NULL)
    )
    resp = OpenStruct.new(code: "200", message: "OK", body: "x" * 2000)
    def resp.each_header(&block); end
    client.log_response_details(resp)
  end

  def test_log_response_details_empty_body
    client = S3Client.new(
      bucket: "b", region: "us-east-1",
      access_key_id: "AK", secret_access_key: "SK",
      endpoint: "http://127.0.0.1:19999",
      debug: true,
      logger: Logger.new(File::NULL)
    )
    resp = OpenStruct.new(code: "200", message: "OK", body: nil)
    def resp.each_header(&block); end
    client.log_response_details(resp)
  end

  def test_log_response_details_non_debug
    resp = OpenStruct.new(code: "200", message: "OK", body: "test")
    def resp.each_header(&block); end
    @client.log_response_details(resp)
  end

  # --- emit_event callback error handling ---

  def test_emit_event_callback_raises
    S3Client.clear_callbacks!
    S3Client.on(:upload_start) { raise "boom" }
    @client.emit_event(:upload_start, "arg1")
  ensure
    S3Client.clear_callbacks!
  end

  # --- thread_log_debug ---

  def test_thread_log_debug
    S3Client.clear_callbacks!
    entries = []
    S3Client.on(:log) { |*args| entries << args }
    @client.thread_log_debug("debug msg", "t0")
    assert_equal 1, entries.size
    assert_equal :debug, entries[0][0]
  ensure
    S3Client.clear_callbacks!
  end

  # --- apply_signer_headers! ---

  def test_apply_signer_headers_string_body
    uri = URI("http://example.com/test")
    req = Net::HTTP::Put.new(uri)
    req["content-type"] = "text/plain"
    @client.send(:apply_signer_headers!, req, "PUT", uri, "hello")
    assert req["authorization"] || req["Authorization"]
  end

  def test_apply_signer_headers_io_body
    uri = URI("http://example.com/test")
    req = Net::HTTP::Put.new(uri)
    Dir.mktmpdir do |dir|
      path = File.join(dir, "signer_io.bin")
      File.write(path, "stream data")
      File.open(path, "rb") do |io|
        @client.send(:apply_signer_headers!, req, "PUT", uri, io)
        assert_equal "UNSIGNED-PAYLOAD", req["x-amz-content-sha256"]
      end
    end
  end

  # --- http_start ---

  def test_http_start_opens_connection
    uri = URI("http://127.0.0.1:19999")
    assert_raises(Errno::ECONNREFUSED, Errno::EHOSTUNREACH, SocketError) do
      @client.send(:http_start, uri) { |http| }
    end
  end

  # --- load_download_state valid path ---

  def test_load_download_state_valid
    Dir.mktmpdir do |dir|
      state_file = File.join(dir, "dl_state.json")
      state = DownloadState.new(
        key: "k", local_path: "/tmp/f",
        part_size: 5_242_880, total_size: 10_485_760,
        parts: { 1 => 5_242_880 }, resume_count: 2
      )
      state.save_to_file(state_file)
      loaded = @client.send(:load_download_state, state_file,
                            key: "k", part_size: 5_242_880, total_size: 10_485_760)
      assert_equal "k", loaded.key
      assert_equal 3, loaded.resume_count
      assert loaded.resumed_at
    end
  end

  # --- build_http_request with IO body_stream ---

  def test_build_http_request_io_body_stream
    uri = URI("http://example.com/test")
    Dir.mktmpdir do |dir|
      path = File.join(dir, "stream.bin")
      File.write(path, "stream data content")
      File.open(path, "rb") do |io|
        req = @client.send(:build_http_request, :put, uri, io,
                           { "content-type" => "text/plain" },
                           stream: true, content_length: 18)
        assert_equal "UNSIGNED-PAYLOAD", req["x-amz-content-sha256"]
        assert_equal "18", req["Content-Length"]
        assert_equal "text/plain", req["Content-Type"]
      end
    end
  end

  def test_build_http_request_io_body_stream_without_content_length
    uri = URI("http://example.com/test")
    Dir.mktmpdir do |dir|
      path = File.join(dir, "stream2.bin")
      File.write(path, "data")
      File.open(path, "rb") do |io|
        req = @client.send(:build_http_request, :put, uri, io, {},
                           stream: true)
        assert_equal "UNSIGNED-PAYLOAD", req["x-amz-content-sha256"]
      end
    end
  end

  # --- generate_presigned_url ---

  def test_generate_presigned_url_put
    uri = URI("http://example.com/upload.bin")
    url = @client.send(:generate_presigned_url, uri, method: :put, expires_in: 600)
    assert_includes url, "X-Amz-Signature"
  end

  # --- validate_bucket! ---

  def test_validate_bucket_rejects_invalid_characters
    assert_raises(ArgumentError) { S3BaseClient.validate_bucket!("my<bucket") }
    assert_raises(ArgumentError) { S3BaseClient.validate_bucket!("my>bucket") }
    assert_raises(ArgumentError) { S3BaseClient.validate_bucket!("my\\bucket") }
    assert_raises(ArgumentError) { S3BaseClient.validate_bucket!("my{bucket") }
    assert_raises(ArgumentError) { S3BaseClient.validate_bucket!("my}bucket") }
    assert_raises(ArgumentError) { S3BaseClient.validate_bucket!("my^bucket") }
    assert_raises(ArgumentError) { S3BaseClient.validate_bucket!("my`bucket") }
    assert_raises(ArgumentError) { S3BaseClient.validate_bucket!("my|bucket") }
    assert_raises(ArgumentError) { S3BaseClient.validate_bucket!("my\x00bucket") }
  end

  def test_validate_bucket_accepts_valid_names
    S3BaseClient.validate_bucket!("my-bucket")
    S3BaseClient.validate_bucket!("b")
    S3BaseClient.validate_bucket!("my.bucket.name")
  end

  # --- validate_key! ---

  def test_validate_key_rejects_too_long
    long_key = "a" * 1025
    err = assert_raises(ArgumentError) { S3BaseClient.validate_key!(long_key) }
    assert_includes err.message, "1024"
  end

  def test_validate_key_rejects_null_bytes
    err = assert_raises(ArgumentError) { S3BaseClient.validate_key!("key\x00name") }
    assert_includes err.message, "null"
  end

  def test_validate_key_accepts_valid_keys
    S3BaseClient.validate_key!("normal/key.txt")
    S3BaseClient.validate_key!("a" * 1024)
  end

  # --- delete_object non-204 ---

  def test_delete_object_non_204_response
    @client.define_singleton_method(:_ops_execute) do |method, key, bucket: nil, **, &block|
      resp = Net::HTTPNotFound.new(1.0, 404, "Not Found")
      resp.instance_variable_set(:@read, true)
      block.call(resp)
    end
    err = assert_raises(S3BaseClient::S3Error) { @client.delete_object(key: "k") }
    assert_includes err.message, "Delete failed"
  ensure
    begin
      @client.singleton_class.remove_method(:_ops_execute)
    rescue StandardError
      nil
    end
  end

  # --- abort_multipart_upload non-204 ---

  def test_abort_multipart_upload_non_204_response
    @client.define_singleton_method(:_ops_execute) do |method, key, bucket: nil, **, &block|
      resp = Net::HTTPNotFound.new(1.0, 404, "Not Found")
      resp.instance_variable_set(:@read, true)
      block.call(resp)
    end
    err = assert_raises(S3BaseClient::S3Error) { @client.abort_multipart_upload(key: "k", upload_id: "bad") }
    assert_includes err.message, "Abort multipart upload failed"
  ensure
    begin
      @client.singleton_class.remove_method(:_ops_execute)
    rescue StandardError
      nil
    end
  end

  # --- download_file rescue paths ---

  def test_download_file_standard_error_rescue
    @client.define_singleton_method(:perform_request) do |method, key, headers: {}, streaming: false, bucket: nil, &block|
      raise StandardError, "Something went wrong"
    end
    err = assert_raises(S3BaseClient::DownloadError) do
      @client.download_file(key: "k", local_path: "/tmp/_nonexistent_dl_test")
    end
    assert_includes err.message, "Download failed"
  ensure
    begin
      @client.singleton_class.remove_method(:perform_request)
    rescue StandardError
      nil
    end
  end

  def test_download_file_download_error_passthrough
    @client.define_singleton_method(:perform_request) do |method, key, headers: {}, streaming: false, bucket: nil, &block|
      raise S3BaseClient::DownloadError, "Already wrapped"
    end
    err = assert_raises(S3BaseClient::DownloadError) do
      @client.download_file(key: "k", local_path: "/tmp/_nonexistent_dl_test2")
    end
    assert_includes err.message, "Already wrapped"
  ensure
    begin
      @client.singleton_class.remove_method(:perform_request)
    rescue StandardError
      nil
    end
  end

  def test_download_file_s3_error_passthrough
    @client.define_singleton_method(:perform_request) do |method, key, headers: {}, streaming: false, bucket: nil, &block|
      raise S3BaseClient::S3Error.new("500", "S3 upstream error")
    end
    err = assert_raises(S3BaseClient::S3Error) do
      @client.download_file(key: "k", local_path: "/tmp/_nonexistent_dl_test3")
    end
    assert_includes err.message, "S3 upstream error"
  ensure
    begin
      @client.singleton_class.remove_method(:perform_request)
    rescue StandardError
      nil
    end
  end

  # --- JSON log formatter ---

  def test_setup_logger_json_format
    output = StringIO.new
    logger = Logger.new(output)
    client = S3Client.new(
      bucket: "b", region: "us-east-1",
      access_key_id: "AK", secret_access_key: "SK",
      endpoint: "http://127.0.0.1:19999",
      log_format: :json,
      logger: logger
    )
    assert_equal :json, client.instance_variable_get(:@log_format)
    client.log_info "json formatted message"
    output.rewind
    line = output.read
    parsed = JSON.parse(line.lines.last)
    assert_equal "INFO", parsed["severity"]
    assert_includes parsed["message"], "json formatted message"
    assert_equal "s3_client", parsed["component"]
  end

  def test_normalize_deprecated_opts_warns_and_maps_access_key
    _, err = capture_io do
      S3Client.new(
        bucket: "b", region: "us-east-1",
        access_key: "AK", secret_access_key: "SK",
        endpoint: "http://127.0.0.1:19999"
      )
    end
    assert_includes err, "[DEPRECATION]"
    assert_includes err, "`access_key:` is deprecated, use `access_key_id:` instead."
  end

  def test_normalize_deprecated_opts_warns_and_maps_secret_key
    _, err = capture_io do
      S3Client.new(
        bucket: "b", region: "us-east-1",
        access_key_id: "AK", secret_key: "SK",
        endpoint: "http://127.0.0.1:19999"
      )
    end
    assert_includes err, "[DEPRECATION]"
    assert_includes err, "`secret_key:` is deprecated, use `secret_access_key:` instead."
  end

  def test_normalize_deprecated_opts_no_warning_with_valid_keys
    _out, err = capture_io do
      S3Client.new(
        bucket: "b", region: "us-east-1",
        access_key_id: "AK", secret_access_key: "SK",
        endpoint: "http://127.0.0.1:19999"
      )
    end
    assert_empty err
  end
end
