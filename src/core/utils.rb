# frozen_string_literal: true

require_relative "constants"
require_relative "errors"

module S3Utils
  include S3Constants
  include S3Errors

  def human_readable_size(bytes)
    return "0 B" if bytes.nil? || bytes.zero?

    units = %w[B KB MB GB TB PB]
    exp   = [(Math.log(bytes.to_f) / Math.log(1024)).to_i, units.size - 1].min
    format("%.2f %s", bytes.to_f / (1024**exp), units[exp])
  end

  def format_elapsed(elapsed)
    format("%.3f", elapsed)
  end

  def format_throughput(mbps)
    format("%.2f", mbps)
  end

  def format_progress(elapsed, mbps)
    "elapsed=#{format_elapsed(elapsed)}s throughput=#{format_throughput(mbps)} MB/s"
  end

  def sse_headers
    return {} unless @sse

    case @sse[:type]
    when 'AES256'
      { 'x-amz-server-side-encryption' => 'AES256' }
    when 'aws:kms'
      h = { 'x-amz-server-side-encryption' => 'aws:kms' }
      h['x-amz-server-side-encryption-aws-kms-key-id'] = @sse[:kms_key_id] if @sse[:kms_key_id]
      h
    when 'customer'
      h = {}
      h['x-amz-server-side-encryption-customer-algorithm'] = 'AES256'
      h['x-amz-server-side-encryption-customer-key'] = @sse[:key] if @sse[:key]
      h['x-amz-server-side-encryption-customer-key-MD5'] = @sse[:key_md5] if @sse[:key_md5]
      h
    else
      {}
    end
  end

  def backoff_with_jitter(attempt)
    base = (@retry_delay || DEFAULT_RETRY_DELAY) * (2**attempt)
    [base * (0.5 + rand), MAX_RETRY_DELAY].min
  end

  def retry_with_backoff(max_retries:, context: "", on_retry: nil, backoff_base: nil, client: nil)
    attempt = 0
    begin
      attempt += 1
      yield attempt
    rescue *transient_errors => e
      if attempt <= max_retries
        delay = backoff_with_jitter(attempt)
        log_warn "↻ #{context} transient #{e.class}: #{e.message} — retry #{attempt}/#{max_retries} in #{format('%.2f', delay)}s"
        on_retry&.call(attempt, max_retries, delay, e)
        sleep(delay)
        retry
      end
      log_error "✗ #{context} exhausted #{max_retries} retries: #{e.class}: #{e.message}"
      raise
    rescue S3Error => e
      retryable = e.code.to_i >= 500 || e.code.to_s == '429'
      if retryable && attempt <= max_retries
        multiplier = e.code.to_s == '429' ? 2.0 : 1.0
        delay = backoff_with_jitter(attempt) * multiplier
        log_warn "↻ #{context} S3 #{e.code}: #{e.message} — retry #{attempt}/#{max_retries} in #{format('%.2f', delay)}s"
        on_retry&.call(attempt, max_retries, delay, e)
        sleep(delay)
        retry
      end
      log_error "✗ #{context} S3 #{e.code}: #{e.message}"
      raise
    end
  end

  def extract_metadata_from_headers(resp)
    metadata = {}
    resp.each_header do |key, value|
      if key.downcase.start_with?("x-amz-meta-")
        meta_key = key.sub(/^x-amz-meta-/i, "")
        metadata[meta_key] = value
      end
    end
    metadata
  end

  def now_mono
    Process.clock_gettime(Process::CLOCK_MONOTONIC)
  end

  def now_iso
    Time.now.utc.iso8601
  end

  def transient_errors
    [Net::OpenTimeout, Net::ReadTimeout, Errno::ECONNRESET, Errno::EPIPE,
     Errno::ECONNABORTED, EOFError, SocketError, IOError]
  end

  def check_response!(response, context: "request")
    return if response.is_a?(Net::HTTPSuccess)

    raise S3Error.new(response.code, "#{context} failed", response["x-amz-request-id"], response.body.to_s)
  end
end
