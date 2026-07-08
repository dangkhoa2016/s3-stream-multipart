# frozen_string_literal: true

# rubocop:disable Style/OneClassPerFile

module DownloadTransport
  # Stream a GET response chunk by chunk.
  def stream_get(key, headers, bucket:, &block)
    raise NotImplementedError
  end

  # Download a byte range.
  def range_get(key, offset, end_byte, bucket:, headers: {}, http: nil)
    raise NotImplementedError
  end

  # Open persistent HTTP connection.
  def open_http(key, bucket:, &block)
    raise NotImplementedError
  end
end

class SingleBucketDownloadTransport
  include DownloadTransport

  def initialize(client)
    @client = client
  end

  def stream_get(key, headers, bucket:, &block)
    @client.perform_request(:get, key, headers: headers, streaming: true) do |resp|
      total = resp['Content-Length']&.to_i
      @client.log_debug "download_stream: status=#{resp.code} content_length=#{total.inspect}"
      local = 0
      resp.read_body do |chunk|
        block.call(chunk)
        local += chunk.bytesize
      end
      local
    end
  end

  def range_get(key, offset, end_byte, bucket:, headers: {}, http: nil)
    uri = @client.build_uri(key)
    req = @client.build_http_request(:get, uri, nil, headers.merge("Range" => "bytes=#{offset}-#{end_byte}"))
    resp = if http
             http.request(req)
           else
             @client.retry_with_backoff(max_retries: @client.max_retries,
                                        context: "range_get #{key} part #{offset / (end_byte - offset + 1)}") do
               @client.http_start(uri) { |h| h.request(req) }
             end
           end
    raise S3BaseClient::DownloadError, "Download failed: part returned #{resp.code}" unless resp.is_a?(Net::HTTPSuccess)

    resp.body
  end

  def open_http(key, bucket:, &)
    uri = @client.build_uri(key)
    @client.http_start(uri, &)
  end
end

class MultiBucketDownloadTransport
  include DownloadTransport

  def initialize(client)
    @client = client
  end

  def stream_get(key, headers, bucket:, &block)
    uri = @client.build_uri(bucket, key)
    local = 0
    @client.retry_with_backoff(max_retries: @client.max_retries,
                               context: "download_stream #{key}") do
      @client.make_http_request(uri) do |http|
        request = Net::HTTP::Get.new(uri)
        headers.each { |k, v| request[k] = v }
        request['Content-Length'] = '0'
        @client.sign_request!(request, 'GET', uri, nil)
        http.request(request) do |response|
          unless response.is_a?(Net::HTTPSuccess) || response.is_a?(Net::HTTPPartialContent)
            raise S3BaseClient::DownloadError, "Download stream failed: #{response.code} #{response.message}"
          end

          @client.log_debug "download_stream: status=#{response.code}"
          response.read_body do |chunk|
            block.call(chunk)
            local += chunk.bytesize
          end
        end
      end
    end
    local
  end

  def range_get(key, offset, end_byte, bucket:, headers: {}, http: nil)
    uri = @client.build_uri(bucket, key, {})
    req = @client.build_http_request(:get, uri, nil, headers.merge("Range" => "bytes=#{offset}-#{end_byte}"))
    resp = if http
             http.request(req)
           else
             @client.http_start(bucket, key) { |h| h.request(req) }
           end
    raise S3BaseClient::DownloadError, "Download failed: part returned #{resp.code}" unless resp.is_a?(Net::HTTPSuccess)

    resp.body
  end

  def open_http(key, bucket:, &)
    @client.http_start(bucket, key, &)
  end
end

# rubocop:enable Style/OneClassPerFile
