# frozen_string_literal: true

# rubocop:disable Style/OneClassPerFile

# Transport interface for multipart upload operations.
# Each client class provides its own implementation.
# Methods raise S3BaseClient::S3Error on failure.
module UploadTransport
  # Upload a single part.
  # @return [String] ETag
  def upload_part(bucket, key, part_number, upload_id, chunk, headers, http)
    raise NotImplementedError
  end

  # Upload a single object (non-multipart).
  # @return [String] ETag
  def put_single(key, body, headers, bucket:)
    raise NotImplementedError
  end

  # Upload an empty file.
  # @return [String] ETag
  def put_empty(key, headers, bucket:)
    raise NotImplementedError
  end
end

# S3Client (single-bucket) transport — uses perform_request.
class SingleBucketUploadTransport
  include UploadTransport

  def initialize(client)
    @client = client
  end

  def upload_part(bucket, key, part_number, upload_id, chunk, headers, http)
    @client.perform_request(:put, key,
                            body: chunk,
                            headers: headers,
                            query: { partNumber: part_number, uploadId: upload_id }) do |resp|
      resp['ETag']&.gsub(/^"|"$/, '')
    end
  end

  def put_single(key, body, headers, bucket:)
    if body.is_a?(String) && File.exist?(body)
      file_size = File.size(body)
      File.open(body, 'rb') do |file|
        @client.perform_request(:put, key, body: file, headers: headers,
                                           stream: true, content_length: file_size) do |resp|
          resp['ETag']
        end
      end
    else
      @client.perform_request(:put, key, body: body, headers: headers) do |resp|
        resp['ETag']
      end
    end
  end

  def put_empty(key, headers, bucket:)
    @client.perform_request(:put, key, body: '', headers: headers) do |resp|
      resp['ETag']
    end
  end
end

# S3MultiBucketClient transport — uses signed_request.
class MultiBucketUploadTransport
  include UploadTransport

  def initialize(client)
    @client = client
  end

  def upload_part(bucket, key, part_number, upload_id, chunk, headers, http)
    bucket = @client.resolve_bucket(bucket)
    uri = @client.build_uri(bucket, key, 'partNumber' => part_number.to_s, 'uploadId' => upload_id)
    if http
      @client.signed_request_via(http, uri, body: chunk, headers: headers)['ETag']&.gsub(/^"|"$/, '')
    else
      response = @client.signed_request(:put, uri, body: chunk, headers: headers)
      unless response.is_a?(Net::HTTPSuccess)
        raise S3BaseClient::S3Error.new(response.code, "Part #{part_number} upload failed", nil, nil)
      end

      response['ETag']&.gsub(/^"|"$/, '')
    end
  end

  def put_single(key, body, headers, bucket:)
    bucket = @client.resolve_bucket(bucket)
    uri = @client.build_uri(bucket, key)
    if body.is_a?(String) && File.exist?(body)
      File.open(body, 'rb') do |file|
        resp = @client.signed_request(:put, uri, body_stream: file, headers: headers)
        unless resp.is_a?(Net::HTTPSuccess)
          raise S3BaseClient::UploadError, "Upload failed: #{resp.code} #{resp.message}"
        end

        resp['ETag']&.gsub(/^"|"$/, '')
      end
    else
      resp = @client.signed_request(:put, uri, body: body, headers: headers)
      unless resp.is_a?(Net::HTTPSuccess)
        raise S3BaseClient::UploadError, "Upload failed: #{resp.code} #{resp.message}"
      end

      resp['ETag']&.gsub(/^"|"$/, '')
    end
  end

  def put_empty(key, headers, bucket:)
    bucket = @client.resolve_bucket(bucket)
    uri = @client.build_uri(bucket, key)
    resp = @client.signed_request(:put, uri, body: '', headers: headers)
    unless resp.is_a?(Net::HTTPSuccess)
      raise S3BaseClient::UploadError, "Upload failed: #{resp.code} #{resp.message}"
    end

    resp['ETag']&.gsub(/^"|"$/, '')
  end
end

# rubocop:enable Style/OneClassPerFile
