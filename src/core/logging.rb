# frozen_string_literal: true

# core/logging.rb
#
# Logging helpers for S3 client classes.
module S3Logging
  # Enhanced logging with file support and detailed request/response info.
  def setup_logger(external_logger = nil, log_file: nil, debug: false, log_color: false, log_format: :text)
    init_logger(external_logger, log_file: log_file, debug: debug)
    @log_color = log_color
    @log_format = log_format
    setup_formatter(log_color: log_color, log_format: log_format)
    @debug_mode = debug
  end

  def init_logger(external_logger = nil, log_file: nil, debug: false)
    if external_logger
      @logger = external_logger
    elsif log_file
      @logger = Logger.new(log_file)
    else
      @logger ||= Logger.new($stdout)
    end
    @logger.level = debug ? Logger::DEBUG : Logger::INFO
  end

  def setup_formatter(log_color: false, log_format: :text)
    @logger.formatter = if log_format == :json
                          proc do |severity, datetime, _progname, msg|
                            "#{JSON.generate({
                                               timestamp: datetime.strftime('%Y-%m-%dT%H:%M:%S.%LZ'),
                                               severity: severity.upcase,
                                               message: msg.to_s.sub(/^\[S3\]\s*/, ''),
                                               component: 's3_client'
                                             })}\n"
                          end
                        elsif log_color
                          proc do |severity, datetime, progname, msg|
                            build_color_log_line(severity, datetime, msg)
                          end
                        else
                          proc do |severity, datetime, progname, msg|
                            timestamp = datetime.strftime('%Y-%m-%d %H:%M:%S.%L')
                            "[#{timestamp}] #{severity.upcase} -- #{"#{progname}: " if progname}#{msg}\n"
                          end
                        end
  end

  def build_color_log_line(severity, datetime, msg)
    colors = self.class::LOG_COLORS
    reset  = self.class::LOG_COLOR_RESET
    green  = self.class::LOG_COLOR_GREEN
    dim    = self.class::LOG_COLOR_DIM
    sev    = severity.upcase

    ts   = "#{green}[#{datetime.strftime('%H:%M:%S')}]#{reset}"
    lvl  = "#{colors[sev] || dim}#{sev.ljust(5)}#{reset}"
    text = msg.to_s

    text = text.gsub(self.class::LOG_KEYWORD_REGEX) { "#{colors['WARN']}#{::Regexp.last_match(1)}#{reset}" }
    text = text.sub(/(?<=\[S3\] )(.+?)(?=: |\s—|\s\||$)/) { "#{dim}#{::Regexp.last_match(1)}#{reset}" }
    text = text.gsub("✓", "#{green}✓#{reset}")
               .gsub("✗", "#{colors['ERROR']}✗#{reset}")
               .gsub("↻", "#{colors['WARN']}↻#{reset}")
    text = text.gsub("already exists", "#{green}already exists#{reset}")
    text = text.gsub(%r{(\w+)=("[^"]*"|[\da-fA-F.]+(?:\s*(?:MB|KB|GB|B|MB/s|KB/s|ms|s|%)(?!\w))?)}) do
      "#{dim}#{::Regexp.last_match(1)}=#{reset}\e[36m#{::Regexp.last_match(2)}#{reset}"
    end

    "#{ts} #{lvl} #{text}\n"
  end

  def log_request_details(method, uri, body_size = 0)
    return unless @debug_mode

    m = method.to_s.upcase
    host = uri.host || ""
    path = uri.path.to_s
    query = uri.query

    log_debug "\e[36m\e[1m ┌─ REQUEST\e[0m"
    log_debug "\e[36m │\e[0m \e[1m#{m}\e[0m \e[33m#{host}\e[0m#{path}#{"?\e[35m#{query}\e[0m" if query && !query.empty?}"
    log_debug "\e[36m │\e[0m Body: \e[32m#{body_size} bytes\e[0m"
    log_debug "\e[36m └─\e[0m"
  end

  def log_response_details(resp)
    return unless @debug_mode

    code = resp.code.to_i
    status_color = case code
                   when 200..299 then "\e[32m"
                   when 300..399 then "\e[33m"
                   when 400..499 then "\e[31m"
                   else "\e[31;1m"
                   end

    log_debug "\e[36m\e[1m ┌─ RESPONSE\e[0m"
    log_debug "\e[36m │\e[0m Status: #{status_color}\e[1m#{resp.code}\e[0m \e[2m#{resp.message}\e[0m"
    log_debug "\e[36m │\e[0m Headers:"
    resp.each_header do |k, v|
      log_debug "\e[36m │\e[0m   \e[36m#{k}\e[0m: \e[2m#{v[0, 120]}\e[0m"
    end
    body = resp.body
    if body && !body.empty?
      body_preview = body.bytesize > 500 ? "#{body[0, 500]}..." : body
      log_debug "\e[36m │\e[0m Body: \e[2m#{body_preview[0, 200]}\e[0m"
    end
    log_debug "\e[36m └─\e[0m"
  end

  # Public accessors for logging — used by PartUploader.
  def log_info(msg)
    @logger&.info("[S3] #{msg}")
  end

  def log_warn(msg)
    @logger&.warn("[S3] #{msg}")
  end

  def log_error(msg)
    @logger&.error("[S3] #{msg}")
  end

  def log_debug(msg)
    @logger&.debug("[S3] #{msg}")
  end

  # Thread-safe log helper for use inside worker threads.
  # Writes directly to the configured logger with a thread-id prefix.
  def thread_log(level, msg, tid = Thread.current[:s3_tid] || "main")
    return unless @logger

    @logger.send(level, "[S3] [#{tid}] #{msg}")
    emit_event(:log, level, msg, tid, Time.now)
  end

  def thread_log_info(msg, tid = nil)
    thread_log(:info, msg, tid)
  end

  def thread_log_debug(msg, tid = nil)
    thread_log(:debug, msg, tid)
  end

  def thread_log_warn(msg, tid = nil)
    thread_log(:warn, msg, tid)
  end

  def thread_log_error(msg, tid = nil)
    thread_log(:error, msg, tid)
  end
end
