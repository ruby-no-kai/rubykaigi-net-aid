# typed: strict
# frozen_string_literal: true

# Tags every line of a request with what the raw request carries.
class RequestLogTagger
  #: (untyped) -> void
  def initialize(app)
    @app = app #: untyped
  end

  #: (Hash[String, untyped]) -> untyped
  def call(env)
    SemanticLogger.tagged(request_id: env["action_dispatch.request_id"]) { @app.call(env) }
  end
end

Rails.application.config.middleware.insert_after(ActionDispatch::RequestId, RequestLogTagger)

# Completed carries everything Started does, so Started logs at debug.
Rails.application.config.rails_semantic_logger.started = false

# on_log runs in the thread that logs, before the line is queued for the appender thread, so
# RequestLogContext is still visible.
SemanticLogger.on_log { RequestLogContext.apply(it) }

ActiveSupport::Notifications.subscribe("rescue_from_callback.action_controller") do |event|
  RequestLogContext.rescued_exception = event.payload[:exception]
end

ActiveSupport::Notifications.subscribe("enqueue.active_job") do |event|
  RequestLogContext.increment(:jobs_enqueued) if event.payload[:job]&.successfully_enqueued?
end

Rails.application.config.after_initialize do
  # rails_semantic_logger swaps the ActiveJob subscriber only if ActiveJob::Base has loaded by its
  # after_initialize, which without eager loading it has not.
  ActiveSupport.on_load(:active_job) do
    next if ActiveSupport::LogSubscriber.subscribers.none?(ActiveJob::LogSubscriber)

    RailsSemanticLogger.swap_subscriber(ActiveJob::LogSubscriber, RailsSemanticLogger::ActiveJob::LogSubscriber, :active_job)
  end
end

Rails.application.config.after_initialize do
  RailsSemanticLogger.swap_subscriber(
    RailsSemanticLogger::ActionController::LogSubscriber,
    NetAid::ActionControllerLogSubscriber,
    :action_controller,
  )
end
