# frozen_string_literal: true

# core/base_client.rb
#
# Shared base class for S3Client and S3MultiBucketClient.
#
# == Thread Safety ==
# Client instances are NOT thread-safe for concurrent public API calls
# (e.g. calling #upload_file from multiple threads on the same client).
# Session metadata is passed as a local hash through the call chain,
#
# For parallel operations (multipart upload/download), the client
# internally manages worker threads safely. The client instance should
# NOT be reused across independent thread contexts.
#
# Ruby's Logger is thread-safe. The aws-sigv4 Signer is effectively
# immutable after construction. All other shared state either uses mutex
# protection or is read-only after initialization.
# Contains code that is shared between the two clients:
#   - Event callback registry machinery (class-level, per-class isolated)
#   - S3Error / UploadError / DownloadError exception classes
#   - Logger setup + log helpers (log_info/warn/error/debug, thread_log*)
#   - Event emission (emit_event)
#   - Utility: human_readable_size, backoff_with_jitter, transient_errors,
#              now_mono, extract_metadata_from_headers, sse_headers
#   - HTTP helpers: build_http_request, apply_signer_headers (shared signing)
#   - XML helpers for multipart: extract_upload_id, extract_etag,
#              build_complete_multipart_xml, parse_multipart_uploads_xml,
#              parse_parts_xml
#
# Subclasses are responsible for:
#   - Per-class `class << self` event registry block (so each class has its own
#     @event_callbacks / @log_queue / @registry_mutex).
#   - Nested UploadState / DownloadState / PartUploader / PartDownloader classes
#     (different data shapes and HTTP strategies).
#   - Public API methods: upload_file, download_file, head_object, etc.
#   - Endpoint / URL construction (build_uri, build_endpoint).

require "net/http"
require "net/https"
require "uri"
require "cgi"
require "fileutils"
require "json"
require "logger"
require "aws-sigv4"
require "securerandom"
require "digest"
require "tempfile"
require "rexml/document"
require "rexml/formatters/default"

require_relative "http_signer"
require_relative "validator"
require_relative "constants"
require_relative "errors"
require_relative "xml_helpers"
require_relative "logging"
require_relative "utils"
require_relative "download_helpers"
require_relative "upload_transport"
require_relative "download_transport"
require_relative "upload_logic"
require_relative "download_logic"

