# frozen_string_literal: true

require 'English'
require "digest"
require "securerandom"
require "tempfile"
require "fileutils"

module S3TestHelpers
  def create_temp_binary_file(size)
    src_dir = File.join(TEST_TMP, "src")
    FileUtils.mkdir_p(src_dir)
    path = File.join(src_dir, "test_#{$PROCESS_ID}_#{rand(100_000)}.bin")
    md5 = Digest::MD5.new
    File.open(path, "wb") do |f|
      written = 0
      while written < size
        chunk_size = [1024 * 1024, size - written].min
        buf = SecureRandom.bytes(chunk_size)
        f.write(buf)
        md5 << buf
        written += chunk_size
      end
    end
    [path, md5.hexdigest]
  end

  def rss_kb
    `ps -o rss= -p #{Process.pid}`.to_i
  end

  def unique_port(base)
    base + (Process.pid % 100) + rand(10)
  end

  def suite_tmp_dir(suite_name)
    dir = File.join(TEST_TMP, suite_name)
    FileUtils.rm_rf(dir)
    FileUtils.mkdir_p(dir)
    dir
  end

  def cleanup_suite_tmp(suite_name)
    FileUtils.rm_rf(File.join(TEST_TMP, suite_name))
  end

  # Helper to stub a class method for the duration of a block.
  # Unlike Minitest's stub, this uses define_singleton_method directly
  # and works with both minitest 5 and 6.
  def with_stubbed(klass, method_name, replacement = nil, &test_block)
    original = klass.method(method_name)
    if replacement
      v = $VERBOSE
      $VERBOSE = nil
      klass.define_singleton_method(method_name, &replacement)
      $VERBOSE = v
    end
    test_block.call
  ensure
    v = $VERBOSE
    $VERBOSE = nil
    klass.define_singleton_method(method_name, original)
    $VERBOSE = v
  end

  def capture_stderr
    old = $stderr
    $stderr = StringIO.new
    yield
    $stderr.string
  ensure
    $stderr = old
  end

  def build_list_xml(contents, common_prefixes, is_truncated, next_token)
    xml = +"<?xml version=\"1.0\" encoding=\"UTF-8\"?><ListBucketResult>"
    contents.each do |c|
      xml << "<Contents><Key>#{c[:key]}</Key><Size>#{c[:size]}</Size>"
      xml << "<LastModified>#{c[:last_modified]}</LastModified>"
      xml << "<StorageClass>#{c[:storage_class]}</StorageClass>"
      xml << "<ETag>#{c[:etag]}</ETag></Contents>"
    end
    common_prefixes.each { |p| xml << "<CommonPrefixes><Prefix>#{p}</Prefix></CommonPrefixes>" }
    xml << "<IsTruncated>#{is_truncated}</IsTruncated>"
    xml << "<NextContinuationToken>#{next_token}</NextContinuationToken>" if next_token
    xml << "</ListBucketResult>"
    xml
  end

  def build_list_response(contents, common_prefixes, is_truncated, next_token)
    OpenStruct.new(
      body: build_list_xml(contents, common_prefixes, is_truncated, next_token),
      code: "200",
      message: "OK"
    )
  end
end
