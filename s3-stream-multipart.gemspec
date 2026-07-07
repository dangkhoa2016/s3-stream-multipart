# frozen_string_literal: true

Gem::Specification.new do |s|
  s.name        = "s3-stream-multipart"
  s.version     = "1.0.0"
  s.summary     = "Resumable multipart upload/download for S3-compatible storage"
  s.description = <<~DESC
    Pure-Ruby S3-compatible storage client for memory-efficient streaming uploads and downloads.
    Resumable multipart upload, parallel streaming download, folder sync.
    No aws-sdk-s3 dependency — uses aws-sigv4 + Net::HTTP.
    Supports AWS S3, MinIO, Cloudflare R2, Backblaze B2.
  DESC
  s.authors     = ["Dang Khoa"]
  s.license     = "MIT"
  s.homepage    = "https://github.com/dangkhoa2016/s3-stream-multipart"

  s.metadata    = {
    "source_code_uri" => "https://github.com/dangkhoa2016/s3-stream-multipart",
    "changelog_uri" => "https://github.com/dangkhoa2016/s3-stream-multipart/blob/main/CHANGELOG.md",
    "bug_tracker_uri" => "https://github.com/dangkhoa2016/s3-stream-multipart/issues",
    "rubygems_mfa_required" => "true"
  }

  s.required_ruby_version = ">= 2.7.8"

  s.files = Dir[
    "src/**/*.rb",
    "sig/**/*.rbs",
    "docs/**/*.md",
    "exe/*",
    "LICENSE",
    "README.md",
    "CHANGELOG.md",
    "Gemfile",
    "Rakefile"
  ]
  s.bindir = "exe"
  s.executables = ["s3sm"]
  s.require_paths = ["src"]

  s.add_dependency "aws-sigv4", "~> 1.0"
  s.add_dependency "rexml", "~> 3.0"

  s.add_development_dependency "minitest", "~> 5.0"
  s.add_development_dependency "rake", "~> 13.0"
  s.add_development_dependency "rubocop", "~> 1.50"
  s.add_development_dependency "rubocop-minitest", "~> 0.30"
  s.add_development_dependency "simplecov", "~> 0.22"
  s.add_development_dependency "simplecov-console", "~> 0.9"
  s.add_development_dependency "webrick", "~> 1.8"
  s.add_development_dependency "yard", "~> 0.9"
end
