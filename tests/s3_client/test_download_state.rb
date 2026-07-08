# frozen_string_literal: true

require_relative "../test_helper"
require_relative "../../src/s3_client"

class S3ClientDownloadStateTest < Minitest::Test
  def test_creation
    state = S3Client::DownloadState.new(
      key: "f.txt", bucket: "b",
      local_path: "/tmp/f.txt", part_size: 8 * 1024 * 1024,
      total_size: 32 * 1024 * 1024,
      parts: { 1 => 8_388_608, 2 => 8_388_608 }
    )
    assert_equal "f.txt", state.key
    assert_equal 2, state.completed_parts_count
    refute state.completed?
    assert_equal 4, state.total_parts
    assert_equal 50.0, state.progress_percentage
    assert_equal 16_777_216, state.bytes_downloaded
  end

  def test_json_round_trip
    state = S3Client::DownloadState.new(
      key: "k", bucket: "b", local_path: "/tmp/f",
      part_size: 5 * 1024 * 1024, total_size: 20 * 1024 * 1024,
      parts: { 1 => 5_242_880 }
    )
    json = state.to_json
    restored = S3Client::DownloadState.from_json(json)
    assert_equal "k", restored.key
    assert_equal 1, restored.parts.size
    assert_equal 5_242_880, restored.parts[1]
  end

  def test_save_to_file_and_from_file
    state = S3Client::DownloadState.new(
      key: "k2", bucket: "b2", local_path: "/tmp/f2",
      part_size: 5 * 1024 * 1024, total_size: 10 * 1024 * 1024,
      parts: { 1 => 5_242_880 }
    )
    tmp = Tempfile.new(["dl_state", ".json"])
    tmp.close
    state.save_to_file(tmp.path)
    assert File.file?(tmp.path)

    restored = S3Client::DownloadState.from_file(tmp.path)
    assert_equal "k2", restored.key
    assert_equal 1, restored.parts.size
  ensure
    tmp&.unlink
  end

  def test_from_file_not_found
    assert_raises(Errno::ENOENT) do
      S3Client::DownloadState.from_file("/nonexistent/state.json")
    end
  end

  def test_from_json_array_format_backward_compat
    json = %({"key":"k","bucket":"b","local_path":"/tmp/f","part_size":5242880,"total_size":10485760,"parts":[{"part_number":1,"size":5242880},{"part_number":2,"size":5242880}]})
    state = S3Client::DownloadState.from_json(json)
    assert_equal "k", state.key
    assert_equal 2, state.parts.size
    assert_equal 5_242_880, state.parts[1]
    assert_equal 5_242_880, state.parts[2]
  end

  def test_from_json_hash_format
    json = %({"key":"k","bucket":"b","local_path":"/tmp/f","part_size":5242880,"total_size":15728640,"parts":{"1":5242880,"3":5242880}})
    state = S3Client::DownloadState.from_json(json)
    assert_equal 2, state.parts.size
    assert_equal 5_242_880, state.parts[1]
    assert_equal 5_242_880, state.parts[3]
  end

  def test_pending_part_numbers
    state = S3Client::DownloadState.new(
      local_path: "/dev/null", part_size: 5 * 1024 * 1024,
      total_size: 20 * 1024 * 1024,
      parts: { 1 => 5_242_880, 3 => 5_242_880 }
    )
    assert_equal [2, 4], state.pending_part_numbers
  end

  def test_pending_part_numbers_empty
    state = S3Client::DownloadState.new(
      local_path: "/dev/null", part_size: 5 * 1024 * 1024,
      total_size: 0
    )
    assert_equal [], state.pending_part_numbers
  end

  def test_bytes_downloaded
    state = S3Client::DownloadState.new(
      part_size: 5 * 1024 * 1024,
      parts: { 1 => 5_242_880, 2 => 3_145_728 }
    )
    assert_equal 8_388_608, state.bytes_downloaded
  end

  def test_progress_percentage_zero
    state = S3Client::DownloadState.new(
      local_path: "/dev/null", part_size: 5 * 1024 * 1024,
      total_size: 0
    )
    assert_equal 0, state.progress_percentage
  end

  def test_summary
    state = S3Client::DownloadState.new(
      local_path: "/dev/null", part_size: 5 * 1024 * 1024,
      total_size: 10 * 1024 * 1024,
      parts: { 1 => 5_242_880 }
    )
    summary = state.summary
    assert_includes summary, "parts=1/2"
    assert_includes summary, "50.0%"
    assert_includes summary, "bytes=5242880"
  end

  def test_to_h_round_trip
    state = S3Client::DownloadState.new(
      key: "k", bucket: "b", local_path: "/tmp/f",
      part_size: 5 * 1024 * 1024, total_size: 20 * 1024 * 1024,
      parts: { 1 => 5_242_880 }, completed: false,
      download_session_id: "sess-1",
      resumed_at: "2024-01-01T00:00:00Z", resume_count: 1
    )
    h = state.to_h
    assert_equal "k", h[:key]
    assert_equal "sess-1", h[:download_session_id]
    assert_equal 1, h[:resume_count]

    restored = S3Client::DownloadState.new(h)
    assert_equal "sess-1", restored.download_session_id
    assert_equal 1, restored.resume_count
  end

  def test_total_parts_edge_cases
    state = S3Client::DownloadState.new(total_size: nil, part_size: nil)
    assert_equal 0, state.total_parts

    state = S3Client::DownloadState.new(total_size: 0, part_size: 5_242_880)
    assert_equal 0, state.total_parts

    state = S3Client::DownloadState.new(total_size: 10_485_760, part_size: 5_242_880)
    assert_equal 2, state.total_parts
  end

  def test_initialize_with_destination_path_alias
    state = S3Client::DownloadState.new(
      destination_path: "/tmp/out.bin"
    )
    assert_equal "/tmp/out.bin", state.local_path
    assert_equal "/tmp/out.bin", state.destination_path
  end

  def test_normalize_parts_unexpected_type
    state = S3Client::DownloadState.new(parts: "invalid")
    assert_equal 0, state.parts.size

    state2 = S3Client::DownloadState.new(parts: 42)
    assert_equal 0, state2.parts.size
  end

  def test_save_to_file_nil_path
    state = S3Client::DownloadState.new
    state.save_to_file(nil)
  end
end
