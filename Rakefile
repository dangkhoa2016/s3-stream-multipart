# frozen_string_literal: true

require "rake/testtask"

desc "Run all tests (both suites in one process for single coverage report)"
Rake::TestTask.new(:test) do |t|
  t.libs << "tests"
  t.test_files = FileList["tests/unit/**/test_*.rb", "tests/s3_client/test_*.rb", "tests/s3_multi_bucket_client/test_*.rb"]
end

desc "Check coverage >= 99% threshold"
task :coverage do
  require "simplecov"
  SimpleCov.coverage_dir "coverage"
  results = SimpleCov::ResultMerger.merged_result
  if results.nil?
    puts "No coverage results available yet. Run `rake test` first."
    next
  end
  percent = results.covered_percent
  puts "Coverage: #{percent.round(4)}%"
  raise "Coverage #{percent}% < 99%" if percent < 99
end

namespace :test do
  desc "Run unit tests"
  Rake::TestTask.new(:unit) do |t|
    t.libs << "tests"
    t.test_files = FileList["tests/unit/**/test_*.rb"]
    t.verbose = true
  end

  desc "Run integration tests only (excludes unit tests)"
  Rake::TestTask.new(:integration) do |t|
    t.libs << "tests"
    t.test_files = FileList["tests/s3_client/test_*.rb", "tests/s3_multi_bucket_client/test_*.rb"]
    t.verbose = true
  end

  desc "Run S3Client tests"
  Rake::TestTask.new(:s3_client) do |t|
    t.libs << "tests"
    t.test_files = FileList["tests/s3_client/test_*.rb"]
  end

  desc "Run S3MultiBucketClient tests"
  Rake::TestTask.new(:s3_multi_bucket_client) do |t|
    t.libs << "tests"
    t.test_files = FileList["tests/s3_multi_bucket_client/test_*.rb"]
  end

  desc "Run quick tests (both suites, exclude memory/race)"
  Rake::TestTask.new(:quick) do |t|
    t.libs << "tests"
    t.test_files = FileList["tests/unit/**/test_*.rb", "tests/s3_client/test_*.rb", "tests/s3_multi_bucket_client/test_*.rb"].exclude(
      "**/test_memory.rb", "**/test_race.rb"
    )
  end

  desc "Run S3Client quick tests (exclude memory/race)"
  Rake::TestTask.new(:s3_client_quick) do |t|
    t.libs << "tests"
    t.test_files = FileList["tests/s3_client/test_*.rb"].exclude(
      "**/test_memory.rb", "**/test_race.rb"
    )
  end

  desc "Run S3MultiBucketClient quick tests (exclude memory/race)"
  Rake::TestTask.new(:s3_multi_bucket_client_quick) do |t|
    t.libs << "tests"
    t.test_files = FileList["tests/s3_multi_bucket_client/test_*.rb"].exclude(
      "**/test_memory.rb", "**/test_race.rb"
    )
  end
end

desc "Validate RBS type signatures (skipped if rbs is not available)"
task :'rbs:validate' do
  if system("rbs --version >/dev/null 2>&1")
    sh "rbs", "validate", "sig/s3-stream-multipart.rbs"
  end
end

desc "Generate YARD documentation"
task :docs do
  sh "yard", "doc", "--no-cache", "--output-dir", "docs/yard"
end

desc "Check YARD documentation coverage"
task :'docs:coverage' do
  output = `yard stats --list-undoc 2>&1`
  puts output
  unless output.include?("100.00% documented")
    warn "Documentation coverage is below 100%"
  end
end

# ── Release tasks ─────────────────────────────────────────────────────
gemspec = Gem::Specification.load("s3-stream-multipart.gemspec")

desc "Build the gem into pkg/"
task :build do
  sh "gem", "build", "s3-stream-multipart.gemspec"
  FileUtils.mkdir_p("pkg")
  FileUtils.mv(Dir.glob("s3-stream-multipart-*.gem"), "pkg/")
end

desc "Build and install the gem locally"
task install: :build do
  sh "gem", "install", "pkg/s3-stream-multipart-#{gemspec.version}.gem"
end

desc "Build, tag, and push the gem to RubyGems"
task :release do
  tag = "v#{gemspec.version}"
  sh "git", "tag", tag
  sh "git", "push", "origin", tag
  sh "gem", "push", "pkg/s3-stream-multipart-#{gemspec.version}.gem"
end

task default: :test
