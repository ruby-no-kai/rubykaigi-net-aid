# typed: strict
# frozen_string_literal: true

require "google/rpc/error_details_pb"

# Adds a google.rpc.RequestInfo holding the request ID to every Connect error a controller renders,
# so an error a user reports leads to its log lines, and records its code and problem for the
# Completed line. Include after Protobufable::Connect::ProblemRescuable.
#
# @requires_ancestor: ConnectRpcRails::Controller
# @requires_ancestor: Protobufable::Connect::ProblemRescuable
# @requires_ancestor: ActionController::Metal
module ConnectRequestInfo
  # A problem can be rendered without raising it, so rescue_from never sees it.
  #: (Problem::Details, untyped) -> void
  private def render_problem(problem, error)
    RequestLogContext.rendered_problem = error if error.is_a?(Problem::Detailable)
    super
  end

  #: (ConnectRpcRails::Error) -> void
  private def render_connect_error(error)
    RequestLogContext.connect_code = error.code
    request_info = Google::Rpc::RequestInfo.new(request_id: request.request_id.to_s)

    super(ConnectRpcRails::Error.new(
      error.code, error.message, details: [*error.details, Google::Protobuf::Any.pack(request_info)],
    ))
  end
end
