# frozen_string_literal: true

#
# extras/helper.rb
#
# Convenience module for common use cases across S3Client and S3MultiBucketClient.
# Automatically detects client type and delegates to the appropriate method.

require_relative "bulk_uploader"

module S3Helper
  # Auto-selects single PUT or multipart upload based on file size.
  #
  # @param client              [S3Client | S3MultiBucketClient] the S3 client instance
  # @param key                 [String] the S3 object key
  # @param local_path          [String] local file path
  # @param bucket              [String, nil] the S3 bucket (required for S3MultiBucketClient)
  # @param multipart_threshold [Integer] byte threshold to switch to multipart (default 100 MB)
  # @param options             [Hash] additional options forwarded to upload_file
  #
  # @raise [ArgumentError] unless local_path is provided
  #
  # @return [Hash, void] the result from the underlying upload method
  #
  # @example Upload a file with auto-detection
  #   S3Helper.upload(client: s3, key: "dir/file.txt", local_path: "/tmp/file.txt")
  def self.upload(client:, key:, local_path:, bucket: nil,
                  multipart_threshold: 100 * 1024 * 1024, **options)
    path = local_path

    size = File.size(File.expand_path(path))

    if size > multipart_threshold && !options.key?(:part_size)
      auto_part = [(size.to_f / S3BaseClient::MAX_PARTS).ceil, S3BaseClient::MIN_PART_SIZE].max
      auto_part = (auto_part.to_f / (1024 * 1024)).ceil * 1024 * 1024
      options[:part_size] = auto_part
    end

    client.upload_file(local_path: path, key: key, bucket: bucket, **options)
  end

  # Download dispatch map for method resolution.
  #
  # Maps { single_bucket? => { mode => { method:, params: } } }.
  # @private
  DOWNLOAD_DISPATCH = {
    true => { default: { method: :download_file,
                         params: { key: :key, local_path: :path, on_progress: :progress } } },
    false => { default: { method: :download_file,
                          params: { bucket: :bucket, key: :key, destination_path: :path,
                                    on_progress: :progress } } }
  }.freeze

  # Download with optional simple progress bar to $stderr.
  #
  # @param client        [S3Client | S3MultiBucketClient] the S3 client instance
  # @param key           [String] the S3 object key
  # @param local_path    [String, nil] output path (for S3Client)
  # @param destination   [String, nil] output path (for S3MultiBucketClient)
  # @param bucket        [String, nil] the S3 bucket (required for S3MultiBucketClient)
  # @param show_progress [Boolean] show progress bar (default true)
  # @param options       [Hash] additional options forwarded to download method
  #
  # @raise [ArgumentError] if neither local_path nor destination is provided
  #
  # @return [Hash] the result from the underlying download method
  #
  # @example Download a file with progress bar
  #   S3Helper.download(client: s3, key: "dir/file.txt", local_path: "/tmp/file.txt")
  def self.download(client:, key:, local_path: nil, destination: nil, bucket: nil,
                    show_progress: true, **options)
    path = local_path || destination
    raise ArgumentError, "local_path or destination required" unless path

    bar_width = 40
    last_print = 0
    progress = if show_progress
                 lambda { |current, total|
                   if total&.positive?
                     pct = (current.to_f / total * 100).round(1)
                     if pct - last_print >= 1.0 || current == total
                       filled = (pct / 100.0 * bar_width).to_i
                       bar = ("█" * filled) + ("░" * (bar_width - filled))
                       $stderr.print "\r  [#{bar}] #{pct}%  " \
                                     "#{client.human_readable_size(current)} / " \
                                     "#{client.human_readable_size(total)}"
                       $stderr.puts if current == total
                       last_print = pct
                     end
                   end
                 }
               end

    is_single = client.single_bucket?
    entry     = DOWNLOAD_DISPATCH[is_single][:default]
    var_map   = { key: key, bucket: bucket, path: path, progress: progress }
    opts      = entry[:params].each_with_object({}) { |(k, v), h| h[k] = var_map[v] }
    opts.merge!(options)
    client.public_send(entry[:method], **opts)
  end

  # Upload all files in a local directory to S3 in parallel.
  # Files are mapped to S3 keys by relative path under the given prefix.
  # Per-file upload uses S3Helper.upload (auto single-PUT vs multipart).
  #
  # @param client              [S3Client | S3MultiBucketClient] the S3 client instance
  # @param directory           [String] local directory path
  # @param prefix              [String] S3 key prefix (default "")
  # @param bucket              [String, nil] required for S3MultiBucketClient
  # @param pattern             [String] glob pattern (default "**/*")
  # @param exclude             [Array<String>] glob patterns to skip
  # @param max_files           [Integer] files uploaded in parallel (default 4)
  # @param multipart_threshold [Integer] per-file byte threshold for multipart (default 100 MB)
  # @param on_file_start       [Proc, nil] callback(path, key, index, total)
  # @param on_file_complete    [Proc, nil] callback(path, key, result, index, total)
  # @param on_file_error       [Proc, nil] callback(path, key, error, index, total)
  # @param content_type        [String, nil] nil = auto-detect from extension
  # @param metadata            [Hash] user metadata forwarded to each upload
  # @param cache_control       [String, nil] forwarded to each upload
  # @param state_dir           [String, nil] directory for per-file resume state (large files only)
  # @param skip_existing       [Boolean] skip files that already exist with matching size/etag
  #
  # @return [Hash] result hash with keys: :uploaded, :failed, :skipped, :total_files,
  #                :total_bytes, :elapsed, :throughput
  #
  # @example Upload all files from a directory
  #   S3Helper.upload_bulk(client: s3, directory: "./build", prefix: "site/")
  def self.upload_bulk(client:, directory:, prefix: "", bucket: nil,
                       pattern: "**/*", exclude: [], max_files: 4,
                       multipart_threshold: 100 * 1024 * 1024,
                       on_file_start: nil, on_file_complete: nil, on_file_error: nil,
                       content_type: nil, metadata: {}, cache_control: nil,
                       skip_existing: false, state_dir: nil)
    uploader = S3BulkUploader.new(
      client: client, directory: directory, prefix: prefix,
      bucket: bucket, pattern: pattern, exclude: exclude,
      max_files: max_files, multipart_threshold: multipart_threshold,
      on_file_start: on_file_start, on_file_complete: on_file_complete,
      on_file_error: on_file_error,
      content_type: content_type, metadata: metadata, cache_control: cache_control,
      skip_existing: skip_existing, state_dir: state_dir
    )
    uploader.run!
  end
end
