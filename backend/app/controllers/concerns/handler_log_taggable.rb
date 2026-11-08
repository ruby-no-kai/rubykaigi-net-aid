# typed: strict
# frozen_string_literal: true

# Tags every log line of a Connect call with the authorisation action of the RPC it routes to.
#
# @requires_ancestor: ConnectRpcRails::Controller
# @requires_ancestor: ActionController::Metal
module HandlerLogTaggable
  extend ActiveSupport::Concern

  # Prefixes every authorisation action, as an AWS service prefixes its IAM actions.
  ACTION_PREFIX = "netaid" #: String

  included do
    # Prepended so lines logged by authentication and the other callbacks carry it too.
    prepend_before_action :set_handler_log_tag
  end

  # The authorisation action of the routed RPC, such as "netaid:GetViewer", or nil for an action
  # serving no RPC.
  #: () -> String?
  private def rpc_action_name_maybe
    klass = self.class #: as singleton(ActionController::API) & ConnectRpcRails::Controller::GeneratedClassMethods
    rpc = klass.connect_rpcs[action_name] #: ConnectRpcRails::ServiceRegistration::Rpc?
    "#{ACTION_PREFIX}:#{rpc.name}" if rpc
  end

  #: () -> void
  private def set_handler_log_tag
    handler = rpc_action_name_maybe
    RequestLogContext.add_tags(handler:) if handler
  end
end
