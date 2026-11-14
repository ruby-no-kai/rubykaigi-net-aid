# typed: strict
# frozen_string_literal: true

# A trusted issuer could not be reached to verify or renew credentials. `reason` is the
# authn_failure value the canonical log line reports, `url` the endpoint that failed, and `answer`
# what it answered when no exception explains the failure.
class Authn::Issuer::IssuerUnavailable < Errors::Unavailable
  #: String
  attr_reader :reason

  #: String
  attr_reader :url

  #: String?
  attr_reader :answer

  #: (String reason, url: String, ?answer: String?) -> void
  def initialize(reason, url:, answer: nil)
    @reason = reason
    @url = url
    @answer = answer
    super("#{url} is unavailable", detail: "The identity provider is unavailable. Retry later.")
  end

  #: () -> Hash[Symbol, untyped]
  def log_fields
    error = cause
    described = answer || ("#{error.class}: #{error.message}" if error)
    {authn_failure: reason, authn_unavailable_cause: described&.truncate(255)}.compact
  end
end
