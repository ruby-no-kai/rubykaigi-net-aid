# typed: strict
# frozen_string_literal: true

# Authorises every RPC before its action runs, by the action derived from the routed RPC. Include
# after Authenticatable and HandlerLogTaggable.
#
# @requires_ancestor: HandlerLogTaggable
# @requires_ancestor: ActionController::Metal
module Authorizable
  extend ActiveSupport::Concern

  included do
    before_action :authorize_rpc!
  end

  # Raises unless Current.actor may perform `action`: Errors::Unauthenticated for an anonymous
  # caller, Errors::PermissionDenied otherwise.
  #: (String action, ?episode: String?) -> void
  private def authorize!(action, episode: nil)
    actor = Current.actor_maybe
    return if Authz::Policy.permit?(actor, action, episode:)

    RequestLogContext.add_fields(authz_denied_action: action)
    raise Errors::Unauthenticated.new(detail: "#{action} requires signing in.") unless actor

    raise Errors::PermissionDenied.new(detail: "The caller may not perform #{action}.")
  end

  # The catch-all for a method the service does not declare serves no RPC, and answers 404 itself.
  #: () -> void
  private def authorize_rpc!
    action = rpc_action_name_maybe
    return unless action

    episode = authorization_episode_maybe
    RequestLogContext.add_tags(episode:) if episode
    authorize!(action, episode:)
  end

  # The Episode slug of the Plan branch the request names. No RPC names a branch yet.
  #: () -> String?
  private def authorization_episode_maybe = nil
end
