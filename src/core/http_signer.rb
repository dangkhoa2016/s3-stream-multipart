# frozen_string_literal: true

# core/http_signer.rb
#
# HTTP signing utilities for S3BaseClient.
#
# == Dependencies ==
# Including class must provide:
#   - @signer (Aws::SigV4::Signer)
#   - @open_timeout (Integer)
#   - @read_timeout (Integer)
#   - transient_errors (method returning Array of Exception classes)
#
# == Visibility ==
# Most methods are private (used internally by the base client).
# build_http_request and generate_presigned_url are public API.

module HttpSigner
  # Generate a presigned URL using the configured SigV4 signer.
  #
  # @param uri        [URI] the target URI
  # @param method     [Symbol] HTTP method (:get, :put, etc.)
  # @param expires_in [Integer] expiration time in seconds
  # @return [String] the presigned URL
  def generate_presigned_url(uri, method:, expires_in:)
    @signer.presign_url(
      http_method: method.to_s.upcase,
      url: uri.to_s,
      expires_in: expires_in
    ).to_s
  end

  # Build a signed Net::HTTP request object.
  #
  # @param method         [Symbol] HTTP method (:get, :put, :post, :delete, :head)
  # @param uri            [URI] the target URI
  # @param body           [String, IO, nil] request body (string or stream)
  # @param extra_headers  [Hash{String => String}] additional headers
  # @param stream         [Boolean] whether to use unsigned-payload mode for streaming
  # @param content_length [Integer, nil] explicit content length for streaming bodies
  #
  # @raise [ArgumentError] if +method+ is unsupported
  #
  # @return [Net::HTTPRequest] the signed request
  #
  # @note Content-Type is kept OUT of the SigV4 signature because some
  #   S3-compatible providers (e.g. Storadera) don't include it in their
  #   verification.
  # @note For streaming bodies (IO), uses UNSIGNED-PAYLOAD to avoid hashing
  #   large streams.
  def build_http_request(method, uri, body, extra_headers, stream: false, content_length: nil)
    req_class = case method.to_s.downcase.to_sym
                when :get    then Net::HTTP::Get
                when :put    then Net::HTTP::Put
                when :post   then Net::HTTP::Post
                when :delete then Net::HTTP::Delete
                when :head   then Net::HTTP::Head
                else raise ArgumentError, "unsupported method #{method}"
                end
    req = req_class.new(uri.request_uri)

    is_string_body = body.is_a?(String) && !body.empty?
    is_stream_body = !is_string_body && (body.respond_to?(:read) || stream)

    sign_headers = { "host" => uri.host }
    if is_string_body
      sign_headers["content-length"] = body.bytesize.to_s
    elsif content_length
      sign_headers["content-length"] = content_length.to_s
    end

    # UNSIGNED-PAYLOAD: used for streaming upload (IO body) to avoid
    # aws-sigv4 having to hash the entire stream before sending.
    sign_body = if is_stream_body
                  sign_headers["x-amz-content-sha256"] = "UNSIGNED-PAYLOAD"
                  nil
                else
                  is_string_body ? body : ""
                end

    # Separate content-type from signed headers: some S3-compatible providers
    # (e.g. Storadera) don't include content-type in SigV4 verification,
    # causing signature mismatch when it's part of the signed headers.
    unsigned_headers = {}
    (extra_headers || {}).each do |k, v|
      lk = k.to_s.downcase
      if lk == "content-type"
        unsigned_headers[lk] = v.to_s
      else
        sign_headers[lk] = v.to_s
      end
    end

    signed = @signer.sign_request(
      http_method: method.to_s.upcase,
      url: uri.to_s,
      headers: sign_headers,
      body: sign_body
    )

    sign_headers.each { |k, v| req[k] = v }
    signed.headers.each { |k, v| req[k] = v }
    unsigned_headers.each { |k, v| req[k] = v }
    if is_string_body
      req.body = body
      req["Content-Type"] ||= "application/octet-stream"
    elsif is_stream_body && body.respond_to?(:read)
      req.body_stream = body
      req["Content-Length"] = content_length.to_s if content_length && !req["Content-Length"]
      req["Content-Type"] ||= "application/octet-stream"
    end
    req
  end

  private

  # Apply signer headers onto an already-built request.
  #
  # Used by subclasses that construct their own Net::HTTP::Request and want
  # shared SigV4 signing.
  #
  # @param request [Net::HTTPRequest] the request to sign
  # @param method  [Symbol] HTTP method
  # @param uri     [URI] the target URI
  # @param body    [String, IO, nil] request body
  # @return [Net::HTTPRequest] the signed request (same object)
  def apply_signer_headers!(request, method, uri, body)
    request_headers = {}
    unsigned_headers = {}
    request.each_header do |k, v|
      if k.downcase == "content-type"
        unsigned_headers[k] = v
      else
        request_headers[k] = v
      end
    end

    sign_body = if body.respond_to?(:read)
                  request_headers["x-amz-content-sha256"] = "UNSIGNED-PAYLOAD"
                  nil
                else
                  body
                end

    signature = @signer.sign_request(
      http_method: method.to_s.upcase,
      url: uri.to_s,
      headers: request_headers,
      body: sign_body
    )

    signature.headers.each { |name, value| request[name] = value }
    unsigned_headers.each { |k, v| request[k] = v }
    request
  end
end
