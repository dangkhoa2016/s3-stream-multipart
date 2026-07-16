# frozen_string_literal: true

#
# extras/bulk_downloader.rb
#
# Parallel bulk download of S3 objects to a local directory.
# Lists objects via S3 list_objects, then downloads them in parallel
# using a thread pool.
#

class S3BulkDownloader
  DEFAULT_MAX_FILES = 4
  FATAL_DOWNLOAD_PATTERNS = %w[AccessDenied Forbidden NoSuchBucket].freeze

  attr_reader :client, :prefix, :delimiter, :local_directory

  def initialize(client:, local_directory:, prefix: "",
                 delimiter: nil,
                 bucket: nil,
                 max_files: DEFAULT_MAX_FILES,
                 exclude: [],
                 on_file_start: nil,
                 on_file_complete: nil,
                 on_file_error: nil)
    @client          = client
    @local_directory = File.expand_path(local_directory)
    @prefix          = prefix
    @delimiter       = delimiter
    @bucket          = bucket
    @max_files       = max_files.to_i.clamp(1, S3BaseClient::MAXIMUM_CONCURRENCY)
    @exclude         = Array(exclude)
    @on_file_start    = on_file_start
    @on_file_complete = on_file_complete
    @on_file_error    = on_file_error
  end

  def run!
    FileUtils.mkdir_p(@local_directory)

    files = list_files
    return build_empty_result if files.empty?

    t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    downloaded, failed = download_files_parallel(files)
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0

    build_result(files, downloaded, failed, elapsed)
  end

  private

  def list_files
    opts = { delimiter: @delimiter, paginate: true }
    opts[:prefix] = @prefix if @prefix && !@prefix.empty?
    opts[:bucket] = @bucket if @bucket

    result = @client.list_objects(**opts)
    contents = result[:contents]

    contents.reject do |obj|
      key = obj[:key]
      @exclude.any? { |pat| File.fnmatch(pat, key, File::FNM_DOTMATCH) }
    end
  end

  def download_files_parallel(files)
    downloaded = []
    failed     = []
    mutex      = Mutex.new
    queue      = Queue.new
    total      = files.size
    index_counter = 0
    index_mutex   = Mutex.new
    stop_flag     = [false]
    stop_mutex    = Mutex.new

    files.each { |f| queue << f }

    threads = @max_files.times.map do
      Thread.new do
        while (obj = pop_from_queue(queue))
          break if stop_mutex.synchronize { stop_flag[0] }

          idx = index_mutex.synchronize { index_counter += 1 }
          process_one_file(obj, idx, total, mutex, downloaded, failed, stop_mutex, stop_flag)
        end
      end
    end

    threads.each(&:join)
    [downloaded, failed]
  end

  def process_one_file(obj, idx, total, mutex, downloaded, failed, stop_mutex, stop_flag)
    key = obj[:key]
    local_path = File.join(@local_directory, key)

    @on_file_start&.call(key, local_path, idx, total)

    FileUtils.mkdir_p(File.dirname(local_path))

    t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    result = @client.download_file(
      key: key, bucket: @bucket, local_path: local_path
    )
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0

    entry = { key: key, local_path: local_path, size: result[:size], elapsed: elapsed }
    mutex.synchronize { downloaded << entry }

    @on_file_complete&.call(key, local_path, entry, idx, total)
  rescue S3BaseClient::DownloadError => e
    entry = { key: key, local_path: local_path, error: e.message }
    mutex.synchronize { failed << entry }
    @on_file_error&.call(key, local_path, e, idx, total)

    if fatal_download_error?(e)
      @client.log_error "[BULK-DL] Fatal error (#{e.message}) — aborting remaining downloads."
      stop_mutex.synchronize { stop_flag[0] = true }
    end
  rescue StandardError => e
    entry = { key: key, local_path: local_path, error: e.message }
    mutex.synchronize { failed << entry }
    @on_file_error&.call(key, local_path, e, idx, total)
  end

  def fatal_download_error?(error)
    msg = error.message.to_s
    FATAL_DOWNLOAD_PATTERNS.any? { |pat| msg.include?(pat) }
  end

  def build_result(files, downloaded, failed, elapsed)
    {
      total: files.size,
      downloaded: downloaded,
      failed: failed,
      skipped: [],
      elapsed: elapsed
    }
  end

  def build_empty_result
    { total: 0, downloaded: [], failed: [], skipped: [], elapsed: 0.0 }
  end

  def pop_from_queue(queue)
    queue.pop(true)
  rescue ThreadError
    nil
  end
end
