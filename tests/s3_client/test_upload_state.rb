# frozen_string_literal: true

require_relative "../test_helper"
require_relative "../../src/states/upload_state"

class UploadStateUnitTest < Minitest::Test
  def test_creation_with_hash_parts
    state = UploadState.new(
      key: "k", upload_id: "uid-1", part_size: 5_242_880, total_size: 10_485_760,
      parts: { 1 => "etag1", 2 => "etag2" }
    )
    assert_equal "k", state.key
    assert_equal 2, state.completed_parts_count
  end

  def test_creation_with_array_parts
    state = UploadState.new(
      parts: [{ part_number: 1, etag: "e1" }, { part_number: 2, etag: "e2" }]
    )
    assert_equal 2, state.parts.size
    assert_equal "e1", state.parts[1]
  end

  def test_from_json_hash_format
    json = %({"upload_id":"uid-1","key":"k","part_size":5242880,"total_size":10485760,"parts":{"1":"etag1"}})
    state = UploadState.from_json(json)
    assert_equal "uid-1", state.upload_id
    assert_equal "etag1", state.parts[1]
  end

  def test_from_json_array_format
    json = %({"key":"k","part_size":5242880,"total_size":10485760,"parts":[{"part_number":1,"etag":"e1"},{"part_number":2,"etag":"e2"}]})
    state = UploadState.from_json(json)
    assert_equal 2, state.parts.size
    assert_equal "e1", state.parts[1]
    assert_equal "e2", state.parts[2]
  end

  def test_from_json_in_progress_parts
    json = %({"key":"k","parts":{},"in_progress_parts":{"3":"t0"}})
    state = UploadState.from_json(json)
    assert_equal 1, state.in_progress_parts.size
    assert_equal "t0", state.in_progress_parts[3]
  end

  def test_from_file_not_found
    assert_raises(Errno::ENOENT) do
      UploadState.from_file("/nonexistent/path.json")
    end
  end

  def test_save_to_file_atomic_write
    state = UploadState.new(key: "k", upload_id: "uid-1")
    tmp = Tempfile.new(["upload_state", ".json"])
    tmp.close
    state.save_to_file(tmp.path)
    assert File.file?(tmp.path)
    refute File.exist?("#{tmp.path}.tmp")

    restored = UploadState.from_file(tmp.path)
    assert_equal "k", restored.key
    assert_equal "uid-1", restored.upload_id
  ensure
    tmp&.unlink
  end

  def test_save_to_file_nil_path
    state = UploadState.new
    state.save_to_file(nil)
  end

  def test_next_part_number_empty
    state = UploadState.new
    assert_equal 1, state.next_part_number
  end

  def test_next_part_number_gap
    state = UploadState.new(parts: { 1 => "e1", 3 => "e3" })
    assert_equal 2, state.next_part_number
  end

  def test_next_part_number_sequential
    state = UploadState.new(parts: { 1 => "e1", 2 => "e2" })
    assert_equal 3, state.next_part_number
  end

  def test_total_parts_edge_cases
    state = UploadState.new(total_size: nil, part_size: nil)
    assert_equal 0, state.total_parts

    state = UploadState.new(total_size: 0, part_size: 5_242_880)
    assert_equal 0, state.total_parts

    state = UploadState.new(total_size: 10_485_760, part_size: 5_242_880)
    assert_equal 2, state.total_parts
  end

  def test_progress_percentage
    state = UploadState.new(total_size: 10_485_760, part_size: 5_242_880)
    assert_equal 0, state.progress_percentage

    state = UploadState.new(parts: { 1 => "e1" }, total_size: 10_485_760, part_size: 5_242_880)
    assert_equal 50.0, state.progress_percentage
  end

  def test_bytes_uploaded_empty
    state = UploadState.new
    assert_equal 0, state.bytes_uploaded
  end

  def test_bytes_uploaded_with_parts
    state = UploadState.new(parts: { 1 => "e1", 2 => "e2" }, part_size: 5_242_880)
    assert_equal 10_485_760, state.bytes_uploaded
  end

  def test_bytes_uploaded_out_of_order_parts
    state = UploadState.new(
      key: "/test.bin", part_size: 100, total_size: 500,
      local_path: "/tmp/test.bin", upload_id: "uid",
      parts: { 1 => "e1", 2 => "e2", 4 => "e4" }
    )
    assert_equal 300, state.bytes_uploaded
  end

  def test_pending_part_numbers
    state = UploadState.new(parts: { 1 => "e1", 3 => "e3" }, total_size: 20_971_520, part_size: 5_242_880)
    assert_equal [2, 4], state.pending_part_numbers
  end

  def test_pending_part_numbers_empty
    state = UploadState.new(total_size: 0, part_size: 5_242_880)
    assert_equal [], state.pending_part_numbers
  end

  def test_in_progress_part_numbers
    state = UploadState.new(in_progress_parts: { 2 => "t0", 5 => "t1" })
    assert_equal [2, 5], state.in_progress_part_numbers
  end

  def test_part_list
    state = UploadState.new(parts: { 2 => "e2", 1 => "e1" })
    assert_equal [{ part_number: 1, etag: "e1" }, { part_number: 2, etag: "e2" }], state.part_list
  end

  # (removed: e_tag_list_alias test — alias removed)

  def test_summary
    state = UploadState.new(parts: { 1 => "e1" }, part_size: 5_242_880, total_size: 10_485_760)
    assert_includes state.summary, "parts=1/2"
    assert_includes state.summary, "50.0%"
  end

  def test_completed?
    state = UploadState.new
    refute state.completed?
    state.completed = true
    assert state.completed?
  end

  def test_total_file_size
    Tempfile.create(["us", ".bin"]) do |f|
      f.write("data")
      f.flush
      state = UploadState.new(local_path: f.path)
      assert_equal 4, state.total_file_size
    end
  end

  def test_total_file_size_not_exist
    state = UploadState.new(local_path: "/nonexistent")
    assert_equal 0, state.total_file_size
  end

  def test_total_file_size_nil_path
    state = UploadState.new
    assert_equal 0, state.total_file_size
  end

  def test_normalize_parts_nil
    state = UploadState.new(parts: nil)
    assert_equal 0, state.parts.size
  end

  def test_normalize_parts_string_keys
    state = UploadState.new(parts: { "1" => "e1", "2" => "e2" })
    assert_equal "e1", state.parts[1]
    assert_equal "e2", state.parts[2]
  end

  def test_normalize_in_progress_not_hash
    state = UploadState.new(in_progress_parts: nil)
    assert_equal 0, state.in_progress_parts.size

    state = UploadState.new(in_progress_parts: "invalid")
    assert_equal 0, state.in_progress_parts.size
  end

  def test_to_h_contains_all_keys
    state = UploadState.new(
      key: "k", upload_id: "u", part_size: 1024, total_size: 2048,
      parts: { 1 => "e" }
    )
    h = state.to_h
    assert_equal "k", h[:key]
    assert_equal 1024, h[:part_size]
    assert_equal "e", h[:parts][1]
  end

  def test_initialize_with_local_path
    state = UploadState.new(local_path: "/a")
    assert_equal "/a", state.local_path

    state2 = UploadState.new(local_path: "/c")
    assert_equal "/c", state2.local_path
  end

  def test_normalize_parts_unexpected_type
    state = UploadState.new(parts: "invalid_string")
    assert_equal 0, state.parts.size

    state2 = UploadState.new(parts: 42)
    assert_equal 0, state2.parts.size
  end

  def test_save_to_file_fsync_dir_rescue
    state = UploadState.new(key: "k", upload_id: "u1")
    Dir.mktmpdir do |dir|
      path = File.join(dir, "state.json")
      state.save_to_file(path)
      assert File.file?(path)
    end
  end
end
