# frozen_string_literal: true

# upload_resume_s3_multi_bucket_client.rb — Demo resumable upload for S3MultiBucketClient.
#
# Usage:
#   $ ruby tests/interactive/upload_resume_s3_multi_bucket_client.rb     # generate file + upload
#   <wait, press Ctrl+C when you see "Part X/20">
#   $ ruby tests/interactive/upload_resume_s3_multi_bucket_client.rb     # auto-resumes
#   <repeat until "Upload completed!">

require_relative "../../src/s3_multi_bucket_client"
require "webrick"
require "digest"
require "fileutils"
require "securerandom"
require "cgi"
require "logger"
require "json"

PORT = 14_692
SCRIPT_DIR = File.expand_path(__dir__)
STORE_DIR = File.join(SCRIPT_DIR, ".upload_store_s3_multi_bucket")
TMP_DIR   = File.join(SCRIPT_DIR, ".upload_tmp_s3_multi_bucket")
STATE     = File.join(SCRIPT_DIR, "demo_s3_multi_bucket.upload.json")
SOURCE    = File.join(SCRIPT_DIR, "demo_s3_multi_bucket.bin")
FILE_SIZE = 100 * 1024 * 1024
PART_SIZE = 5 * 1024 * 1024
BUCKET    = "demo"

FileUtils.mkdir_p(STORE_DIR)
FileUtils.mkdir_p(TMP_DIR)
UPLOADS = {}.freeze
MUTEX = Mutex.new

def etag_for(d) = %("#{Digest::MD5.hexdigest(d)}")

def parse_qs(qs)
  return {} if qs.to_s.empty?

  qs.split("&").each_with_object({}) do |p, h|
    k, v = p.split("=", 2)
    h[CGI.unescape(k)] = v ? CGI.unescape(v) : nil
  end
end

class FakeS3 < WEBrick::HTTPServlet::AbstractServlet
  def initialize(s, store, tmp, u, m)
    super(s)
    @store, @tmp, @u, @m = store, tmp, u, m
  end

  def service(req, res) = @m.synchronize { h(req, res) }

  def h(req, res)
    m, path, qs = req.request_method, req.path, req.query_string.to_s
    case [m, path, qs]
    when ->(t) { t[0] == "POST" && ["uploads", "uploads="].include?(t[2]) }
      uid = SecureRandom.uuid
      dir = File.join(@tmp, uid)
      FileUtils.mkdir_p(dir)
      @u[uid] = { key: path, dir: dir, parts: {} }
      res.content_type = "application/xml"
      res.body = %(<InitiateMultipartUploadResult><UploadId>#{uid}</UploadId></InitiateMultipartUploadResult>)
    when ->(t) { t[0] == "PUT" && t[2].include?("partNumber=") }
      q = parse_qs(qs)
      uid = q["uploadId"]
      n = q["partNumber"].to_i
      u = @u[uid] or (res.status = 404
                      return)
      sleep 0.3
      pp = File.join(u[:dir], format("%06d.part", n))
      File.binwrite(pp, req.body || "")
      u[:parts][n] = pp
      res["ETag"] = etag_for(File.binread(pp))
      res.status = 200
    when ->(t) { t[0] == "POST" && t[2].start_with?("uploadId=") }
      uid = parse_qs(qs)["uploadId"]
      u = @u.delete(uid)
      out = File.join(@store, path)
      FileUtils.mkdir_p(File.dirname(out))
      md5 = Digest::MD5.new
      File.open(out, "wb") do |f|
        u[:parts].keys.sort.each do |n|
          File.open(u[:parts][n], "rb") do |p|
            while (c = p.read(64 * 1024))
              f.write(c)
              md5 << c
            end
          end
        end
      end
      FileUtils.rm_rf(u[:dir])
      res.content_type = "application/xml"
      res.body = %(<CompleteMultipartUploadResult><ETag>"#{md5.hexdigest}"</ETag></CompleteMultipartUploadResult>)
    when ->(t) { t[0] == "DELETE" && t[2].start_with?("uploadId=") }
      uid = parse_qs(qs)["uploadId"]
      u = @u.delete(uid)
      FileUtils.rm_rf(u[:dir]) if u
      res.status = 204
    end
  end
end

srv = WEBrick::HTTPServer.new(Port: PORT, Logger: WEBrick::Log.new(File::NULL), AccessLog: [])
srv.mount("/", FakeS3, STORE_DIR, TMP_DIR, UPLOADS, MUTEX)
Thread.new { srv.start }
at_exit do
  srv.shutdown
  FileUtils.rm_rf(TMP_DIR)
end
sleep 0.3

unless File.exist?(SOURCE) && File.size(SOURCE) == FILE_SIZE
  puts "Generating #{FILE_SIZE / 1024 / 1024} MB source file..."
  File.open(SOURCE, "wb") do |f|
    written = 0
    while written < FILE_SIZE
      chunk = SecureRandom.bytes([1024 * 1024, FILE_SIZE - written].min)
      f.write(chunk)
      written += chunk.bytesize
    end
  end
end
src_md5 = Digest::MD5.file(SOURCE).hexdigest
puts "Source: #{SOURCE} (MD5: #{src_md5})"
puts "State:  #{STATE}"

client = S3MultiBucketClient.new(
  endpoint: "http://127.0.0.1:#{PORT}", region: "us-east-1",
  access_key_id: "x", secret_access_key: "y",
  logger: Logger.new($stdout, level: Logger::INFO)
)

total_parts = (FILE_SIZE.to_f / PART_SIZE).ceil
last_progress = nil
nil

if File.exist?(STATE)
  puts "\nState file found! Resuming..."
  resume_state = S3MultiBucketClient::UploadState.from_file(STATE)
  puts "  #{resume_state.completed_parts_count}/#{total_parts} parts done"
end

trap("INT") do
  warn "\nCtrl+C received. State file preserved."
  if last_progress
    done = last_progress[0]
    warn "  Progress: #{done}/#{total_parts} parts"
  end
  if File.exist?(STATE)
    raw = begin
      JSON.parse(File.read(STATE))
    rescue StandardError
      {}
    end
    warn "  State: #{raw['parts']&.size || 0} parts persisted"
  end
  warn "  Run again to resume."
  exit 130
end

begin
  result = client.upload_file(
    bucket: BUCKET, key: "demo.bin", local_path: SOURCE,
    part_size: PART_SIZE, max_threads: 4,
    state_file: STATE,
    on_progress: lambda { |done, total|
      last_progress = [done, total]
      puts "  Part #{done}/#{total}  (#{(done.to_f / total * 100).round(1)}%)"
    }
  )

  puts "\nUpload completed!"
  puts "  parts: #{result[:parts_uploaded]}"
  puts "  elapsed: #{'%.2f' % result[:elapsed]}s"
  puts "  throughput: #{'%.2f' % result[:throughput]} MB/s"

  stored = File.join(STORE_DIR, BUCKET, "demo.bin")
  if File.exist?(stored)
    dl_md5 = Digest::MD5.file(stored).hexdigest
    puts "  #{dl_md5 == src_md5 ? 'byte-for-byte match' : 'MISMATCH'}"
  end
rescue Interrupt
  exit 130
end
