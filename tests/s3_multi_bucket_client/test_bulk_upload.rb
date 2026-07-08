# frozen_string_literal: true

require_relative "../test_helper"
require_relative "../../src/s3_multi_bucket_client"

class S3MultiBucketBulkUploadTest < Minitest::Test
  include S3TestHelpers

  PORT = 15_680
  BUCKET = "fake-bucket"

  def setup
    dir = suite_tmp_dir("multibucket_bulk")
    @store_dir = File.join(dir, "store")
    @tmp_dir   = File.join(dir, "tmp")
    @src_dir   = File.join(dir, "upload_me")
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
      bucket: BUCKET,
      max_files: 2
    )

    assert_equal 3, result[:uploaded].size
    assert_empty result[:failed]
    assert_equal 3, result[:total_files]
    assert result[:total_bytes] > 0

    keys = result[:uploaded].map { |r| r[:key] }.sort
    assert_equal ["bulk-test/data/report.csv", "bulk-test/images/logo.png", "bulk-test/readme.txt"], keys

    assert File.exist?(File.join(@store_dir, "#{BUCKET}/bulk-test/readme.txt"))
    assert File.exist?(File.join(@store_dir, "#{BUCKET}/bulk-test/data/report.csv"))

    content = File.read(File.join(@store_dir, "#{BUCKET}/bulk-test/readme.txt"))
    assert_equal "hello world", content
  end

  def test_bulk_upload_exclude_pattern
    create_test_directory(@src_dir, {
                            "keep.txt" => "yes", "skip.tmp" => "no",
                            "sub/ok.txt" => "yes", "sub/bad.tmp" => "no"
                          })

    result = S3Helper.upload_bulk(
      client: @client, directory: @src_dir,
      bucket: BUCKET, exclude: ["**/*.tmp"]
    )

    assert_equal 2, result[:uploaded].size
    keys = result[:uploaded].map { |r| r[:key] }.sort
    assert_equal ["keep.txt", "sub/ok.txt"], keys
  end

  def test_bulk_upload_callbacks
    create_test_directory(@src_dir, { "a.txt" => "aaa", "b.txt" => "bbb" })

    started = []
    completed = []

    S3Helper.upload_bulk(
      client: @client, directory: @src_dir, bucket: BUCKET,
      on_file_start: ->(path, key, idx, total) { started << key },
      on_file_complete: ->(path, key, res, idx, total) { completed << key }
    )

    assert_equal 2, started.size
    assert_equal 2, completed.size
  end

  def test_bulk_upload_preserves_content
    files = {
      "small.bin" => SecureRandom.bytes(100),
      "medium.bin" => SecureRandom.bytes(10 * 1024)
    }
    create_test_directory(@src_dir, files)

    S3Helper.upload_bulk(
      client: @client, directory: @src_dir,
      prefix: "verify", bucket: BUCKET
    )

    files.each do |name, data|
      stored = File.binread(File.join(@store_dir, "#{BUCKET}/verify/#{name}"))
      assert_equal data.bytesize, stored.bytesize, "size mismatch for #{name}"
      assert_equal Digest::MD5.hexdigest(data), Digest::MD5.hexdigest(stored), "content mismatch for #{name}"
    end
  end

  def test_upload_directory_method_on_client
    create_test_directory(@src_dir, {
                            "x.txt" => "foo",
                            "nested/y.txt" => "bar"
                          })

    result = @client.upload_directory(
      bucket: BUCKET,
      directory: @src_dir,
      prefix: "direct",
      max_files: 2
    )

    assert_equal 2, result[:uploaded].size
    assert_empty result[:failed]
    keys = result[:uploaded].map { |r| r[:key] }.sort
    assert_equal ["direct/nested/y.txt", "direct/x.txt"], keys

    assert File.exist?(File.join(@store_dir, "#{BUCKET}/direct/x.txt"))
    assert File.exist?(File.join(@store_dir, "#{BUCKET}/direct/nested/y.txt"))
  end

  def test_bulk_upload_skip_existing_multi_bucket
    create_test_directory(@src_dir, { "a.txt" => "skip test", "b.txt" => "skip test 2" })
    @client.upload_directory(bucket: BUCKET, directory: @src_dir, prefix: "skip_mb/")
    result = @client.upload_directory(
      bucket: BUCKET, directory: @src_dir, prefix: "skip_mb/",
      skip_existing: true
    )
    assert !result[:skipped].empty?
  end

  def test_bulk_upload_with_state_dir_multi_bucket
    create_test_directory(@src_dir, { "a.txt" => "state dir test", "b.txt" => "state dir test 2" })
    state_dir = File.join(@store_dir, "mb_states")
    result = @client.upload_directory(
      bucket: BUCKET, directory: @src_dir, prefix: "mb_st/",
      state_dir: state_dir, multipart_threshold: 1
    )
    assert_equal 2, result[:uploaded].size
    assert File.directory?(state_dir)
  end

  def test_bulk_upload_with_cache_control_multi_bucket
    create_test_directory(@src_dir, { "a.txt" => "cc test", "b.txt" => "cc test 2" })
    result = @client.upload_directory(
      bucket: BUCKET, directory: @src_dir, prefix: "mb_cc/",
      cache_control: "max-age=3600",
      metadata: { "author" => "test" }
    )
    assert_equal 2, result[:uploaded].size
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
