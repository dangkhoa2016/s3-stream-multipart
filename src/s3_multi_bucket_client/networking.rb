# frozen_string_literal: true

# s3_multi_bucket_client/networking.rb — HTTP networking, signing, and simple S3 operations.
# Reopens S3MultiBucketClient to define networking infrastructure.

class S3MultiBucketClient
  # =========================================================================
  # BUILD URI
  # =========================================================================

  def build_uri(bucket, key, query_params = {})
    S3BaseClient.validate_bucket!(bucket)
    S3BaseClient.validate_key!(key) unless key.to_s.empty?
    path = "/#{bucket}/#{CGI.escape(key).gsub('+', '%20').gsub('%7E', '~')}".gsub('//', '/')

    uri = URI.parse("#{@endpoint}#{path}")

    unless query_params.empty?
      uri.query = URI.encode_www_form(query_params)
    end

    uri
  end

  # =========================================================================
  # HTTP CONNECTION
  # =========================================================================

  def http_start(bucket, key, &block)
    _http_start(build_uri(bucket, key), &block)
  end

  def signed_request_via(http, uri, body: nil, body_stream: nil, headers: {})
    request = Net::HTTP::Put.new(uri)
    headers.each { |k, v| request[k] = v }

    if body_stream
      request.body_stream = body_stream
      request['Transfer-Encoding'] = 'chunked' unless request['Content-Length']
      request['Content-Type'] ||= 'application/octet-stream'
    elsif body
      request.body = body
      request['Content-Length'] = body.bytesize.to_s unless request['Content-Length']
      request['Content-Type'] ||= 'application/octet-stream'
    end

    sign_request!(request, 'PUT', uri, body)
    http.request(request)
  end

  # =========================================================================
  # SIMPLE S3 OPERATIONS
  # =========================================================================

  # =========================================================================
  # INTERNAL: signed request infrastructure
  # =========================================================================

  private

  def signed_request(method, uri, body: nil, body_stream: nil, headers: {})
    method_str = method.to_s.upcase
    body_size = if body.is_a?(String)
                  body.bytesize
                elsif body_stream
                  "stream"
                else
                  0
                end

    log_request_details(method_str, uri, body_size) if @debug_mode
    log_debug "→ #{method_str} #{uri.path}#{"?#{uri.query}" if uri.query} body=#{body_size}"

    execute_with_retry(method_str, uri, max_attempts: @max_retries + 1) do
      make_http_request(uri) do |http|
        request = if body_stream
                    req = build_http_request(method, uri, nil, headers, stream: true,
                                                                        content_length: body_stream.respond_to?(:size) ? body_stream.size : nil)
                    req.body_stream = body_stream
                    req['Transfer-Encoding'] = 'chunked' unless req['Content-Length']
                    req
                  else
                    build_http_request(method, uri, body || '', headers)
                  end
        http.request(request)
      end
    end
  end

  public :signed_request

  def make_http_request(uri, &block)
    _http_start(uri, &block)
  end

  def sign_request!(request, method, uri, body)
    apply_signer_headers!(request, method, uri, body)
  end

  # =========================================================================
  # ABSTRACT OPERATION EXECUTION — eliminates +if single_bucket?+ branches
  # =========================================================================

  def perform_request(method, key, body: nil, headers: {}, query: nil,
                      stream: false, content_length: nil, streaming: false,
                      bucket: nil)
    if method == :get && streaming
      uri = build_uri(resolve_bucket(bucket), key, query || {})
      retry_with_backoff(max_retries: @max_retries, context: "stream GET #{key}") do
        make_http_request(uri) do |http|
          request = Net::HTTP::Get.new(uri)
          headers.each { |k, v| request[k] = v }
          request['Content-Length'] = '0'
          sign_request!(request, 'GET', uri, nil)
          http.request(request) do |resp|
            unless resp.is_a?(Net::HTTPSuccess) || resp.is_a?(Net::HTTPPartialContent)
              raise DownloadError, "Download failed: #{resp.code} #{resp.message}"
            end

            return yield(resp)
          end
        end
      end
    else
      b = resolve_bucket(bucket)
      uri = build_uri(b, key, query || {})
      resp = signed_request(method, uri, body: body || '', headers: headers)
      block_given? ? yield(resp) : resp
    end
  end

  public :perform_request

  def _ops_execute(method, key, bucket: nil, query: nil, headers: {}, body: nil, &block)
    b = resolve_bucket(bucket)
    uri = build_uri(b, key, query || {})
    response = signed_request(method, uri, body: body, headers: headers)
    check_response!(response, context: "#{method.to_s.upcase} request")
    block ? block.call(response) : response
  end

  def _ops_build_uri(key, method: nil, query: nil, bucket: nil)
    build_uri(resolve_bucket(bucket), key, query || {})
  end

  # Format helpers — keep backward-compatible return values.
  def _format_delete_result(key)
    { key: key, status: 'deleted' }
  end

  def _format_abort_result(key, upload_id)
    { key: key, upload_id: upload_id, status: "aborted" }
  end

  # Path resolution for downloads — MBC expands and validates destination.
  def _resolve_download_path(local_path, destination_path)
    dp = destination_path || local_path
    raise ArgumentError, "missing keyword: destination_path or local_path" unless dp

    File.expand_path(dp)
  end

  # Result formatting for downloads.
  def _format_download_result(key, bucket, local_path, size, resumed, elapsed: nil)
    { key: key, bucket: bucket, destination: local_path, size: size, resumed: resumed }
  end

  # Stream a download chunk by chunk — MBC builds URI + signs + retries.
  def _stream_download(key, bucket: nil, headers: {}, &block)
    uri = build_uri(resolve_bucket(bucket), key)
    local = 0
    retry_with_backoff(max_retries: @max_retries,
                       context: "download_stream #{key}") do
      make_http_request(uri) do |http|
        request = Net::HTTP::Get.new(uri)
        headers.each { |k, v| request[k] = v }
        request['Content-Length'] = '0'
        sign_request!(request, 'GET', uri, nil)
        http.request(request) do |response|
          unless response.is_a?(Net::HTTPSuccess) || response.is_a?(Net::HTTPPartialContent)
            raise DownloadError, "Download stream failed: #{response.code} #{response.message}"
          end

          log_debug "download_stream: status=#{response.code} " \
                    "content_length=#{response['Content-Length'].inspect}"

          response.read_body do |chunk|
            block.call(chunk)
            local += chunk.bytesize
          end
        end
      end
    end
    local
  end

  # Resume download — MBC uses stream_multi_bucket_download.
  def _resume_download(key, paths:, on_progress:, bucket: nil)
    stream_multi_bucket_download(key, bucket, paths, on_progress)
  end
end
