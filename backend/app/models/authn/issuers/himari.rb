# typed: strict
# frozen_string_literal: true

module Authn
  module Issuers
    # himari, issuing RFC 9068 access tokens for a person to the client that obtained them.
    class Himari < Authn::Issuer
      ACTOR_ISSUER = "himari" #: String
      # RFC 9068 section 2.1, compared case-insensitively as media types are.
      ACCESS_TOKEN_TYPES = %w[at+jwt application/at+jwt].freeze #: Array[String]

      # @override
      #: () -> String
      def actor_issuer = ACTOR_ISSUER

      # @override
      #: () -> String
      def jwks_url = "#{url}/public/jwks"

      # @override
      #: () -> Array[String]
      def required_claims = %w[jti client_id]

      # An ID token has the same issuer and audience as an access token, and differs in `typ`.
      # @override
      #: (Hash[String, untyped]) -> bool
      def bearer_type?(header)
        ACCESS_TOKEN_TYPES.include?(header["typ"].to_s.downcase)
      end

      # @override
      #: (Hash[String, untyped] claims, user_agent: String) -> Actor
      def actor_for(claims, user_agent:)
        subject = claims.fetch("sub").to_s
        roles = Array(claims["roles"]).grep(String)
        Actor.new(
          issuer: ACTOR_ISSUER,
          subject:,
          display_name: (claims["name"] || subject).to_s,
          credential_id: "#{claims.fetch("client_id")}/#{claims.fetch("jti")}",
          user_agent:,
          roles:,
        )
      end
    end
  end
end
