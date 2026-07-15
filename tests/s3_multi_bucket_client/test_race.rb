# frozen_string_literal: true

require_relative "../test_helper"
require_relative "../../src/s3_multi_bucket_client"

class S3MultiBucketRaceTest < Minitest::Test
  include S3TestHelpers

  PORT = 15_691
  PART_SIZE = 5 * 1024 * 1024
  N_PARTS = 8
  FILE_SIZE = PART_SIZE * N_PARTS
  BUCKET = "b"

  def setup
    dir = suite_tmp_dir("multibucket_race")
    @store_dir  = File.join(dir, "store")
    @tmp_dir    = File.join(dir, "tmp")
    @state_file = File.join(dir, "race.upload.json")
    @server = FakeS3::Server.new(port: PORT, store_dir: @store_dir, tmp_dir: @tmp_dir)
    @server.start_fork

    @client = S3MultiBucketClient.new(
      endpoint: "http://127.0.0.1:#{PORT}", region: "us-east-1",
      access_key_id: "a", secret_access_key: "k",
      logger: Logger.new(File::NULL)
    )

    @src_path, @src_md5 = create_temp_binary_file(FILE_SIZE)
  end

  def teardown
    @server.stop
    File.delete(@src_path) if @src_path && File.exist?(@src_path)
  end

  def test_concurrent_upload_monotonic_state
    state_history = []
    state_mtx = Mutex.new
    observer_stop = false

    observer = Thread.new do
      last_count = 0
      until observer_stop
        if File.exist?(@state_file)
          begin
            raw = JSON.parse(File.read(@state_file))
            count = raw["parts"]&.size || 0
            if count < last_count
              Thread.current[:bad] = "count decreased: #{last_count} -> #{count}"
              break
            end
            last_count = count
            state_mtx.synchronize { state_history << count }
          rescue JSON::ParserError => e
            Thread.current[:bad] = "corrupt JSON: #{e.message}"
            break
          rescue Errno::ENOENT
            # race: file deleted by upload completion between exist? check and read
          end
        end
        sleep 0.002
      end
    end

    progress_calls = []
    r = @client.upload_file(
      bucket: BUCKET, key: "race.bin", local_path: @src_path,
      part_size: PART_SIZE, max_threads: 8, max_retries: 1,
      state_file: @state_file,
      on_progress: ->(done, total) { progress_calls << [done, total] }
    )

    observer_stop = true
    observer.join

    refute r[:error], "upload failed: #{r[:error]}"
    refute observer[:bad], "observer error: #{observer[:bad]}"
    assert_equal N_PARTS, r[:parts_uploaded]
    refute File.exist?(@state_file)
    assert progress_calls.each_cons(2).all? { |a, b| a[0] <= b[0] }, "progress not monotonic"

    dl_md5 = Digest::MD5.file(File.join(@store_dir, BUCKET, "race.bin")).hexdigest
    assert_equal @src_md5, dl_md5
  end

  def test_resume_from_half_state
    upload_id = @client.multipart_start(bucket: BUCKET, key: "race.bin")

    manual_parts = []
    (1..N_PARTS / 2).each do |n|
      data = File.open(@src_path, "rb") do |f|
        f.seek((n - 1) * PART_SIZE)
        f.read(PART_SIZE)
      end
      etag = @client.multipart_upload_part(
        bucket: BUCKET, key: "race.bin", upload_id: upload_id,
        part_number: n, body: data
      )
      manual_parts << { part_number: n, etag: etag, size: PART_SIZE }
    end

    resume_state = S3MultiBucketClient::UploadState.new(
      upload_id: upload_id, key: "race.bin", bucket: BUCKET,
      local_path: File.expand_path(@src_path), part_size: PART_SIZE,
      total_size: FILE_SIZE, parts: manual_parts
    )
    resume_state.save_to_file(@state_file)

    progress_calls = []
    r = @client.resume_upload(
      bucket: BUCKET, key: "race.bin", local_path: @src_path,
      state_file: @state_file,
      on_progress: ->(done, total) { progress_calls << [done, total] }
    )

    assert_equal N_PARTS, r[:parts_uploaded]
    dl_md5 = Digest::MD5.file(File.join(@store_dir, BUCKET, "race.bin")).hexdigest
    assert_equal @src_md5, dl_md5
  end
end
