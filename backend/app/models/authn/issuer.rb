# typed: strict
# frozen_string_literal: true

module Authn
  # A trusted token issuer: where its signing keys are, which audiences it must name, and how its
  # claims map to an Actor.
  #
  # @abstract
  class Issuer
    # The signing algorithms accepted from any issuer.
    ALGORITHMS = %w[RS256 ES256].freeze #: Array[String]

    # Trusted issuers keyed by their `iss`.
    #: () -> Hash[String, Issuer]
    def self.trusted
      authn = Rails.configuration.x.authn
      aws_issuers = authn.aws_issuers #: Array[String]
      issuers = [
        Issuer::Himari.new(url: authn.himari_issuer, audiences: authn.himari_client_ids),
        Issuer::GithubActions.new(url: authn.github_actions_issuer, audiences: [authn.audience]),
        *aws_issuers.map { Issuer::AwsIam.new(url: it, audiences: [authn.audience]) }
      ]
      issuers.index_by(&:url)
    end

    #: String
    attr_reader :url

    #: Array[String]
    attr_reader :audiences

    #: (url: String, audiences: Array[String]) -> void
    def initialize(url:, audiences:)
      @url = url
      @audiences = audiences
    end

    # The issuer of the Actor this issuer's tokens authenticate.
    #: () -> String
    def actor_issuer = raise(NotImplementedError, "#{self.class} declares no actor_issuer")

    #: () -> String
    def jwks_url = raise(NotImplementedError, "#{self.class} declares no jwks_url")

    # Claims the Actor mapping reads, beyond the standard ones every token must carry.
    #: () -> Array[String]
    def required_claims = []

    # Whether the token's header names the token type this issuer's bearer tokens have.
    #: (Hash[String, untyped]) -> bool
    def bearer_type?(_header) = true

    #: (Hash[String, untyped] claims, user_agent: String) -> Actor
    def actor_for(claims, user_agent:) = raise(NotImplementedError, "#{self.class} declares no actor_for")
  end
end
