# frozen_string_literal: true

require_relative "../test_helper"
require_relative "../../src/s3-stream-multipart"

class S3MultiBucketMemoryTest < Minitest::Test
  include S3TestHelpers

  PORT = 15_680
  FILE_SIZE = 30 * 1024 * 1024
  BUCKET = "b"

  def setup
    dir = suite_tmp_dir("multibucket_mem")
    @store_dir = File.join(dir, "store")
    @tmp_dir   = File.join(dir, "tmp")
    @server = FakeS3::Server.new(port: PORT, store_dir: @store_dir, tmp_dir: @tmp_dir)
    @server.start_fork

    @client = S3MultiBucketClient.new(
      endpoint: "http://127.0.0.1:#{PORT}", region: "us-east-1",
      access_key_id: "a", secret_access_key: "k",
      logger: Logger.new(File::NULL)
    )
  end

  def teardown
    @server.stop
  end

  def test_memory_efficiency_upload_download_200mb
    src_path, expected_md5 = create_temp_binary_file(FILE_SIZE)

    GC.start
    rss_before_upload = rss_kb

    @client.upload_file(
      bucket: BUCKET, key: "huge.bin", local_path: src_path,
      part_size: 10 * 1024 * 1024, max_threads: 4,
      on_progress: lambda { |done, total|
        if done == total
          puts
          puts "  Upload done. RSS = #{rss_kb} KB (+#{rss_kb - rss_before_upload} KB)"
        end
      }
    )
    @client.upload_file(
      bucket: BUCKET, key: "huge.bin", local_path: src_path,
      part_size: 10 * 1024 * 1024, max_threads: 4,
      on_progress: lambda { |done, total|
        if done == total
          puts
          puts "  Upload done. RSS = #{rss_kb} KB (+#{rss_kb - rss_before_upload} KB)"
        end
      }
    )
    rss_after_upload = rss_kb

    dst = Tempfile.new(["dl", ".bin"])
    dst.close
    GC.start
    rss_before_dl = rss_kb
    @client.download_file(
      bucket: BUCKET, key: "huge.bin", destination_path: dst.path,
      on_progress: lambda { |done, total|
        if done == total
          puts
          puts "  Download done. RSS = #{rss_kb} KB (+#{rss_kb - rss_before_dl} KB)"
        end
      }
    )
    rss_after_dl = rss_kb

    dl_md5 = Digest::MD5.new
    File.open(dst.path, "rb") do |f|
      while (chunk = f.read(1024 * 1024))
        dl_md5 << chunk
      end
    end
    assert_equal expected_md5, dl_md5.hexdigest

    puts
    puts "\n=== RAM RESULTS (s3_multi_bucket) ==="
    puts "  File size:       #{FILE_SIZE / 1024 / 1024} MB"
    puts "  part_size:       10 MB, max_threads: 4"
    puts "  Upload RAM:      #{(rss_after_upload - rss_before_upload) / 1024} MB"
    puts "  Download RAM:    #{rss_after_dl - rss_before_dl} KB"
  ensure
    File.delete(src_path) if src_path && File.exist?(src_path)
    dst&.unlink
  end
end
