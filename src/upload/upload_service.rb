# frozen_string_literal: true

class S3BaseClient
  # Auto-dispatches uploads to EmptyUpload, SinglePartUpload, or MultipartUpload.
  # Determines strategy based on file size relative to part_size.
  class UploadService
    def initialize(client:, logger: nil)
      @client = client
      @logger = logger
    end

    def call(key:, local_path: nil,
             content_type: "application/octet-stream", metadata: {}, cache_control: nil,
             part_size: nil, on_progress: nil,
             state_file: nil, skip_existing: false,
             max_threads: nil,
             max_retries: nil, retry_delay: nil,
             bucket: nil)
      raise ArgumentError, "local_path is required" unless local_path

      size = File.size(local_path)
      pz = part_size || @client.part_size
      raise ArgumentError, "part_size < 5MB" if pz < S3BaseClient::MIN_PART_SIZE
      raise ArgumentError, "exceeds 10,000 parts" if size.positive? && (size.to_f / pz).ceil > S3BaseClient::MAX_PARTS

      if skip_existing
        result = @client.check_skip_existing(key: key, file_path: local_path, file_size: size, bucket: bucket)
        return result if result
      end

      session = @client.compute_upload_session_metadata(local_path, size)
      @logger&.info "upload_file: key=#{key.inspect} size=#{size} session=#{session[:upload_session_id]}"
      t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)

      if size.zero?
        EmptyUpload.new(client: @client, logger: @logger).call(
          key: key, content_type: content_type, metadata: metadata,
          cache_control: cache_control, on_progress: on_progress,
          t0: t0, state_file: state_file, bucket: bucket, session: session
        )
      elsif size <= pz
        SinglePartUpload.new(client: @client, logger: @logger).call(
          key: key, local_path: local_path, size: size,
          content_type: content_type, metadata: metadata,
          cache_control: cache_control, on_progress: on_progress,
          t0: t0, state_file: state_file, bucket: bucket, session: session
        )
      else
        MultipartUpload.new(client: @client, logger: @logger).call(
          local_path: local_path, key: key, part_size: pz, size: size,
          content_type: content_type, metadata: metadata,
          cache_control: cache_control, on_progress: on_progress,
          state_file: state_file, t0: t0,
          max_concurrency: max_threads,
          max_retries: max_retries, retry_delay: retry_delay,
          bucket: bucket, session: session
        )
      end
    end
  end
end
