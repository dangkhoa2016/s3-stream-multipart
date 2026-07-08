# frozen_string_literal: true

require_relative "../test_helper"
require_relative "../../src/s3_multi_bucket_client"

class S3MultiBucketUploadStateTest < Minitest::Test
  def test_creation
    state = S3MultiBucketClient::UploadState.new(
      upload_id: "test-123", key: "file.txt", bucket: "bucket",
      local_path: "/tmp/f.txt", part_size: 8 * 1024 * 1024,
      total_size: 32 * 1024 * 1024,
      parts: [
        { part_number: 1, etag: '"abc"', size: 8 * 1024 * 1024 },
        { part_number: 2, etag: '"def"', size: 8 * 1024 * 1024 }
      ]
    )
    assert_equal "test-123", state.upload_id
    assert_equal 2, state.completed_parts_count
    assert_equal 3, state.next_part_number
    refute state.completed?
    assert_equal 4, state.total_parts
    assert_equal 50.0, state.progress_percentage
  end

  def test_json_round_trip
    state = S3MultiBucketClient::UploadState.new(
      upload_id: "u1", key: "k", bucket: "b", local_path: "/tmp/f",
      part_size: 5 * 1024 * 1024, total_size: 20 * 1024 * 1024,
      parts: [{ part_number: 1, etag: '"e1"', size: 5 * 1024 * 1024 }]
    )
    json = state.to_json
    restored = S3MultiBucketClient::UploadState.from_json(json)
    assert_equal "u1", restored.upload_id
    assert_equal 1, restored.parts.length
    assert_equal '"e1"', restored.parts[1]
  end

  def test_save_to_file_and_from_file
    state = S3MultiBucketClient::UploadState.new(
      upload_id: "u2", key: "k2", bucket: "b2", local_path: "/tmp/f2",
      part_size: 5 * 1024 * 1024, total_size: 10 * 1024 * 1024,
      parts: [{ part_number: 1, etag: '"x"', size: 5 * 1024 * 1024 }]
    )
    tmp = Tempfile.new(["state", ".json"])
    tmp.close
    state.save_to_file(tmp.path)
    assert File.file?(tmp.path)

    restored = S3MultiBucketClient::UploadState.from_file(tmp.path)
    assert_equal "u2", restored.upload_id
    assert_equal 1, restored.parts.length
  ensure
    tmp&.unlink
  end

  def test_gap_detection
    state = S3MultiBucketClient::UploadState.new(
      parts: [
        { part_number: 1, etag: "a" },
        { part_number: 3, etag: "c" },
        { part_number: 4, etag: "d" }
      ]
    )
    assert_equal 2, state.next_part_number
  end

  def test_bytes_uploaded
    state = S3MultiBucketClient::UploadState.new(
      part_size: 5 * 1024 * 1024,
      parts: [
        { part_number: 1, etag: "a", size: 5 * 1024 * 1024 },
        { part_number: 2, etag: "b", size: 3 * 1024 * 1024 }
      ]
    )
    assert_equal 10 * 1024 * 1024, state.bytes_uploaded
  end

  def test_pending_part_numbers
    state = S3MultiBucketClient::UploadState.new(
      local_path: "/dev/null", part_size: 5 * 1024 * 1024, total_size: 20 * 1024 * 1024,
      parts: [{ part_number: 1, etag: "a" }, { part_number: 3, etag: "c" }]
    )
    assert_equal [2, 4], state.pending_part_numbers
  end

  def test_part_list_sorted
    state = S3MultiBucketClient::UploadState.new(
      parts: [
        { part_number: 3, etag: "c" },
        { part_number: 1, etag: "a" },
        { part_number: 2, etag: "b" }
      ]
    )
    list = state.part_list
    assert_equal [1, 2, 3], list.map { |p| p[:part_number] }
    assert_equal ["a", "b", "c"], list.map { |p| p[:etag] }
  end

  def test_part_list_alias
    state = S3MultiBucketClient::UploadState.new(
      parts: [{ part_number: 1, etag: '"e1"' }, { part_number: 2, etag: '"e2"' }]
    )
    etags = state.part_list
    assert_equal 2, etags.length
    assert_equal '"e1"', etags[0][:etag]
  end

  def test_session_tracking
    state = S3MultiBucketClient::UploadState.new(
      upload_id: "test-uid", key: "/test.bin", bucket: "b",
      local_path: "/tmp/test.bin", part_size: 5 * 1024 * 1024, total_size: 20 * 1024 * 1024,
      parts: [{ part_number: 1, etag: "abc", size: 5 * 1024 * 1024 }],
      upload_session_id: "sess123", started_at: "2024-01-01T00:00:00Z",
      resume_count: 2
    )
    assert_equal "sess123", state.upload_session_id
    assert_equal 2, state.resume_count
    assert_includes state.summary, "parts=1/4"
    assert_includes state.summary, "25.0%"

    json = state.to_json
    restored = S3MultiBucketClient::UploadState.from_json(json)
    assert_equal "sess123", restored.upload_session_id
    assert_equal 2, restored.resume_count
  end
end
