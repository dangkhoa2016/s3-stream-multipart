# frozen_string_literal: true

class BulkUploadWorker
  def initialize(client:, bucket: nil, multipart_threshold: 100 * 1024 * 1024,
                 content_type: nil, metadata: {}, cache_control: nil,
                 state_dir: nil, skip_existing: true, resume: true)
    @client              = client
    @bucket              = bucket
    @multipart_threshold = multipart_threshold
    @content_type        = content_type
    @metadata            = metadata
    @cache_control       = cache_control
    @state_dir           = state_dir
    @skip_existing       = skip_existing
    @resume              = resume
  end

  def upload(file, thread_client: nil)
    tc = thread_client || @client
    t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)

    sf = @state_dir ? state_file_for(file[:key]) : nil
    if resume_eligible?(sf, file)
      result = begin
        resume_upload(tc, sf, file, t0)
      rescue S3BaseClient::S3Error, S3BaseClient::UploadError, StandardError => e
        tc.log_info "[BULK] RESUME failed for #{file[:key]}: #{e.message}, falling back to normal upload"
        nil
      end
      return result if result
    end

    opts = build_upload_opts(file, sf)
    result = S3Helper.upload(
      client: tc,
      key: file[:key],
      local_path: file[:path],
      bucket: @bucket,
      multipart_threshold: @multipart_threshold,
      **opts
    )

    build_result(file, result, t0)
  end

  def skip_check(file, thread_client: nil, existing_map: nil)
    return nil unless @skip_existing

    tc = thread_client || @client

    if existing_map
      remote = existing_map[file[:key]]
      return nil unless remote
      return nil unless remote[:size] == file[:size]
      return nil unless tc.etag_matches_file?(remote[:etag], file[:path])

      { path: file[:path], key: file[:key],
        reason: "already exists (size=#{file[:size]}, etag=#{remote[:etag]})" }
    else
      skip_check_head(tc, file)
    end
  end

  private

  def skip_check_head(tc, file)
    is_single = tc.single_bucket?
    existing = begin
      if is_single
        tc.head_object(key: file[:key], bucket: @bucket)
      else
        tc.head_object(bucket: @bucket, key: file[:key])
      end
    rescue S3BaseClient::S3Error => e
      raise unless e.code == "404"

      tc.log_debug "[BULK] head_object: #{file[:key]}: not found (expected)"
      nil
    end
    return nil unless existing
    return nil unless existing[:content_length] == file[:size]
    return unless tc.etag_matches_file?(existing[:etag], file[:path])

    { path: file[:path], key: file[:key],
      reason: "already exists (size=#{file[:size]}, etag=#{existing[:etag]})" }
  end

  def resume_upload(tc, state_file, file, t0)
    result = tc.resume_upload(
      state_file: state_file,
      key: file[:key],
      bucket: @bucket,
      local_path: file[:path]
    )

    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0
    etag = result.is_a?(Hash) ? (result[:etag] || result["etag"]) : nil

    { path: file[:path], key: file[:key], etag: etag,
      size: file[:size], elapsed: elapsed }
  end

  def resume_eligible?(sf, file)
    @resume && sf && File.exist?(sf) && file[:size] > @multipart_threshold
  end

  def build_upload_opts(file, sf)
    ct = @content_type || detect_content_type(file[:path])
    opts = { content_type: ct, metadata: @metadata, skip_existing: false }
    opts[:cache_control] = @cache_control if @cache_control
    if sf && file[:size] > @multipart_threshold
      opts[:state_file] = sf
    end
    opts
  end

  def build_result(file, result, t0)
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0
    etag = result.is_a?(Hash) ? (result[:etag] || result["etag"]) : nil
    { path: file[:path], key: file[:key], etag: etag,
      size: file[:size], elapsed: elapsed }
  end

  def state_file_for(key)
    safe = key.gsub("/", "--").gsub(/[^a-zA-Z0-9._~-]/) { |c| format("_%02X", c.ord) }
    safe = safe[0, 120] if safe.length > 120
    File.join(@state_dir, "#{safe}.s3state.json")
  end

  def detect_content_type(path)
    @content_type_cache ||= {}
    ext = File.extname(path).downcase
    @content_type_cache[ext] ||= DirectoryScanner::MIME_TYPES[ext] || "application/octet-stream"
  end
end
