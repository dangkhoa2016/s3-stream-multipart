# frozen_string_literal: true

class S3BaseClient
  # Uploads a small file via streaming single PUT.
  # Used by UploadService when file size ≤ part_size.
  class SinglePartUpload
    def initialize(client:, logger: nil)
      @client = client
      @logger = logger
    end

    def call(key:, local_path:, size:, content_type: "application/octet-stream",
             metadata: {}, cache_control: nil, on_progress: nil,
             t0: nil, state_file: nil, bucket: nil, session: {})
      @client.upload_state_manager.cleanup_state(state_file) if state_file
      @logger&.info "upload_file: file #{size}B -> streaming single PUT"

      etag = @client.put_single_object(key, local_path,
                                       content_type: content_type, metadata: metadata,
                                       cache_control: cache_control, bucket: bucket)

      on_progress&.call(size, size)
      elapsed = t0 ? Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0 : 0.0
      throughput = elapsed.positive? ? (size.to_f / 1024 / 1024 / elapsed) : 0.0
      @logger&.info "upload_file done (small): key=#{key.inspect} etag=#{etag} " \
                    "elapsed=#{format('%.3f', elapsed)}s"

      S3BaseClient::UploadResult.new(
        key: key, size: size, etag: etag,
        elapsed: elapsed, throughput: throughput,
        extra: { parts: [{ part_number: 1, etag: etag }] }
      )
    end
  end
end
