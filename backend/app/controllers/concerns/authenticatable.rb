# typed: strict
# frozen_string_literal: true

# Resolves the caller of a request into Current.actor, from an `Authorization: Bearer` token. A
# request without credentials stays anonymous; one with credentials that fail answers
# Errors::Unauthenticated.
#
# @requires_ancestor: ActionController::Metal
module Authenticatable
  extend ActiveSupport::Concern

  BEARER_PATTERN = /\ABearer +(?<token>\S+)\s*\z/i #: Regexp

  included do
    before_action :authenticate
  end

  #: () -> void
  private def authenticate
    actor = bearer_actor_maybe
    return unless actor

    Current.actor = actor
    RequestLogContext.add_tags(
      actor_issuer: actor.issuer, actor_subject: actor.subject, credential_id: actor.credential_id,
    )
  end

  #: () -> Actor?
  private def bearer_actor_maybe
    authorization = request.authorization
    return if authorization.blank?

    token = BEARER_PATTERN.match(authorization)&.[](:token)
    raise Errors::Unauthenticated.new(detail: "The Authorization header carries no bearer token.") unless token

    Authn::BearerVerifier.new.verify(token, user_agent: Actor.truncate_user_agent(request.user_agent))
  rescue Authn::BearerVerifier::Failure => e
    RequestLogContext.add_fields(**{authn_failure: e.reason, authn_issuer: e.issuer&.truncate(255)}.compact)
    detail = e.reason == "expired" ? "The bearer token has expired." : "The bearer token is not accepted."
    raise Errors::Unauthenticated.new(detail:)
  end
end
