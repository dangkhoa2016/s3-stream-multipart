# frozen_string_literal: true

#
# states/upload_state.rb
#
# OOP wrapper for resumable multipart upload state.
# Can serialize/deserialize, track progress, manage parts.
# Supports both hash-format parts ({ part_number => etag }) and
# array-format parts ([{ part_number:, etag:, size: }]) for backward
# compatibility with older S3Client and S3MultiBucketClient state files.

require_relative "state_base"

class UploadState < StateBase
  # @return [String, nil] the multipart upload ID
  attr_accessor :upload_id

  # @return [String, nil] local path of the file being uploaded
  attr_accessor :local_path

  # @return [String, nil] file modification time at upload start
  attr_accessor :file_mtime

  # @return [String, nil] unique session identifier for this upload
  attr_accessor :upload_session_id

  # @return [Hash{Integer => String}] parts currently being uploaded (part_number => thread_id)
  attr_accessor :in_progress_parts

  # @return [Hash{String => Hash}] per-thread state tracking data
  attr_accessor :thread_states

  # @return [String, nil] ISO 8601 timestamp of last completed part
  attr_accessor :last_part_completed_at

  # @return [String, nil] fingerprint of the file content for change detection (mtime-size)
  attr_accessor :file_fingerprint

  # Initialize a new upload state.
  #
  # @param attrs [Hash] attribute hash:
  #   @option attrs [String] :upload_id multipart upload ID
  #   @option attrs [String] :local_path local file path
  #   @option attrs [String] :file_path alias for local_path (backward compat, maps to local_path)
  #   @option attrs [String] :file_mtime file modification time
  #   @option attrs [String] :upload_session_id session identifier
  #   @option attrs [Hash] :in_progress_parts parts in progress
  #   @option attrs [Hash] :thread_states per-thread state
  #   @option attrs [String] :last_part_completed_at timestamp
  #   @option attrs [String] :file_fingerprint content fingerprint
  #   @option attrs [Hash] inherited keys are passed to StateBase#initialize
  def initialize(attrs = {})
    super
    @upload_id          = attrs[:upload_id]
    @local_path         = attrs[:local_path]
    @file_mtime         = attrs[:file_mtime]
    @upload_session_id  = attrs[:upload_session_id]
    @in_progress_parts  = normalize_in_progress(attrs[:in_progress_parts] || {})
    @thread_states      = attrs[:thread_states] || {}
    @last_part_completed_at = attrs[:last_part_completed_at]
    @file_fingerprint = attrs[:file_fingerprint]
  end

  # Convert state to a serializable hash.
  #
  # @return [Hash] all state attributes as a flat hash
  def to_h
    {
      upload_id: @upload_id,
      key: @key,
      bucket: @bucket,
      part_size: @part_size,
      total_size: @total_size,
      local_path: @local_path,
      parts: @parts,
      completed: @completed,
      started_at: @started_at,
      last_updated_at: @last_updated_at,
      completed_at: @completed_at,
      file_mtime: @file_mtime,
      upload_session_id: @upload_session_id,
      in_progress_parts: @in_progress_parts,
      thread_states: @thread_states,
      last_part_completed_at: @last_part_completed_at,
      resumed_at: @resumed_at,
      resume_count: @resume_count,
      file_fingerprint: @file_fingerprint
    }
  end

  # Find the next available (lowest missing) part number.
  #
  # @return [Integer] the next part number to upload (1-indexed)
  def next_part_number
    uploaded = @parts.keys.map(&:to_i).sort
    return 1 if uploaded.empty?

    uploaded.each_with_index do |num, idx|
      expected = idx + 1
      return expected if num > expected
    end
    uploaded.last + 1
  end

  # Calculate the total number of bytes that have been uploaded.
  #
  # @return [Integer] bytes uploaded
  def bytes_uploaded
    return 0 if @parts.empty? || @part_size.nil?

    if @total_size
      n = @parts.keys.size
      last_part = @total_size - (@part_size * (n - 1))
      last_part = @part_size if last_part <= 0 || last_part > @part_size
      (@part_size * (n - 1)) + last_part
    else
      @parts.keys.size * @part_size
    end
  end

  # Return sorted list of part numbers currently being uploaded.
  #
  # @return [Array<Integer>] sorted in-progress part numbers
  def in_progress_part_numbers
    @in_progress_parts.keys.map(&:to_i).sort
  end

  # Build the part list required for completing the multipart upload.
  #
  # @return [Array<Hash{Symbol => Integer, String}>] array of { part_number:, etag: }
  def part_list
    @parts.keys.map(&:to_i).sort.map do |pn|
      { part_number: pn, etag: @parts[pn] }
    end
  end

  alias e_tag_list part_list

  # Return the current size of the source file on disk.
  #
  # @note Useful for detecting file changes between resume attempts.
  #
  # @return [Integer] file size in bytes (0 if file does not exist)
  def total_file_size
    return 0 unless @local_path && File.exist?(@local_path.to_s)

    File.size(@local_path)
  end

  # Return a detailed summary of upload progress.
  #
  # @return [String] summary including part count, bytes, in-progress parts, and thread info
  def summary
    super + " bytes=#{bytes_uploaded}/#{@total_size || '?'} " \
            "in_progress=#{in_progress_part_numbers.inspect} " \
            "threads=#{@thread_states.keys.size}"
  end

  private

  # Normalize a part value to string (etag format).
  #
  # @param v [Object] raw value
  # @return [String] string representation
  def normalize_value(v)
    v.to_s
  end

  # Extract etag from array-format part entry.
  #
  # @param p [Hash] part entry
  # @return [String, nil] etag value
  def normalize_array_value(p)
    p[:etag] || p['etag']
  end

  # Normalize in-progress parts hash to integer keys and string values.
  #
  # @param input [Hash] raw in-progress parts
  # @return [Hash{Integer => String}] normalized mapping
  def normalize_in_progress(input)
    return {} unless input.is_a?(Hash)

    input.each_with_object({}) do |(k, v), h|
      h[k.to_s.to_i] = v.to_s
    end
  end
end
