# frozen_string_literal: true

class S3BaseClient
  # Uploads a 0-byte file via single PUT.
  # Used by UploadService when file size is 0.
  class EmptyUpload
    def initialize(client:, logger: nil)
      @client = client
      @logger = logger
    end

    def call(key:, content_type: "application/octet-stream", metadata: {}, cache_control: nil,
             on_progress: nil, t0: nil, state_file: nil, bucket: nil, session: {})
      @client.upload_state_manager.cleanup_state(state_file) if state_file

      etag = @client.put_single_object(key, "",
                                       content_type: content_type, metadata: metadata,
                                       cache_control: cache_control, bucket: bucket)

      on_progress&.call(0, 0)
      elapsed = t0 ? Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0 : 0.0
      @logger&.info "upload_file done (empty): key=#{key.inspect} etag=#{etag} elapsed=#{format('%.3f', elapsed)}s"

      S3BaseClient::UploadResult.new(
        key: key, size: 0, etag: etag,
        elapsed: elapsed, throughput: 0,
        extra: { parts: [] }
      )
    end
  end
end
