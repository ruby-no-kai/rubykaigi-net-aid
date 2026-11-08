# typed: strict
# frozen_string_literal: true

# Request-scoped named tags carried by every log line written after they are added, and the
# outcome and counters of the work done during the request or job, which its canonical line
# reports. The executor resets it per request and per job.
class RequestLogContext < ActiveSupport::CurrentAttributes
  JOB_PERFORM_EVENT = "perform.active_job" #: String

  attribute :tags, default: -> { {} }
  attribute :fields, default: -> { {} }
  attribute :counters, default: -> { Hash.new(0) }
  attribute :rescued_exception
  attribute :connect_code
  attribute :rendered_problem

  #: (**untyped) -> void
  def self.add_tags(**new_tags)
    tags.merge!(new_tags)
  end

  # Fields describing the request's outcome, reported on its canonical line only.
  #: (**untyped) -> void
  def self.add_fields(**new_fields)
    fields.merge!(new_fields)
  end

  #: (Symbol, ?by: Integer) -> void
  def self.increment(key, by: 1)
    counters[key] += by
  end

  # Tags from an enclosing `SemanticLogger.tagged` block win on a shared key. A job has no
  # Completed line, so its counters go on rails_semantic_logger's Performed line.
  #: (SemanticLogger::Log) -> void
  def self.apply(log)
    log.named_tags = tags.merge(log.named_tags) unless tags.empty?

    payload = log.payload
    payload.merge!(log_payload) if payload.is_a?(Hash) && payload[:event_name] == JOB_PERFORM_EVENT
  end

  # Outcome fields and counters. Counters are only ever stored once incremented, so none of them is
  # zero.
  #: () -> Hash[Symbol, untyped]
  def self.log_payload
    fields.merge(counters)
  end
end
