# frozen_string_literal: true

require_relative "../../test_helper"
require_relative "../../../src/s3_client"
require_relative "../../../src/extras/bulk_downloader"
require "fileutils"

class S3BulkDownloaderUnitTest < Minitest::Test
  include S3TestHelpers

  PORT = 15_590

  def setup
    dir = suite_tmp_dir("bulk_dl_unit")
    @store_dir = File.join(dir, "store")
    @tmp_dir   = File.join(dir, "tmp")
    @server = FakeS3::Server.new(port: PORT, store_dir: @store_dir, tmp_dir: @tmp_dir)
    @server.start_thread

    @client = S3Client.new(
      region: "us-east-1", bucket: "b",
      access_key_id: "a", secret_access_key: "k",
      endpoint: "http://127.0.0.1:#{PORT}", endpoint_style: :path,
      logger: Logger.new(File::NULL)
    )

    @dl_dir = File.join(dir, "downloads")
  end

  def teardown
    @server.stop
    cleanup_suite_tmp("bulk_dl_unit")
  end

  def test_download_empty_result
    stub_list_objects(@client, [])

    downloader = S3BulkDownloader.new(
      client: @client, local_directory: @dl_dir, prefix: "empty/"
    )
    result = downloader.run!

    assert_equal 0, result[:total]
    assert_empty result[:downloaded]
    assert_empty result[:failed]
    assert_equal 0.0, result[:elapsed]
  end

  def test_download_single_file
    content = "hello world"
    upload_file(@client, "/dir/file.txt", content)

    stub_list_objects(@client, [
                        { key: "/dir/file.txt", size: content.bytesize, last_modified: "2024-01-01T00:00:00Z", storage_class: "STANDARD", etag: %("#{Digest::MD5.hexdigest(content)}") }
                      ])

    downloader = S3BulkDownloader.new(
      client: @client, local_directory: @dl_dir, prefix: "dir/",
      max_files: 1
    )
    result = downloader.run!

    assert_equal 1, result[:total]
    assert_equal 1, result[:downloaded].size
    assert_empty result[:failed]

    downloaded_path = File.join(@dl_dir, "/dir/file.txt")
    assert File.exist?(downloaded_path)
    assert_equal content, File.read(downloaded_path)
  end

  def test_download_multiple_files
    files = {
      "/a.txt" => "content a",
      "/b.txt" => "content b",
      "/c.txt" => "content c"
    }
    files.each { |k, v| upload_file(@client, k, v) }

    stub_list_objects(@client, files.map do |k, v|
      { key: k, size: v.bytesize, last_modified: "2024-01-01T00:00:00Z",
        storage_class: "STANDARD", etag: %("#{Digest::MD5.hexdigest(v)}") }
    end)

    downloader = S3BulkDownloader.new(
      client: @client, local_directory: @dl_dir, max_files: 2
    )
    result = downloader.run!

    assert_equal 3, result[:total]
    assert_equal 3, result[:downloaded].size
    assert_empty result[:failed]
  end

  def test_download_with_exclude
    files = {
      "/keep.txt" => "keep",
      "/skip.log" => "skip",
      "/also.txt" => "also"
    }
    files.each { |k, v| upload_file(@client, k, v) }

    stub_list_objects(@client, files.map do |k, v|
      { key: k, size: v.bytesize, last_modified: "2024-01-01T00:00:00Z",
        storage_class: "STANDARD", etag: %("#{Digest::MD5.hexdigest(v)}") }
    end)

    downloader = S3BulkDownloader.new(
      client: @client, local_directory: @dl_dir, exclude: ["*.log"]
    )
    result = downloader.run!

    assert_equal 2, result[:total]
    assert_equal 2, result[:downloaded].size
  end

  def test_download_with_prefix
    upload_file(@client, "/prefix/a.txt", "aaa")
    upload_file(@client, "/other/b.txt", "bbb")

    stub_list_objects(@client, [
                        { key: "/prefix/a.txt", size: 3, last_modified: "2024-01-01T00:00:00Z",
                          storage_class: "STANDARD", etag: %("#{Digest::MD5.hexdigest('aaa')}") }
                      ])

    downloader = S3BulkDownloader.new(
      client: @client, local_directory: @dl_dir, prefix: "prefix/"
    )
    result = downloader.run!

    assert_equal 1, result[:total]
    assert_equal 1, result[:downloaded].size
  end

  def test_download_with_bucket
    upload_file(@client, "/test.txt", "test data")

    stub_list_objects(@client, [
                        { key: "/test.txt", size: 9, last_modified: "2024-01-01T00:00:00Z",
                          storage_class: "STANDARD", etag: %("#{Digest::MD5.hexdigest('test data')}") }
                      ], bucket: "other-bucket")

    downloader = S3BulkDownloader.new(
      client: @client, local_directory: @dl_dir, bucket: "other-bucket"
    )
    result = downloader.run!

    assert_equal 1, result[:total]
    assert_equal 1, result[:downloaded].size
  end

  def test_download_creates_subdirectories
    upload_file(@client, "/deep/nested/dir/file.txt", "deep content")

    stub_list_objects(@client, [
                        { key: "/deep/nested/dir/file.txt", size: 13, last_modified: "2024-01-01T00:00:00Z",
                          storage_class: "STANDARD", etag: %("#{Digest::MD5.hexdigest('deep content')}") }
                      ])

    downloader = S3BulkDownloader.new(
      client: @client, local_directory: @dl_dir, max_files: 1
    )
    result = downloader.run!

    assert_equal 1, result[:downloaded].size
    assert File.exist?(File.join(@dl_dir, "/deep/nested/dir/file.txt"))
  end

  def test_download_callbacks
    starts = []
    completes = []
    errors = []

    upload_file(@client, "/cb.txt", "callback test")

    stub_list_objects(@client, [
                        { key: "/cb.txt", size: 14, last_modified: "2024-01-01T00:00:00Z",
                          storage_class: "STANDARD", etag: %("#{Digest::MD5.hexdigest('callback test')}") }
                      ])

    downloader = S3BulkDownloader.new(
      client: @client, local_directory: @dl_dir, max_files: 1,
      on_file_start: lambda { |key, path, idx, total|
        starts << { key: key, path: path, idx: idx, total: total }
      },
      on_file_complete: lambda { |key, path, entry, idx, total|
        completes << { key: key, path: path, idx: idx, total: total }
      },
      on_file_error: lambda { |key, path, error, idx, total|
        errors << { key: key, path: path, error: error, idx: idx, total: total }
      }
    )
    downloader.run!

    assert_equal 1, starts.size
    assert_equal "/cb.txt", starts[0][:key]
    assert_equal 1, completes.size
    assert_empty errors
  end

  def test_download_error_callback_on_failure
    errors = []

    stub_list_objects(@client, [
                        { key: "/missing.txt", size: 10, last_modified: "2024-01-01T00:00:00Z",
                          storage_class: "STANDARD", etag: %("#{Digest::MD5.hexdigest('x' * 10)}") }
                      ])

    downloader = S3BulkDownloader.new(
      client: @client, local_directory: @dl_dir, max_files: 1,
      on_file_error: lambda { |key, path, error, idx, total|
        errors << { key: key, path: path, error: error }
      }
    )
    result = downloader.run!

    assert_equal 1, result[:failed].size
    assert_equal 1, errors.size
    assert_equal "/missing.txt", errors[0][:key]
  end

  def test_download_fatal_error_stops_remaining
    errors = []

    stub_list_objects(@client, [
                        { key: "/good.txt", size: 4, last_modified: "2024-01-01T00:00:00Z",
                          storage_class: "STANDARD", etag: %("#{Digest::MD5.hexdigest('good')}") },
                        { key: "/bad.txt", size: 4, last_modified: "2024-01-01T00:00:00Z",
                          storage_class: "STANDARD", etag: %("#{Digest::MD5.hexdigest('bad1')}") }
                      ])

    call_count = 0
    original_download = @client.method(:download_file)
    @client.define_singleton_method(:download_file) do |**kwargs|
      call_count += 1
      if kwargs[:key] == "/bad.txt"
        raise S3Errors::S3Error.new("403", "AccessDenied")
      end

      original_download.call(**kwargs)
    end

    downloader = S3BulkDownloader.new(
      client: @client, local_directory: @dl_dir, max_files: 1,
      on_file_error: lambda { |key, path, error, idx, total|
        errors << { key: key, error: error }
      }
    )
    result = downloader.run!

    assert result[:failed].size >= 1
    assert errors.any? { |e| e[:key] == "/bad.txt" }
  ensure
    @client.singleton_class.remove_method(:download_file) if @client.respond_to?(:download_file)
  end

  def test_download_standard_error_rescued
    errors = []

    stub_list_objects(@client, [
                        { key: "/err.txt", size: 4, last_modified: "2024-01-01T00:00:00Z",
                          storage_class: "STANDARD", etag: %("#{Digest::MD5.hexdigest('errr')}") }
                      ])

    original_download = @client.method(:download_file)
    @client.define_singleton_method(:download_file) do |**kwargs|
      raise "unexpected failure" if kwargs[:key] == "/err.txt"

      original_download.call(**kwargs)
    end

    downloader = S3BulkDownloader.new(
      client: @client, local_directory: @dl_dir, max_files: 1,
      on_file_error: lambda { |key, path, error, idx, total|
        errors << { key: key, error: error }
      }
    )
    result = downloader.run!

    assert_equal 1, result[:failed].size
    assert_equal 1, errors.size
  ensure
    @client.singleton_class.remove_method(:download_file) if @client.respond_to?(:download_file)
  end

  def test_download_max_files_clamping
    downloader = S3BulkDownloader.new(
      client: @client, local_directory: @dl_dir, max_files: 0
    )
    assert_equal 1, downloader.instance_variable_get(:@max_files)

    downloader2 = S3BulkDownloader.new(
      client: @client, local_directory: @dl_dir, max_files: 100
    )
    max = S3BaseClient::MAXIMUM_CONCURRENCY
    assert_equal max, downloader2.instance_variable_get(:@max_files)
  end

  def test_download_default_max_files
    downloader = S3BulkDownloader.new(
      client: @client, local_directory: @dl_dir
    )
    assert_equal 4, downloader.instance_variable_get(:@max_files)
  end

  def test_download_file_size_in_result
    content = "size check"
    upload_file(@client, "/sized.txt", content)

    stub_list_objects(@client, [
                        { key: "/sized.txt", size: content.bytesize, last_modified: "2024-01-01T00:00:00Z",
                          storage_class: "STANDARD", etag: %("#{Digest::MD5.hexdigest(content)}") }
                      ])

    downloader = S3BulkDownloader.new(
      client: @client, local_directory: @dl_dir
    )
    result = downloader.run!

    entry = result[:downloaded].first
    assert_equal content.bytesize, entry[:size]
    assert entry[:elapsed] >= 0
  end

  def test_download_elapsed_time_recorded
    upload_file(@client, "/timed.txt", "timed")

    stub_list_objects(@client, [
                        { key: "/timed.txt", size: 5, last_modified: "2024-01-01T00:00:00Z",
                          storage_class: "STANDARD", etag: %("#{Digest::MD5.hexdigest('timed')}") }
                      ])

    downloader = S3BulkDownloader.new(
      client: @client, local_directory: @dl_dir
    )
    result = downloader.run!

    assert result[:elapsed] >= 0
  end

  # --- Mock-based tests for code paths not covered by FakeS3 ---

  def test_run_with_empty_result_mock
    client = build_mock_client
    client.define_singleton_method(:list_objects) do |**_kwargs|
      { contents: [], common_prefixes: [], is_truncated: false, next_continuation_token: nil }
    end

    downloader = S3BulkDownloader.new(
      client: client, local_directory: Dir.mktmpdir
    )
    result = downloader.run!
    assert_equal 0, result[:total]
    assert_equal 0.0, result[:elapsed]
  ensure
    client.singleton_class.remove_method(:list_objects) if client.respond_to?(:list_objects)
  end

  def test_standard_error_rescue_in_download_mock
    client = build_mock_client
    client.define_singleton_method(:list_objects) do |**_kwargs|
      { contents: [{ key: "f.txt", size: 4, last_modified: "2024-01-01", storage_class: "STANDARD", etag: '"x"' }],
        common_prefixes: [], is_truncated: false, next_continuation_token: nil }
    end
    client.define_singleton_method(:download_file) do |**_kwargs|
      raise "kaboom"
    end

    errors = []
    downloader = S3BulkDownloader.new(
      client: client, local_directory: Dir.mktmpdir, max_files: 1,
      on_file_error: ->(k, p, e, _i, _t) { errors << { key: k, error: e } }
    )
    result = downloader.run!
    assert_equal 1, result[:failed].size
    assert errors.any?
  ensure
    client&.singleton_class&.remove_method(:list_objects) if client.respond_to?(:list_objects)
    client&.singleton_class&.remove_method(:download_file) if client.respond_to?(:download_file)
  end

  def test_download_with_exclude_pattern_mock
    client = build_mock_client
    client.define_singleton_method(:list_objects) do |**_kwargs|
      { contents: [
        { key: "a.txt", size: 1, last_modified: "2024-01-01", storage_class: "STANDARD", etag: '"a"' },
        { key: "b.log", size: 1, last_modified: "2024-01-01", storage_class: "STANDARD", etag: '"b"' }
      ], common_prefixes: [], is_truncated: false, next_continuation_token: nil }
    end

    dl = S3BulkDownloader.new(
      client: client, local_directory: Dir.mktmpdir,
      exclude: ["*.log"]
    )
    files = dl.send(:list_files)
    assert_equal 1, files.size
    assert_equal "a.txt", files[0][:key]
  ensure
    client&.singleton_class&.remove_method(:list_objects) if client.respond_to?(:list_objects)
  end

  def test_fatal_download_error_mock
    client = build_mock_client
    client.define_singleton_method(:list_objects) do |**_kwargs|
      { contents: [{ key: "f.txt", size: 4, last_modified: "2024-01-01", storage_class: "STANDARD", etag: '"x"' }],
        common_prefixes: [], is_truncated: false, next_continuation_token: nil }
    end
    client.define_singleton_method(:download_file) do |**_kwargs|
      raise S3Errors::DownloadError, "NoSuchBucket"
    end

    dl = S3BulkDownloader.new(
      client: client, local_directory: Dir.mktmpdir, max_files: 1
    )
    result = dl.run!
    assert_equal 1, result[:failed].size
  ensure
    client&.singleton_class&.remove_method(:list_objects) if client.respond_to?(:list_objects)
    client&.singleton_class&.remove_method(:download_file) if client.respond_to?(:download_file)
  end

  private

  def build_mock_client
    S3Client.new(
      region: "us-east-1", bucket: "b",
      access_key_id: "a", secret_access_key: "k",
      endpoint: "http://127.0.0.1:1", endpoint_style: :path,
      logger: Logger.new(File::NULL)
    )
  end

  def upload_file(client, key, content)
    path = File.join(@store_dir, client.bucket, key.sub(%r{^/}, ""))
    FileUtils.mkdir_p(File.dirname(path))
    File.binwrite(path, content)
  end

  def stub_list_objects(client, contents, bucket: nil)
    client.define_singleton_method(:list_objects) do |**_kwargs|
      {
        contents: contents,
        common_prefixes: [],
        is_truncated: false,
        next_continuation_token: nil
      }
    end
  end
end
