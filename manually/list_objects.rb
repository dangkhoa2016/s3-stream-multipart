# frozen_string_literal: true

require "net/http"
require "uri"
require "cgi"
require "rexml/document"
require "aws-sigv4"

# ANSI color codes for terminal output
module Color
  RESET   = "\e[0m"
  BOLD    = "\e[1m"
  DIM     = "\e[2m"
  RED     = "\e[31m"
  GREEN   = "\e[32m"
  YELLOW  = "\e[33m"
  BLUE    = "\e[34m"
  MAGENTA = "\e[35m"
  CYAN    = "\e[36m"
  WHITE   = "\e[37m"

  def self.green(text)  = "#{GREEN}#{text}#{RESET}"
  def self.red(text)    = "#{RED}#{text}#{RESET}"
  def self.yellow(text) = "#{YELLOW}#{text}#{RESET}"
  def self.blue(text)   = "#{BLUE}#{text}#{RESET}"
  def self.cyan(text)   = "#{CYAN}#{text}#{RESET}"
  def self.bold(text)   = "#{BOLD}#{text}#{RESET}"
  def self.dim(text)    = "#{DIM}#{text}#{RESET}"
  def self.magenta(text) = "#{MAGENTA}#{text}#{RESET}"
  def self.header(title, width = 68, color=CYAN)
    line = "─" * width
    "#{color}#{line}#{RESET}\n" \
    "#{BOLD}#{color}  #{title}#{RESET}\n" \
    "#{color}#{line}#{RESET}"
  end
end

# Convert bytes to human-readable format (e.g. "1.5 MB")
def human_size(bytes)
  return "0 B" if bytes.nil? || bytes.zero?
  units = %w[B KB MB GB TB]
  exp = [(Math.log(bytes.to_f) / Math.log(1024)).to_i, units.size - 1].min
  format("%.1f %s", bytes.to_f / (1024**exp), units[exp])
end

# Format an ISO 8601 timestamp into a shorter local-time string
def format_time(iso)
  return "N/A" if iso.nil? || iso == "N/A"
  t = Time.parse(iso)
  t.strftime("%Y-%m-%d %H:%M:%S")
rescue ArgumentError
  iso
end

# ==========================================
# 1. AWS & ENDPOINT CONFIGURATION
# ==========================================
access_key = ENV['S3_ACCESS_KEY_ID']     || 'YOUR_ACCESS_KEY'
secret_key = ENV['S3_SECRET_ACCESS_KEY'] || 'YOUR_SECRET_KEY'
region     = ENV['S3_REGION']            || 'us-east-1'
bucket     = ENV['S3_BUCKET']            || 'YOUR_BUCKET_NAME'
endpoint   = ENV['S3_ENDPOINT']
service    = 's3'

# Build the request URL:
#   - Path-style for S3-compatible services (MinIO, R2, Backblaze B2)
#   - Virtual-hosted style for standard AWS S3
if endpoint && !endpoint.empty?
  clean_endpoint = endpoint.sub(%r{/$}, '')
  url = "#{clean_endpoint}/#{bucket}?list-type=2"
  style_label = "path-style"
else
  url = "https://#{bucket}.s3.#{region}.amazonaws.com/?list-type=2"
  style_label = "virtual-hosted"
end

uri = URI(url)

puts
puts Color.header("AWS S3 List Objects — Configuration")
puts "  #{Color.bold 'Region:'}     #{Color.cyan region}"
puts "  #{Color.bold 'Bucket:'}     #{Color.cyan bucket}"
puts "  #{Color.bold 'Endpoint:'}   #{Color.cyan(endpoint || 'aws (default)')}"
puts "  #{Color.bold 'Style:'}      #{Color.cyan style_label}"
puts "  #{Color.bold 'URL:'}        #{Color.dim url}"

# ==========================================
# 2. SIGN REQUEST (AWS SIGV4)
# ==========================================
signer = Aws::Sigv4::Signer.new(
  service: service,
  region: region,
  access_key_id: access_key,
  secret_access_key: secret_key
)

# sign_request computes the Authorization header and x-amz-* headers automatically
signature = signer.sign_request(http_method: 'GET', url: url)

# ==========================================
# 3. BUILD HTTP CLIENT & ATTACH HEADERS
# ==========================================
http = Net::HTTP.new(uri.host, uri.port)
http.use_ssl = (uri.scheme == 'https')
# Uncomment the line below to dump raw TCP traffic:
# http.set_debug_output($stdout)

request = Net::HTTP::Get.new(uri.request_uri)
signature.headers.each { |key, value| request[key] = value }

puts
puts Color.header("Request")
puts "  #{Color.bold 'Method:'}    #{Color.green 'GET'}"
puts "  #{Color.bold 'URL:'}       #{uri}"
puts "  #{Color.bold 'Headers:'}"
request.each_header do |key, value|
  # Truncate long header values (e.g. Authorization) for readability
  display = value.length > 80 ? "#{value[0..76]}..." : value
  puts "    #{Color.dim key + ':'} #{display}"
end

# ==========================================
# 4. SEND REQUEST & HANDLE RESPONSE
# ==========================================
puts
puts Color.dim("  Sending request...")

