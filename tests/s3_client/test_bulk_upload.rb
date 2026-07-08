# frozen_string_literal: true

require_relative "../test_helper"
require_relative "../../src/s3_client"

class S3ClientBulkUploadTest < Minitest::Test
  include S3TestHelpers

  PORT = 15_580

  def setup
    dir = suite_tmp_dir("s3client_bulk")
    @store_dir = File.join(dir, "store")
    @tmp_dir   = File.join(dir, "tmp")
    @src_dir   = File.join(dir, "upload_me")
    @server = FakeS3::Server.new(port: PORT, store_dir: @store_dir, tmp_dir: @tmp_dir)
    @server.start_thread

    @client = S3Client.new(
      region: "us-east-1", bucket: "fake-bucket",
      access_key_id: "AKIAFAKE", secret_access_key: "secretfake",
      endpoint: "http://127.0.0.1:#{PORT}", endpoint_style: :path,
      part_size: 5 * 1024 * 1024, max_concurrency: 2, max_retries: 2,
      open_timeout: 5, read_timeout: 30,
      logger: Logger.new(File::NULL)
    )
  end

  def teardown
    @server.stop
  end

  def test_bulk_upload_directory
    create_test_directory(@src_dir, {
                            "readme.txt" => "hello world",
                            "data/report.csv" => "a,b,c\n1,2,3",
                            "images/logo.png" => SecureRandom.bytes(1024)
                          })

    result = S3Helper.upload_bulk(
      client: @client,
      directory: @src_dir,
      prefix: "bulk-test",
      max_files: 2
    )

    assert_equal 3, result[:uploaded].size
    assert_empty result[:failed]
    assert_equal 3, result[:total_files]
    assert result[:total_bytes] > 0
    assert result[:elapsed] >= 0

    keys = result[:uploaded].map { |r| r[:key] }.sort
    assert_equal ["bulk-test/data/report.csv", "bulk-test/images/logo.png", "bulk-test/readme.txt"], keys

    assert File.exist?(File.join(@store_dir, "fake-bucket/bulk-test/readme.txt"))
    assert File.exist?(File.join(@store_dir, "fake-bucket/bulk-test/data/report.csv"))
    assert File.exist?(File.join(@store_dir, "fake-bucket/bulk-test/images/logo.png"))

    content = File.read(File.join(@store_dir, "fake-bucket/bulk-test/readme.txt"))
    assert_equal "hello world", content
  end

  def test_bulk_upload_with_prefix_trailing_slash
    create_test_directory(@src_dir, { "file.txt" => "data" })

    result = S3Helper.upload_bulk(
      client: @client, directory: @src_dir, prefix: "my-prefix/"
    )

    assert_equal 1, result[:uploaded].size
    assert_equal "my-prefix/file.txt", result[:uploaded].first[:key]
  end

  def test_bulk_upload_without_prefix
    create_test_directory(@src_dir, { "a.txt" => "aaa", "b.txt" => "bbb" })

    result = S3Helper.upload_bulk(
      client: @client, directory: @src_dir, prefix: ""
    )

    assert_equal 2, result[:uploaded].size
    keys = result[:uploaded].map { |r| r[:key] }.sort
    assert_equal ["a.txt", "b.txt"], keys
  end

  def test_bulk_upload_exclude_pattern
    create_test_directory(@src_dir, {
                            "keep.txt" => "yes", "skip.tmp" => "no",
                            "sub/ok.txt" => "yes", "sub/bad.tmp" => "no"
                          })

    result = S3Helper.upload_bulk(
      client: @client, directory: @src_dir,
      exclude: ["**/*.tmp"]
    )

    assert_equal 2, result[:uploaded].size
    keys = result[:uploaded].map { |r| r[:key] }.sort
    assert_equal ["keep.txt", "sub/ok.txt"], keys
  end

  def test_bulk_upload_glob_pattern
    create_test_directory(@src_dir, {
                            "a.txt" => "text", "b.csv" => "csv", "sub/c.txt" => "nested"
                          })

    result = S3Helper.upload_bulk(
      client: @client, directory: @src_dir,
      pattern: "*.txt"
    )

    assert_equal 1, result[:uploaded].size
    assert_equal "a.txt", result[:uploaded].first[:key]
  end

  def test_bulk_upload_empty_directory
    FileUtils.mkdir_p(@src_dir)

    result = S3Helper.upload_bulk(
      client: @client, directory: @src_dir
    )

    assert_empty result[:uploaded]
    assert_empty result[:failed]
    assert_equal 0, result[:total_files]
  end

  def test_bulk_upload_nonexistent_directory
    assert_raises(Errno::ENOENT) do
      S3Helper.upload_bulk(
        client: @client, directory: "/nonexistent/path"
      )
    end
  end

  def test_bulk_upload_callbacks
    create_test_directory(@src_dir, { "a.txt" => "aaa", "b.txt" => "bbb" })

    started = []
    completed = []

    S3Helper.upload_bulk(
      client: @client, directory: @src_dir,
      on_file_start: ->(path, key, idx, total) { started << [key, idx, total] },
      on_file_complete: ->(path, key, res, idx, total) { completed << [key, idx, total] }
    )

    assert_equal 2, started.size
    assert_equal 2, completed.size
    started.each { |_, idx, total| assert_equal 2, total }
    completed.each { |_, idx, total| assert_equal 2, total }
  end

  def test_bulk_upload_content_type_detection
    create_test_directory(@src_dir, {
                            "page.html" => "<html></html>",
                            "style.css" => "body{}",
                            "data.json" => '{"a":1}',
                            "binary.dat" => SecureRandom.bytes(64)
                          })

    result = S3Helper.upload_bulk(
      client: @client, directory: @src_dir
    )

    assert_equal 4, result[:uploaded].size
    assert_empty result[:failed]
  end

  def test_bulk_upload_preserves_file_content
    files = {
      "small.bin" => SecureRandom.bytes(100),
      "medium.bin" => SecureRandom.bytes(10 * 1024)
    }
    create_test_directory(@src_dir, files)

    S3Helper.upload_bulk(client: @client, directory: @src_dir, prefix: "verify")

    files.each do |name, data|
      stored = File.binread(File.join(@store_dir, "fake-bucket/verify/#{name}"))
      assert_equal data.bytesize, stored.bytesize, "size mismatch for #{name}"
      assert_equal Digest::MD5.hexdigest(data), Digest::MD5.hexdigest(stored), "content mismatch for #{name}"
    end
  end

  def test_upload_directory_method_on_client
    create_test_directory(@src_dir, {
                            "a.txt" => "hello",
                            "sub/b.txt" => "world"
                          })

    result = @client.upload_directory(
      directory: @src_dir,
      prefix: "direct",
      max_files: 2
    )

    assert_equal 2, result[:uploaded].size
    assert_empty result[:failed]
    keys = result[:uploaded].map { |r| r[:key] }.sort
    assert_equal ["direct/a.txt", "direct/sub/b.txt"], keys
  end

  def test_upload_directory_with_exclude
    create_test_directory(@src_dir, {
                            "keep.txt" => "yes", "skip.log" => "no"
                          })

    result = @client.upload_directory(
      directory: @src_dir,
      prefix: "filtered",
      exclude: ["*.log"]
    )

    assert_equal 1, result[:uploaded].size
    assert_equal "filtered/keep.txt", result[:uploaded].first[:key]
  end

  private

  def create_test_directory(dir, files)
    FileUtils.rm_rf(dir)
    FileUtils.mkdir_p(dir)
    files.each do |name, content|
      path = File.join(dir, name)
      FileUtils.mkdir_p(File.dirname(path))
      if content.is_a?(String) && content.encoding == Encoding::BINARY
        File.binwrite(path, content)
      else
        File.write(path, content)
      end
    end
  end
end
