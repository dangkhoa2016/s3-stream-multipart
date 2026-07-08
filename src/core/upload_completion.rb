# frozen_string_literal: true

# core/upload_completion.rb
#
# Multipart upload completion and abort operations.

class S3BaseClient
  def abort_multipart_upload(key:, upload_id:, bucket: nil)
    _ops_execute(:delete, key, bucket: bucket, query: { uploadId: upload_id }) do |resp|
      unless resp.is_a?(Net::HTTPNoContent)
        raise S3Error.new(resp.code, "Abort multipart upload failed", resp["x-amz-request-id"], resp.body)
      end

      log_info "Multipart upload aborted: #{upload_id}"
      _format_abort_result(key, upload_id)
    end
  end

  # Complete an S3 multipart upload.
  def complete_multipart_upload(key:, upload_id:, parts:, bucket: nil)
    xml = build_complete_multipart_xml(parts)
    _ops_execute(:post, key, bucket: bucket, body: xml,
                             headers: { "content-type" => "application/xml" },
                             query: { uploadId: upload_id }) do |resp|
      (resp["ETag"] || "").gsub(/^"|"$/, "")
    end
  end

  # Safely abort a multipart upload, logging but not propagating errors.
  def safe_abort(key:, upload_id:, bucket: nil)
    _ops_execute(:delete, key, bucket: bucket, query: { uploadId: upload_id }) { |_| true }
  rescue StandardError => e
    log_error "safe_abort failed: #{e.class}: #{e.message}"
  end
end
