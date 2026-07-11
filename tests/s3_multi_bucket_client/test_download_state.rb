# frozen_string_literal: true

require_relative "../test_helper"
require_relative "../../src/s3_multi_bucket_client"

class S3MultiBucketDownloadStateTest < Minitest::Test
  def test_creation
    state = S3MultiBucketClient::DownloadState.new(
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
  end

  def test_json_round_trip
    state = S3MultiBucketClient::DownloadState.new(
      key: "k", bucket: "b", local_path: "/tmp/f",
      part_size: 5 * 1024 * 1024, total_size: 20 * 1024 * 1024,
      parts: { 1 => 5_242_880 }
    )
    json = state.to_json
    restored = S3MultiBucketClient::DownloadState.from_json(json)
    assert_equal "k", restored.key
    assert_equal 1, restored.parts.size
  end

  def test_save_to_file_and_from_file
    state = S3MultiBucketClient::DownloadState.new(
      key: "k2", bucket: "b2", local_path: "/tmp/f2",
      part_size: 5 * 1024 * 1024, total_size: 10 * 1024 * 1024,
      parts: { 1 => 5_242_880 }
    )
    tmp = Tempfile.new(["dl_state", ".json"])
    tmp.close
    state.save_to_file(tmp.path)
    assert File.file?(tmp.path)

    restored = S3MultiBucketClient::DownloadState.from_file(tmp.path)
    assert_equal "k2", restored.key
    assert_equal 1, restored.parts.size
  ensure
    tmp&.unlink
  end

  def test_from_json_array_format_backward_compat
    json = %({"key":"k","local_path":"/tmp/f","part_size":5242880,"total_size":10485760,"parts":[{"part_number":1,"size":5242880},{"part_number":2,"size":5242880}]})
    state = S3MultiBucketClient::DownloadState.from_json(json)
    assert_equal 2, state.parts.size
    assert_equal 5_242_880, state.parts[1]
    assert_equal 5_242_880, state.parts[2]
  end

  def test_save_to_file_creates_tmp_and_renames
    state = S3MultiBucketClient::DownloadState.new(
      key: "k", local_path: "/tmp/f",
      part_size: 5 * 1024 * 1024, total_size: 10 * 1024 * 1024
    )
    tmp = Tempfile.new(["dl_state", ".json"])
    tmp.close
    File.delete(tmp.path)

    state.save_to_file(tmp.path)
    assert File.file?(tmp.path)
    refute File.exist?("#{tmp.path}.tmp")
  ensure
    File.delete(tmp.path) if tmp && File.exist?(tmp.path)
  end

  def test_pending_part_numbers
    state = S3MultiBucketClient::DownloadState.new(
      local_path: "/dev/null", part_size: 5 * 1024 * 1024,
      total_size: 20 * 1024 * 1024,
      parts: { 1 => 5_242_880, 3 => 5_242_880 }
    )
    assert_equal [2, 4], state.pending_part_numbers
  end

  def test_completed_flag
    state = S3MultiBucketClient::DownloadState.new
    refute state.completed?
    state.completed = true
    assert state.completed?
  end

  def test_summary
    state = S3MultiBucketClient::DownloadState.new(
      local_path: "/dev/null", part_size: 5 * 1024 * 1024,
      total_size: 10 * 1024 * 1024,
      parts: { 1 => 5_242_880 }
    )
    assert_includes state.summary, "parts=1/2"
    assert_includes state.summary, "bytes=5242880"
  end

  def test_total_parts_edge_cases
    state = S3MultiBucketClient::DownloadState.new(total_size: nil)
    assert_equal 0, state.total_parts

    state = S3MultiBucketClient::DownloadState.new(total_size: 0, part_size: 5_242_880)
    assert_equal 0, state.total_parts
  end
end
