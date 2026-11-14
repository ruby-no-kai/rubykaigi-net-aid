# frozen_string_literal: true

module RuboCop
  module Cop
    module NetAid
      # Flags direct use of Net::HTTP, so outbound requests go through NetAid::Http with its
      # User-Agent and timeouts.
      class NetHttp < RuboCop::Cop::Base
        MSG = "Use NetAid::Http (HTTPX) instead of Net::HTTP."

        RESTRICT_ON_SEND = %i[require].freeze

        # @!method net_http?(node)
        def_node_matcher :net_http?, "(const (const {nil? cbase} :Net) :HTTP)"

        # @!method require_net_http?(node)
        def_node_matcher :require_net_http?, "(send nil? :require (str \"net/http\"))"

        def on_const(node)
          add_offense(node) if net_http?(node)
        end

        def on_send(node)
          add_offense(node) if require_net_http?(node)
        end
      end
    end
  end
end
