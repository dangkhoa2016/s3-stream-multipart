# frozen_string_literal: true

require_relative "s3_client"
require_relative "s3_multi_bucket_client"
require_relative "core/result"
require_relative "core/session_metadata"
require_relative "core/upload_completion"
require_relative "upload/empty_upload"
require_relative "upload/single_part_upload"
require_relative "upload/multipart_upload"
require_relative "upload/resume_upload"
require_relative "upload/upload_service"
require_relative "download/download_service"
require_relative "download/single_part_download"
require_relative "extras/helper"

# Convenience factory — auto-selects single-bucket vs multi-bucket client.
#
# @param bucket [String, nil]
#   If provided → returns S3Client (single-bucket).
#   If nil     → returns S3MultiBucketClient (multi-bucket).
#   When omitted you must include +endpoint:+ in opts.
# @param opts [Hash] forwarded to the underlying constructor.
#
# @raise [ArgumentError] if +bucket:+ is nil and +endpoint:+ is missing from opts.
#
# @example Single-bucket client
#   client = S3Client.build(bucket: "my-bucket", region: "us-east-1",
#                            access_key_id: "...", secret_access_key: "...")
#
# @example Multi-bucket client (e.g. MinIO)
#   client = S3Client.build(region: "us-east-1", endpoint: "https://minio.local:9000",
#                            access_key_id: "minioadmin", secret_access_key: "minioadmin")
#
# @return [S3Client, S3MultiBucketClient]
def S3Client.build(bucket: nil, **opts)
  if bucket
    S3Client.new(bucket: bucket, **opts)
  else
    raise ArgumentError, "endpoint is required when building a multi-bucket client" unless opts[:endpoint]

    S3MultiBucketClient.new(**opts)
  end
end
