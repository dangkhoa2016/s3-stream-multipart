# frozen_string_literal: true

#
# core/request_executor.rb
#
# HTTP request execution with retry orchestration for S3Client and S3MultiBucketClient.
# The retry loop itself lives in S3BaseClient#retry_with_backoff; this module
# wraps it with request timing, response logging, and HTTP-code-to-error conversion.

module RequestExecutor
  # Execute an HTTP request with automatic retry for transient and S3 server errors.
  #
  # @param method_label [String] e.g. "GET", "PUT" — for logging
  # @param uri          [URI]    target URI — for logging
  # @param max_attempts [Integer] total attempts (1 + retries)
  #
  # @yield block that performs the actual HTTP request
  # @yieldreturn [Net::HTTPResponse] the HTTP response
  #
  # @raise [S3BaseClient::S3Error] if the response code is >= 500 or 429
  #
  # @return [Net::HTTPResponse] the HTTP response
  #
  # @example Execute a GET request with retry
  #   execute_with_retry("GET", uri, max_attempts: 3) { http.request(req) }
  def execute_with_retry(method_label, uri, max_attempts:)
    max_retries = max_attempts - 1
    context = "#{method_label} #{uri.path}"
    retry_with_backoff(max_retries: max_retries, context: context) do |attempt|
      t_req = now_mono
      result = yield
      elapsed_ms = (now_mono - t_req) * 1000
      code = result.code.to_i
      status_color = if code < 300
                       "\e[32m"
                     else
                       code < 400 ? "\e[33m" : "\e[31m"
                     end
      log_debug "\e[32m ←\e[0m #{status_color}#{result.code}\e[0m \e[1m#{method_label}\e[0m \e[2m#{uri.path}\e[0m " \
                "\e[36m#{elapsed_ms.round(1)}ms\e[0m req_id=\e[2m#{result['x-amz-request-id'].inspect}\e[0m"
      log_response_details(result) if @debug_mode

      code = result.code.to_i
      if (code >= 500 || code == 429) && attempt <= max_retries
        raise S3BaseClient::S3Error.new(result.code, "Server error", result['x-amz-request-id'])
      end

      result
    end
  end
end
