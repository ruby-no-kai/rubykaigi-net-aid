# typed: strict
# frozen_string_literal: true

module Authz
  # Allows or denies the actions matching any of its `actions` patterns, or, as IAM's NotAction,
  # every action matching none of its `not_actions`. `*` matches any run of characters.
  class Statement
    #: Symbol
    attr_reader :effect

    #: Array[String]
    attr_reader :actions

    #: Array[String]
    attr_reader :not_actions

    #: (effect: Symbol, ?actions: Array[String], ?not_actions: Array[String]) -> void
    def initialize(effect:, actions: [], not_actions: [])
      raise ArgumentError, "a statement takes either actions or not_actions" unless actions.empty? ^ not_actions.empty?

      @effect = effect
      @actions = actions
      @not_actions = not_actions
      freeze
    end

    #: (String) -> bool
    def match?(action)
      return not_actions.none? { pattern_for(it).match?(action) } if actions.empty?

      actions.any? { pattern_for(it).match?(action) }
    end

    #: () -> bool
    def deny? = effect == :deny

    #: (String) -> Regexp
    private def pattern_for(action_pattern)
      /\A#{action_pattern.split("*", -1).map { Regexp.escape(it) }.join(".*")}\z/
    end
  end
end
