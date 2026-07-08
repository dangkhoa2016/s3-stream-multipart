# frozen_string_literal: true

#
# extras/retry_helper.rb
#
# Delegates to S3BaseClient#retry_with_backoff (the unified retry implementation).
# Kept for backward compatibility.

module S3RetryHelper
  # Retry a block with exponential backoff by delegating to the client instance.
  #
  # @param max_retries [Integer] maximum number of retries
  # @param client      [Object] the client with retry_with_backoff capability
  # @param backoff_base [Float, nil] base backoff in seconds (deprecated, unused)
  # @param context     [String] description for log messages (default "")
  # @param on_retry    [Proc, nil] callback called on each retry
  # @param block       [Proc] the block to execute with retry
  #
  # @return [Object] the return value of the block
  #
  # @example Retry a fragile operation
  #   S3RetryHelper.retry_with_backoff(max_retries: 3, client: s3) { s3.head_object("key") }
  def self.retry_with_backoff(max_retries:, client:, backoff_base: nil, context: "", on_retry: nil, &)
    client.retry_with_backoff(max_retries: max_retries, context: context, on_retry: on_retry, &)
  end

  # Instance method for modules/classes that include S3RetryHelper.
  # When +client != self+ (e.g. PartUploader with @client), delegates to client.
  # When +client == self+ (e.g. S3BaseClient subclass calling with client: self),
  # calls super to reach S3BaseClient#retry_with_backoff directly, avoiding
  # infinite recursion through the module.
  #
  # @param max_retries [Integer] maximum number of retries
  # @param client      [Object] the client with retry_with_backoff capability
  # @param backoff_base [Float, nil] base backoff in seconds (deprecated)
  # @param context     [String] description for log messages (default "")
  # @param on_retry    [Proc, nil] callback called on each retry
  # @param block       [Proc] the block to execute with retry
  #
  # @raise [ArgumentError] if no block given
  #
  # @return [Object] the return value of the block
  def retry_with_backoff(max_retries:, client: nil, backoff_base: nil, context: "", on_retry: nil, &)
    if client.nil? || client.equal?(self)
      super(max_retries: max_retries, context: context, on_retry: on_retry, &)
    else
      client.retry_with_backoff(max_retries: max_retries, context: context, on_retry: on_retry, &)
    end
  end
end
