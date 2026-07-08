# frozen_string_literal: true

class S3BaseClient
  # Resumes an interrupted multipart upload from a state file.
  # Rebuilds upload state and continues where it left off.
  class ResumeUpload
    def initialize(client:, logger: nil)
      @client = client
      @logger = logger
    end

    def call(state_file:, key: nil, on_progress: nil, bucket: nil, local_path: nil)
      raise Errno::ENOENT, state_file unless File.file?(state_file)

      state = @client.upload_state_manager.load_state(state_file)
      raise ArgumentError, "invalid state file" unless state && state[:upload_id]

      local_path ||= state[:local_path]
      raise Errno::ENOENT, local_path if local_path && !File.file?(local_path)

      if local_path && File.file?(local_path) && !(File.size(local_path) == state[:total_size])
        raise ArgumentError, "file size has changed"
      end

      upload_id   = state[:upload_id]
      key       ||= state[:key]
      pz          = state[:part_size]
      total_size  = state[:total_size]
      done        = state[:parts].size
      t0          = Process.clock_gettime(Process::CLOCK_MONOTONIC)

      @logger&.info "resume_upload start: key=#{key.inspect} upload_id=#{upload_id} " \
                    "done=#{done}/#{(total_size.to_f / pz).ceil} total_size=#{total_size}"

      upload_state = build_upload_state_object(state, local_path)
      progress_cb = build_resume_progress_callback(on_progress, upload_state, total_size)

      begin
        parts = run_resume_parts(upload_state, progress_cb, state_file)
        etag = @client.complete_multipart_upload(key: key, upload_id: upload_id, parts: parts, bucket: bucket)
        @client.upload_state_manager.cleanup_state(state_file)
        elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0
        throughput = elapsed.positive? ? (total_size.to_f / 1024 / 1024 / elapsed) : 0.0
        @logger&.info "resume_upload completed: key=#{key.inspect} etag=#{etag} " \
                      "new_parts=#{parts.size - done}"
        S3BaseClient::UploadResult.new(key: key, size: total_size, etag: etag, elapsed: elapsed,
                                       throughput: throughput,
                                       extra: { upload_id: upload_id, parts: parts,
                                                parts_uploaded: parts.size })
      rescue S3BaseClient::S3Error, S3BaseClient::UploadError => e
        @logger&.warn "resume_upload failed (state preserved at #{state_file}): #{e.class}: #{e.message}"
        raise
      end
    end

    private

    def build_upload_state_object(state, local_path)
      state[:local_path] = local_path
      UploadState.new(state)
    end

    def build_resume_progress_callback(on_progress, upload_state, total_size)
      return nil unless on_progress

      if [2, -1].include?(on_progress.arity)
        ->(*) { on_progress.call(upload_state.bytes_uploaded, total_size) }
      else
        on_progress
      end
    end

    def run_resume_parts(upload_state, progress_cb, state_file)
      uploader = PartUploader.new(
        @client, upload_state,
        max_concurrency: @client.max_concurrency,
        max_retries: @client.max_retries,
        retry_delay: @client.retry_delay,
        on_progress: progress_cb,
        state_file: state_file
      )
      uploader.upload_all!
    end
  end
end
