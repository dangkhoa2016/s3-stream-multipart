# frozen_string_literal: true

require_relative "../test_helper"
require_relative "../../src/s3_client"
require_relative "../../src/s3_multi_bucket_client"
require_relative "../../src/extras/helper"

class S3HelperModuleTest < Minitest::Test
  include S3TestHelpers

  PORT = 15_587

  def setup
    dir = suite_tmp_dir("helper_mod")
    @store_dir = File.join(dir, "store")
    @tmp_dir   = File.join(dir, "tmp")
    @server = FakeS3::Server.new(port: PORT, store_dir: @store_dir, tmp_dir: @tmp_dir)
    @server.start_thread

    @s3_client = S3Client.new(
      region: "us-east-1", bucket: "b",
      access_key_id: "a", secret_access_key: "k",
      endpoint: "http://127.0.0.1:#{PORT}", endpoint_style: :path,
      logger: Logger.new(File::NULL)
    )

    @mb_client = S3MultiBucketClient.new(
      region: "us-east-1",
      access_key_id: "a", secret_access_key: "k",
      endpoint: "http://127.0.0.1:#{PORT}",
      logger: Logger.new(File::NULL)
    )
  end

  def teardown
    @server.stop
    cleanup_suite_tmp("helper_mod")
  end

  def test_helper_upload_single_bucket_small_file
    Tempfile.create(["hlp", ".bin"]) do |f|
      f.write("hello")
      f.flush
      result = S3Helper.upload(client: @s3_client, key: "/sml.bin", local_path: f.path)
      assert result[:etag]
    end
  end

  def test_helper_upload_multi_bucket_small_file
    Tempfile.create(["hlp", ".bin"]) do |f|
      f.write("hello")
      f.flush
      result = S3Helper.upload(client: @mb_client, key: "/sml-mb.bin", local_path: f.path, bucket: "b")
      assert result[:etag]
    end
  end

  def test_helper_upload_missing_path
    assert_raises(ArgumentError) do
      S3Helper.upload(client: @s3_client, key: "/x.bin")
    end
  end

  def test_helper_download_single_bucket
    Tempfile.create(["dl", ".bin"]) do |f|
      f.write("data for download test")
      f.flush
      @s3_client.upload_file(local_path: f.path, key: "/dl.bin")
    end
    Dir.mktmpdir do |dir|
      dest = File.join(dir, "out.bin")
      S3Helper.download(client: @s3_client, key: "/dl.bin", local_path: dest, show_progress: false)
      assert File.file?(dest)
    end
  end

  def test_helper_download_multi_bucket
    Tempfile.create(["dl-mb", ".bin"]) do |f|
      f.write("data for multi-bucket download")
      f.flush
      @s3_client.upload_file(local_path: f.path, key: "/dl-mb.bin")
    end
    Dir.mktmpdir do |dir|
      dest = File.join(dir, "out.bin")
      S3Helper.download(client: @mb_client, key: "/dl-mb.bin", destination: dest, bucket: "b", show_progress: false)
      assert File.file?(dest)
    end
  end

  def test_helper_download_single_bucket_with_content
    size = 2 * 1024 * 1024
    src_path, = create_temp_binary_file(size)
    begin
      @s3_client.upload_file(local_path: src_path, key: "/dl-par.bin")
      Dir.mktmpdir do |dir|
        dest = File.join(dir, "out.bin")
        S3Helper.download(client: @s3_client, key: "/dl-par.bin", local_path: dest,
                          show_progress: false)
        assert File.file?(dest)
        assert_equal size, File.size(dest)
      end
    ensure
      File.delete(src_path) if File.exist?(src_path)
    end
  end

  def test_helper_download_multi_bucket_with_content
    size = 2 * 1024 * 1024
    src_path, = create_temp_binary_file(size)
    begin
      @s3_client.upload_file(local_path: src_path, key: "/dl-par-mb.bin")
      Dir.mktmpdir do |dir|
        dest = File.join(dir, "out.bin")
        S3Helper.download(
          client: @mb_client, key: "/dl-par-mb.bin",
          destination: dest, bucket: "b",
          show_progress: false
        )
        assert File.file?(dest)
      end
    ensure
      File.delete(src_path) if File.exist?(src_path)
    end
  end

  def test_helper_download_single_bucket_small
    Tempfile.create(["dl-res", ".bin"]) do |f|
      f.write("data for download")
      f.flush
      @s3_client.upload_file(local_path: f.path, key: "/dl-res.bin")
    end
    Dir.mktmpdir do |dir|
      dest = File.join(dir, "out.bin")
      S3Helper.download(client: @s3_client, key: "/dl-res.bin", local_path: dest,
                        show_progress: false)
      assert File.file?(dest)
    end
  end

  def test_helper_download_multi_bucket_small
    Tempfile.create(["dl-res-mb", ".bin"]) do |f|
      f.write("data for multi-bucket download")
      f.flush
      @s3_client.upload_file(local_path: f.path, key: "/dl-res-mb.bin")
    end
    Dir.mktmpdir do |dir|
      dest = File.join(dir, "out.bin")
      S3Helper.download(
        client: @mb_client, key: "/dl-res-mb.bin",
        destination: dest, bucket: "b",
        show_progress: false
      )
      assert File.file?(dest)
    end
  end

  def test_helper_download_missing_path
    assert_raises(ArgumentError) do
      S3Helper.download(client: @s3_client, key: "/x.bin")
    end
  end

  def test_helper_download_with_progress_bar
    Tempfile.create(["dl-pb", ".bin"]) do |f|
      f.write("x" * 5_000)
      f.flush
      @s3_client.upload_file(local_path: f.path, key: "/dl-pb.bin")
    end
    Dir.mktmpdir do |dir|
      dest = File.join(dir, "out.bin")
      capture_io do
        S3Helper.download(client: @s3_client, key: "/dl-pb.bin", local_path: dest, show_progress: true)
      end
      assert File.file?(dest)
    end
  end

  def test_helper_download_with_range_single_bucket
    Tempfile.create(["dl-range", ".bin"]) do |f|
      f.write("x" * 2_000)
      f.flush
      @s3_client.upload_file(local_path: f.path, key: "/dl-range-s.bin")
    end
    Dir.mktmpdir do |dir|
      dest = File.join(dir, "range_out.bin")
      S3Helper.download(
        client: @s3_client, key: "/dl-range-s.bin",
        local_path: dest, range: (100..500), show_progress: false
      )
      assert File.file?(dest)
      assert_operator File.size(dest), :>, 0
    end
  end

  def test_helper_download_with_range_multi_bucket
    Tempfile.create(["dl-range-mb", ".bin"]) do |f|
      f.write("x" * 2_000)
      f.flush
      @s3_client.upload_file(local_path: f.path, key: "/dl-range-m.bin")
    end
    Dir.mktmpdir do |dir|
      dest = File.join(dir, "range_out_mb.bin")
      S3Helper.download(
        client: @mb_client, key: "/dl-range-m.bin",
        destination: dest, bucket: "b",
        range: (100..500), show_progress: false
      )
      assert File.file?(dest)
    end
  end

  def test_helper_upload_auto_part_size_single_bucket
    size = 12 * 1024 * 1024
    src_path, src_md5 = create_temp_binary_file(size)
    begin
      r = S3Helper.upload(
        client: @s3_client, key: "/auto_ps.bin", local_path: src_path,
        multipart_threshold: 5 * 1024 * 1024
      )
      assert r[:etag]
      dl_md5 = Digest::MD5.file(File.join(@store_dir, "b/auto_ps.bin")).hexdigest
      assert_equal src_md5, dl_md5
    ensure
      File.delete(src_path) if File.exist?(src_path)
    end
  end

  def test_helper_upload_auto_part_size_multi_bucket
    src_path, = create_temp_binary_file(2_000)
    begin
      r = S3Helper.upload(
        client: @mb_client, key: "/auto_ps_mb.bin",
        local_path: src_path, bucket: "b",
        multipart_threshold: 1000
      )
      assert r[:etag] || r[:upload_id]
    ensure
      File.delete(src_path) if File.exist?(src_path)
    end
  end

  def test_helper_upload_bulk_with_state_dir
    dir = File.join(TEST_TMP, "helper_mod", "bulk_state_dir")
    FileUtils.mkdir_p(dir)
    File.write(File.join(dir, "a.txt"), "state dir test")

    state_dir = File.join(TEST_TMP, "helper_mod", "states")
    result = S3Helper.upload_bulk(
      client: @s3_client, directory: dir, prefix: "st/",
      state_dir: state_dir, multipart_threshold: 1
    )
    assert_equal 1, result[:uploaded].size
  end

  def test_helper_upload_bulk_with_skip_existing
    dir = File.join(TEST_TMP, "helper_mod", "bulk_skip_dir")
    FileUtils.mkdir_p(dir)
    File.write(File.join(dir, "a.txt"), "skip test data")

    S3Helper.upload_bulk(client: @s3_client, directory: dir, prefix: "skp/")
    result = S3Helper.upload_bulk(
      client: @s3_client, directory: dir, prefix: "skp/",
      skip_existing: true
    )
    assert_equal 1, result[:skipped].size
  end
end
