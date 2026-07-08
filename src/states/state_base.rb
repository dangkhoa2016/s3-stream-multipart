# frozen_string_literal: true

#
# states/state_base.rb
#
# Shared base class for UploadState and DownloadState.
# Provides common state management: JSON serialization, progress tracking,
# part management, and persistence with atomic writes.

require "json"

class StateBase
  # @return [String, nil] the S3 object key
  attr_accessor :key

  # @return [String, nil] the S3 bucket name
  attr_accessor :bucket

  # @return [Integer, nil] part size in bytes
  attr_accessor :part_size

  # @return [Integer, nil] total file size in bytes
  attr_accessor :total_size

  # @return [Hash{Integer => Object}] mapping of part numbers to their metadata (etag for uploads, size for downloads)
  attr_accessor :parts

  # @return [Boolean] whether the transfer is completed
  attr_accessor :completed

  # @return [String, nil] ISO 8601 timestamp when transfer started
  attr_accessor :started_at

  # @return [String, nil] ISO 8601 timestamp of last state update
  attr_accessor :last_updated_at

  # @return [String, nil] ISO 8601 timestamp when transfer completed
  attr_accessor :completed_at

  # @return [String, nil] ISO 8601 timestamp when transfer was resumed
  attr_accessor :resumed_at

  # @return [Integer] number of times the transfer has been resumed
  attr_accessor :resume_count

  # Initialize a new state object.
  #
  # @param attrs [Hash] attribute hash with optional keys:
  #   @option attrs [String] :key S3 object key
  #   @option attrs [String] :bucket S3 bucket name
  #   @option attrs [Integer] :part_size part size in bytes
  #   @option attrs [Integer] :total_size total file size
  #   @option attrs [Hash, Array] :parts completed parts (hash or array format)
  #   @option attrs [Boolean] :completed whether transfer is complete
  #   @option attrs [String] :started_at ISO 8601 start timestamp
  #   @option attrs [String] :last_updated_at ISO 8601 update timestamp
  #   @option attrs [String] :completed_at ISO 8601 completion timestamp
  #   @option attrs [String] :resumed_at ISO 8601 resume timestamp
  #   @option attrs [Integer] :resume_count resume count
  def initialize(attrs = {})
    @key             = attrs[:key]
    @bucket          = attrs[:bucket]
    @part_size       = attrs[:part_size]
    @total_size      = attrs[:total_size]
    @parts           = normalize_parts(attrs[:parts] || {})
    @completed       = attrs[:completed] || false
    @started_at      = attrs[:started_at]
    @last_updated_at = attrs[:last_updated_at]
    @completed_at    = attrs[:completed_at]
    @resumed_at      = attrs[:resumed_at]
    @resume_count    = attrs[:resume_count] || 0
  end

  # Calculate the total number of parts for the transfer.
  #
  # @return [Integer] total parts (0 if size or part_size is unknown)
  def total_parts
    return 0 if @total_size.nil? || @total_size.zero? || @part_size.nil?

    (@total_size.to_f / @part_size).ceil
  end

  # Return the count of completed parts.
  #
  # @return [Integer] number of completed parts
  def completed_parts_count = @parts.size

  # Calculate the progress percentage.
  #
  # @return [Float] percentage complete (0.0 to 100.0)
  def progress_percentage
    return 0 if total_parts.zero?

    ((completed_parts_count.to_f / total_parts) * 100).round(2)
  end

  # Check whether the transfer is marked as completed.
  #
  # @return [Boolean]
  def completed? = @completed

  # Return an array of part numbers that have not yet been completed.
  #
  # @return [Array<Integer>] pending part numbers (1-indexed)
  def pending_part_numbers
    return [] if total_parts.zero?

    done = @parts.keys.to_set(&:to_i)
    (1..total_parts).reject { |n| done.include?(n) }
  end

  # Serialize state to a JSON string.
  #
  # @return [String] JSON representation of the state
  def to_json(*_args)
    JSON.generate(to_h)
  end

  # Deserialize state from a JSON string.
  #
  # @param json_str [String] JSON string
  # @return [StateBase] new state instance
  def self.from_json(json_str)
    data = JSON.parse(json_str, symbolize_names: true)
    new(data)
  end

  # Load state from a JSON file on disk.
  #
  # @param path [String] path to the state file
  # @raise [Errno::ENOENT] if the file does not exist
  # @return [StateBase] new state instance
  def self.from_file(path)
    raise Errno::ENOENT, path unless File.file?(path)

    from_json(File.read(path))
  end

  # Atomically save state to a file using a temporary file + rename.
  #
  # @param path [String, nil] output path (no-op if nil)
  # @return [void]
  def save_to_file(path)
    return unless path

    tmp = "#{path}.tmp"
    File.open(tmp, 'w') do |f|
      f.write(to_json)
      f.fsync
    end
    File.rename(tmp, path)
    sync_dir(File.dirname(path))
  end

  # Return a human-readable summary of progress.
  #
  # @return [String] summary string like "parts=3/10 (30.0%)"
  def summary
    "parts=#{completed_parts_count}/#{total_parts} (#{progress_percentage}%)"
  end

  # Hash-style access for backward compatibility with legacy state access patterns.
  def [](key)
    respond_to?(key) ? send(key) : nil
  end

  def []=(key, value)
    setter = :"#{key}="
    respond_to?(setter) ? send(setter, value) : nil
  end

  private

  # Synchronize a directory to ensure state file is persisted.
  #
  # @param path [String] directory path
  # @return [void]
  def sync_dir(path)
    File.open(path, &:fsync)
  rescue Errno::EISDIR, Errno::EINVAL, IOError, Errno::EACCES
    # Best-effort directory sync — not critical for correctness
  end

  # Normalize parts input into a consistent hash format.
  #
  # @param input [Hash, Array, nil] raw parts data
  # @return [Hash{Integer => Object}] normalized parts mapping
  def normalize_parts(input)
    case input
    in Hash
      input.each_with_object({}) { |(k, v), h| h[k.to_s.to_i] = normalize_value(v) }
    in Array
      input.each_with_object({}) do |p, h|
        pn = p[:part_number] || p['part_number']
        h[pn.to_i] = normalize_array_value(p) if pn
      end
    else
      {}
    end
  end

  # Transform a single part value (overridden by subclasses).
  #
  # @param v [Object] raw value
  # @return [Object] normalized value
  def normalize_value(v) = v

  # Extract the relevant value from an array-format part entry (overridden by subclasses).
  #
  # @param p [Hash] part entry hash
  # @return [Object] extracted value
  def normalize_array_value(p)
    p[:etag] || p['etag']
  end
end
