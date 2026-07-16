# frozen_string_literal: true

require_relative "../../test_helper"
require_relative "../../../src/s3_client"
require_relative "../../../src/s3_multi_bucket_client"
require_relative "../../../src/extras/bulk_upload_worker"
require_relative "../../../src/extras/bulk_uploader"
require_relative "../../../src/extras/bulk_downloader"

class CoverageGapsUnitTest < Minitest::Test
  include S3TestHelpers

  # ── validator.rb: validate_endpoint! error paths (lines 64, 70, 73) ──

  def test_validate_endpoint_non_http_scheme
    assert_raises(ArgumentError) { S3Client.validate_endpoint!("ftp://bucket.s3.com") }
  end

  def test_validate_endpoint_empty_hostname
    assert_raises(ArgumentError) { S3Client.validate_endpoint!("http://") }
  end

  def test_validate_endpoint_invalid_uri
    assert_raises(ArgumentError) { S3Client.validate_endpoint!("http://[invalid") }
  end

  # ── base_client.rb: validate_xml_response! error raise (lines 301-302) ──

  def test_validate_xml_response_raises_on_non_xml
    client = build_s3_client
    resp = OpenStruct.new(
      "content-type" => "text/html",
      body: "<html><body>Error</body></html>",
      code: "200"
    )
    error = assert_raises(S3Errors::S3Error) do
      client.send(:validate_xml_response!, resp, "test_op")
    end
    assert_includes error.message, "expected XML response"
    assert_includes error.message, "text/html"
  end

  # ── bulk_downloader.rb: DownloadError rescue + fatal path (lines 113-115, 117-119, 128-129) ──

  def test_bulk_downloader_download_error_rescue
    client = build_s3_client
    client.define_singleton_method(:list_objects) do |**_kwargs|
      { contents: [{ key: "a.txt", size: 10, last_modified: "2024-01-01", storage_class: "STANDARD", etag: '"abc"' }],
        common_prefixes: [], is_truncated: false, next_continuation_token: nil }
    end
    client.define_singleton_method(:download_file) do |**_kwargs|
      raise S3Errors::DownloadError, "Download failed: 403 Forbidden"
    end

    errors = []
    downloader = S3BulkDownloader.new(
      client: client, local_directory: File.join(TEST_TMP, "dl_err"),
      max_files: 1,
      on_file_error: ->(key, _path, err, _idx, _total) { errors << { key: key, error: err } }
    )
    result = downloader.run!

    assert_equal 1, result[:failed].size
    assert_equal "a.txt", result[:failed][0][:key]
    assert_equal 1, errors.size
    assert_includes errors[0][:error].message, "403 Forbidden"
  ensure
    client.singleton_class.remove_method(:list_objects) if client.respond_to?(:list_objects)
    client.singleton_class.remove_method(:download_file) if client.respond_to?(:download_file)
  end

  def test_bulk_downloader_fatal_download_error_sets_stop_flag
    client = build_s3_client
    client.define_singleton_method(:list_objects) do |**_kwargs|
      { contents: [
        { key: "ok.txt", size: 4, last_modified: "2024-01-01", storage_class: "STANDARD", etag: '"x"' },
        { key: "bad.txt", size: 4, last_modified: "2024-01-01", storage_class: "STANDARD", etag: '"y"' }
      ], common_prefixes: [], is_truncated: false, next_continuation_token: nil }
    end
    client.define_singleton_method(:download_file) do |**kwargs|
      raise S3Errors::DownloadError, "AccessDenied" if kwargs[:key] == "bad.txt"

      File.binwrite(kwargs[:local_path], "data")
      { size: 4 }
    end

    errors = []
    downloader = S3BulkDownloader.new(
      client: client, local_directory: File.join(TEST_TMP, "dl_fatal"),
      max_files: 1,
      on_file_error: ->(key, _path, err, _idx, _total) { errors << { key: key, error: err } }
    )
    result = downloader.run!

    assert result[:failed].size >= 1
    assert errors.any? { |e| e[:key] == "bad.txt" }
  ensure
    client.singleton_class.remove_method(:list_objects) if client.respond_to?(:list_objects)
    client.singleton_class.remove_method(:download_file) if client.respond_to?(:download_file)
  end

  def test_bulk_downloader_non_fatal_download_error_no_stop
    client = build_s3_client
    client.define_singleton_method(:list_objects) do |**_kwargs|
      { contents: [
        { key: "ok.txt", size: 4, last_modified: "2024-01-01", storage_class: "STANDARD", etag: '"x"' },
        { key: "bad.txt", size: 4, last_modified: "2024-01-01", storage_class: "STANDARD", etag: '"y"' }
      ], common_prefixes: [], is_truncated: false, next_continuation_token: nil }
    end
    client.define_singleton_method(:download_file) do |**kwargs|
      raise S3Errors::DownloadError, "NetworkError timeout" if kwargs[:key] == "bad.txt"

      File.binwrite(kwargs[:local_path], "data")
      { size: 4 }
    end

    downloader = S3BulkDownloader.new(
      client: client, local_directory: File.join(TEST_TMP, "dl_nonfatal"),
      max_files: 1
    )
    result = downloader.run!

    assert_equal 1, result[:downloaded].size
    assert_equal 1, result[:failed].size
  ensure
    client.singleton_class.remove_method(:list_objects) if client.respond_to?(:list_objects)
    client.singleton_class.remove_method(:download_file) if client.respond_to?(:download_file)
  end

  # ── xml_helpers.rb: parse_buckets_xml (lines 105-108, 113) ──

  def test_parse_buckets_xml_with_buckets
    client = build_s3_client
    xml = <<~XML
      <?xml version="1.0" encoding="UTF-8"?>
      <ListAllMyBucketsResult>
        <Owner><ID>abc</ID></Owner>
        <Buckets>
          <Bucket><Name>bucket1</Name><CreationDate>2024-01-01T00:00:00Z</CreationDate></Bucket>
          <Bucket><Name>bucket2</Name><CreationDate>2024-06-15T12:00:00Z</CreationDate></Bucket>
        </Buckets>
      </ListAllMyBucketsResult>
    XML
    result = client.send(:parse_buckets_xml, xml)
    assert_equal 2, result.size
    assert_equal "bucket1", result[0][:name]
    assert_equal "2024-01-01T00:00:00Z", result[0][:creation_date]
    assert_equal "bucket2", result[1][:name]
  end

  def test_parse_buckets_xml_empty
    client = build_s3_client
    xml = <<~XML
      <?xml version="1.0" encoding="UTF-8"?>
      <ListAllMyBucketsResult>
        <Owner><ID>abc</ID></Owner>
        <Buckets></Buckets>
      </ListAllMyBucketsResult>
    XML
    result = client.send(:parse_buckets_xml, xml)
    assert_equal [], result
  end

  # ── s3_client/networking.rb: list_buckets (lines 180-191) ──

  def test_list_buckets_path_style
    client = build_s3_client
    buckets_xml = <<~XML
      <?xml version="1.0" encoding="UTF-8"?>
      <ListAllMyBucketsResult>
        <Owner><ID>abc</ID></Owner>
        <Buckets>
          <Bucket><Name>my-bucket</Name><CreationDate>2024-01-01T00:00:00Z</CreationDate></Bucket>
        </Buckets>
      </ListAllMyBucketsResult>
    XML

    mock_resp = Net::HTTPOK.new("1.1", "200", "OK")
    mock_resp.define_singleton_method(:body) { buckets_xml }
    mock_resp.define_singleton_method(:[]) { |k| k == "content-type" ? "application/xml" : nil }
    http_stub = Object.new
    http_stub.define_singleton_method(:request) { |_req| mock_resp }
    client.define_singleton_method(:_http_start) do |_uri, &block|
      block.call(http_stub)
    end

    result = client.list_buckets
    assert_equal 1, result.size
    assert_equal "my-bucket", result[0][:name]
  ensure
    client.singleton_class.remove_method(:_http_start) if client.respond_to?(:_http_start)
  end

  def test_list_buckets_virtual_hosted_style
    client = S3Client.new(
      region: "us-east-1", bucket: "b",
      access_key_id: "a", secret_access_key: "k",
      endpoint: "http://127.0.0.1:9999", endpoint_style: :virtual,
      logger: Logger.new(File::NULL)
    )
    buckets_xml = <<~XML
      <?xml version="1.0" encoding="UTF-8"?>
      <ListAllMyBucketsResult>
        <Owner><ID>abc</ID></Owner>
        <Buckets>
          <Bucket><Name>vh-bucket</Name><CreationDate>2024-01-01T00:00:00Z</CreationDate></Bucket>
        </Buckets>
      </ListAllMyBucketsResult>
    XML

    mock_resp = Net::HTTPOK.new("1.1", "200", "OK")
    mock_resp.define_singleton_method(:body) { buckets_xml }
    mock_resp.define_singleton_method(:[]) { |k| k == "content-type" ? "application/xml" : nil }
    http_stub = Object.new
    http_stub.define_singleton_method(:request) { |_req| mock_resp }
    client.define_singleton_method(:_http_start) do |_uri, &block|
      block.call(http_stub)
    end

    result = client.list_buckets
    assert_equal 1, result.size
    assert_equal "vh-bucket", result[0][:name]
  ensure
    client.singleton_class.remove_method(:_http_start) if client.respond_to?(:_http_start)
  end

  # ── s3_multi_bucket_client/networking.rb: list_buckets (lines 188-191) ──

  def test_mbc_list_buckets
    mbc = build_mbc_client
    buckets_xml = <<~XML
      <?xml version="1.0" encoding="UTF-8"?>
      <ListAllMyBucketsResult>
        <Owner><ID>abc</ID></Owner>
        <Buckets>
          <Bucket><Name>mbc-bucket</Name><CreationDate>2024-01-01T00:00:00Z</CreationDate></Bucket>
        </Buckets>
      </ListAllMyBucketsResult>
    XML

    mock_resp = Net::HTTPOK.new("1.1", "200", "OK")
    mock_resp.define_singleton_method(:body) { buckets_xml }
    mbc.define_singleton_method(:signed_request) do |_method, _uri|
      mock_resp
    end

    result = mbc.list_buckets
    assert_equal 1, result.size
    assert_equal "mbc-bucket", result[0][:name]
  ensure
    mbc.singleton_class.remove_method(:signed_request) if mbc.respond_to?(:signed_request)
  end

  # ── bulk_upload_worker.rb: skip_check with existing_map (lines 52-57) ──

  def test_skip_check_with_existing_map_hit
    worker = build_worker(skip_existing: true)
    file = { path: "/tmp/f.txt", key: "f.txt", size: 100 }
    existing_map = { "f.txt" => { size: 100, etag: '"abc"' } }
    tc = build_s3_client
    tc.define_singleton_method(:etag_matches_file?) { |_etag, _path| true }

    result = worker.skip_check(file, thread_client: tc, existing_map: existing_map)
    refute_nil result
    assert_equal "f.txt", result[:key]
    assert_includes result[:reason], "already exists"
  end

  def test_skip_check_with_existing_map_etag_mismatch
    worker = build_worker(skip_existing: true)
    file = { path: "/tmp/f.txt", key: "f.txt", size: 100 }
    existing_map = { "f.txt" => { size: 100, etag: '"abc"' } }
    tc = build_s3_client
    tc.define_singleton_method(:etag_matches_file?) { |_etag, _path| false }

    result = worker.skip_check(file, thread_client: tc, existing_map: existing_map)
    assert_nil result
  end

  def test_skip_check_with_existing_map_multipart_etag
    worker = build_worker(skip_existing: true)
    file = { path: "/tmp/f.txt", key: "f.txt", size: 100 }
    existing_map = { "f.txt" => { size: 100, etag: '"abc-5"' } }
    tc = build_s3_client
    tc.define_singleton_method(:etag_matches_file?) { |_etag, _path| true }

    result = worker.skip_check(file, thread_client: tc, existing_map: existing_map)
    refute_nil result
    assert_includes result[:reason], "already exists"
  end

  def test_skip_check_with_existing_map_size_mismatch
    worker = build_worker(skip_existing: true)
    file = { path: "/tmp/f.txt", key: "f.txt", size: 100 }
    existing_map = { "f.txt" => { size: 200, etag: '"abc"' } }

    result = worker.skip_check(file, existing_map: existing_map)
    assert_nil result
  end

  def test_skip_check_with_existing_map_key_missing
    worker = build_worker(skip_existing: true)
    file = { path: "/tmp/f.txt", key: "f.txt", size: 100 }
    existing_map = { "other.txt" => { size: 100, etag: '"abc"' } }

    result = worker.skip_check(file, existing_map: existing_map)
    assert_nil result
  end

  def test_skip_check_disabled
    worker = build_worker(skip_existing: false)
    file = { path: "/tmp/f.txt", key: "f.txt", size: 100 }
    existing_map = { "f.txt" => { size: 100, etag: '"abc"' } }

    result = worker.skip_check(file, existing_map: existing_map)
    assert_nil result
  end

  # ── bulk_upload_worker.rb: resume_upload success path (lines 95-96, 98) ──

  def test_resume_upload_success
    dir = File.join(TEST_TMP, "coverage_worker_resume")
    FileUtils.mkdir_p(dir)
    big_file = File.join(dir, "big.bin")
    File.write(big_file, "x" * 2_000_000)

    state_dir = File.join(dir, "states")
    FileUtils.mkdir_p(state_dir)

    worker = build_worker(resume: true, state_dir: state_dir, multipart_threshold: 1)

    mock_result = { etag: '"resumed-etag"', size: 2_000_000 }
    mock_tc = Object.new
    mock_tc.define_singleton_method(:resume_upload) do |**_kwargs|
      mock_result
    end

    file = { path: big_file, key: "big.bin", size: 2_000_000 }
    t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    result = worker.send(:resume_upload, mock_tc, "/fake/state.json", file, t0)

    assert_equal "big.bin", result[:key]
    assert_equal big_file, result[:path]
    assert_equal '"resumed-etag"', result[:etag]
    assert result[:elapsed] >= 0
  end

  # ── bulk_uploader.rb: fetch_existing_objects success path (lines 102-104, 107-109) ──

  def test_fetch_existing_objects_success
    dir = File.join(TEST_TMP, "coverage_uploader_exist")
    FileUtils.mkdir_p(dir)
    File.write(File.join(dir, "a.txt"), "data")

    test = self
    stub = proc do |_method, _key, **_opts, &blk|
      contents = [
        { key: "prefix/a.txt", size: 4, last_modified: "2024-01-01", storage_class: "STANDARD", etag: '"abc"' }
      ]
      blk.call(test.build_list_response(contents, [], false, nil))
    end

    client = build_s3_client
    client.define_singleton_method(:_ops_execute, &stub)

    uploader = S3BulkUploader.new(
      client: client, directory: dir, prefix: "prefix/",
      skip_existing: true, max_files: 1
    )
    map = uploader.send(:fetch_existing_objects)

    assert_equal 1, map.size
    assert_equal 4, map["prefix/a.txt"][:size]
    assert_equal '"abc"', map["prefix/a.txt"][:etag]
  ensure
    client.singleton_class.remove_method(:_ops_execute) if client.respond_to?(:_ops_execute)
  end

  # ── bulk_uploader.rb: handle_upload_error fatal path (lines 173-174) ──

  def test_handle_upload_error_fatal_sets_stop_flag
    dir = File.join(TEST_TMP, "coverage_uploader_fatal")
    FileUtils.mkdir_p(dir)
    File.write(File.join(dir, "f.txt"), "data")

    client = build_s3_client
    uploader = S3BulkUploader.new(
      client: client, directory: dir, max_files: 1
    )

    errors = []
    uploader.instance_variable_set(:@on_file_error, ->(_p, _k, _e, _i, _t) { errors << true })

    mutex = Mutex.new
    failed = []
    stop_flag = [false]
    stop_mutex = Mutex.new

    file = { path: "/tmp/f.txt", key: "f.txt" }
    error = S3Errors::S3Error.new("403", "AccessDenied")

    fatal_logged = [false]
    uploader.send(:handle_upload_error, error, file, client, 1, 1, mutex, failed, stop_mutex, stop_flag, fatal_logged)

    assert_equal 1, failed.size
    assert stop_mutex.synchronize { stop_flag[0] }
  end

  def test_handle_upload_error_non_fatal_no_stop_flag
    dir = File.join(TEST_TMP, "coverage_uploader_nonfatal")
    FileUtils.mkdir_p(dir)
    File.write(File.join(dir, "f.txt"), "data")

    client = build_s3_client
    uploader = S3BulkUploader.new(
      client: client, directory: dir, max_files: 1
    )

    mutex = Mutex.new
    failed = []
    stop_flag = [false]
    stop_mutex = Mutex.new

    file = { path: "/tmp/f.txt", key: "f.txt" }
    error = S3Errors::S3Error.new("500", "ServerError")

    fatal_logged = [false]
    uploader.send(:handle_upload_error, error, file, client, 1, 1, mutex, failed, stop_mutex, stop_flag, fatal_logged)

    assert_equal 1, failed.size
    refute stop_mutex.synchronize { stop_flag[0] }
  end

  # ── bulk_upload_worker.rb: skip_check head-based paths (lines 59-69) ──

  def test_skip_check_head_single_bucket
    worker = build_worker(skip_existing: true)
    tc = build_s3_client
    tc.define_singleton_method(:single_bucket?) { true }
    tc.define_singleton_method(:head_object) do |**_kwargs|
      { content_length: 100, etag: '"abc"', content_type: "text/plain" }
    end
    tc.define_singleton_method(:etag_matches_file?) { |_etag, _path| true }

    Dir.mktmpdir do |dir|
      path = File.join(dir, "f.txt")
      File.write(path, "x" * 100)
      file = { path: path, key: "f.txt", size: 100 }
      result = worker.skip_check(file, thread_client: tc)
      assert result
      assert_equal "f.txt", result[:key]
    end
  end

  def test_skip_check_head_not_found
    worker = build_worker(skip_existing: true)
    tc = build_s3_client
    tc.define_singleton_method(:single_bucket?) { false }
    tc.define_singleton_method(:head_object) do |**_kwargs|
      raise S3BaseClient::S3Error.new("404", "Not Found")
    end

    file = { path: "/tmp/f.txt", key: "f.txt", size: 100 }
    result = worker.skip_check(file, thread_client: tc)
    assert_nil result
  end

  def test_skip_check_head_size_mismatch
    worker = build_worker(skip_existing: true)
    tc = build_s3_client
    tc.define_singleton_method(:single_bucket?) { true }
    tc.define_singleton_method(:head_object) do |**_kwargs|
      { content_length: 200, etag: '"abc"', content_type: "text/plain" }
    end

    file = { path: "/tmp/f.txt", key: "f.txt", size: 100 }
    result = worker.skip_check(file, thread_client: tc)
    assert_nil result
  end

  def test_skip_check_head_etag_no_match
    worker = build_worker(skip_existing: true)
    tc = build_s3_client
    tc.define_singleton_method(:single_bucket?) { true }
    tc.define_singleton_method(:head_object) do |**_kwargs|
      { content_length: 100, etag: '"abc"', content_type: "text/plain" }
    end
    tc.define_singleton_method(:etag_matches_file?) { |_etag, _path| false }

    file = { path: "/tmp/f.txt", key: "f.txt", size: 100 }
    result = worker.skip_check(file, thread_client: tc)
    assert_nil result
  end

  def test_skip_check_head_raises_non_404
    worker = build_worker(skip_existing: true)
    tc = build_s3_client
    tc.define_singleton_method(:single_bucket?) { true }
    tc.define_singleton_method(:head_object) do |**_kwargs|
      raise S3BaseClient::S3Error.new("500", "Server Error")
    end

    file = { path: "/tmp/f.txt", key: "f.txt", size: 100 }
    assert_raises(S3BaseClient::S3Error) { worker.skip_check(file, thread_client: tc) }
  end

  # ── bulk_upload_worker.rb: resume_eligible? (lines 83-86) ──

  def test_resume_eligible
    worker = build_worker(resume: true, multipart_threshold: 100)
    sf = File.join(TEST_TMP, "resume_state.json")
    File.write(sf, "{}")
    file = { path: "/tmp/f.txt", key: "f.txt", size: 200 }
    assert worker.send(:resume_eligible?, sf, file)
  ensure
    FileUtils.rm_f(sf)
  end

  def test_resume_not_eligible_no_state_file
    worker = build_worker(resume: true, multipart_threshold: 100)
    file = { path: "/tmp/f.txt", key: "f.txt", size: 200 }
    refute worker.send(:resume_eligible?, nil, file)
  end

  def test_resume_not_eligible_resume_disabled
    worker = build_worker(resume: false, multipart_threshold: 100)
    sf = File.join(TEST_TMP, "resume_state.json")
    File.write(sf, "{}")
    file = { path: "/tmp/f.txt", key: "f.txt", size: 200 }
    refute worker.send(:resume_eligible?, sf, file)
  ensure
    FileUtils.rm_f(sf)
  end

  def test_resume_not_eligible_file_too_small
    worker = build_worker(resume: true, multipart_threshold: 100)
    sf = File.join(TEST_TMP, "resume_state.json")
    File.write(sf, "{}")
    file = { path: "/tmp/f.txt", key: "f.txt", size: 50 }
    refute worker.send(:resume_eligible?, sf, file)
  ensure
    FileUtils.rm_f(sf)
  end

  # ── bulk_upload_worker.rb: build_upload_opts (lines 106-116) ──

  def test_build_upload_opts_with_cache_control
    worker = build_worker
    worker.instance_variable_set(:@content_type, "text/plain")
    worker.instance_variable_set(:@cache_control, "max-age=3600")
    worker.instance_variable_set(:@metadata, { "env" => "test" })

    opts = worker.send(:build_upload_opts, { path: "/tmp/f.txt", key: "f.txt", size: 100 }, nil)
    assert_equal "text/plain", opts[:content_type]
    assert_equal "max-age=3600", opts[:cache_control]
    assert opts.key?(:metadata)
  end

  def test_build_upload_opts_auto_content_type
    worker = build_worker
    worker.instance_variable_set(:@content_type, nil)

    opts = worker.send(:build_upload_opts, { path: "/tmp/f.txt", key: "f.txt", size: 100 }, nil)
    assert opts[:content_type]
  end

  def test_build_upload_opts_with_state_file
    worker = build_worker(multipart_threshold: 100)
    sf = File.join(TEST_TMP, "opts_state.json")
    File.write(sf, "{}")
    opts = worker.send(:build_upload_opts, { path: "/tmp/f.txt", key: "f.txt", size: 200 }, sf)
    assert_equal sf, opts[:state_file]
  ensure
    FileUtils.rm_f(sf)
  end

  # ── bulk_upload_worker.rb: state_file_for (line 119) ──

  def test_state_file_for_key
    worker = build_worker(state_dir: "/tmp/states")
    result = worker.send(:state_file_for, "path/to/file.txt")
    assert_includes result, "/tmp/states/"
    assert_includes result, ".s3state.json"
  end

  def test_state_file_for_long_key
    worker = build_worker(state_dir: "/tmp/states")
    long_key = "a" * 200
    result = worker.send(:state_file_for, long_key)
    basename = File.basename(result)
    assert basename.length <= 120 + ".s3state.json".length
  end

  # ── bulk_upload_worker.rb: detect_content_type (line 122) ──

  def test_detect_content_type
    worker = build_worker
    assert_equal "text/plain", worker.send(:detect_content_type, "/tmp/file.txt")
    assert_equal "application/json", worker.send(:detect_content_type, "/tmp/file.json")
    assert_equal "application/octet-stream", worker.send(:detect_content_type, "/tmp/file.xyz")
  end

  def test_detect_content_type_caches
    worker = build_worker
    worker.send(:detect_content_type, "/tmp/file.txt")
    cache = worker.instance_variable_get(:@content_type_cache)
    assert cache.key?(".txt")
  end

  # ── bulk_upload_worker.rb: build_result (line 132) ──

  def test_build_worker_result
    worker = build_worker
    t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    file = { path: "/tmp/f.txt", key: "f.txt", size: 100 }
    result = { etag: '"abc"' }
    r = worker.send(:build_result, file, result, t0)
    assert_equal "f.txt", r[:key]
    assert_equal "/tmp/f.txt", r[:path]
    assert r[:elapsed] >= 0
  end

  # ── bulk_upload_worker.rb: upload normal + resume fallback (lines 30-48) ──

  def test_worker_upload_normal_flow
    dir = File.join(TEST_TMP, "worker_normal")
    FileUtils.mkdir_p(dir)
    big_file = File.join(dir, "big.bin")
    File.write(big_file, "x" * 2_000_000)

    worker = build_worker(skip_existing: false, multipart_threshold: 100 * 1024 * 1024)

    mock_client = build_s3_client
    mock_client.define_singleton_method(:upload_file) do |**_kwargs|
      { etag: '"abc123"', size: 2_000_000 }
    end

    file = { path: big_file, key: "big.bin", size: 2_000_000 }
    result = worker.upload(file, thread_client: mock_client)

    assert_equal "big.bin", result[:key]
    assert_equal big_file, result[:path]
    assert result[:elapsed] >= 0
  ensure
    FileUtils.rm_rf(dir)
  end

  def test_worker_upload_resume_fallback_on_error
    dir = File.join(TEST_TMP, "worker_resume_err")
    FileUtils.mkdir_p(dir)
    big_file = File.join(dir, "big.bin")
    File.write(big_file, "x" * 2_000_000)

    state_dir = File.join(dir, "states")
    FileUtils.mkdir_p(state_dir)
    File.write(File.join(state_dir, "big.bin.s3state.json"), "{}")

    worker = build_worker(resume: true, state_dir: state_dir, multipart_threshold: 1)

    mock_client = build_s3_client
    call_count = 0
    mock_client.define_singleton_method(:resume_upload) do |**_kwargs|
      call_count += 1
      raise S3BaseClient::S3Error.new("500", "Server Error") if call_count == 1

      { etag: '"resumed"' }
    end
    mock_client.define_singleton_method(:upload_file) do |**_kwargs|
      { etag: '"uploaded"' }
    end

    file = { path: big_file, key: "big.bin", size: 2_000_000 }
    result = worker.upload(file, thread_client: mock_client)
    assert result
  ensure
    FileUtils.rm_rf(dir)
  end

  # ── s3_multi_bucket_client/download.rb: download_directory (line 46) ──

  def test_mbc_download_directory
    dir = File.join(TEST_TMP, "coverage_mbc_dl")
    FileUtils.mkdir_p(dir)
    store_dir = File.join(dir, "store")
    FileUtils.mkdir_p(store_dir)
    dl_dir = File.join(dir, "downloads")

    mbc = build_mbc_client

    test = self
    stub = proc do |_method, _key, **_opts, &blk|
      contents = []
      blk.call(OpenStruct.new(body: test.build_list_xml(contents, [], false, nil), code: "200", message: "OK"))
    end
    mbc.define_singleton_method(:_ops_execute, &stub)

    result = mbc.download_directory(
      bucket: "b", local_directory: dl_dir, prefix: "test/"
    )

    assert_equal 0, result[:total]
    assert_empty result[:downloaded]
  ensure
    mbc.singleton_class.remove_method(:_ops_execute) if mbc.respond_to?(:_ops_execute)
  end

  private

  def build_s3_client
    S3Client.new(
      region: "us-east-1", bucket: "b",
      access_key_id: "a", secret_access_key: "k",
      endpoint: "http://127.0.0.1:1", endpoint_style: :path,
      logger: Logger.new(File::NULL)
    )
  end

  def build_mbc_client
    S3MultiBucketClient.new(
      region: "us-east-1", default_bucket: "b",
      access_key_id: "a", secret_access_key: "k",
      endpoint: "http://127.0.0.1:1", endpoint_style: :path,
      logger: Logger.new(File::NULL)
    )
  end

  def build_worker(skip_existing: false, resume: false, state_dir: nil, multipart_threshold: 100 * 1024 * 1024)
    client = build_s3_client
    BulkUploadWorker.new(
      client: client, bucket: "b",
      multipart_threshold: multipart_threshold,
      skip_existing: skip_existing, resume: resume,
      state_dir: state_dir
    )
  end
end
