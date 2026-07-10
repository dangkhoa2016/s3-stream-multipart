# frozen_string_literal: true

# s3_client.rb
#
# Resumable multipart upload + streaming download for S3-compatible storage.
# Uses aws-sigv4 for request signing, Net::HTTP for transport.
#
# RAM guarantees:
#   - Upload N GB file: max RAM ≈ part_size × max_concurrency
#                        (each thread reads exactly 1 part then sends it, doesn't keep entire file)
#   - Download N GB file: max RAM = chunk buffer (default few dozen KB, as
#                         Net::HTTP#read_body pipes chunks directly to File#write)

require_relative "core/base_client"
require_relative "core/event_registry"
require_relative "core/upload_state_manager"
require_relative "core/request_executor"
require_relative "states/upload_state"
require_relative "states/download_state"
require_relative "extras/helper"
require_relative "extras/retry_helper"
require_relative "concurrent/parallel_uploader"
require_relative "concurrent/parallel_downloader"
class S3Client < S3BaseClient
  extend S3EventRegistry

  include RequestExecutor
  include S3UploadLogic
  include S3DownloadLogic

  # -------------------- Tunables --------------------
  # DEFAULT_PART_SIZE is S3Client-specific (10 MB). All other constants are inherited from S3BaseClient.
  DEFAULT_PART_SIZE = 10 * 1024 * 1024 # 10 MB

  # -------------------- Errors --------------------
  # S3Error, UploadError, DownloadError are defined in S3BaseClient and inherited here.
  # Resolved via Ruby's constant lookup: `S3Client::S3Error` → `S3BaseClient::S3Error`.

  # Shared state classes (aliases for backward compatibility)
  UploadState   = ::UploadState
  DownloadState = ::DownloadState

  # PartUploader and PartDownloader are defined in s3_client/upload.rb and s3_client/download.rb.

  attr_reader :region, :bucket, :endpoint, :part_size,
              :max_concurrency, :max_retries, :retry_delay, :open_timeout, :read_timeout,
              :upload_state_manager

  # @param region              [String]  AWS region, e.g. "us-east-1"
  # @param bucket              [String]
  # @param access_key          [String]
  # @param secret_key          [String]
  # @param endpoint            [String, nil]
  #        AWS default -> nil (auto-builds virtual-hosted).
  #        MinIO/R2/... -> pass base URL (e.g. "https://minio.local:9000") + endpoint_style: :path
  # @param session_token       [String, nil]  for STS
  # @param part_size           [Integer]      part size (bytes)
  # @param max_concurrency     [Integer]      number of concurrent upload threads
  # @param retries             [Integer]      retries for transient errors / 5xx responses
  # @param open_timeout        [Integer]
  # @param read_timeout        [Integer]
  # @param endpoint_style      [Symbol]      :auto | :virtual_hosted | :path
  # @param logger              [Logger, nil]
  # @param log_file            [String, nil]  path to log file (enables file logging)
  # @param debug               [Boolean]      enable debug mode with detailed request/response logging
  #
  # @raise [ArgumentError] if access_key_id/access_key or secret_access_key/secret_key are missing
  # @raise [ArgumentError] if part_size is < 5 MB
  # @raise [S3BaseClient::ValidationError] if bucket name is invalid
  #
  # @example Basic MinIO setup
  #   client = S3Client.new(
  #     region: "us-east-1", bucket: "my-bucket",
  #     access_key_id: "minioadmin", secret_access_key: "minioadmin",
  #     endpoint: "https://minio.local:9000", endpoint_style: :path
  #   )
  # @example AWS S3 with env vars
  #   client = S3Client.new(
  #     region: "us-east-1", bucket: "my-bucket",
  #     access_key_id: ENV["AWS_ACCESS_KEY_ID"],
  #     secret_access_key: ENV["AWS_SECRET_ACCESS_KEY"]
  #   )
  # Single-bucket client always uses the bucket configured at construction
  def single_bucket?
    true
  end

  # @deprecated Use +access_key_id:+ instead of +access_key:+.
  # @deprecated Use +secret_access_key:+ instead of +secret_key:+.
  # @deprecated Use +max_concurrency:+ instead of +max_threads:+.
  # @deprecated Use +max_retries:+ instead of +retries:+.
  def initialize(region:, bucket:, **opts)
    normalize_deprecated_opts(opts)
    ak, sk = _extract_credentials!(opts)
    @part_size = _extract_part_size!(opts)

    super()

    self.class.validate_credentials!(ak, sk)
    self.class.validate_bucket!(bucket)

    @bucket             = bucket
    @access_key_id      = ak
    @secret_access_key  = sk

    endpoint = opts[:endpoint]
    endpoint_style = opts.fetch(:endpoint_style, :auto)
    @endpoint_style = resolve_style(endpoint_style, endpoint)
    @endpoint       = build_endpoint(endpoint, region, bucket, @endpoint_style)

    _assign_shared_opts(
      region: region, session_token: opts[:session_token],
      open_timeout: opts.fetch(:open_timeout, 30), read_timeout: opts.fetch(:read_timeout, 600),
      debug: opts.fetch(:debug, false),
      sse: opts[:sse],
      max_retries: opts.fetch(:max_retries, DEFAULT_MAX_RETRIES),
      retry_delay: opts.fetch(:retry_delay, DEFAULT_RETRY_DELAY),
      max_concurrency: opts[:max_concurrency],
      logger: opts[:logger], log_file: opts[:log_file],
      log_color: opts.fetch(:log_color, false), log_format: opts.fetch(:log_format, :text)
    )

    _init_shared(region: region, session_token: opts[:session_token],
                 access_key_id: ak, secret_access_key: sk,
                 signature_version: opts.fetch(:signature_version, :v4))

    @upload_transport = SingleBucketUploadTransport.new(self)
    @download_transport = SingleBucketDownloadTransport.new(self)
  end

  # setup_logger, log_request_details, log_response_details are inherited from S3BaseClient.

  # Delegate to service objects
  def upload_file(...)
    UploadService.new(client: self, logger: @logger).call(...)
  end

  def resume_upload(state_file:, key: nil, on_progress: nil, bucket: nil, local_path: nil)
    ResumeUpload.new(client: self, logger: @logger).call(
      state_file: state_file, key: key, on_progress: on_progress,
      bucket: bucket, local_path: local_path
    )
  end

  # Upload methods (upload_file_multipart, upload_directory, etc.) are
  # defined in s3_client/upload.rb.

  # Download methods (download_file, download_stream, etc.) are
  # defined in s3_client/download.rb.

  # Low-level multipart, simple ops, presigned URLs, and internal networking
  # are defined in s3_client/networking.rb.
  # Upload helpers (put_single_object, create_multipart_upload, etc.) are in
  # s3_client/upload.rb.

  private

  def _extract_credentials!(opts)
    ak = opts[:access_key_id]
    sk = opts[:secret_access_key]
    raise ArgumentError, "missing keywords: access_key_id and secret_access_key" if ak.nil? || sk.nil?

    [ak, sk]
  end

  def _extract_part_size!(opts)
    ps = opts.fetch(:part_size, DEFAULT_PART_SIZE)
    raise ArgumentError, "part_size must be >= 5MB" if ps < MIN_PART_SIZE

    ps
  end
end

require_relative "s3_client/networking"
require_relative "s3_client/upload"
require_relative "s3_client/download"
