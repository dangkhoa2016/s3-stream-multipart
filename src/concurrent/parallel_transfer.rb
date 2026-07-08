# frozen_string_literal: true

#
# concurrent/parallel_transfer.rb
#
# S3ParallelTransfer — shared base class for parallel upload/download workers.
# Provides common initializer for mutex setup, clamping, and instance variable
# assignment used by both S3ParallelUploader and S3ParallelDownloader.

require_relative "../core/constants"
require_relative "../extras/retry_helper"
require_relative "thread_tracking"
require_relative "thread_pool"
require_relative "part_geometry"

class S3ParallelTransfer
  include S3RetryHelper
  include S3ThreadTracking
  include S3ThreadPool
  include S3PartGeometry
  include S3Constants

  attr_reader :client, :state

  def initialize(client, state, max_threads:, max_retries:, retry_delay:,
                 on_progress: nil, state_file: nil,
                 state_save_frequency: PARALLEL_SAVE_FREQUENCY,
                 progress_callback: nil)
    @client            = client
    @state             = state
    @max_threads       = max_threads.to_i.clamp(1, S3BaseClient::MAXIMUM_CONCURRENCY)
    @max_retries       = max_retries
    @retry_delay       = retry_delay
    @progress_callback = on_progress || progress_callback
    @state_file = state_file
    @state_save_frequency = state_save_frequency
    @parts_since_save     = 0
    @save_batch_mtx       = Mutex.new
    @mutex             = Mutex.new
    @rename_mutex      = Mutex.new
    @completed_count   = 0
    @tracking_mtx      = Mutex.new
    @in_progress_parts = {}
    @thread_states     = {}
  end
end
