# frozen_string_literal: true

require_relative "../test_helper"
require_relative "../../src/s3_client"

class S3ClientParallelDownloadTest < Minitest::Test
  include S3TestHelpers

  PORT = 15_604

  def setup
    dir = suite_tmp_dir("s3client_parallel_dl")
    @store_dir = File.join(dir, "store")
    @tmp_dir   = File.join(dir, "tmp")
    @server = FakeS3::Server.new(port: PORT, store_dir: @store_dir, tmp_dir: @tmp_dir)
    @server.start_thread

    @client = S3Client.new(
      region: "us-east-1", bucket: "b", access_key_id: "a", secret_access_key: "k",
      endpoint: "http://127.0.0.1:#{PORT}", endpoint_style: :path,
      part_size: 5 * 1024 * 1024, max_concurrency: 1,
      max_retries: 2, retry_delay: 0.01,
      compute_md5: true,
      logger: Logger.new(File::NULL)
    )
  end

  def teardown
    @server.stop
    cleanup_suite_tmp("s3client_parallel_dl")
  end

  def test_download_part_reuses_http_connection
    state = DownloadState.new(key: "/test.bin", local_path: "/tmp/test.bin",
                              total_size: 100_000, part_size: 50_000, parts: {})
    tmpfile = Tempfile.new(["dl_reuse", ".bin"])
    downloader = PartDownloader.new(
      @client, state, output_file: tmpfile, max_threads: 1, max_retries: 1, retry_delay: 0.01
    )

    http_mock = Object.new
    def http_mock.request(*)
      nil
    end

    call_count = 0
    nil_count = 0
    @client.define_singleton_method(:download_part_http) do |_bucket, _key, _pn, _o, _eb, _len, http|
      call_count += 1
      nil_count += 1 if http.nil?
      "x"
    end

    downloader.send(:download_part_with_retry, 1, 0, 49_999, 50_000, http_mock, "t0")

    assert_equal 1, call_count, "download_part_http should be called once"
    assert_equal 0, nil_count,
                 "expected http to be reused (non-nil), got #{nil_count} nil calls"
  end
end
