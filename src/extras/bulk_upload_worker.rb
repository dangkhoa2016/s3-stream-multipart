# frozen_string_literal: true

class BulkUploadWorker
  def initialize(client:, bucket: nil, multipart_threshold: 100 * 1024 * 1024,
                 content_type: nil, metadata: {}, cache_control: nil,
                 state_dir: nil, skip_existing: false)
    @client              = client
    @bucket              = bucket
    @multipart_threshold = multipart_threshold
    @content_type        = content_type
    @metadata            = metadata
    @cache_control       = cache_control
    @state_dir           = state_dir
    @skip_existing       = skip_existing
  end

  def upload(file, thread_client: nil)
    tc = thread_client || @client
    t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    ct = @content_type || detect_content_type(file[:path])

    opts = { content_type: ct, metadata: @metadata }
    opts[:cache_control] = @cache_control if @cache_control

    if @state_dir && file[:size] > @multipart_threshold
      sf = state_file_for(file[:key])
      if File.exist?(sf)
        tc.log_info "[BULK] RESUME: #{file[:key]} state=#{sf}"
      else
        tc.log_info "[BULK] STATE: #{file[:key]} -> #{sf}"
      end
      opts[:state_file] = sf
    end

    result = S3Helper.upload(
      client: tc,
      key: file[:key],
      local_path: file[:path],
      bucket: @bucket,
      multipart_threshold: @multipart_threshold,
      **opts
    )

    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0
    etag = result.is_a?(Hash) ? (result[:etag] || result["etag"]) : nil

    { path: file[:path], key: file[:key], etag: etag,
      size: file[:size], elapsed: elapsed }
  end

  def skip_check(file, thread_client: nil)
    return nil unless @skip_existing

    tc = thread_client || @client
    is_single = tc.single_bucket?
    existing = begin
      if is_single
        tc.head_object(file[:key])
      else
        tc.head_object(bucket: @bucket, key: file[:key])
      end
    rescue StandardError => e
      raise unless e.is_a?(S3BaseClient::S3Error) && e.code == "404"

      tc.log_debug "[BULK] head_object: #{file[:key]}: not found (expected)"
      nil
    end
    return nil unless existing
    return nil unless existing[:content_length] == file[:size]
    return unless tc.etag_matches_file?(existing[:etag], file[:path])

    { path: file[:path], key: file[:key],
      reason: "already exists (size=#{file[:size]}, etag=#{existing[:etag]})" }
  end

  private

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
