# frozen_string_literal: true
# typed: strict

# Runs as the Actor that enqueued the job, carried in its serialized arguments, or as a system
# Actor named by the job class when nobody did.
class ApplicationJob < ActiveJob::Base
  ACTOR_KEY = "netaid_actor" #: String

  around_perform :perform_as_starting_actor

  #: (*untyped) -> void
  def initialize(*arguments)
    super
    @starting_actor = Current.actor_maybe #: Actor?
  end
  ruby2_keywords(:initialize)

  #: () -> Hash[String, untyped]
  def serialize
    super.merge(ACTOR_KEY => @starting_actor&.serialize)
  end

  #: (Hash[String, untyped]) -> void
  def deserialize(job_data)
    super
    @starting_actor = job_data[ACTOR_KEY]&.then { Actor.deserialize(it) }
  end

  #: () { () -> void } -> void
  private def perform_as_starting_actor(&block)
    actor = @starting_actor || Actor.system(self.class.name.to_s)
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
end
