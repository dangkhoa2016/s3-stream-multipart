# frozen_string_literal: true

Gem::Specification.new do |s|
  s.name        = "s3-upload"
  s.version     = "3.0.0"
  s.summary     = "Resumable multipart upload/download for S3-compatible storage"
  s.description = <<~DESC
    A lightweight, memory-efficient Ruby client for S3-compatible storage.
    Features parallel multipart upload/download with resume support,
    event callbacks, bulk directory upload, presigned URLs, and
    support for AWS S3, MinIO, Cloudflare R2, and other S3-compatible providers.
  DESC
  s.authors     = ["Dang Khoa"]
  s.license     = "MIT"
  s.homepage    = "https://github.com/dangkhoa2016/s3-upload"

  s.metadata    = {
    "source_code_uri" => "https://github.com/dangkhoa2016/s3-upload",
    "changelog_uri" => "https://github.com/dangkhoa2016/s3-upload/blob/main/CHANGELOG.md",
    "bug_tracker_uri" => "https://github.com/dangkhoa2016/s3-upload/issues",
    "rubygems_mfa_required" => "true"
  }

  s.required_ruby_version = ">= 3.2"

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
  s.executables = ["s3-up"]
  s.require_paths = ["src"]

  s.add_dependency "aws-sigv4", "~> 1.0"
  s.add_dependency "rexml", "~> 3.0"

  s.add_development_dependency "minitest", "~> 6.0"
  s.add_development_dependency "rake", "~> 13.0"
  s.add_development_dependency "rbs", ">= 3.0"
  s.add_development_dependency "rubocop", "~> 1.50"
  s.add_development_dependency "rubocop-minitest", "~> 0.30"
  s.add_development_dependency "simplecov", "~> 0.22"
  s.add_development_dependency "simplecov-console", "~> 0.9"
  s.add_development_dependency "steep", "~> 2.0"
  s.add_development_dependency "webrick", "~> 1.8"
  s.add_development_dependency "yard", "~> 0.9"
end
