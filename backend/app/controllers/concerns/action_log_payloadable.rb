# typed: strict
# frozen_string_literal: true

# Adds the request's outcome to the process_action.action_controller payload, which
# rails_semantic_logger logs as the Completed line.
#
# @requires_ancestor: ActionController::Metal
module ActionLogPayloadable
  #: (Hash[Symbol, untyped]) -> void
  private def append_info_to_payload(payload)
    super
    payload.merge!(request_log_payload, error_log_payload, RequestLogContext.log_payload)
  end

  #: () -> Hash[Symbol, untyped]
  private def request_log_payload
    {
      ip: request.remote_ip,
      user_agent: request.user_agent&.truncate(Actor::USER_AGENT_LIMIT, omission: "")
    }
  end

  #: () -> Hash[Symbol, untyped]
  private def error_log_payload
    error = RequestLogContext.rescued_exception
    problem = RequestLogContext.rendered_problem || error
    {
      connect_code: RequestLogContext.connect_code,
      error_class: error&.class&.name,
      problem_type: (problem_type_for(problem) if problem)
    }.compact
  end

  #: (Exception) -> Symbol?
  private def problem_type_for(error)
    return unless error.is_a?(Problem::Detailable)

    klass = error.class #: as Problem::Detailable::ClassMethods
    klass.type&.to_sym
  end
end
