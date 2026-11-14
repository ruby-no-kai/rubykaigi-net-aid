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

        # Constants whose delete takes an argument and is not Active Record's.
        # @!method non_record_constant?(node)
        def_node_matcher :non_record_constant?, "(const {nil? cbase} {:ENV :File :Dir})"

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
          when :delete then delete_offense?(node)
          else false
          end
        end

        # A record's delete takes no argument, a model's takes ids. Hash#delete and Array#delete
        # take an argument on a receiver that is no constant.
        private def delete_offense?(node)
          receiver = node.receiver
          return false unless receiver
          return true unless node.arguments?

          receiver.const_type? && !non_record_constant?(receiver)
        end
      end
    end
  end
end
