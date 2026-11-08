# typed: strict
# frozen_string_literal: true

module Authz
  # Decides whether an Actor may perform an action, in the style of AWS IAM. A role permits an
  # action that one of its statements allows and none of them denies, and an Actor may perform
  # what any of its roles permits, so an operator's denies never narrow an admin's grants.
  module Policy
    # Actions any caller may perform, signed in or not.
    PUBLIC_ACTIONS = %w[netaid:GetViewer netaid:RefreshSession].freeze #: Array[String]

    VIEWER_STATEMENTS = [
      Statement.new(
        effect: :allow,
        actions: %w[netaid:Get* netaid:List* netaid:Lookup* netaid:Bootstrap netaid:PullChanges netaid:Download*],
      )
    ].freeze #: Array[Statement]

    # A later spec adding an admin-only RPC adds it to the deny list.
    ROLE_STATEMENTS = {
      "viewer" => VIEWER_STATEMENTS,
      "operator" => [
        Statement.new(effect: :allow, actions: %w[netaid:*]),
        Statement.new(
          effect: :deny,
          actions: %w[
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

      actor.roles.any? { role_permit?(it, action) }
    end

    #: (String, String) -> bool
    private_class_method def self.role_permit?(role, action)
      matching = ROLE_STATEMENTS.fetch(role, []).select { it.match?(action) }
      matching.any? && matching.none?(&:deny?)
    end
  end
end
