# typed: strict
# frozen_string_literal: true

# The journal of client write requests, applied or rejected, keyed by the client's idempotency key.
class Mutation < ApplicationRecord
  include TypeidRails::Identifiable

  id_prefix "mut"

  OUTCOME_APPLIED = "OUTCOME_APPLIED" #: String
  OUTCOME_REJECTED = "OUTCOME_REJECTED" #: String

  has_many :change_sets, dependent: nil

  # Only Changelog.write inserts Mutations, and nothing updates them.
  #: () -> bool
  def readonly? = super || !Changelog.writing?

  #: () -> bool
  def applied? = outcome == OUTCOME_APPLIED

  #: () -> bool
  def rejected? = outcome == OUTCOME_REJECTED

  # The request as sent.
  #: () -> Google::Protobuf::AbstractMessage
  def payload_message = Changelog::AnyJson.load(payload)

  # The response returned when it was applied.
  #: () -> Google::Protobuf::AbstractMessage
  def response_message = Changelog::AnyJson.load(Must.because(response) { "an applied Mutation stores its response" })

  # The problem it was rejected with.
  #: () -> Protobufable::ProblemDetails
  def error_details
    json = Must.because(error) { "a rejected Mutation stores its problem" }
    Protobufable::ProblemDetails.decode_json(JSON.generate(json))
  end
end
