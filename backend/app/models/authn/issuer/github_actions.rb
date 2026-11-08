# typed: strict
# frozen_string_literal: true

module Authn
  class Issuer
    # GitHub Actions, issuing an OIDC ID token to a workflow run with `id-token: write`.
    class GithubActions < Issuer
      ACTOR_ISSUER = "github-actions" #: String

      # @override
      #: () -> String
      def actor_issuer = ACTOR_ISSUER

      # @override
      #: () -> String
      def jwks_url = "#{url}/.well-known/jwks"

      # @override
      #: () -> Array[String]
      def required_claims = %w[repository workflow run_number run_id run_attempt]

      # @override
      #: (Hash[String, untyped] claims, user_agent: String) -> Actor
      def actor_for(claims, user_agent:)
        subject = claims.fetch("sub").to_s
        Actor.new(
          issuer: ACTOR_ISSUER,
          subject:,
          display_name: "#{claims.fetch("repository")} #{claims.fetch("workflow")} ##{claims.fetch("run_number")}",
          credential_id: "#{claims.fetch("run_id")}/#{claims.fetch("run_attempt")}",
          user_agent:,
          roles: MachineRoles.roles_for(ACTOR_ISSUER, subject),
        )
      end
    end
  end
end
