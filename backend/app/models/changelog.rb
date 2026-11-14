# typed: strict
# frozen_string_literal: true

# The one entry point for writes to Branched tables. Each write takes the next seq on every branch
# it touches, records one ChangeSet per such branch and one Change per touched row, and journals
# the client request as a Mutation.
#
#   Changelog.write(mutation: header, branches: [branch], rpc:, payload: request) do
#     Site.on(branch).find(site_id).update!(name:)
#     Rk::NetAid::SiteServiceUpdateSiteResponse.new(...)
#   end
module Changelog
  # A Branched row was saved on a branch the write did not declare.
  class UndeclaredBranch < StandardError; end

  # A Branched row was saved or destroyed outside a Changelog.write.
  class NotWriting < StandardError; end

  # Changelog.write was called inside a transaction it would join, so a rejection could commit the
  # caller's writes and a retry would run in an aborted transaction.
  class TransactionOpen < StandardError; end

  # `cursors` maps each branch the write produced a ChangeSet on to its cursor after the write.
  Result = Data.define(:mutation_id, :response, :cursors)

  CONTEXT_KEY = :changelog_context #: Symbol
  WRITING_KEY = :changelog_writing #: Symbol

  # Runs the block in a retryable transaction and returns what it returned as the response. With
  # a mutation header, a request whose mutation_id was already journalled is answered with the
  # stored outcome instead.
  #: [T] (mutation: Rk::NetAid::MutationHeader?, branches: Array[Branch], ?rpc: String?,
  #|      ?payload: Google::Protobuf::AbstractMessage?) { (Changelog::Context) -> T } -> Changelog::Result
  def self.write(mutation:, branches:, rpc: nil, payload: nil, &block)
    raise ArgumentError, "Changelog.write does not nest" if writing?
    # A transactional test fixture is not joinable, so a write inside one still opens a savepoint.
    if ApplicationRecord.connection.current_transaction.joinable?
      raise TransactionOpen, "Changelog.write opens its own transaction and cannot run inside another"
    end

    writer = Changelog::Writer.new(mutation:, branches:, rpc:, payload:)
    ActiveSupport::IsolatedExecutionState[WRITING_KEY] = true
    begin
      writer.perform(&block)
    ensure
      ActiveSupport::IsolatedExecutionState.delete(WRITING_KEY) # rubocop:disable Changelog/BulkWrite -- a thread-local key, not a record
    end
  end

  # The attempt of the Changelog.write running in this thread.
  #: () -> Changelog::Context
  def self.current
    current_maybe || raise(NotWriting, "Branched rows are written inside Changelog.write")
  end

  #: () -> Changelog::Context?
  def self.current_maybe
    ActiveSupport::IsolatedExecutionState[CONTEXT_KEY] #: as Changelog::Context?
  end

  #: () -> bool
  def self.writing? = ActiveSupport::IsolatedExecutionState[WRITING_KEY] == true

  #: [T] (Changelog::Context) { () -> T } -> T
  def self.with_context(context, &block)
    ActiveSupport::IsolatedExecutionState[CONTEXT_KEY] = context
    yield
  ensure
    ActiveSupport::IsolatedExecutionState.delete(CONTEXT_KEY) # rubocop:disable Changelog/BulkWrite -- a thread-local key, not a record
  end

  # The actor_* columns ChangeSets and Mutations record.
  #: (Actor) -> Hash[Symbol, String?]
  def self.actor_columns(actor)
    {
      actor_issuer: actor.issuer,
      actor_subject: actor.subject,
      actor_display_name: actor.display_name.presence,
      actor_credential_id: actor.credential_id.presence,
      actor_user_agent: actor.user_agent.presence
    }
  end
end
