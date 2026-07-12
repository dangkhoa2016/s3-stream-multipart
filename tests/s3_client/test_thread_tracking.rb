# frozen_string_literal: true

require_relative "../test_helper"
require_relative "../../src/concurrent/thread_tracking"

class S3ThreadTrackingTest < Minitest::Test
  class TrackingHost
    include S3ThreadTracking

    attr_reader :tracking_mtx, :in_progress_parts, :thread_states

    def initialize
      @tracking_mtx = Mutex.new
      @in_progress_parts = {}
      @thread_states = {}
      @client = self
    end

    def log_debug(*); end
    def log_info(*); end
    def log_warn(*); end
    def log_error(*); end

    def now_iso
      "2026-01-01T00:00:00Z"
    end
  end

  def setup
    @host = TrackingHost.new
  end

  def test_register_thread
    @host.register_thread("t0", 42)
    assert_equal "started", @host.thread_states["t0"][:status]
    assert_equal 42, @host.thread_states["t0"][:native_thread_id]
  end

  def test_mark_part_in_progress
    @host.register_thread("t0", 1)
    @host.mark_part_in_progress(5, "t0")
    assert_equal "t0", @host.in_progress_parts[5]
    assert_equal "uploading", @host.thread_states["t0"][:status]
    assert_equal 5, @host.thread_states["t0"][:current_part]
  end

  def test_mark_part_error
    @host.register_thread("t0", 1)
    @host.mark_part_in_progress(5, "t0")
    @host.mark_part_error(5, "t0")
    assert_nil @host.in_progress_parts[5]
    assert_equal "error", @host.thread_states["t0"][:status]
  end

  def test_finish_thread
    @host.register_thread("t0", 1)
    @host.finish_thread("t0", 3)
    assert_equal "finished", @host.thread_states["t0"][:status]
    assert @host.thread_states["t0"][:finished_at]
  end
end
