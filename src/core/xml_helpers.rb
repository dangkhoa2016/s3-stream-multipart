# frozen_string_literal: true

# core/xml_helpers.rb
#
# XML parsing helpers for multipart upload S3 responses.
module S3XmlHelpers
  include S3Constants
  include S3Errors

  private

  def extract_upload_id(xml)
    doc = REXML::Document.new(xml)
    el = doc.elements["//UploadId"]
    raise S3Error.new("500", "Did not find UploadId in response", nil, xml) unless el

    el.text
  end

  def extract_etag(xml)
    doc = REXML::Document.new(xml)
    el = doc.elements["//ETag"]
    raise S3Error.new("500", "Did not find ETag in response", nil, xml) unless el

    el.text
  end

  def build_complete_multipart_xml(parts)
    doc = REXML::Document.new
    doc << REXML::XMLDecl.new("1.0", "UTF-8")
    root = doc.add_element("CompleteMultipartUpload")
    parts.each do |p|
      part = root.add_element("Part")
      part.add_element("PartNumber").add_text(p[:part_number].to_s)
      part.add_element("ETag").add_text(p[:etag])
    end
    out = +""
    REXML::Formatters::Default.new.write(doc, out)
    out
  end

  def parse_multipart_uploads_xml(xml)
    doc = REXML::Document.new(xml)
    uploads = []
    doc.elements.each("//Upload") do |upload|
      uploads << {
        upload_id: upload.elements["UploadId"]&.text,
        key: upload.elements["Key"]&.text,
        initiated: upload.elements["Initiated"]&.text,
        storage_class: upload.elements["StorageClass"]&.text
      }
    end
    uploads
  end

  def parse_parts_xml(xml)
    doc = REXML::Document.new(xml)
    parts = []
    doc.elements.each("//Part") do |part|
      parts << {
        part_number: part.elements["PartNumber"]&.text&.to_i,
        etag: part.elements["ETag"]&.text,
        size: part.elements["Size"]&.text&.to_i,
        last_modified: part.elements["LastModified"]&.text
      }
    end
    parts
  end

  def parse_list_objects_xml(xml)
    doc = REXML::Document.new(xml)
    contents = []
    doc.elements.each("//Contents") do |el|
      contents << {
        key: el.elements["Key"]&.text,
        size: el.elements["Size"]&.text&.to_i,
        last_modified: el.elements["LastModified"]&.text,
        storage_class: el.elements["StorageClass"]&.text,
        etag: el.elements["ETag"]&.text
      }
    end
    common_prefixes = []
    doc.elements.each("//CommonPrefixes") do |el|
      common_prefixes << el.elements["Prefix"]&.text
    end
    is_truncated = doc.elements["//IsTruncated"]&.text == "true"
    next_token = doc.elements["//NextContinuationToken"]&.text
    {
      contents: contents,
      common_prefixes: common_prefixes,
      is_truncated: is_truncated,
      next_continuation_token: next_token
    }
  end

  def extract_total_size(response, start_byte)
    if response['Content-Range']
      response['Content-Range'][%r{/(\d+)$}, 1]&.to_i
    elsif response['Content-Length']
      response['Content-Length'].to_i + start_byte
    end
  end

  def parse_buckets_xml(xml)
    doc = REXML::Document.new(xml)
    buckets = []
    doc.elements.each("//Bucket") do |el|
      buckets << {
        name: el.elements["Name"]&.text,
        creation_date: el.elements["CreationDate"]&.text
      }
    end
    buckets
  end
end
