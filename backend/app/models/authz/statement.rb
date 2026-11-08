# typed: strict
# frozen_string_literal: true

module Authz
  # Allows or denies the actions matching any of its patterns, where `*` matches any run of
  # characters.
  Statement = Data.define(:effect, :actions)

  class Statement
    #: (String) -> bool
    def match?(action)
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
