# frozen_string_literal: true

#
# states/download_state.rb
#
# OOP wrapper for resumable parallel download state.
# Can serialize/deserialize, track progress, manage parts.
# Supports both hash-format parts ({ part_number => size }) and
# array-format parts ([{ part_number:, size: }]) for backward
# compatibility with older S3Client and S3MultiBucketClient state files.

require_relative "state_base"

class DownloadState < StateBase
  # @return [String, nil] local output path for the downloaded file
  attr_accessor :local_path

  # @return [String, nil] unique session identifier for this download
  attr_accessor :download_session_id

  alias destination_path local_path

  # Initialize a new download state.
  #
  # @param attrs [Hash] attribute hash:
  #   @option attrs [String] :local_path local output path
  #   @option attrs [String] :destination_path alias for local_path
  #   @option attrs [String] :download_session_id session identifier
  #   @option attrs [Hash] inherited keys passed to StateBase#initialize
  def initialize(attrs = {})
    super
    @local_path          = attrs[:local_path] || attrs[:destination_path]
    @download_session_id = attrs[:download_session_id]
  end

  # Convert state to a serializable hash.
  #
  # @return [Hash] all state attributes as a flat hash
  def to_h
    {
      key: @key, bucket: @bucket,
      local_path: @local_path,
      total_size: @total_size, part_size: @part_size,
      parts: @parts, completed: @completed,
      started_at: @started_at, last_updated_at: @last_updated_at,
      completed_at: @completed_at,
      download_session_id: @download_session_id,
      resumed_at: @resumed_at, resume_count: @resume_count
    }
  end

  # Calculate the total number of bytes downloaded.
  #
  # @return [Integer] bytes downloaded (sum of all part sizes)
  def bytes_downloaded
    @parts.values.sum(&:to_i)
  end

  # Return a detailed summary of download progress.
  #
  # @return [String] summary including part count and bytes
  def summary
    super + " bytes=#{bytes_downloaded}/#{@total_size || '?'}"
  end

  private

  # Normalize a part value to integer (byte count).
  #
  # @param v [Object] raw value
  # @return [Integer] integer representation
  def normalize_value(v)
    v.to_i
  end

  # Extract byte size from array-format part entry.
  #
  # @param p [Hash] part entry
  # @return [Integer] byte count (0 if missing)
  def normalize_array_value(p)
    p[:size] || p['size'] || 0
  end
end
