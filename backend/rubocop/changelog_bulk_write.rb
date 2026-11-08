# frozen_string_literal: true

module RuboCop
  module Cop
    module Changelog
      # Flags Active Record writes that skip the callbacks recording a Branched row's Change. Bulk
      # inserts of Branched rows go through Changelog.current.insert_all!. A receiver that is not
      # Branched cannot be told apart statically, so such a call disables this cop inline.
      class BulkWrite < RuboCop::Cop::Base
        MSG = "`%<method>s` skips the changelog; use Changelog.current.insert_all! or a save per row."

        ALWAYS = %i[
          insert_all upsert_all update_all delete_all delete_by update_column update_columns update_counters
          increment! decrement!
        ].freeze
        # Shared with Array#insert and String#insert, which never take a Hash first.
        ROW_INSERTS = %i[insert insert! upsert].freeze

        RESTRICT_ON_SEND = [*ALWAYS, *ROW_INSERTS, :insert_all!, :touch, :delete].freeze

        # @!method changelog_current?(node)
        def_node_matcher :changelog_current?, "(send (const {nil? cbase} :Changelog) :current)"

        # @!method file_utils?(node)
        def_node_matcher :file_utils?, "(const {nil? cbase} :FileUtils)"

        def on_send(node)
          return unless offense?(node)

          add_offense(node.loc.selector, message: format(MSG, method: node.method_name))
        end
        alias on_csend on_send

        private def offense?(node)
          case node.method_name
          when *ALWAYS then true
          when *ROW_INSERTS then node.first_argument&.hash_type?
          when :insert_all! then !(node.receiver && changelog_current?(node.receiver))
          when :touch then !(node.receiver && file_utils?(node.receiver))
          # Hash#delete and Array#delete take an argument; a record's delete takes none.
          when :delete then !node.arguments? && !node.receiver.nil?
          else false
          end
        end
      end
    end
  end
end
