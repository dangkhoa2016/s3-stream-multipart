# frozen_string_literal: true

#
# concurrent/part_geometry.rb
#
# Shared part geometry calculations for parallel upload/download workers.
# Provides offset and length computation for multi-part file operations.
#

module S3PartGeometry
  # Compute the byte offset and length for a given part number.
  #
  # @param part_number [Integer] the 1-based part number
  # @param part_size   [Integer] part size in bytes
  # @param total_size  [Integer] total file size in bytes
  # @return [Array(Integer, Integer)] [offset, length] in bytes
  def calculate_part_offset_and_length(part_number, part_size = @state.part_size, total_size = @state.total_size)
    offset = (part_number - 1) * part_size
    length = [part_size, (total_size - offset)].compact.min
    [offset, length]
  end

  # Compute byte offset, length, and end byte for a given part number.
  #
  # @param part_number [Integer] the 1-based part number
  # @param part_size   [Integer] part size in bytes
  # @param total_size  [Integer] total file size in bytes (ignored, kept for compat)
  # @return [Array(Integer, Integer, Integer)] [offset, length, end_byte]
  def calculate_part_geometry(part_number, _total_size = nil, part_size = @state.part_size, total_size = @state.total_size)
    offset, length = calculate_part_offset_and_length(part_number, part_size, total_size)
    end_byte = offset + length - 1
    [offset, length, end_byte]
  end
end
