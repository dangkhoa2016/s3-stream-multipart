# frozen_string_literal: true

# s3_client/networking.rb — HTTP networking, signing, and simple S3 operations.
# Reopens S3Client to define networking infrastructure.

class S3Client
  # =========================================================================
  # INTERNAL: endpoint / URL
  # =========================================================================

  private

  def build_endpoint(endpoint, region, bucket, style)
    if endpoint
      endpoint.to_s.sub(%r{/+$}, "")
    elsif style == :path
      "https://s3.#{region}.amazonaws.com"
    else
      "https://#{bucket}.s3.#{region}.amazonaws.com"
    end
  end

  def encode_path(path)
    path.split("/", -1).map { |seg| CGI.escape(seg).gsub("+", "%20").gsub("%7E", "~") }.join("/")
  end

  def build_uri(key, query: nil)
    S3BaseClient.validate_key!(key) unless key == "/"
    encoded_key = encode_path(key)
    path = if @endpoint_style == :path
             "/#{@bucket}/#{encoded_key.sub(%r{^/+}, '')}"
           else
             encoded_key.start_with?("/") ? encoded_key : "/#{encoded_key}"
           end
    url = "#{@endpoint}#{path}"
    url += "?#{encode_query(query)}" if query && !query.to_s.empty?
    URI(url)
  end

  public :build_uri

  def encode_query(q)
    return q if q.is_a?(String)

    q.map do |k, v|
      ck = CGI.escape(k.to_s)
      v.nil? ? ck : "#{ck}=#{CGI.escape(v.to_s)}"
    end.join("&")
  end

  # =========================================================================
  # INTERNAL: core request (sign + send + retry + check)
  # =========================================================================

  def perform_request(method, key, body: nil, headers: {}, query: nil,
                      stream: false, content_length: nil, streaming: false,
                      bucket: nil)
    uri = build_uri(key, query: query)
    body_size = body.is_a?(String) ? body.bytesize : 0

    log_request_details(method, uri, body_size) if @debug_mode
    log_debug "→ #{method.to_s.upcase} #{uri.path}#{"?#{uri.query}" if uri.query} " \
              "body=#{body_size}B#{' (stream)' if stream}"

    max_attempts = streaming ? 1 : @max_retries + 1
    method_label = method.to_s.upcase

    if streaming
      execute_with_retry(method_label, uri, max_attempts: max_attempts) do
        http_start(uri) do |http|
          req = build_http_request(method, uri, body, headers,
                                   stream: stream, content_length: content_length)
          http.request(req) do |resp|
            ensure_success!(resp)
            return yield(resp)
          end
        end
      end
    else
      resp = execute_with_retry(method_label, uri, max_attempts: max_attempts) do
        http_start(uri) do |http|
          req = build_http_request(method, uri, body, headers,
                                   stream: stream, content_length: content_length)
          http.request(req)
        end
      end
      ensure_success!(resp)
      yield(resp)
    end
  end

  def ensure_success!(resp)
    check_response!(resp, context: resp.message)
  end

  # build_http_request is inherited from S3BaseClient (HttpSigner).

  def http_start(uri, &block)
    _http_start(uri, &block)
  end

  public :perform_request, :http_start

  # =========================================================================
  # SIMPLE OPS
  # =========================================================================

  public

  # Backward-compatible wrappers: positional key → keyword args for base.
  def head_object(key = nil, **kwargs)
    super(key: key || kwargs[:key], bucket: kwargs[:bucket])
  end

  def delete_object(key = nil, **kwargs)
    super(key: key || kwargs[:key], bucket: kwargs[:bucket])
  end

  # =========================================================================
  # ABSTRACT OPERATION EXECUTION — overrides in S3MultiBucketClient::Networking
  # Eliminates +if single_bucket?+ branches in S3BaseClient.
  # =========================================================================

  # Execute a generic S3 operation against the single fixed bucket.
  def _ops_execute(method, key, bucket: nil, query: nil, headers: {}, body: nil, &block)
    perform_request(method, key, body: body, headers: headers, query: query, &block)
  end

  # Build a URI for a presigned URL (no bucket param needed for single-bucket).
  def _ops_build_uri(key, method: nil, query: nil, bucket: nil)
    build_uri(key, query: query)
  end

  # Format helpers — keep backward-compatible return values.
  def _format_delete_result(_key)
    204
  end

  def _format_abort_result(key, upload_id)
    { key: key, upload_id: upload_id, status: "aborted" }
  end

  # Path resolution for downloads — single-bucket uses local_path directly.
  def _resolve_download_path(local_path, destination_path)
    lp = local_path || destination_path
    FileUtils.mkdir_p(File.dirname(lp))
    lp
  end

  # Result formatting for downloads.
  def _format_download_result(key, bucket, local_path, size, resumed, elapsed: nil)
    { key: key, local_path: local_path, size: size, resumed: resumed }
  end

  # Stream a download chunk by chunk — single-bucket uses perform_request.
  def _stream_download(key, bucket: nil, headers: {}, &block)
    perform_request(:get, key, headers: headers, streaming: true) do |resp|
      total = resp["Content-Length"]&.to_i
      log_debug "download_stream: server responded status=#{resp.code} " \
                "content_length=#{total.inspect}"
      local = 0
      resp.read_body do |chunk|
        block.call(chunk)
        local += chunk.bytesize
      end
      local
    end
  end

  # Resume download — single-bucket uses stream_single_bucket_download.
  def _resume_download(key, paths:, on_progress:, bucket: nil)
    stream_single_bucket_download(key, paths, on_progress)
  end
end
