# frozen_string_literal: true

require_relative "../test_helper"
require_relative "../../src/s3_client"

class S3ClientRaceTest < Minitest::Test
  include S3TestHelpers

  PORT = 15_591
  PART_SIZE = 5 * 1024 * 1024
  N_PARTS = 8
  FILE_SIZE = PART_SIZE * N_PARTS

  def setup
    dir = suite_tmp_dir("s3client_race")
    @store_dir  = File.join(dir, "store")
    @tmp_dir    = File.join(dir, "tmp")
    @state_file = File.join(dir, "race.upload.json")
    @server = FakeS3::Server.new(port: PORT, store_dir: @store_dir, tmp_dir: @tmp_dir)
    @server.start_fork

    @client = S3Client.new(
      region: "us-east-1", bucket: "b", access_key_id: "a", secret_access_key: "k",
      endpoint: "http://127.0.0.1:#{PORT}", endpoint_style: :path,
      part_size: PART_SIZE, max_concurrency: 8, max_retries: 1,
      open_timeout: 5, read_timeout: 30,
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
            # File may not exist yet
          end
        end
        sleep 0.002
      end
    end

    progress_calls = []
    r = @client.upload_file(
      local_path: @src_path, key: "/race.bin", state_file: @state_file,
      on_progress: ->(w, t) { progress_calls << [w, t] }
    )

    observer_stop = true
    observer.join

    refute observer[:bad], "observer saw error: #{observer[:bad]}"
    assert_equal N_PARTS, r[:parts].size
    refute File.exist?(@state_file)
    assert_equal [FILE_SIZE, FILE_SIZE], progress_calls.last
    assert progress_calls.each_cons(2).all? { |a, b| a[0] <= b[0] }, "progress not monotonic"

    dl_md5 = Digest::MD5.file(File.join(@store_dir, "b/race.bin")).hexdigest
    assert_equal @src_md5, dl_md5
  end

  def test_resume_from_half_state
    upload_id = @client.send(:create_multipart_upload, key: "/race.bin",
                                                       content_type: "application/octet-stream",
                                                       metadata: {}, cache_control: nil)

    manual_parts = {}
    (1..N_PARTS / 2).each do |n|
      data = File.open(@src_path, "rb") do |f|
        f.seek((n - 1) * PART_SIZE)
        f.read(PART_SIZE)
      end
      etag = @client.send(:upload_part, key: "/race.bin", upload_id: upload_id,
                                        part_number: n, body: data)
      manual_parts[n] = etag
    end

    File.write(@state_file, JSON.pretty_generate({
                                                   upload_id: upload_id, key: "/race.bin",
                                                   part_size: PART_SIZE, total_size: FILE_SIZE,
                                                   local_path: File.expand_path(@src_path), parts: manual_parts
                                                 }))

    progress_calls = []
    r = @client.resume_upload(state_file: @state_file,
                              on_progress: ->(w, t) { progress_calls << [w, t] })

    assert_equal N_PARTS, r[:parts].size
    r[:parts][0, N_PARTS / 2].each_with_index do |p, i|
      assert_equal manual_parts[i + 1], p[:etag], "part #{i + 1} etag mismatch"
    end
    assert_equal [(N_PARTS / 2) * PART_SIZE, FILE_SIZE], progress_calls.first
    assert_equal [FILE_SIZE, FILE_SIZE], progress_calls.last

    dl_md5 = Digest::MD5.file(File.join(@store_dir, "b/race.bin")).hexdigest
    assert_equal @src_md5, dl_md5
  end
end
