# typed: strict
# frozen_string_literal: true

# The problem a journalled Mutation was rejected with, raised again when the Mutation is replayed.
class Changelog::ReplayedRejection < StandardError
  include Problem::Detailable
  include Protobufable::Problem::Information

  #: Protobufable::ProblemDetails
  attr_reader :details

  #: (Protobufable::ProblemDetails) -> void
  def initialize(details)
    @details = details
    super(detail: details.detail.presence)
  end

  #: () -> Problem::Details
  def to_problem
    Problem::Details.new(
      type: details.type.presence,
      title: details.title.presence,
      status: details.status,
      detail:,
      instance: details.instance.presence,
      extensions: problem_extensions,
    )
  end

  #: () -> Array[untyped]
  def problem_information
    super + details.information.map { Changelog::AnyJson.unpack(it) }
  end
end
