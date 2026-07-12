# frozen_string_literal: true

require_relative "../test_helper"
require_relative "../../src/s3_client"
require_relative "../../src/concurrent/parallel_uploader"
require_relative "../../src/concurrent/parallel_downloader"

class ConcurrentModuleTest < Minitest::Test
  def setup
    @client = S3Client.new(
      bucket: "b", region: "us-east-1",
      access_key_id: "AK", secret_access_key: "SK",
      endpoint: "http://127.0.0.1:19999",
      logger: Logger.new(File::NULL)
    )
  end

  # --- S3ParallelUploader ---

  def test_uploader_empty_pending_parts
    state = UploadState.new(
      upload_id: "u1", key: "k", part_size: 5_242_880,
      total_size: 5_242_880, parts: { 1 => "etag1" },
      local_path: "/dev/null"
    )
    uploader = PartUploader.new(
      @client, state, max_threads: 2, max_retries: 1, retry_delay: 0.01
    )
    result = uploader.upload_all!
    assert_kind_of Array, result
  end

  def test_uploader_raise_upload_errors
    state = UploadState.new(
      upload_id: "u1", key: "k", part_size: 5_242_880,
      total_size: 10_485_760, parts: {},
      local_path: "/dev/null"
    )
    uploader = PartUploader.new(
      @client, state, max_threads: 1, max_retries: 0, retry_delay: 0.01
    )
    errors = [{ part: 1, error: "test error" }, { part: 2, error: "test error 2" }]
    assert_raises(S3BaseClient::UploadError) do
      uploader.send(:raise_upload_errors, errors)
    end
  end

  def test_uploader_calculate_pre_transferred_bytes
    Tempfile.create(["conc", ".bin"]) do |f|
      f.write("x" * 15_728_640)
      f.flush
      state = UploadState.new(
        upload_id: "u1", key: "k", part_size: 5_242_880,
        total_size: 15_728_640, parts: { 1 => "e1", 2 => "e2" },
        local_path: f.path
      )
      uploader = PartUploader.new(
        @client, state, max_threads: 2, max_retries: 1, retry_delay: 0.01
      )
      uploaded_set = [1, 2].to_set
      bytes = uploader.send(:calculate_pre_transferred_bytes, uploaded_set)
      assert_equal 10_485_760, bytes
    end
  end

  def test_uploader_calculate_part_offset_and_length
    Tempfile.create(["conc2", ".bin"]) do |f|
      f.write("x" * 1024)
      f.flush
      state = UploadState.new(
        part_size: 5_242_880, total_size: 12_582_912,
        local_path: f.path
      )
      uploader = PartUploader.new(
        @client, state, max_threads: 1, max_retries: 0, retry_delay: 0.01
      )
      offset, length = uploader.send(:calculate_part_offset_and_length, 1)
      assert_equal 0, offset
      assert_equal 5_242_880, length

      offset, length = uploader.send(:calculate_part_offset_and_length, 3)
      assert_equal 10_485_760, offset
      assert_equal 2_097_152, length
    end
  end

  # --- S3ParallelDownloader ---

  def test_downloader_empty_pending_parts
    state = DownloadState.new(
      key: "k", local_path: "/dev/null",
      part_size: 5_242_880, total_size: 5_242_880,
      parts: { 1 => 5_242_880 }
    )
    output = StringIO.new
    downloader = PartDownloader.new(
      @client, state, output_file: output,
                      max_threads: 2, max_retries: 1, retry_delay: 0.01
    )
    downloader.download_all!
  end

  def test_downloader_raise_download_errors
    state = DownloadState.new(
      key: "k", local_path: "/dev/null",
      part_size: 5_242_880, total_size: 10_485_760, parts: {}
    )
    output = StringIO.new
    downloader = PartDownloader.new(
      @client, state, output_file: output,
                      max_threads: 1, max_retries: 0, retry_delay: 0.01
    )
    errors = [{ part: 1, error: "dl error" }]
    assert_raises(S3BaseClient::DownloadError) do
      downloader.send(:raise_download_errors, errors)
    end
  end

  def test_downloader_calculate_part_geometry
    state = DownloadState.new(
      part_size: 5_242_880, total_size: 12_582_912
    )
    output = StringIO.new
    downloader = PartDownloader.new(
      @client, state, output_file: output,
                      max_threads: 1, max_retries: 0, retry_delay: 0.01
    )

    offset, length, end_byte = downloader.send(:calculate_part_geometry, 1, 12_582_912)
    assert_equal 0, offset
    assert_equal 5_242_880, length
    assert_equal 5_242_879, end_byte

    offset, length, end_byte = downloader.send(:calculate_part_geometry, 3, 12_582_912)
    assert_equal 10_485_760, offset
    assert_equal 2_097_152, length
    assert_equal 12_582_911, end_byte
  end

  def test_downloader_save_state_after_part_no_state_file
    state = DownloadState.new(
      key: "k", local_path: "/dev/null",
      part_size: 5_242_880, total_size: 10_485_760
    )
    output = StringIO.new
    downloader = PartDownloader.new(
      @client, state, output_file: output,
                      max_threads: 1, max_retries: 0, retry_delay: 0.01
    )
    downloader.send(:save_state_after_part, 1, 5_242_880, "t0")
  end

  def test_downloader_log_prefix
    state = DownloadState.new(part_size: 1024, total_size: 2048)
    output = StringIO.new
    downloader = PartDownloader.new(
      @client, state, output_file: output,
                      max_threads: 1, max_retries: 0, retry_delay: 0.01
    )
    assert_equal "PartDownloader", downloader.send(:log_prefix)
  end

  def test_downloader_thread_id
    state = DownloadState.new(part_size: 1024, total_size: 2048)
    output = StringIO.new
    downloader = PartDownloader.new(
      @client, state, output_file: output,
                      max_threads: 1, max_retries: 0, retry_delay: 0.01
    )
    assert_equal "t0", downloader.send(:thread_id, 0)
    assert_equal "t3", downloader.send(:thread_id, 3)
  end

  # --- S3ParallelUploader default template methods ---

  def test_uploader_default_on_upload_complete
    state = UploadState.new(
      upload_id: "u1", key: "k", part_size: 1024, total_size: 2048,
      local_path: "/dev/null"
    )
    uploader = PartUploader.new(
      @client, state, max_threads: 1, max_retries: 0, retry_delay: 0.01
    )
    uploader.send(:on_upload_complete)
  end

  def test_uploader_default_on_before_thread_loop
    state = UploadState.new(
      upload_id: "u1", key: "k", part_size: 1024, total_size: 2048,
      local_path: "/dev/null"
    )
    uploader = PartUploader.new(
      @client, state, max_threads: 1, max_retries: 0, retry_delay: 0.01
    )
    uploader.send(:on_before_thread_loop, "t0", nil)
  end

  def test_uploader_safe_native_thread_id
    state = UploadState.new(
      upload_id: "u1", key: "k", part_size: 1024, total_size: 2048,
      local_path: "/dev/null"
    )
    uploader = PartUploader.new(
      @client, state, max_threads: 1, max_retries: 0, retry_delay: 0.01
    )
    tid = uploader.send(:safe_native_thread_id)
    assert(tid.nil? || tid.is_a?(Integer))
  end

  def test_uploader_safe_native_thread_id_rescue
    state = UploadState.new(
      upload_id: "u1", key: "k", part_size: 1024, total_size: 2048,
      local_path: "/dev/null"
    )
    uploader = PartUploader.new(
      @client, state, max_threads: 1, max_retries: 0, retry_delay: 0.01
    )
    Thread.current.singleton_class.define_method(:native_thread_id) { raise "unsupported" }
    assert_nil uploader.send(:safe_native_thread_id)
  ensure
    begin
      Thread.current.singleton_class.remove_method(:native_thread_id)
    rescue StandardError
      nil
    end
  end

  def test_uploader_thread_id
    state = UploadState.new(
      upload_id: "u1", key: "k", part_size: 1024, total_size: 2048,
      local_path: "/dev/null"
    )
    uploader = PartUploader.new(
      @client, state, max_threads: 1, max_retries: 0, retry_delay: 0.01
    )
    assert_equal "t0", uploader.send(:thread_id, 0)
    assert_equal "t5", uploader.send(:thread_id, 5)
  end

  def test_uploader_mark_part_done_default
    state = UploadState.new(
      upload_id: "u1", key: "k", part_size: 1024, total_size: 2048,
      local_path: "/dev/null"
    )
    uploader = PartUploader.new(
      @client, state, max_threads: 1, max_retries: 0, retry_delay: 0.01
    )
    uploader.instance_variable_get(:@thread_states)["t0"] = {
      status: "uploading", current_part: 1, parts_done: [], parts_count: 0
    }
    uploader.instance_variable_get(:@in_progress_parts)[1] = "t0"
    uploader.send(:mark_part_done, 1, "t0", 1)
  end

  def test_uploader_save_state_after_part_default
    state = UploadState.new(
      upload_id: "u1", key: "k", part_size: 1024, total_size: 2048,
      local_path: "/dev/null"
    )
    uploader = PartUploader.new(
      @client, state, max_threads: 1, max_retries: 0, retry_delay: 0.01
    )
    uploader.send(:save_state_after_part, 1, "etag", "t0")
  end

  # --- S3ParallelDownloader default methods ---

  def test_downloader_on_part_failed
    state = DownloadState.new(part_size: 1024, total_size: 2048)
    output = StringIO.new
    downloader = PartDownloader.new(
      @client, state, output_file: output,
                      max_threads: 1, max_retries: 0, retry_delay: 0.01
    )
    S3Client.clear_callbacks!
    events = []
    S3Client.on(:download_part_failed) { |*a| events << a }
    downloader.send(:on_part_failed, 1, "t0", RuntimeError.new("test"))
    assert_equal 1, events.size
  ensure
    S3Client.clear_callbacks!
  end

  def test_downloader_on_thread_start
    state = DownloadState.new(part_size: 1024, total_size: 2048)
    output = StringIO.new
    downloader = PartDownloader.new(
      @client, state, output_file: output,
                      max_threads: 1, max_retries: 0, retry_delay: 0.01
    )
    S3Client.clear_callbacks!
    events = []
    S3Client.on(:thread_start) { |*a| events << a }
    downloader.send(:on_thread_start, "t0", nil)
    assert_equal 1, events.size
  ensure
    S3Client.clear_callbacks!
  end

  def test_downloader_on_thread_finish
    state = DownloadState.new(part_size: 1024, total_size: 2048)
    output = StringIO.new
    downloader = PartDownloader.new(
      @client, state, output_file: output,
                      max_threads: 1, max_retries: 0, retry_delay: 0.01
    )
    S3Client.clear_callbacks!
    events = []
    S3Client.on(:thread_finish) { |*a| events << a }
    downloader.send(:on_thread_finish, "t0", 3)
    assert_equal 1, events.size
  ensure
    S3Client.clear_callbacks!
  end
end