t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
begin
  response = http.request(request)
  elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0

  puts
  puts Color.header("Response  (#{'%.3f' % (elapsed * 1000)}ms)")

  # Color-code the status line based on the HTTP code
  status_text = case response.code.to_i
                when 200..299 then Color.green("#{response.code} #{response.message}")
                when 300..399 then Color.yellow("#{response.code} #{response.message}")
                when 400..499 then Color.red("#{response.code} #{response.message}")
                when 500..599 then Color.red("#{response.code} #{response.message}")
                else Color.dim("#{response.code} #{response.message}")
                end
  puts "  #{Color.bold 'Status:'}     #{status_text}"
  puts "  #{Color.bold 'Body size:'}  #{human_size(response.body&.bytesize || 0)}"

  # Print response headers
  puts
  puts "  #{Color.bold 'Response Headers:'}"
  response.each_header do |key, value|
    puts "    #{Color.dim key + ':'} #{value}"
  end

  # Print raw XML body (truncated for readability)
  if response.body && !response.body.empty?
    puts
    puts "  #{Color.bold 'Response Body:'}  #{Color.dim('(first 2000 chars)')}"
    body_preview = response.body.length > 2000 ? "#{response.body[0..1999]}..." : response.body
    body_preview.each_line { |line| puts "  #{Color.dim line.rstrip}" }
  end

  if response.code.to_i == 200
    # Parse the XML response body
    doc = REXML::Document.new(response.body)

    bucket_name      = doc.elements["ListBucketResult/Name"]&.text
    key_count        = doc.elements["ListBucketResult/KeyCount"]&.text&.to_i || 0
    max_keys         = doc.elements["ListBucketResult/MaxKeys"]&.text
    is_truncated     = doc.elements["ListBucketResult/IsTruncated"]&.text
    prefix           = doc.elements["ListBucketResult/Prefix"]&.text

    # Collect all objects for summary statistics
    objects = []
    doc.elements.each("ListBucketResult/Contents") do |item|
      objects << {
        key:           item.elements["Key"]&.text          || "N/A",
        size:          item.elements["Size"]&.text&.to_i   || 0,
        last_modified: item.elements["LastModified"]&.text || "N/A",
        storage_class: item.elements["StorageClass"]&.text || "N/A",
        etag:          item.elements["ETag"]&.text&.gsub('"', '') || "N/A"
      }
    end

    total_size = objects.sum { |o| o[:size] }

    puts
    puts Color.header("Bucket: #{bucket_name}", 68, Color::MAGENTA)
    puts "  #{Color.bold 'Objects:'}        #{Color.green objects.size.to_s}"
    puts "  #{Color.bold 'Total size:'}    #{Color.green human_size(total_size)}"
    puts "  #{Color.bold 'Key count:'}     #{key_count}"
    puts "  #{Color.bold 'Max keys:'}      #{max_keys || 'N/A'}"
    puts "  #{Color.bold 'Truncated:'}     #{is_truncated == 'true' ? Color.yellow('yes') : Color.green('no')}"
    puts "  #{Color.bold 'Prefix:'}        #{prefix.empty? ? '(none)' : prefix}" if prefix

    # Print the objects table
    puts
    col_key  = 44
    col_size = 12
    col_mod  = 20
    col_cls  = 14
    sep = "#{Color.dim '│'}"
    header_fmt = "%-#{col_key}s #{sep} %-#{col_size}s #{sep} %-#{col_mod}s #{sep} %-#{col_cls}s"

    puts "  #{Color.bold format(header_fmt, 'Key', 'Size', 'Last Modified', 'Storage Class')}"
    puts "  #{Color.dim('─' * col_key)} #{Color.dim '┼'} #{Color.dim('─' * col_size)} #{Color.dim '┼'} #{Color.dim('─' * col_mod)} #{Color.dim '┼'} #{Color.dim('─' * col_cls)}"

    if objects.empty?
      puts "  #{Color.dim '(empty — no objects found)'}"
    else
      objects.each_with_index do |obj, i|
        row_color = i.even? ? Color::WHITE : Color::DIM
        key_display = obj[:key].length > col_key ? "#{obj[:key][0..col_key - 4]}..." : obj[:key]
        puts "  #{row_color}#{format(header_fmt, key_display, human_size(obj[:size]), format_time(obj[:last_modified]), obj[:storage_class])}#{Color::RESET}"
      end
    end

    puts
    puts "  #{Color.dim '───'}"
    puts "  #{Color.bold 'Summary:'} #{Color.green("#{objects.size} objects")}, #{Color.green(human_size(total_size))}"

  else
    # Non-200 response — display error details from the XML body
    puts
    puts Color.header("Error Details")

    # Try to parse S3 error XML for a cleaner display
    begin
      err_doc = REXML::Document.new(response.body)
      code    = err_doc.elements["Error/Code"]&.text
      message = err_doc.elements["Error/Message"]&.text
      req_id  = err_doc.elements["Error/RequestId"]&.text

      puts "  #{Color.bold 'Code:'}       #{Color.red(code || 'N/A')}"
      puts "  #{Color.bold 'Message:'}    #{Color.red(message || 'N/A')}"
      puts "  #{Color.bold 'RequestId:'}  #{Color.dim(req_id || 'N/A')}"
    rescue REXML::ParseException
      # Fallback: print raw body if it's not valid XML
      puts "  #{Color.red response.body}"
    end
  end

rescue StandardError => e
  elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0

  puts
  puts Color.header("Connection Error  (#{'%.3f' % (elapsed * 1000)}ms)")
  puts "  #{Color.red "#{e.class}: #{e.message}"}"
  puts "  #{Color.dim e.backtrace&.first(3)&.join("\n  ")}"
end
puts
