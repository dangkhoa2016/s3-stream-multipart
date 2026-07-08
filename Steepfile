# frozen_string_literal: true

target :s3_upload do
  check "src"
  signature "sig"

  configure_code_diagnostics do |config|
    config[Steep::Diagnostic::Ruby::NoMethod] = :information
    config[Steep::Diagnostic::Ruby::UndeclaredMethodDefinition] = :information
    config[Steep::Diagnostic::Ruby::UnknownConstant] = :information
    config[Steep::Diagnostic::Ruby::UnannotatedEmptyCollection] = :information
    config[Steep::Diagnostic::Ruby::MethodDefinitionInUndeclaredModule] = :hint
    config[Steep::Diagnostic::Ruby::FallbackAny] = :hint
    config[Steep::Diagnostic::Ruby::ArgumentTypeMismatch] = :information
    config[Steep::Diagnostic::Ruby::MethodArityMismatch] = :information
    config[Steep::Diagnostic::Ruby::MethodBodyTypeMismatch] = :information
    config[Steep::Diagnostic::Ruby::MethodParameterMismatch] = :information
    config[Steep::Diagnostic::Ruby::ReturnTypeMismatch] = :information
    config[Steep::Diagnostic::Ruby::UnexpectedKeywordArgument] = :information
    config[Steep::Diagnostic::Ruby::UnexpectedPositionalArgument] = :information
    config[Steep::Diagnostic::Ruby::InsufficientKeywordArguments] = :information
    config[Steep::Diagnostic::Ruby::IncompatibleArgumentForwarding] = :information
    config[Steep::Diagnostic::Ruby::RequiredBlockMissing] = :information
    config[Steep::Diagnostic::Ruby::UnexpectedBlockGiven] = :information
    config[Steep::Diagnostic::Ruby::UnexpectedYield] = :information
    config[Steep::Diagnostic::Ruby::UnresolvedOverloading] = :information
  end

  library "pathname"
  library "json"
  library "securerandom"
  library "uri"
  library "cgi"
  library "net-http"
  library "fileutils"
  library "tempfile"
  library "digest"
  library "logger"
  library "forwardable"
end
