# frozen_string_literal: true

#
# core/upload_state_manager.rb
#
# Class for managing resumable multipart upload state.
# Handles loading, saving, validating, and cleaning up state files.
# Uses atomic writes with fsync for durability.
#
# Instantiate with a client reference:
#   @upload_state_manager = UploadStateManager.new(self)
#
# Requires the client to respond to: log_info, log_warn, log_debug,
# emit_event, human_readable_size, safe_abort.
require_relative "../states/upload_state"

class UploadStateManager
  def initialize(client)
    @client = client
    @_last_saved_parts_count = nil
    @rename_mutex = Mutex.new
  end

  def load_state(path)
    return nil unless path && File.file?(path)

    raw = parse_state_data(path)
    return nil unless raw

    state_obj = UploadState.new(raw)
    @client.log_info "[STATE LOADED] Auto-loaded state from #{path}: " \
                     "upload_id=#{raw[:upload_id]} session=#{raw[:upload_session_id] || 'N/A'} " \
                     "progress=#{state_obj.completed_parts_count}/#{state_obj.total_parts} parts"

    @client.emit_event(:state_load, raw, path)
    state_obj
  end

  # Load state from file, validate against expected key/part_size/total_size/path.
  # Returns UploadState on match, nil on mismatch (aborting old upload if needed).
  # rubocop:disable Metrics/CyclomaticComplexity
  def load_and_validate(path, key:, part_size:, total_size:, local_path:, bucket: nil, file_fingerprint: nil)
    return nil unless path && File.file?(path)

    raw = parse_state_data(path)
    return nil unless raw

    state = UploadState.new(raw)
    state.bucket ||= bucket
    state.local_path ||= local_path

    if state.key == key && state.part_size == part_size &&
       state.total_size == total_size && state.local_path == File.expand_path(local_path) &&
       (file_fingerprint.nil? || state.file_fingerprint.nil? || state.file_fingerprint == file_fingerprint)
      @client.log_info "[STATE LOADED] Auto-loaded state from #{path}: " \
                       "upload_id=#{state.upload_id} session=#{state.upload_session_id || 'N/A'} " \
                       "progress=#{state.completed_parts_count}/#{state.total_parts} parts"
      state
    else
      @client.log_warn "[STATE MISMATCH] State file does not match — starting fresh"
      @client.safe_abort(key: state.key, upload_id: state.upload_id, bucket: state.bucket)
      File.delete(path) if File.exist?(path)
      nil
    end
  rescue JSON::ParserError, Errno::ENOENT => e
    @client.log_warn "[STATE LOAD FAILED] #{path}: #{e.message}"
    nil
  end
  # rubocop:enable Metrics/CyclomaticComplexity

  def parse_state_data(path)
    raw = JSON.parse(File.read(path), symbolize_names: true)
    return nil unless raw.is_a?(Hash) && raw[:upload_id]

    raw[:part_size]  = raw[:part_size].to_i
    raw[:total_size] = raw[:total_size].to_i
    parts = raw[:parts] || {}
    raw[:parts] = parts.each_with_object({}) do |(k, v), h|
      h[k.to_s.to_i] = v.to_s
    end
    in_progress = raw[:in_progress_parts] || {}
    raw[:in_progress_parts] = in_progress.each_with_object({}) do |(k, v), h|
      h[k.to_s.to_i] = v.to_s
    end
    raw[:thread_states] ||= {}
    raw[:resume_count] ||= 0
    raw
  rescue JSON::ParserError => e
    @client.log_warn "[STATE CORRUPT] #{path}: #{e.message}"
    nil
  end

  # Atomic state write: write tmp -> fsync -> rename -> fsync dir.
  #
  # During parallel upload, multiple threads may want to persist state simultaneously.
  # Each thread holds 1 snapshot at a time (later snapshots always have
  # MORE parts than earlier snapshots, as completed_parts only increases).
  # If write + rename run freely, threads with older snapshots might
  # rename AFTER threads with newer snapshots -> external readers observe
  # DECREASED part count (violates monotonicity).
  #
  # -> All write/fsync/rename operations are in `@rename_mutex`. State file
  # is only ~1 KB, fsync ~10us on SSD -> contention is much smaller than
  # part upload (~hundreds of ms).
  def save_state(path, state, tmp_path: nil)
    return unless path

    state[:last_updated_at] = @client.now_iso

    new_count = (state[:parts] || {}).size
    state_obj = UploadState.new(state)
    payload = state_obj.to_json

    atomic_write_state(path, payload, new_count, tmp_path)
    sync_dir(path)
    # :nocov:
    in_prog = (state[:in_progress_parts] || {}).keys.map(&:to_i).sort
    thread_summary = (state[:thread_states] || {}).map do |tid, info|
      "#{tid}:#{info[:status] || '?'}(#{(info[:parts_done] || []).size})"
    end.join(",")

    @client.log_debug "[STATE SAVED] #{path}: #{state_obj.completed_parts_count}/#{state_obj.total_parts} parts " \
                      "(#{state_obj.progress_percentage}%) session=#{state_obj.upload_session_id} " \
                      "in_progress=#{in_prog.inspect} threads=[#{thread_summary}]"
    # :nocov:
  end

  def atomic_write_state(path, payload, new_count, tmp_path)
    tmp = tmp_path || "#{path}.tmp"
    @rename_mutex.synchronize do
      if @_last_saved_parts_count && new_count < @_last_saved_parts_count
        @client.log_debug "[STATE SKIP] #{path}: #{new_count} < #{@_last_saved_parts_count} (stale snapshot, skipping)"
        return
      end
      write_and_rename(tmp, path, payload)
      @_last_saved_parts_count = new_count
    end
  end

  def write_and_rename(tmp, path, payload)
    File.open(tmp, "w") do |f|
      f.write(payload)
      f.fsync
    end
    File.rename(tmp, path)
  end

  def sync_dir(path)
    File.open(File.dirname(path)) do |d|
      d.fsync
    rescue StandardError
      nil
    end
  rescue Errno::EISDIR, Errno::EINVAL
    nil
  end

  # Return state if valid (matches key/part_size/total_size/local_path);
  # otherwise abort old upload on S3 (if any) and return nil.
  def validate_state(state, key:, part_size:, total_size:, local_path:)
    return nil unless state

    state_obj = UploadState.new(state)
    return nil if state_mismatched?(state, key, part_size, total_size, local_path)
    return nil if file_changed?(state, local_path)

    @client.log_info "[RESUME] Progress: #{state_obj.summary}"
    @client.log_info "[RESUME] Started: #{state[:started_at] || 'unknown'} | " \
                     "Last updated: #{state[:last_updated_at] || 'unknown'}"
    state_obj
  end

  def state_mismatched?(state, key, part_size, total_size, local_path)
    abs_local = File.expand_path(local_path)

    return false if state[:key] == key &&
                    state[:part_size] == part_size &&
                    state[:total_size] == total_size &&
                    state[:local_path] == abs_local

    @client.log_warn "[STATE MISMATCH] Aborting old upload (id=#{state[:upload_id]}, session=#{state[:upload_session_id] || 'N/A'})"
    @client.log_warn "  Old: key=#{state[:key].inspect} size=#{state[:total_size]} (#{@client.human_readable_size(state[:total_size] || 0)}) " \
                     "part_size=#{state[:part_size]} path=#{state[:local_path].inspect} " \
                     "session=#{state[:upload_session_id] || 'N/A'} fingerprint=#{state[:file_fingerprint] || 'N/A'}"
    @client.log_warn "  New: key=#{key.inspect} size=#{total_size} (#{@client.human_readable_size(total_size)}) " \
                     "part_size=#{part_size} path=#{abs_local.inspect}"
    @client.emit_event(:state_mismatch, state, key, total_size)
    @client.safe_abort(key: state[:key], upload_id: state[:upload_id])
    true
  end

  def file_changed?(state, local_path)
    return false unless state[:file_fingerprint] && File.exist?(local_path)

    current_fp = begin
      mtime = File.mtime(local_path).to_f
      size  = File.size(local_path)
      "#{mtime}-#{size}"
    end
  rescue Errno::ENOENT
    false
  else
    return false if current_fp == state[:file_fingerprint]

    @client.log_warn "[STATE FILE CHANGED] Local file fingerprint mismatch! " \
                     "Expected #{state[:file_fingerprint]}, got #{current_fp}. " \
                     "File may have been modified since upload started."
    @client.log_warn "  Aborting old upload and starting fresh."
    @client.emit_event(:state_mismatch, state, state[:key], state[:total_size])
    @client.safe_abort(key: state[:key], upload_id: state[:upload_id])
    true
  end

  def cleanup_state(path)
    File.delete(path) if path && File.exist?(path)
  rescue StandardError => e
    @client.log_warn "state file cleanup failed (#{path}): #{e.message}"
  end
end
