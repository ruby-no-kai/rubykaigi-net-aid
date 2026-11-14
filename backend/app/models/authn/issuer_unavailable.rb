# typed: strict
# frozen_string_literal: true

module Authn
  # A trusted issuer could not be reached to verify or renew credentials. `reason` is the
  # authn_failure value the canonical log line reports, `url` the endpoint that failed, and
  # `detail` what it answered when no exception explains the failure.
  class IssuerUnavailable < StandardError
    #: String
    attr_reader :reason

    #: String
    attr_reader :url

    #: String?
    attr_reader :detail

    #: (String reason, url: String, ?detail: String?) -> void
    def initialize(reason, url:, detail: nil)
      @reason = reason
      @url = url
      @detail = detail
      super("#{url} is unavailable")
    end

    # The canonical log line's fields for this failure, naming its cause.
    #: () -> Hash[Symbol, String]
    def log_fields
      error = cause
      described = detail || ("#{error.class}: #{error.message}" if error)
      {authn_failure: reason, authn_unavailable_cause: described&.truncate(255)}.compact
    end
  end
end
