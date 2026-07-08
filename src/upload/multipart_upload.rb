# frozen_string_literal: true

class S3BaseClient
  # Uploads a large file via parallel multipart upload.
  # Used by UploadService when file size > part_size.
  class MultipartUpload
    def initialize(client:, logger: nil)
      @client = client
      @logger = logger
    end

    def call(local_path:, key:, part_size:, size:,
             content_type: "application/octet-stream", metadata: {}, cache_control: nil,
             on_progress: nil, state_file: nil, t0: nil,
             max_concurrency: nil, max_retries: nil, retry_delay: nil,
             bucket: nil, session: {})
      @client.validate_part_config!(part_size, size)

      _, state, = @client.setup_multipart_upload_state(
        local_path: local_path, key: key, part_size: part_size, size: size,
        content_type: content_type, metadata: metadata, cache_control: cache_control,
        state_file: state_file, bucket: bucket, session: session
      )

      upload_state = @client.build_upload_state_object(state, local_path)
      progress_cb = @client.build_upload_progress_callback(on_progress, upload_state, size)

      begin
        uploader = PartUploader.new(
          @client, upload_state,
          max_concurrency: max_concurrency || @client.max_concurrency,
          max_retries: max_retries || @client.max_retries,
          retry_delay: retry_delay || @client.retry_delay,
          on_progress: progress_cb,
          state_file: state_file
        )
        parts = uploader.upload_all!
        etag = @client.complete_multipart_upload(
          key: key, upload_id: upload_state.upload_id, parts: parts, bucket: bucket
        )
        finish(state_file, state, key, upload_state.upload_id, etag, parts, size, t0)
      rescue S3BaseClient::S3Error, S3BaseClient::UploadError => e
        fail_upload(e, key, upload_state&.upload_id, state_file)
      end
    end

    private

    def finish(state_file, state, key, upload_id, etag, parts, size, t0)
      if state_file && state
        state[:completed] = true
        state[:completed_at] = Time.now.utc.iso8601
        state[:last_updated_at] = state[:completed_at]
        state[:parts] = parts.to_h { |p| [p[:part_number], p[:etag]] }
        state[:in_progress_parts] = {}
        state[:thread_states] = {}
        state[:last_part_completed_at] = state[:completed_at]
        @client.upload_state_manager.save_state(state_file, state)
      end
      @client.upload_state_manager.cleanup_state(state_file)

      elapsed = t0 ? Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0 : 0.0
      throughput = elapsed.positive? ? (size.to_f / 1024 / 1024 / elapsed) : 0.0

      result = S3BaseClient::UploadResult.new(
        key: key, size: size, etag: etag, elapsed: elapsed,
        throughput: throughput,
        extra: { upload_id: upload_id, parts: parts,
                 parts_uploaded: parts.size,
                 session_id: state[:upload_session_id] }
      )
      @logger&.info "[UPLOAD COMPLETE] key=#{key.inspect} etag=#{etag} parts=#{parts.size}"
      @client.emit_event(:upload_complete, result, elapsed, throughput)
      result
    end

    def fail_upload(e, key, upload_id, state_file)
      @logger&.error "upload_file failed on key=#{key.inspect}: #{e.message}"
      @client.emit_event(:upload_error, key, upload_id, e)
      @client.safe_abort(key: key, upload_id: upload_id, bucket: nil)
      @client.upload_state_manager.cleanup_state(state_file)
      raise e
    end
  end
end
