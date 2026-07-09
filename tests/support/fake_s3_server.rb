# frozen_string_literal: true

require "webrick"
require "digest"
require "fileutils"
require "find"
require "cgi"
require "securerandom"
require "json"

module FakeS3
  Fault = Struct.new(:status, :body, :method_matcher, :path_matcher, :times, keyword_init: true)

  @faults = []

  class << self
    attr_reader :faults
  end

  def self.inject_fault(status:, body: "", method: nil, path: nil, times: 1)
    @faults << Fault.new(
      status: status, body: body,
      method_matcher: method, path_matcher: path,
      times: times
    )
  end

  def self.match_fault(method, path)
    @faults.each_with_index do |fault, idx|
      next if fault.times <= 0
      next if fault.method_matcher && fault.method_matcher != method
      next if fault.path_matcher && !path.include?(fault.path_matcher)

      return idx
    end
    nil
  end

  def self.consume_fault(idx)
    @faults[idx].times -= 1
    @faults.delete_at(idx) if @faults[idx].times <= 0
  end

  def self.reset_faults
    @faults.clear
  end

  def self.etag_for(data)
    %("#{Digest::MD5.hexdigest(data)}")
  end

  def self.parse_qs(qs)
    return {} if qs.nil? || qs.empty?

    qs.split("&").each_with_object({}) do |pair, h|
      k, v = pair.split("=", 2)
      h[CGI.unescape(k)] = v ? CGI.unescape(v) : nil
    end
  end

  class Servlet < WEBrick::HTTPServlet::AbstractServlet
    def initialize(server, store_dir, tmp_dir, uploads, mutex)
      super(server)
      @store_dir = store_dir
      @tmp_dir   = tmp_dir
      @uploads   = uploads
      @mutex     = mutex
    end

    def service(req, res)
      @mutex.synchronize { handle(req, res) }
    end

    private

    def handle(req, res)
      m    = req.request_method
      path = req.path
      qs   = req.query_string.to_s
      body = req.body || ""

      fidx = FakeS3.match_fault(m, path)
      if fidx
        fault = FakeS3.faults[fidx]
        res.status = fault.status
        res.body = fault.body
        FakeS3.consume_fault(fidx)
        return
      end

      case [m, path, qs]

      # --- Initiate multipart upload ---
      when ->(t) { t[0] == "POST" && (t[2] == "uploads" || t[2] == "uploads=" || t[2].start_with?("uploads")) }
        uid = SecureRandom.uuid
        dir = File.join(@tmp_dir, uid)
        FileUtils.mkdir_p(dir)
        # Extract key without bucket prefix (path-style: /bucket/key -> /key)
        segments = path.split("/", 3)
        obj_key = segments.length >= 3 ? "/#{segments[2]}" : path
        @uploads[uid] = {
          key: obj_key, dir: dir, parts: {},
          content_type: req["Content-Type"],
          metadata: extract_meta(req),
          cache_control: req["Cache-Control"],
          initiated: Time.now.utc.iso8601
        }
        res.content_type = "application/xml"
        res.body = "<?xml version=\"1.0\"?><InitiateMultipartUploadResult><Bucket>b</Bucket><Key>#{obj_key}</Key><UploadId>#{uid}</UploadId></InitiateMultipartUploadResult>"

      # --- Upload part ---
      when ->(t) { t[0] == "PUT" && t[2].include?("partNumber=") }
        q   = FakeS3.parse_qs(qs)
        uid = q["uploadId"]
        n   = q["partNumber"].to_i
        u   = @uploads[uid]
        unless u
          res.status = 404
          res.body = "no such upload"
          return
        end
        pp = File.join(u[:dir], format("%06d.part", n))
        File.binwrite(pp, body)
        etag = FakeS3.etag_for(body)
        u[:parts][n] = { path: pp, size: body.bytesize, etag: etag, ts: Time.now.utc.iso8601 }
        res["ETag"] = etag
        res.status = 200

      # --- Complete multipart ---
      when ->(t) { t[0] == "POST" && t[2].start_with?("uploadId=") }
        q   = FakeS3.parse_qs(qs)
        uid = q["uploadId"]
        u   = @uploads.delete(uid)
        unless u
          res.status = 404
          res.body = "no such upload"
          return
        end
        out = store_path(path)
        FileUtils.mkdir_p(File.dirname(out))
        md5 = Digest::MD5.new
        File.open(out, "wb") do |f|
          u[:parts].keys.sort.each do |n|
            File.open(u[:parts][n][:path], "rb") do |pf|
              while (chunk = pf.read(64 * 1024))
                f.write(chunk)
                md5 << chunk
              end
            end
          end
        end
        write_meta(out, u)
        FileUtils.rm_rf(u[:dir])
        res.content_type = "application/xml"
        res["ETag"] = %("#{md5.hexdigest}")
        res.body = "<?xml version=\"1.0\"?><CompleteMultipartUploadResult><Location>loc</Location><Bucket>b</Bucket><Key>#{path}</Key><ETag>\"#{md5.hexdigest}\"</ETag></CompleteMultipartUploadResult>"

      # --- Abort multipart ---
      when ->(t) { t[0] == "DELETE" && t[2].start_with?("uploadId=") }
        uid = FakeS3.parse_qs(qs)["uploadId"]
        u   = @uploads.delete(uid)
        FileUtils.rm_rf(u[:dir]) if u
        res.status = 204

      # --- Single PUT ---
      when ->(t) { t[0] == "PUT" }
        out = store_path(path)
        FileUtils.mkdir_p(File.dirname(out))
        File.binwrite(out, body)
        write_meta(out, {
                     content_type: req["Content-Type"],
                     metadata: extract_meta(req),
                     cache_control: req["Cache-Control"]
                   })
        res["ETag"] = FakeS3.etag_for(body)
        res.status = 200

      # --- List objects (v2) ---
      when ->(t) { t[0] == "GET" && t[2].include?("list-type") }
        q = FakeS3.parse_qs(qs)
        prefix     = q["prefix"] || ""
        delimiter  = q["delimiter"]
        max_keys   = (q["max-keys"] || 1000).to_i
        bucket_dir = store_path(path).chomp("/")

        all_keys = []
        if File.directory?(bucket_dir)
          Find.find(bucket_dir) do |fp|
            next unless File.file?(fp)
            next if fp.end_with?(".meta")

            rel = fp.sub("#{bucket_dir}/", "")
            next if rel.empty?

            all_keys << rel if rel.start_with?(prefix)
          end
        end

        all_keys.sort!
        contents = []
        common_prefixes = []
        count = 0

        all_keys.each do |key|
          break if count >= max_keys

          if delimiter && key.include?(delimiter)
            cp_len = key.index(delimiter, prefix.length)
            cp = cp_len ? key[0, cp_len + delimiter.length] : key
            common_prefixes << cp unless common_prefixes.include?(cp)
            next
          end

          fp = File.join(bucket_dir, key)
          data = begin
            File.binread(fp)
          rescue StandardError
            ""
          end
          contents << {
            key: key,
            size: File.size(fp),
            last_modified: File.mtime(fp).utc.iso8601,
            storage_class: "STANDARD",
            etag: FakeS3.etag_for(data)
          }
          count += 1
        end

        is_truncated = count >= max_keys && all_keys.length > count
        xml = +%(<?xml version="1.0" encoding="UTF-8"?><ListBucketResult>)
        xml << %(<Name>b</Name>)
        xml << %(<Prefix>#{prefix}</Prefix>)
        xml << %(<MaxKeys>#{max_keys}</MaxKeys>)
        xml << %(<IsTruncated>#{is_truncated}</IsTruncated>)
        common_prefixes.sort.each { |cp| xml << %(<CommonPrefixes><Prefix>#{cp}</Prefix></CommonPrefixes>) }
        contents.each do |c|
          xml << %(<Contents><Key>#{c[:key]}</Key><Size>#{c[:size]}</Size>)
          xml << %(<LastModified>#{c[:last_modified]}</LastModified>)
          xml << %(<StorageClass>#{c[:storage_class]}</StorageClass>)
          xml << %(<ETag>#{c[:etag]}</ETag></Contents>)
        end
        xml << %(</ListBucketResult>)
        res.content_type = "application/xml"
        res.body = xml

      # --- List multipart uploads ---
      when ->(t) { t[0] == "GET" && t[2].include?("uploads") }
        q = FakeS3.parse_qs(qs)
        prefix = q["prefix"]
        xml = +%(<?xml version="1.0" encoding="UTF-8"?><ListMultipartUploadsResult>)
        @uploads.each do |uid, u|
          next if prefix && !u[:key].start_with?(prefix)

          xml << %(<Upload><Key>#{u[:key]}</Key><UploadId>#{uid}</UploadId>)
          xml << %(<Initiated>#{u[:initiated]}</Initiated><StorageClass>STANDARD</StorageClass></Upload>)
        end
        xml << %(</ListMultipartUploadsResult>)
        res.content_type = "application/xml"
        res.body = xml

      # --- List parts ---
      when ->(t) { t[0] == "GET" && t[2].include?("uploadId=") }
        q   = FakeS3.parse_qs(qs)
        u   = @uploads[q["uploadId"]]
        unless u
          res.status = 404
          return
        end
        xml = +%(<?xml version="1.0" encoding="UTF-8"?><ListPartsResult>)
        u[:parts].keys.sort.each do |n|
          p = u[:parts][n]
          xml << %(<Part><PartNumber>#{n}</PartNumber><ETag>#{p[:etag]}</ETag>)
          xml << %(<Size>#{p[:size]}</Size><LastModified>#{p[:ts]}</LastModified></Part>)
        end
        xml << %(</ListPartsResult>)
        res.content_type = "application/xml"
        res.body = xml

      # --- HEAD ---
      when ->(t) { t[0] == "HEAD" }
        fp = store_path(path)
        if File.file?(fp)
          meta = load_meta(fp)
          res["Content-Length"]      = File.size(fp).to_s
          res["Content-Type"]        = meta[:content_type] || "application/octet-stream"
          res["ETag"]                = FakeS3.etag_for(File.binread(fp))
          res["Last-Modified"]       = File.mtime(fp).httpdate
          res["x-amz-storage-class"] = meta[:storage_class] || "STANDARD"
          res["Cache-Control"]       = meta[:cache_control] if meta[:cache_control]
          (meta[:metadata] || {}).each { |k, v| res["x-amz-meta-#{k}"] = v }
          res.status = 200
        else
          res.status = 404
        end

      # --- DELETE ---
      when ->(t) { t[0] == "DELETE" }
        fp = store_path(path)
        File.delete(fp) if File.file?(fp)
        File.delete("#{fp}.meta") if File.file?("#{fp}.meta")
        res.status = 204

      # --- GET (download) ---
      when ->(t) { t[0] == "GET" }
        fp = store_path(path)
        unless File.file?(fp)
          res.status = 404
          res.body = "not found"
          return
        end
        total = File.size(fp)
        s, f  = 0, total - 1
        if req["range"] =~ /bytes=(\d+)-(\d*)/
          s = ::Regexp.last_match(1).to_i
          f = ::Regexp.last_match(2).empty? ? total - 1 : ::Regexp.last_match(2).to_i
          res.status = 206
        end
        length = f - s + 1
        res.status = 200 if res.status != 206
        res.content_type = "application/octet-stream"
        res["Content-Length"] = length.to_s
        res["Content-Range"]  = "bytes #{s}-#{f}/#{total}"
        res.body = proc { |out|
          File.open(fp, "rb") do |file|
            file.seek(s)
            remaining = length
            while remaining > 0
              chunk = file.read([64 * 1024, remaining].min)
              break unless chunk

              out.write(chunk)
              remaining -= chunk.bytesize
            end
          end
        }

      else
        res.status = 400
        res.body = "unhandled: #{m} #{path}?#{qs}"
      end
    end

    def store_path(p)
      full = "#{@store_dir}#{p}"
      FileUtils.mkdir_p(File.dirname(full))
      full
    end

    def extract_meta(req)
      meta = {}
      req.header.each do |key, values|
        if key.downcase.start_with?("x-amz-meta-")
          meta[key.sub(/^x-amz-meta-/i, "")] = values.first
        end
      end
      meta
    end

    def write_meta(file_path, info)
      meta_path = "#{file_path}.meta"
      File.write(meta_path, JSON.generate({
                                            content_type: info[:content_type],
                                            metadata: info[:metadata] || {},
                                            cache_control: info[:cache_control],
                                            storage_class: "STANDARD"
                                          }))
    end

    def load_meta(file_path)
      meta_path = "#{file_path}.meta"
      return { metadata: {} } unless File.file?(meta_path)

      data = JSON.parse(File.read(meta_path), symbolize_names: true)
      data[:metadata] ||= {}
      data
    rescue StandardError
      { metadata: {} }
    end
  end

  class Server
    attr_reader :port, :store_dir, :tmp_dir, :pid

    def initialize(port:, store_dir:, tmp_dir:)
      @port      = port
      @store_dir = store_dir
      @tmp_dir   = tmp_dir
      @uploads   = {}
      @mutex     = Mutex.new
      @pid       = nil
    end

    def start_fork
      FileUtils.rm_rf(@store_dir)
      FileUtils.mkdir_p(@store_dir)
      FileUtils.rm_rf(@tmp_dir)
      FileUtils.mkdir_p(@tmp_dir)

      @pid = fork do
        server = WEBrick::HTTPServer.new(
          Port: @port,
          Logger: WEBrick::Log.new(File::NULL),
          AccessLog: []
        )
        server.mount("/", Servlet, @store_dir, @tmp_dir, @uploads, @mutex)
        trap("INT") { server.shutdown }
        server.start
      end
      sleep 0.2
      self
    end

    def start_thread
      FileUtils.rm_rf(@store_dir)
      FileUtils.mkdir_p(@store_dir)
      FileUtils.rm_rf(@tmp_dir)
      FileUtils.mkdir_p(@tmp_dir)

      @server = WEBrick::HTTPServer.new(
        Port: @port,
        Logger: WEBrick::Log.new(File::NULL),
        AccessLog: []
      )
      @server.mount("/", Servlet, @store_dir, @tmp_dir, @uploads, @mutex)
      trap("INT") { @server.shutdown }
      @thread = Thread.new { @server.start }
      sleep 0.15
      self
    end

    def stop
      if @pid
        begin
          Process.kill("TERM", @pid)
        rescue StandardError
          nil
        end
        begin
          Process.wait(@pid)
        rescue StandardError
          nil
        end
      elsif @server
        begin
          @server.shutdown
        rescue StandardError
          nil
        end
        @thread&.join(2)
      end
      FileUtils.rm_rf(@tmp_dir)
    end

    def store_path(key)
      File.join(@store_dir, key.sub(%r{^/}, ""))
    end
  end
end
