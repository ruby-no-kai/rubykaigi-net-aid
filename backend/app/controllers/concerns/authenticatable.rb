# typed: strict
# frozen_string_literal: true

# Resolves the caller of a request into Current.actor, from the browser session first and then an
# `Authorization: Bearer` token. A request without credentials stays anonymous. A session whose
# access token has expired answers Errors::SessionExpired without refreshing it, and refused
# credentials answer Errors::Unauthenticated.
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
    actor = session_actor_maybe || bearer_actor_maybe
    authenticated_as(actor) if actor
  end

  #: (Actor) -> void
  private def authenticated_as(actor)
    Current.actor = actor
    RequestLogContext.add_tags(
      actor_issuer: actor.issuer, actor_subject: actor.subject, credential_id: actor.credential_id,
    )
  end

  #: () -> String
  private def request_user_agent = Actor.truncate_user_agent(request.user_agent)

  #: () -> Actor?
  private def session_actor_maybe
    browser_session = Authn::BrowserSession.load(session)
    return unless browser_session

    if browser_session.expired?
      RequestLogContext.add_fields(authn_failure: "session_expired")
      raise Errors::SessionExpired.new(detail: "The session has expired. Refresh it with ViewerService.RefreshSession.")
    end

    browser_session.actor_for(user_agent: request_user_agent)
  end

  #: () -> Actor?
  private def bearer_actor_maybe
    authorization = request.authorization
    return if authorization.blank?

    token = BEARER_PATTERN.match(authorization)&.[](:token)
    raise Errors::Unauthenticated.new(detail: "The Authorization header carries no bearer token.") unless token

    Authn::BearerVerifier.new.verify(token, user_agent: request_user_agent)
  rescue Authn::BearerVerifier::Failure => e
    RequestLogContext.add_fields(**{authn_failure: e.reason, authn_issuer: e.issuer&.truncate(255)}.compact)
    detail = e.reason == "expired" ? "The bearer token has expired." : "The bearer token is not accepted."
    raise Errors::Unauthenticated.new(detail:)
  end
end
