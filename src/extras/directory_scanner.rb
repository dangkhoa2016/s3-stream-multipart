# frozen_string_literal: true

class DirectoryScanner
  MIME_TYPES = {
    ".html" => "text/html", ".htm" => "text/html",
    ".css" => "text/css", ".js" => "application/javascript",
    ".json" => "application/json", ".xml" => "application/xml",
    ".txt" => "text/plain", ".csv" => "text/csv",
    ".md" => "text/markdown",
    ".png" => "image/png", ".jpg" => "image/jpeg", ".jpeg" => "image/jpeg",
    ".gif" => "image/gif", ".svg" => "image/svg+xml", ".webp" => "image/webp",
    ".ico" => "image/x-icon",
    ".mp4" => "video/mp4", ".webm" => "video/webm",
    ".mp3" => "audio/mpeg", ".wav" => "audio/wav", ".ogg" => "audio/ogg",
    ".pdf" => "application/pdf",
    ".zip" => "application/zip", ".gz" => "application/gzip",
    ".tar" => "application/x-tar",
    ".wasm" => "application/wasm",
    ".woff" => "font/woff", ".woff2" => "font/woff2",
    ".ttf" => "font/ttf", ".eot" => "application/vnd.ms-fontobject"
  }.freeze

  DEFAULT_PATTERN = "**/*"

  attr_reader :directory, :prefix

  def initialize(directory, prefix: "", pattern: DEFAULT_PATTERN, exclude: [])
    @directory = directory
    @prefix    = normalize_prefix(prefix)
    @pattern   = pattern
    @exclude   = Array(exclude)
  end

  def scan
    full_pattern = File.join(@directory, @pattern)
    all_files = Dir.glob(full_pattern).select { |f| File.file?(f) }

    excluded = @exclude.flat_map do |pat|
      Dir.glob(File.join(@directory, pat)).select { |f| File.file?(f) }
    end.to_set

    all_files.reject { |f| excluded.include?(f) }.sort.map do |path|
      rel = path.sub("#{@directory}/", "")
      { path: path, key: "#{@prefix}#{rel}", size: File.size(path) }
    end
  end

  def deduplicate(files)
    keys_seen = {}
    unique = []
    skipped = []
    files.each do |f|
      if keys_seen.key?(f[:key])
        skipped << { path: f[:path], key: f[:key],
                     reason: "duplicate key (first: #{keys_seen[f[:key]]})" }
      else
        keys_seen[f[:key]] = f[:path]
        unique << f
      end
    end
    [unique, skipped]
  end

  def detect_content_type(path)
    @content_type_cache ||= {}
    ext = File.extname(path).downcase
    @content_type_cache[ext] ||= MIME_TYPES[ext] || "application/octet-stream"
  end

  private

  def normalize_prefix(prefix)
    return "" if prefix.nil? || prefix.empty?

    prefix.end_with?("/") ? prefix : "#{prefix}/"
  end
end
