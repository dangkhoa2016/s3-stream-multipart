# frozen_string_literal: true

require 'simplecov'
require 'simplecov-console'

SimpleCov.start do
  add_filter '/tests/'

  SimpleCov.formatter = SimpleCov::Formatter::MultiFormatter.new([
                                                                   SimpleCov::Formatter::HTMLFormatter,
                                                                   SimpleCov::Formatter::Console
                                                                 ])
end

require "minitest/autorun"

# Silence noisy warnings from AWS SDK HTTP client during tests.
Warning.define_singleton_method(:warn) do |msg|
  super(msg) unless msg.include?("net/http: Content-Type did not set")
end

begin
  require "minitest/mock"
rescue LoadError
  # minitest/mock not available (minitest 6 removed it).
  # Provide minimal polyfill so tests still work.
  module Minitest
    class Mock
      def initialize
        @expectations = {}
      end

      def expect(method, retval, args = [], **kwargs)
        @expectations[[method, args, kwargs]] = retval
      end

      def method_missing(name, *args, **kwargs)
        key = @expectations.keys.find { |m, a, k| m == name && a == args && k == kwargs }
        key ? @expectations[key] : super
      end

      def respond_to_missing?(name, *)
        @expectations.keys.any? { |m,| m == name }
      end

      def verify; end
    end
  end
end
require "securerandom"
require "digest"
require "tempfile"
require "fileutils"
require "json"
require "ostruct"

require_relative "support/helpers"
require_relative "support/fake_s3_server"

TEST_TMP = File.expand_path("tmp", __dir__)
FileUtils.mkdir_p(TEST_TMP)

Minitest.after_run { FileUtils.rm_rf(TEST_TMP) }

PROJECT_ROOT = File.expand_path("..", __dir__)

# Make thread failures visible in test environment —
# rescues inside threads still work, but unexpected fatal
# errors (NoMemoryError, SystemStackError, ScriptError) will
# crash the test immediately instead of silently killing the thread.
Thread.abort_on_exception = true
