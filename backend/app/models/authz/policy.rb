# typed: strict
# frozen_string_literal: true

module Authz
  # Decides whether an Actor may perform an action, in the style of AWS IAM. The statements of all
  # the Actor's roles are pooled: an action is permitted when one allows it and none denies it.
  module Policy
    # Actions any caller may perform, signed in or not.
    PUBLIC_ACTIONS = %w[netaid:GetViewer netaid:RefreshSession].freeze #: Array[String]

    VIEWER_STATEMENTS = [
      Statement.new(
        effect: :allow,
        actions: %w[netaid:Get* netaid:List* netaid:Lookup* netaid:Bootstrap netaid:PullChanges netaid:Download*],
      )
    ].freeze #: Array[Statement]

    # A later spec adding an admin-only RPC adds it to the operator's not_actions.
    ROLE_STATEMENTS = {
      "viewer" => VIEWER_STATEMENTS,
      "operator" => [
        # NotAction rather than a deny, which would also take these from an Actor who is an admin too.
        Statement.new(
          effect: :allow,
          not_actions: %w[
            netaid:CreateEpisode netaid:UpdateEpisode netaid:CloseEpisode netaid:CreateFleetSnapshot
            netaid:CreateImport netaid:ApplyImport netaid:Restore*
          ],
        )
      ].freeze,
      "admin" => [Statement.new(effect: :allow, actions: %w[netaid:*])].freeze,
      "exporter" => [*VIEWER_STATEMENTS, Statement.new(effect: :allow, actions: %w[netaid:CreateExport])].freeze
    }.freeze #: Hash[String, Array[Statement]]

    # `episode` is the Episode slug the request targets. It is ignored until statements are
    # scoped per Episode.
    #: (Actor?, String, ?episode: String?) -> bool
    def self.permit?(actor, action, episode: nil)
      return true if PUBLIC_ACTIONS.include?(action)
      return false unless actor

      matching = actor.roles.flat_map { ROLE_STATEMENTS.fetch(it, []) }.select { it.match?(action) }
      matching.any? && matching.none?(&:deny?)
    end
  end
end
