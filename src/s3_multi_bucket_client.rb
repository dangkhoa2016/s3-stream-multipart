# frozen_string_literal: true

require_relative "core/base_client"
require_relative "core/event_registry"
require_relative "core/request_executor"
require_relative "core/upload_state_manager"
require_relative "states/upload_state"
require_relative "states/download_state"
require_relative "extras/helper"
require_relative "extras/retry_helper"
require_relative "concurrent/parallel_uploader"
require_relative "concurrent/parallel_downloader"
# ============================================================
# S3MultiBucketClient - OOP Class for AWS S3 Upload/Download
# Features:
#   - Memory-efficient streaming upload (multipart/resumable)
#   - Memory-efficient streaming download (chunked)
#   - Thread-safe parallel part uploads
#   - Automatic retry with exponential backoff
#   - Progress callback support
#   - Uses aws-sigv4 gem + Net::HTTP (no aws-sdk-s3 needed)
# ============================================================
class S3MultiBucketClient < S3BaseClient
  extend S3EventRegistry
  include S3RetryHelper
  include RequestExecutor
  include S3UploadLogic
  include S3DownloadLogic

  # Default part size (8MB) — specific to multi-bucket variant
  DEFAULT_PART_SIZE = 8 * 1024 * 1024

  # Structured error class (S3Error) — inherited from S3BaseClient.
  # Resolved via Ruby's constant lookup: `S3MultiBucketClient::S3Error` → `S3BaseClient::S3Error`.

  # Default chunk size for streaming downloads (matches base class).
  DOWNLOAD_CHUNK_SIZE = READ_CHUNK_BYTES

  # Shared state classes (aliases for backward compatibility)
  UploadState   = ::UploadState
  DownloadState = ::DownloadState

  # Alias for backward compatibility — parse_multipart_uploads_xml was renamed.
  alias parse_multipart_uploads parse_multipart_uploads_xml
  alias parse_parts_list parse_parts_xml

  # PartUploader and PartDownloader are defined in
  # s3_multi_bucket_client/upload.rb and s3_multi_bucket_client/download.rb.

  # UploadError, DownloadError (and S3Error) are inherited from S3BaseClient.

  attr_reader :endpoint, :region, :bucket, :access_key_id, :secret_access_key, :session_token, :signer, :logger,
              :part_size, :max_concurrency, :max_retries, :retry_delay, :upload_state_manager

  # Initialize S3 client
  # @param bucket [String, nil] optional — when given, acts as single-bucket client (like S3Client)
  # @param endpoint [String] S3 endpoint URL
  # @param region [String] AWS region
  # @param access_key_id [String]
  # @param secret_access_key [String]
  # @param session_token [String, nil]
  # @param open_timeout [Integer] Connection timeout (default 30)
  # @param read_timeout [Integer] Read timeout (default 600)
  # @param logger [Logger, nil]
  # @param log_file [String, nil] path to log file (enables file logging)
  # @param debug [Boolean] enable debug mode with detailed request/response logging
  #
  # @raise [ArgumentError] if access_key_id or secret_access_key are missing
  # @raise [S3BaseClient::ValidationError] if access_key_id or secret_access_key are empty
  #
  # @example MinIO multi-bucket setup
  #   client = S3MultiBucketClient.new(
  #     endpoint: "https://minio.local:9000", region: "us-east-1",
  #     access_key_id: "minioadmin", secret_access_key: "minioadmin"
  #   )
  # @example Single-bucket setup (S3Client-compatible)
  #   client = S3MultiBucketClient.new(
  #     region: "us-east-1", bucket: "my-bucket",
  #     access_key_id: ENV["AWS_ACCESS_KEY_ID"],
  #     secret_access_key: ENV["AWS_SECRET_ACCESS_KEY"]
  #   )
  # @deprecated Use +access_key_id:+ instead of +access_key:+.
  # @deprecated Use +secret_access_key:+ instead of +secret_key:+.
  # @deprecated Use +max_concurrency:+ instead of +max_threads:+.
  def initialize(bucket: nil, endpoint: nil, region: nil,
                 access_key_id: nil, secret_access_key: nil, session_token: nil,
                 part_size: DEFAULT_PART_SIZE, endpoint_style: :auto,
                 open_timeout: 30, read_timeout: 600, logger: nil,
                 log_file: nil, debug: false, sse: nil,
                 max_retries: DEFAULT_MAX_RETRIES, retry_delay: DEFAULT_RETRY_DELAY,
                 max_concurrency: nil,
                 log_color: false,
                 log_format: :text,
                 signature_version: :v4,
                 **opts)
    super()
    normalize_deprecated_opts(opts)

    ak = access_key_id || opts[:access_key_id]
    sk = secret_access_key || opts[:secret_access_key]

    raise ArgumentError, "access_key_id is required" unless ak
    raise ArgumentError, "secret_access_key is required" unless sk

    if ak
      self.class.validate_credentials!(ak, sk,
                                       access_key_name: "access_key_id",
                                       secret_key_name: "secret_access_key")
    end

    if bucket
      self.class.validate_bucket!(bucket)
      @bucket = bucket
      @endpoint = endpoint&.chomp('/')
    else
      raise ArgumentError, "endpoint is required for multi-bucket client" unless endpoint

      @endpoint = endpoint.chomp('/')
    end

    self.class.validate_endpoint!(@endpoint) if @endpoint

    @part_size = part_size
    raise ArgumentError, "part_size too small: #{@part_size} (min #{MIN_PART_SIZE})" if @part_size < MIN_PART_SIZE

    @endpoint_style = resolve_style(endpoint_style, endpoint)

    _assign_shared_opts(
      region: region, session_token: session_token,
      open_timeout: open_timeout, read_timeout: read_timeout,
      debug: debug, sse: sse,
      max_retries: max_retries, retry_delay: retry_delay,
      max_concurrency: max_concurrency,
      logger: logger, log_file: log_file,
      log_color: log_color, log_format: log_format
    )

    _init_shared(region: region, session_token: session_token,
                 access_key_id: ak, secret_access_key: sk,
                 signature_version: signature_version)

    @upload_transport = MultiBucketUploadTransport.new(self)
    @download_transport = MultiBucketDownloadTransport.new(self)

    log_info "S3MultiBucketClient initialized for region: #{@region}"
  end

  def single_bucket?
    !@bucket.nil?
  end

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
  # defined in s3_multi_bucket_client/upload.rb.
  # Download methods (download_file, download_stream, etc.) are
  # defined in s3_multi_bucket_client/download.rb.
  # Networking/simple-ops (head_object, delete_object, presigned_url, etc.) are
  # defined in s3_multi_bucket_client/networking.rb.
end

require_relative "upload/upload_service"
require_relative "upload/resume_upload"
require_relative "s3_multi_bucket_client/networking"
require_relative "s3_multi_bucket_client/upload"
require_relative "s3_multi_bucket_client/download"
