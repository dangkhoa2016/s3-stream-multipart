# frozen_string_literal: true

# core/session_metadata.rb
#
# Session metadata computation for upload operations.

class S3BaseClient
  def compute_upload_session_metadata(path, size)
    started_at        = now_iso
    upload_session_id = SecureRandom.hex(8)
    meta = { started_at: started_at, upload_session_id: upload_session_id }
    begin
      mtime = File.mtime(path)
      meta[:file_mtime] = mtime.iso8601
      meta[:file_fingerprint] = "#{mtime.to_f}-#{size}"
    rescue Errno::ENOENT, Errno::EACCES => e
      log_warn "[HASH] Could not compute file metadata: #{e.message}"
    end
    meta
  end
end
