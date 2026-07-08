# frozen_string_literal: true

module S3UploadLogic
  include S3Constants
  include S3Errors
  include S3Logging
  include S3Utils

  # =========================================================================
  # UPLOAD — multipart, parallel, RAM holds only 1 part per thread at a time
  # =========================================================================

  # =========================================================================
  # LOW-LEVEL MULTIPART (allows resume / manual state management)
  # =========================================================================

  def multipart_start(key:, content_type: "application/octet-stream",
                      metadata: {}, cache_control: nil, bucket: nil)
    create_multipart_upload(key: key, content_type: content_type,
                            metadata: metadata, cache_control: cache_control, bucket: bucket)
  end

  def multipart_upload_part(key:, upload_id:, part_number:, body:,
                            length: nil, io_offset: 0, bucket: nil)
    data = case body
           when String then body
           when IO, File
             body.seek(io_offset)
             body.read(length)
           else raise ArgumentError, "body must be String or IO"
           end
    upload_part(key: key, upload_id: upload_id, part_number: part_number, body: data, bucket: bucket)
  end

  def multipart_complete(key:, upload_id:, parts:, bucket: nil)
    complete_multipart_upload(key: key, upload_id: upload_id, parts: parts, bucket: bucket)
  rescue S3Error => e
    raise UploadError, e.message
  end

  def multipart_abort(key:, upload_id:, bucket: nil)
    _ops_execute(:delete, key, bucket: bucket, query: { uploadId: upload_id }) { |resp| resp.code.to_i }
  end

  # Upload a single part via the transport.
  def upload_part(key:, upload_id:, part_number:, body:, bucket: nil)
    _ops_execute(:put, key, bucket: bucket, body: body,
                            headers: sse_headers,
                            query: { partNumber: part_number, uploadId: upload_id }) do |resp|
      resp["ETag"]&.gsub(/^"|"$/, '')
    end
  rescue S3Error => e
    raise UploadError, e.message
  end

  def validate_part_config!(part_size, file_size)
    raise ArgumentError, "part_size < 5MB" if part_size < MIN_PART_SIZE
    return unless file_size.positive? && (file_size.to_f / part_size).ceil > MAX_PARTS

    raise ArgumentError, "exceeds 10,000 parts"
  end

  def build_upload_state_object(state, local_path)
    upload_state = state.is_a?(UploadState) ? state : UploadState.new(state)
    upload_state.local_path ||= File.expand_path(local_path)
    upload_state
  end

  def build_upload_progress_callback(on_progress, upload_state, total_size)
    return nil unless on_progress

    ls = upload_state
    ->(*) { on_progress.call(ls.bytes_uploaded, total_size) }
  end

  def setup_multipart_upload_state(local_path:, key:, part_size:, size:,
                                   content_type:, metadata:, cache_control:,
                                   state_file:, bucket: nil, session: {})
    pz = part_size
    state = state_file ? @upload_state_manager.load_state(state_file) : nil
    state = @upload_state_manager.validate_state(state, key: key, part_size: pz, total_size: size, local_path: local_path)
    total_parts = (size.to_f / pz).ceil

    if state
      resume_existing_upload(state, total_parts)
    else
      state = create_new_upload_state(key, pz, size, local_path, content_type, metadata, cache_control, state_file, bucket: bucket, session: session)
    end

    [state[:upload_id], state, total_parts]
  end

  def put_single_object(key, body, content_type:, metadata:, cache_control: nil, bucket: nil)
    headers = { "content-type" => content_type }
    headers.merge!(sse_headers)
    metadata.each { |k, v| headers["x-amz-meta-#{k}"] = v.to_s }
    headers["cache-control"] = cache_control if cache_control

    @upload_transport.put_single(key, body, headers, bucket: bucket)
  end

  private

  def resume_existing_upload(state, total_parts)
    upload_session_id = state[:upload_session_id] || "N/A"
    state[:resume_count] = (state[:resume_count] || 0) + 1
    state[:resumed_at] = now_iso
    log_info "upload_file RESUME: key=#{state[:key].inspect} upload_id=#{state[:upload_id]} " \
             "done=#{state[:parts].size}/#{total_parts} session=#{upload_session_id} " \
             "resume_count=#{state[:resume_count]}"
    emit_event(:upload_resume, state)
  end

  def create_new_upload_state(key, part_size, total_size, local_path, content_type, metadata, cache_control, state_file, bucket: nil, session: {})
    log_info "upload_file MULTIPART: key=#{key.inspect} total_parts=#{(total_size.to_f / part_size).ceil} session=#{session[:upload_session_id]}"
    upload_id = create_multipart_upload(key: key, content_type: content_type, metadata: metadata, cache_control: cache_control, bucket: bucket)
    state = {
      upload_id: upload_id, key: key, part_size: part_size, total_size: total_size,
      local_path: File.expand_path(local_path), parts: {},
      started_at: session[:started_at], upload_session_id: session[:upload_session_id],
      file_mtime: session[:file_mtime], file_fingerprint: session[:file_fingerprint],
      in_progress_parts: {}, thread_states: {}, resume_count: 0,
      bucket: bucket
    }
    @upload_state_manager.save_state(state_file, state) if state_file
    log_info "upload_file initiated: upload_id=#{upload_id} session=#{session[:upload_session_id]}"
    state
  end
end
