# frozen_string_literal: true

module RuboCop
  module Cop
    module Changelog
      # Flags Active Record bulk writes, which skip the callbacks that record a Branched row's Change.
      # Bulk inserts of Branched rows go through Changelog.current.insert_all!. A receiver that is not
      # Branched cannot be told apart statically, so such a call disables this cop inline.
      class BulkWrite < RuboCop::Cop::Base
        MSG = "`%<method>s` skips the changelog; use Changelog.current.insert_all! or a save per row."

        RESTRICT_ON_SEND = %i[insert_all upsert_all update_all delete_all update_column update_columns].freeze

        def on_send(node)
          add_offense(node.loc.selector, message: format(MSG, method: node.method_name))
        end
        alias on_csend on_send
      end
    end
  end
end
