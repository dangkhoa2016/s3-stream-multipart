# frozen_string_literal: true

# core/constants.rb
#
# Shared constants for S3 client classes.
module S3Constants
  # Minimum part size for multipart upload (5 MB per S3 requirement).
  MIN_PART_SIZE = 5 * 1024 * 1024

  # Maximum part size (5 GB per S3 limit).
  MAX_PART_SIZE = 5 * 1024 * 1024 * 1024

  # Maximum number of parts S3 accepts in a single multipart upload.
  MAX_PARTS     = 10_000

  # Default concurrency / thread count.
  DEFAULT_MAX_THREADS = 4

  # Default retry count for transient errors.
  DEFAULT_MAX_RETRIES = 3

  # Default base delay for exponential backoff (seconds).
  DEFAULT_RETRY_DELAY = 0.25

  # Default chunk buffer size for streaming download.
  READ_CHUNK_BYTES    = 64 * 1024

  # ANSI color codes for colored log output.
  LOG_COLORS = {
    "DEBUG" => "\e[2m",
    "INFO" => "\e[34m",
    "WARN" => "\e[33m",
    "ERROR" => "\e[31m",
    "FATAL" => "\e[35m"
  }.freeze
  LOG_COLOR_RESET  = "\e[0m"
  LOG_COLOR_GREEN  = "\e[32m"
  LOG_COLOR_DIM    = "\e[2m"

  # Regex to colorize key S3 action words in log messages.
  LOG_KEYWORD_REGEX = /(
    \[PLAN\]|\[PART START\]|\[PART DONE\]|\[PART FAILED\]|
    \bRETRY\b|\bRESUME\b|\bSKIP\b|\bCOMPLETE\b|\bFAILED\b|
    \bSTATE\b|\bBULK\b|\bUPLOAD\b|\bDOWNLOAD\b
  )/x

  # Threshold for streaming single PUT (bytes).
  STREAM_SINGLE_PUT_THRESHOLD = 10 * 1024 * 1024

  # Hard cap on concurrency to prevent resource exhaustion.
  MAXIMUM_CONCURRENCY = 32

  # Default SSL verify mode (verify server certificate).
  DEFAULT_SSL_VERIFY_MODE = OpenSSL::SSL::VERIFY_PEER

  # Maximum backoff delay for retries (seconds).
  MAX_RETRY_DELAY = 30.0

  # Frequency of state file saves during parallel transfers (parts completed).
  PARALLEL_SAVE_FREQUENCY = 10
end
