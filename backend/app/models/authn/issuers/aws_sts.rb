# typed: strict
# frozen_string_literal: true

module Authn
  module Issuers
    # An AWS account's outbound identity federation issuer, minting tokens through
    # sts:GetWebIdentityToken whose `sub` is the caller's role ARN.
    class AwsSts < Authn::Issuer
      ACTOR_ISSUER = "aws-sts" #: String

      # @override
      #: () -> String
      def actor_issuer = ACTOR_ISSUER

      # @override
      #: () -> String
      def jwks_url = "#{url}/.well-known/jwks.json"

      # @override
      #: () -> Array[String]
      def required_claims = %w[jti]

      # @override
      #: (Hash[String, untyped] claims, user_agent: String) -> Actor
      def actor_for(claims, user_agent:)
        subject = claims.fetch("sub").to_s
        Actor.new(
          issuer: ACTOR_ISSUER,
          subject:,
          display_name: subject.split("/").last.to_s,
          credential_id: claims.fetch("jti").to_s,
          user_agent:,
          roles: MachineRoles.roles_for(ACTOR_ISSUER, subject),
        )
      end
    end
  end
end
