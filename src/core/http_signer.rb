# frozen_string_literal: true

require "base64"
require "openssl"

# core/http_signer.rb
#
# HTTP signing utilities for S3BaseClient.
#
# == Dependencies ==
# Including class must provide:
#   - @signer (Aws::SigV4::Signer) — only when signature_version == :v4
#   - @signature_version (:v2 | :v4)
#   - @access_key_id (String)
#   - @secret_access_key (String)
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

    if @signature_version == :v2
      _build_request_v2(req, method, uri, body, extra_headers,
                        is_string_body: is_string_body, is_stream_body: is_stream_body,
                        content_length: content_length)
    else
      _build_request_v4(req, method, uri, body, extra_headers,
                        is_string_body: is_string_body, is_stream_body: is_stream_body,
                        content_length: content_length)
    end
    req
  end

  private

  # ─────────────────────────────────────────────────────────────────────
  #  SigV2 signing
  # ─────────────────────────────────────────────────────────────────────

  def _build_request_v2(req, method, uri, body, extra_headers, is_string_body:, is_stream_body:, content_length:)
    date_str = Time.now.utc.strftime("%a, %d %b %Y %H:%M:%S GMT")
    req["Date"] = date_str

    # Collect x-amz-* headers for canonicalized string
    amz_headers = {}
    (extra_headers || {}).each do |k, v|
      lk = k.to_s.downcase
      if lk.start_with?("x-amz-")
        amz_headers[lk] = v.to_s
      else
        req[k] = v.to_s
      end
    end

    content_type = (extra_headers || {}).find { |k, _| k.to_s.downcase == "content-type" }
    content_type_val = content_type ? content_type[1].to_s : ""
    md5 = ""

    resource = uri.path.empty? ? "/" : uri.path

    parts = [method.to_s.upcase, md5, content_type_val, date_str]
    amz_headers.sort.each { |k, v| parts << "#{k}:#{v}" }
    parts << resource
    string_to_sign = parts.join("\n")

    if @debug_mode
      warn "\e[35m[SIGV2]\e[0m string_to_sign=\e[2m#{string_to_sign.inspect}\e[0m"
      warn "\e[35m[SIGV2]\e[0m resource=\e[33m#{resource}\e[0m"
    end

    signature = Base64.strict_encode64(
      OpenSSL::HMAC.digest("SHA1", @secret_access_key, string_to_sign)
    )

    req["Authorization"] = "AWS #{@access_key_id}:#{signature}"

    if @debug_mode
      warn "\e[35m[SIGV2]\e[0m auth=\e[36m#{req['Authorization']}\e[0m"
    end

    if is_string_body
      req.body = body
      req["Content-Type"] ||= "application/octet-stream"
    elsif is_stream_body && body.respond_to?(:read)
      req.body_stream = body
      req["Content-Length"] = content_length.to_s if content_length && !req["Content-Length"]
      req["Content-Type"] ||= "application/octet-stream"
    end
  end

  # ─────────────────────────────────────────────────────────────────────
  #  SigV4 signing (existing logic)
  # ─────────────────────────────────────────────────────────────────────

  def _build_request_v4(req, method, uri, body, extra_headers, is_string_body:, is_stream_body:, content_length:)
    sign_headers = { "host" => uri.host }
    if is_string_body
      sign_headers["content-length"] = body.bytesize.to_s
    elsif content_length
      sign_headers["content-length"] = content_length.to_s
    end

    sign_body = if is_stream_body
                  sign_headers["x-amz-content-sha256"] = "UNSIGNED-PAYLOAD"
                  nil
                else
                  is_string_body ? body : ""
                end

    # Separate content-type from signed headers: some S3-compatible providers
    # (e.g. Storadera) don't include content-type in SigV4 verification.
    unsigned_headers = {}
    (extra_headers || {}).each do |k, v|
      lk = k.to_s.downcase
      if lk == "content-type"
        unsigned_headers[lk] = v.to_s
      else
        sign_headers[lk] = v.to_s
      end
    end

    if @debug_mode
      warn "\e[35m[SIGV4]\e[0m method=\e[1m#{method.to_s.upcase}\e[0m url=\e[33m#{uri}\e[0m"
      warn "\e[35m[SIGV4]\e[0m sign_headers=\e[2m#{sign_headers.inspect}\e[0m"
      warn "\e[35m[SIGV4]\e[0m body=\e[2m#{sign_body.is_a?(String) ? sign_body[0..100].inspect : sign_body.inspect}\e[0m"
    end

    signed = @signer.sign_request(
      http_method: method.to_s.upcase,
      url: uri.to_s,
      headers: sign_headers,
      body: sign_body
    )

    if @debug_mode
      warn "\e[35m[SIGV4]\e[0m signed=\e[2m#{signed.headers.inspect}\e[0m"
    end

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
  end

  # ─────────────────────────────────────────────────────────────────────
  #  apply_signer_headers! — used by S3MultiBucketClient
  # ─────────────────────────────────────────────────────────────────────

  # Apply signer headers onto an already-built request.
  #
  # @param request [Net::HTTPRequest] the request to sign
  # @param method  [Symbol] HTTP method
  # @param uri     [URI] the target URI
  # @param body    [String, IO, nil] request body
  # @return [Net::HTTPRequest] the signed request (same object)
  def apply_signer_headers!(request, method, uri, body)
    if @signature_version == :v2
      _apply_signer_headers_v2!(request, method, uri, body)
    else
      _apply_signer_headers_v4!(request, method, uri, body)
    end
  end

  def _apply_signer_headers_v2!(request, method, uri, body)
    date_str = request["date"] || request["Date"] || Time.now.utc.strftime("%a, %d %b %Y %H:%M:%S GMT")
    request["Date"] = date_str

    amz_headers = {}
    content_type_val = ""
    request.each_header do |k, v|
      lk = k.to_s.downcase
      if lk.start_with?("x-amz-")
        amz_headers[lk] = v
      elsif lk == "content-type"
        content_type_val = v
      end
    end

    md5 = ""

    resource = uri.path.empty? ? "/" : uri.path

    parts = [method.to_s.upcase, md5, content_type_val, date_str]
    amz_headers.sort.each { |k, v| parts << "#{k}:#{v}" }
    parts << resource
    string_to_sign = parts.join("\n")

    if @debug_mode
      warn "\e[35m[SIGV2]\e[0m method=\e[1m#{method.to_s.upcase}\e[0m resource=\e[33m#{resource}\e[0m"
      warn "\e[35m[SIGV2]\e[0m string_to_sign=\e[2m#{string_to_sign.inspect}\e[0m"
    end

    signature = Base64.strict_encode64(
      OpenSSL::HMAC.digest("SHA1", @secret_access_key, string_to_sign)
    )

    request["Authorization"] = "AWS #{@access_key_id}:#{signature}"
    request
  end

  def _apply_signer_headers_v4!(request, method, uri, body)
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

    if @debug_mode
      warn "\e[35m[SIGV4]\e[0m method=\e[1m#{method.to_s.upcase}\e[0m url=\e[33m#{uri}\e[0m"
      warn "\e[35m[SIGV4]\e[0m request_headers=\e[2m#{request_headers.inspect}\e[0m"
    end

    signature = @signer.sign_request(
      http_method: method.to_s.upcase,
      url: uri.to_s,
      headers: request_headers,
      body: sign_body
    )

    if @debug_mode
      warn "\e[35m[SIGV4]\e[0m signed=\e[2m#{signature.headers.inspect}\e[0m"
    end

    signature.headers.each { |name, value| request[name] = value }
    unsigned_headers.each { |k, v| request[k] = v }
    request
  end
end
