# typed: strict
# frozen_string_literal: true

# Runs a job as the Actor that enqueued it, carried in its serialized data, or as a system Actor
# named by the job class when nobody did.
#
# @requires_ancestor: ActiveJob::Base
module ActorJob
  extend ActiveSupport::Concern

  SERIALIZED_KEY = "netaid_actor" #: String

  included do
    around_perform :perform_as_starting_actor
  end

  #: () -> Hash[String, untyped]
  def serialize
    super.merge(SERIALIZED_KEY => (starting_actor_maybe || Current.actor_maybe)&.serialize)
  end

  #: (Hash[String, untyped]) -> void
  def deserialize(job_data)
    super
    @starting_actor = job_data[SERIALIZED_KEY]&.then { Actor.deserialize(it) } || system_actor #: Actor?
  end

  # rescue_from, retry_on and discard_on handlers run after around_perform has unwound.
  #: (Exception) -> untyped
  def rescue_with_handler(exception)
    perform_as_starting_actor { super }
  end

  #: () { () -> untyped } -> untyped
  private def perform_as_starting_actor(&block)
    # A job performed inline, never serialized, runs as its caller.
    actor = starting_actor_maybe || Current.actor_maybe || system_actor
    RequestLogContext.add_tags(**actor.log_tags)
    # Current.set reads the raising Current.actor, and a job performed inline must hand the caller
    # its own Actor back.
    previous = Current.actor_maybe
    Current.actor = actor
    begin
      yield
    ensure
      Current.actor = previous
    end
  end

  #: () -> Actor?
  private def starting_actor_maybe = @starting_actor

  #: () -> Actor
  private def system_actor = Actor.system(self.class.name.to_s)
end
