# frozen_string_literal: true

# s3_multi_bucket_client/upload.rb — upload operations for S3MultiBucketClient.
# Reopens S3MultiBucketClient to define upload methods.

require_relative "../upload/part_uploader"

class S3MultiBucketClient
  # =========================================================================
  # BULK UPLOAD
  # =========================================================================

  def upload_directory(bucket:, directory:, prefix: "", pattern: "**/*", exclude: [],
                       max_files: 4, multipart_threshold: 100 * 1024 * 1024,
                       on_file_start: nil, on_file_complete: nil, on_file_error: nil,
                       content_type: nil, metadata: {}, cache_control: nil,
                       skip_existing: false, state_dir: nil)
    S3BulkUploader.new(
      client: self, directory: directory, prefix: prefix,
      bucket: bucket, pattern: pattern, exclude: exclude,
      max_files: max_files, multipart_threshold: multipart_threshold,
      on_file_start: on_file_start, on_file_complete: on_file_complete,
      on_file_error: on_file_error,
      content_type: content_type, metadata: metadata, cache_control: cache_control,
      skip_existing: skip_existing, state_dir: state_dir
    ).run!
  end
end