class S3BaseClient
  include HttpSigner
  include S3Constants
  include S3Errors
  include S3Logging
  include S3XmlHelpers
  include S3Utils
  include S3DownloadHelpers
  extend Validator

  # Mapping of deprecated parameter names to their replacements.
  DEPRECATED_OPTS = {
    access_key: :access_key_id,
    secret_key: :secret_access_key,
    max_threads: :max_concurrency,
    retries: :max_retries
  }.freeze

  def normalize_deprecated_opts(opts)
    DEPRECATED_OPTS.each do |old_key, new_key|
      next unless opts.key?(old_key)

      loc = caller_locations(2, 1).first
      warn "[DEPRECATION] `#{old_key}:` is deprecated, use `#{new_key}:` instead. " \
           "Called from #{loc.path}:#{loc.lineno}"
      opts[new_key] = opts.delete(old_key)
    end
    opts
  end

  private :normalize_deprecated_opts

  # Whether this client manages a single fixed bucket.
  # @return [Boolean] +true+ for +S3Client+, +false+ for +S3MultiBucketClient+
  def single_bucket?
    false
  end

  attr_reader :upload_transport, :download_transport

  # =========================================================================
  # SHARED HELPERS — used by both S3Client and S3MultiBucketClient
  # =========================================================================

  # Resolve the bucket to use: explicit parameter or instance default.
  def resolve_bucket(bucket = nil)
    bucket || @bucket
  end

  # Parse a HEAD response into a standard metadata hash.
  def parse_head_response(resp)
    {
      content_length: resp["content-length"]&.to_i,
      content_type: resp["content-type"],
      etag: resp["etag"]&.gsub(/^"|"$/, ""),
      last_modified: resp["last-modified"],
      storage_class: resp["x-amz-storage-class"],
      metadata: extract_metadata_from_headers(resp)
    }
  end

  # Check for an existing .part file and return its size (resume start byte).
  def resume_start_byte(local_path)
    part_path = "#{local_path}.part"
    File.exist?(part_path) ? File.size(part_path) : 0
  end

  # Build Range headers for resume download.
  def build_resume_headers(start_byte)
    start_byte.positive? ? { "Range" => "bytes=#{start_byte}-" } : {}
  end

  # Parse Content-Range or Content-Length to determine total size.
  def parse_content_range(resp)
    if resp["content-range"]
      resp["content-range"][%r{/(\d+)$}, 1]&.to_i
    else
      resp["content-length"]&.to_i
    end
  end

  # Resolve endpoint style: nil/:auto → :path if custom endpoint, :virtual_hosted otherwise.
  def resolve_style(style, endpoint)
    return style unless style.nil? || style == :auto

    if endpoint
      :path
    else
      :virtual_hosted
    end
  end

  # Check if an S3 object's ETag matches a local file.
  def etag_matches_file?(etag, local_path)
    return false unless etag

    clean = etag.gsub(/^"|"$/, "")
    clean.include?("-") || clean == Digest::MD5.file(local_path).hexdigest
  end

  # =========================================================================
  # SIMPLE S3 OPERATIONS — unified via _ops_execute / _ops_build_uri hooks
  # Subclasses define _ops_execute / _ops_build_uri in their Networking modules.
  # =========================================================================

  def head_object(key:, bucket: nil)
    _ops_execute(:head, key, bucket: bucket) { |resp| parse_head_response(resp) }
  end

  def delete_object(key:, bucket: nil)
    _ops_execute(:delete, key, bucket: bucket) do |resp|
      unless resp.is_a?(Net::HTTPNoContent)
        raise S3Error.new(resp.code, "Delete failed", resp["x-amz-request-id"], resp.body)
      end

      log_info "Object deleted: #{key}"
      _format_delete_result(key)
    end
  end

  def presigned_url(key:, method: :get, expires_in: 3600, bucket: nil, query: nil)
    uri = _ops_build_uri(key, method: method, query: query, bucket: bucket)
    url = generate_presigned_url(uri, method: method, expires_in: expires_in)
    log_info "presigned_url: #{method.to_s.upcase} #{key.inspect} expires_in=#{expires_in}s"
    url
  end

  def list_multipart_uploads(prefix: nil, max_uploads: 100, bucket: nil)
    query = { "uploads" => "", "max-uploads" => max_uploads.to_s }
    query["prefix"] = prefix if prefix
    _ops_execute(:get, "/", bucket: bucket, query: query) do |resp|
      xml = resp.body
      log_debug "list_multipart_uploads: #{xml.bytesize}B XML"
      parse_multipart_uploads_xml(xml)
    end
  end

  def list_parts(key:, upload_id:, max_parts: 100, bucket: nil)
    upload_id_param = { "uploadId" => upload_id, "max-parts" => max_parts.to_s }
    _ops_execute(:get, key, bucket: bucket, query: upload_id_param) do |resp|
      xml = resp.body
      log_debug "list_parts: #{xml.bytesize}B XML"
      parse_parts_xml(xml)
    end
  end

  # =========================================================================
  # SHARED MULTIPART UPLOAD HELPERS — subclass-agnostic via _ops_execute hook
  # Subclasses provide _ops_execute / _ops_build_uri in their Networking modules.
  # =========================================================================

  # Create an S3 multipart upload and return the upload ID.
  def create_multipart_upload(key:, content_type: "application/octet-stream",
                              metadata: {}, cache_control: nil, bucket: nil)
    headers = { "content-type" => content_type }
    headers.merge!(sse_headers)
    metadata.each { |k, v| headers["x-amz-meta-#{k}"] = v.to_s }
    headers["cache-control"] = cache_control if cache_control

    _ops_execute(:post, key, bucket: bucket, headers: headers, query: { uploads: nil }) do |resp|
      extract_upload_id(resp.read_body)
    end
  end

  # Check if an object already exists in S3 with matching size and ETag.
  def check_skip_existing(key:, file_path:, file_size:, bucket: nil)
    existing = begin
      _ops_execute(:head, key, bucket: bucket) { |resp| parse_head_response(resp) }
    rescue S3Error
      nil
    end
    return unless existing && existing[:content_length] == file_size && etag_matches_file?(existing[:etag], file_path)

    log_info "skip_existing: key=#{key.inspect} already exists " \
             "(size=#{file_size}, etag=#{existing[:etag]})"
    { key: key, skipped: true, reason: "already exists (size=#{file_size})" }
  end

  # =========================================================================
  # HTTP CONNECTION — unified Net::HTTP.start with best-practice SSL config
  # Subclasses with different http_start signatures should delegate here.
  # =========================================================================

  private

  def _http_start(uri, &block)
    Net::HTTP.start(uri.host, uri.port,
                    use_ssl: uri.scheme == "https",
                    verify_mode: OpenSSL::SSL::VERIFY_PEER,
                    open_timeout: @open_timeout,
                    read_timeout: @read_timeout,
                    connect_timeout: @open_timeout, &block)
  end

  # Assign shared instance variables from constructor keyword arguments.
  # Intended to be called by each subclass constructor after validation.
  def _assign_shared_opts(region:, session_token: nil,
                          open_timeout: 30, read_timeout: 600,
                          debug: false, sse: nil,
                          max_retries: DEFAULT_MAX_RETRIES, retry_delay: DEFAULT_RETRY_DELAY,
                          max_concurrency: nil,
                          logger: nil, log_file: nil, log_color: false, log_format: :text)
    @region          = region
    @session_token   = session_token
    @open_timeout    = open_timeout
    @read_timeout    = read_timeout
    @sse             = sse
    @max_retries     = max_retries
    @retry_delay     = retry_delay

    setup_logger(logger, log_file: log_file, debug: debug, log_color: log_color, log_format: log_format)

    requested = (max_concurrency || DEFAULT_MAX_THREADS).to_i
    @max_concurrency = requested.clamp(1, MAXIMUM_CONCURRENCY)
    return unless @max_concurrency != requested

    log_warn "[CONCURRENCY] max_concurrency=#{requested} clamped to #{@max_concurrency} " \
             "(valid range: 1–#{MAXIMUM_CONCURRENCY})"
  end

  # Initialize shared components (signer, state manager, transports).
  # Called by subclass constructors after validation and _assign_shared_opts.
  def _init_shared(region:, access_key_id:, secret_access_key:, session_token: nil)
    @region          = region
    @session_token   = session_token
    @access_key_id   = access_key_id
    @secret_access_key = secret_access_key

    @signer = Aws::Sigv4::Signer.new(
      service: "s3",
      region: @region,
      access_key_id: @access_key_id,
      secret_access_key: @secret_access_key,
      session_token: @session_token,
      uri_escape_path: false
    )

    @upload_state_manager = UploadStateManager.new(self)
  end

  public

  # Emit an event to all registered callbacks.
  # Catches and logs callback errors so one bad callback doesn't break upload.
  # Public so callers can emit custom events.
  def emit_event(event, *args)
    callbacks = self.class.registry_mutex.synchronize do
      self.class.event_callbacks[event.to_sym].dup
    end
    callbacks.each do |cb|
      cb.call(*args)
    rescue StandardError => e
      log_warn "[EVENT] callback for #{event} raised: #{e.class}: #{e.message}"
    end
  end
end
