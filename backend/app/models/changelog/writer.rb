# typed: strict
# frozen_string_literal: true

# Performs one Changelog.write: replay of a journalled Mutation, or the transaction with its
# journal entry.
class Changelog::Writer
  #: (mutation: Rk::NetAid::MutationHeader?, branches: Array[Branch], rpc: String?,
  #|  payload: Google::Protobuf::AbstractMessage?) -> void
  def initialize(mutation:, branches:, rpc:, payload:)
    if mutation && (rpc.nil? || payload.nil?)
      raise ArgumentError, "Changelog.write with a mutation takes the rpc and payload it journals"
    end

    @header = mutation
    @branches = branches
    @rpc = rpc
    @payload = payload
  end

  #: [T] () { (Changelog::Context) -> T } -> Changelog::Result
  def perform(&block)
    header = @header
    return apply(nil, &block) unless header

    actor = Current.actor
    stored = Mutation.find_by(id: mutation_id)
    return replay(stored, actor) if stored

    begin
      apply(actor, &block)
    rescue ActiveRecord::RecordNotUnique
      # A concurrent request with the same mutation_id committed first.
      winner = Mutation.find_by(id: mutation_id)
      raise unless winner

      replay(winner, actor)
    end
  end

  #: [T] (Actor?) { (Changelog::Context) -> T } -> Changelog::Result
  private def apply(request_actor, &block)
    actor = request_actor || Current.actor
    response, cursors, stats = transact(actor, &block)

    log(outcome: Mutation::OUTCOME_APPLIED, stats:)
    Changelog::Result.new(mutation_id: (mutation_id if @header), response:, cursors:)
  rescue Errors::Rejection, ActiveRecord::RecordInvalid => e
    raise if request_actor.nil?

    ApplicationRecord.retryable_transaction do
      journal(request_actor, outcome: Mutation::OUTCOME_REJECTED, error: problem_json(e))
    end
    log(outcome: Mutation::OUTCOME_REJECTED)
    raise
  end

  # A unique violation from the block is a row a concurrent write committed first. One more attempt
  # lets the block see that row and answer with a rejection of its own.
  #: [T] (Actor) { (Changelog::Context) -> T } -> [T, Hash[String, String], Changelog::Context::Stats]
  private def transact(actor, &block)
    retried_duplicate = false #: bool
    begin
      ApplicationRecord.retryable_transaction do
        context = Changelog::Context.new(branches: @branches)
        Changelog.with_context(context) do
          response = run_block(context, &block)
          stats = context.flush!(actor:, mutation_id: (mutation_id if @header))
          journal(actor, outcome: Mutation::OUTCOME_APPLIED, response: Changelog::AnyJson.dump(response_message(response))) if @header
          [response, context.cursors, stats]
        end
      end
    rescue Errors::DuplicateRow
      raise if retried_duplicate

      retried_duplicate = true
      retry
    end
  end

  # Keeps a unique violation from the block apart from one on mutations.id, which perform handles.
  #: [T] (Changelog::Context) { (Changelog::Context) -> T } -> T
  private def run_block(context, &block)
    yield context
  rescue ActiveRecord::RecordNotUnique => e
    Rails.logger.warn("Changelog.write met a row a concurrent write committed first: #{e.message}")
    raise Errors::DuplicateRow.new(detail: "Another request wrote a row with the same key at the same time. Retry the request.")
  end

  #: (Mutation, Actor) -> Changelog::Result
  private def replay(stored, actor)
    unless stored.rpc == @rpc && stored.actor_issuer == actor.issuer && stored.actor_subject == actor.subject && stored.payload_message == @payload
      raise Errors::MutationIdReused.new(detail: "The mutation #{mutation_id} was already used for another request.")
    end

    log(outcome: "replayed")
    raise Changelog::ReplayedRejection, stored.error_details if stored.rejected?

    cursors = stored.change_sets.to_h { [it.branch_id, Changelog::Cursor.encode(branch_id: it.branch_id, seq: it.seq)] }
    Changelog::Result.new(mutation_id:, response: stored.response_message, cursors:)
  end

  #: (Actor, outcome: String, ?response: Hash[String, untyped]?, ?error: Hash[String, untyped]?) -> void
  private def journal(actor, outcome:, response: nil, error: nil)
    header = Must.because(@header) { "only a write with a mutation header is journalled" }
    payload = Must.because(@payload) { "the initializer requires a payload with a mutation header" }
    Mutation.create!(
      id: mutation_id,
      **Changelog.actor_columns(actor),
      rpc: @rpc,
      payload: Changelog::AnyJson.dump(payload),
      base_seqs: base_seqs(header),
      client_time: header.client_time&.to_time,
      outcome:,
      response:,
      error:,
    )
  end

  # base_seqs are informational, so a cursor this server cannot read is left out.
  #: (Rk::NetAid::MutationHeader) -> Hash[String, Integer]
  private def base_seqs(header)
    seqs = {} #: Hash[String, Integer]
    header.base_cursors.values.each do |cursor|
      parsed = Changelog::Cursor.parse(cursor)
      seqs[parsed.branch_uuid] = parsed.seq
    rescue Errors::ResyncRequired
      next
    end
    seqs
  end

  #: (Errors::Rejection | ActiveRecord::RecordInvalid) -> Hash[String, untyped]
  private def problem_json(error)
    problem = case error
    when ActiveRecord::RecordInvalid then invalid_record_for(error)
    else Must.be_a(error, Errors::ApiError)
    end
    details = Errors.problem_details_for(problem)
    JSON.parse(Protobufable::ProblemDetails.encode_json(details, preserve_proto_fieldnames: true))
  end

  # The problem Api::ApplicationController answers a RecordInvalid with, with the proto field names
  # of a binary request.
  #: (ActiveRecord::RecordInvalid) -> Errors::InvalidRecord
  private def invalid_record_for(error)
    payload = Must.because(@payload) { "the initializer requires a payload with a mutation header" }
    input_field = payload.class.descriptor.lookup("input")
    Errors::InvalidRecord.new(
      record: error.record,
      input_class: input_field&.subtype&.msgclass,
      field_prefix: input_field ? input_field.name : "",
    )
  end

  #: (untyped) -> Google::Protobuf::AbstractMessage
  private def response_message(response)
    return response if Changelog::AnyJson.message?(response)

    raise ArgumentError, "a Changelog.write with a mutation returns the response message, got #{response.class}"
  end

  #: (outcome: String, ?stats: Changelog::Context::Stats?) -> void
  private def log(outcome:, stats: nil)
    RequestLogContext.add_fields(mutation_id:, mutation_outcome: outcome) if @header
    return unless stats

    RequestLogContext.increment(:change_sets_written, by: stats.change_sets) if stats.change_sets.positive?
    RequestLogContext.increment(:changes_written, by: stats.changes) if stats.changes.positive?
  end

  #: () -> String
  private def mutation_id
    header = Must.because(@header) { "only a write with a mutation header has a mutation_id" }
    id = header.mutation_id
    raise ArgumentError, "mutation_id #{id.inspect} is not a mut_ TypeID" unless TypeidRails.to_uuid(id, expected_prefix: "mut")

    id
  end
end
