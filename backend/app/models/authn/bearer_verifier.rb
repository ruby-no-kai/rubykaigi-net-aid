# typed: strict
# frozen_string_literal: true

module Authn
  # Verifies a bearer token against the trusted issuer its unverified `iss` names, and maps its
  # claims to an Actor.
  class BearerVerifier
    # Tolerated clock skew between an issuer and this server.
    LEEWAY = 30 #: Integer

    # The token is not accepted. `reason` is one of the authn_failure values the canonical log
    # line reports, and `issuer` the unverified `iss`.
    class Failure < StandardError
      #: String
      attr_reader :reason

      #: String?
      attr_reader :issuer

      #: (String reason, issuer: String?) -> void
      def initialize(reason, issuer:)
        @reason = reason
        @issuer = issuer
        super("bearer token refused: #{reason}")
      end
    end

    #: (?issuers: Hash[String, Issuer]) -> void
    def initialize(issuers: Issuer.trusted)
      @issuers = issuers
    end

    #: (String token, user_agent: String) -> Actor
    def verify(token, user_agent:)
      encoded = JWT::EncodedToken.new(token)
      header, unverified_claims = unverified_parts(encoded)
      iss = unverified_claims["iss"].then { it.to_s if it }

      issuer = @issuers[iss.to_s] or raise Failure.new("unknown_issuer", issuer: iss)
      raise Failure.new("id_token_as_bearer", issuer: iss) unless issuer.bearer_type?(header)

      verify_signature!(encoded, issuer, header, iss:)
      verify_claims!(encoded, issuer, iss:)
      issuer.actor_for(encoded.payload, user_agent:)
    end

    #: (JWT::EncodedToken) -> [Hash[String, untyped], Hash[String, untyped]]
    private def unverified_parts(encoded)
      header = encoded.header
      claims = encoded.unverified_payload
      raise Failure.new("bad_signature", issuer: nil) unless header.is_a?(Hash) && claims.is_a?(Hash)

      [header, claims]
    rescue JWT::DecodeError, JSON::ParserError
      raise Failure.new("bad_signature", issuer: nil)
    end

    #: (JWT::EncodedToken, Issuer, Hash[String, untyped], iss: String?) -> void
    private def verify_signature!(encoded, issuer, header, iss:)
      kid = header["kid"]
      key = (JwksCache.find(issuer.jwks_url, kid) if kid.is_a?(String))
      raise Failure.new("unknown_kid", issuer: iss) unless key

      key_alg = key[:alg]
      algorithms = key_alg ? Issuer::ALGORITHMS & [key_alg] : Issuer::ALGORITHMS
      encoded.verify_signature!(algorithm: algorithms, key:)
    rescue JWT::DecodeError
      raise Failure.new("bad_signature", issuer: iss)
    end

    #: (JWT::EncodedToken, Issuer, iss: String?) -> void
    private def verify_claims!(encoded, issuer, iss:)
      encoded.verify_claims!(
        :numeric,
        {exp: {leeway: LEEWAY}},
        {nbf: {leeway: LEEWAY}},
        {iat: {leeway: LEEWAY}},
        {iss: issuer.url},
        {aud: issuer.audiences},
        {required: ["sub", "exp", "iat", *issuer.required_claims]},
      )
    rescue JWT::ExpiredSignature, JWT::ImmatureSignature, JWT::InvalidIatError
      raise Failure.new("expired", issuer: iss)
    rescue JWT::InvalidAudError
      raise Failure.new("wrong_audience", issuer: iss)
    rescue JWT::InvalidIssuerError
      raise Failure.new("unknown_issuer", issuer: iss)
    rescue JWT::DecodeError
      raise Failure.new("bad_signature", issuer: iss)
    end
  end
end
