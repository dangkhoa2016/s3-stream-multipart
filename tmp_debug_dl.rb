# frozen_string_literal: true

require_relative "tests/test_helper"
require_relative "src/s3_multi_bucket_client"
require_relative "src/states/download_state"

# Monkey-patch to trace execution with file output
S3ParallelDownloader.class_eval do
  alias_method :orig_join_threads, :join_threads
  def join_threads(thread_pool)
    File.open("/tmp/dl_trace.txt", "a") { |f| f.puts "ENTER join_threads" }
    orig_join_threads(thread_pool)
  rescue Interrupt
    File.open("/tmp/dl_trace.txt", "a") { |f| f.puts "  RESCUE Interrupt" }
    yield
    File.open("/tmp/dl_trace.txt", "a") { |f| f.puts "  after yield" }
    thread_pool.each { |t| t.raise(Interrupt) rescue nil }
    File.open("/tmp/dl_trace.txt", "a") { |f| f.puts "  after raise(Interrupt)" }
    thread_pool.each(&:join)
    File.open("/tmp/dl_trace.txt", "a") { |f| f.puts "  before save_state" }
    save_state_on_interrupt
    File.open("/tmp/dl_trace.txt", "a") { |f| f.puts "  after save_state, before raise" }
    raise Interrupt
    File.open("/tmp/dl_trace.txt", "a") { |f| f.puts "  AFTER raise (should not exec)" }
  end

  alias_method :orig_save_state_on_interrupt, :save_state_on_interrupt
  def save_state_on_interrupt
    File.open("/tmp/dl_trace.txt", "a") { |f| f.puts "    in save_state_on_interrupt" }
    orig_save_state_on_interrupt
  end
end

client = S3MultiBucketClient.new(
  region: "us-east-1", access_key: "test", secret_key: "test",
  endpoint: "http://127.0.0.1:12345", endpoint_style: :path,
  logger: Logger.new(File::NULL)
)

state = DownloadState.new(
  key: "/test.bin", local_path: "/tmp/test.bin",
  total_size: 100, part_size: 50, parts: {}
)

tmpfile = Tempfile.new(["dl_test", ".bin"])
downloader = S3ParallelDownloader.new(client, state, tmpfile,
  max_threads: 1, max_retries: 1, retry_delay: 0.01
)

File.open("/tmp/dl_trace.txt", "w") { |f| f.puts "START" }

worker = Thread.new { raise Interrupt }
worker.report_on_exception = false
begin
  downloader.send(:join_threads, [worker]) { puts "YIELD CALLED" }
rescue Interrupt
  puts "Interrupt caught"
  File.open("/tmp/dl_trace.txt", "a") { |f| f.puts "  CALLER caught Interrupt" }
end

puts "--- TRACE ---"
puts File.read("/tmp/dl_trace.txt")
