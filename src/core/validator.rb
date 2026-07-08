# frozen_string_literal: true

# core/validator.rb
#
# Input validation methods for S3BaseClient.
# Intended to be extended (class-level methods) or included as needed.

module Validator
  # Validate an S3 bucket name.
  #
  # S3-compatible services (MinIO, R2, etc.) may use relaxed naming rules,
  # so we only enforce non-empty and no obviously invalid characters.
  #
  # @param bucket [String] the bucket name to validate
  # @raise [ArgumentError] if bucket is empty or contains invalid characters
  # @return [void]
  def validate_bucket!(bucket)
    raise ArgumentError, "bucket cannot be empty" if bucket.to_s.empty?
    return unless bucket.match?(/[<>\\{}^`|\x00]/)

    raise ArgumentError, "bucket name contains invalid characters: #{bucket}"
  end

  # Validate an S3 object key.
  #
  # @param key [String] the object key to validate
  # @raise [ArgumentError] if key is empty, exceeds 1024 bytes, or contains null bytes
  # @return [void]
  def validate_key!(key)
    raise ArgumentError, "key cannot be empty" if key.to_s.empty?
    if key.bytesize > 1024
      raise ArgumentError, "key must be <= 1024 bytes, got #{key.bytesize}"
    end
    return unless key.match?(/\x00/)

    raise ArgumentError, "key cannot contain null bytes"
  end

  # Validate AWS credentials format.
  #
  # @param access_key      [String] the AWS access key ID
  # @param secret_key      [String] the AWS secret access key
  # @param access_key_name [String] parameter name for error messages (default "access_key")
  # @param secret_key_name [String] parameter name for error messages (default "secret_key")
  # @raise [ArgumentError] if either key is empty
  # @return [void]
  def validate_credentials!(access_key, secret_key,
                            access_key_name: "access_key",
                            secret_key_name: "secret_key")
    raise ArgumentError, "#{access_key_name} cannot be empty" if access_key.to_s.empty?
    raise ArgumentError, "#{secret_key_name} cannot be empty" if secret_key.to_s.empty?
  end
end
