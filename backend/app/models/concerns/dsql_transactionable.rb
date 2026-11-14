# typed: strict
# frozen_string_literal: true

# OCC-aware transactions for DSQL, included in ApplicationRecord. DSQL rejects a conflicting
# transaction at commit instead of waiting on a lock, so idempotent blocks are retried, as are
# PostgreSQL's deadlock victims.
#
# @requires_ancestor: ActiveRecord::Base
module DsqlTransactionable
  extend ActiveSupport::Concern

  # The longest wait before one retry, before jitter.
  MAX_SLEEP_SECONDS = 2.0 #: Float

  module ClassMethods
    #: [T] (?retries: Integer, ?base_sleep_seconds: Float, ?max_sleep_seconds: Float) { () -> T } -> T
    def retryable_transaction(retries: 4, base_sleep_seconds: 0.2, max_sleep_seconds: MAX_SLEEP_SECONDS, &block)
      #: self as singleton(ActiveRecord::Base)
      attempts = 0

      begin
        transaction(&block)
      rescue ActiveRecord::SerializationFailure, ActiveRecord::Deadlocked => e
        if (e.is_a?(ActiveRecord::Deadlocked) || e.dsql_retryable?) && attempts < retries
          attempts += 1
          RequestLogContext.increment(:occ_retries)
          sleep_seconds = [base_sleep_seconds * (2.0**(attempts - 1)), max_sleep_seconds].min * (0.5 + (0.5 * rand))
          Rails.logger.warn("Transaction conflict detected, retrying transaction", {attempts:, retries:, sleep_seconds:}, e)
          sleep(sleep_seconds)
          retry
        else
          raise
        end
      end
    end

    # Marks a transaction that must not be retried (external side effects, data read before the block).
    #: [T] () { () -> T } -> T
    def non_idempotent_transaction(&block)
      #: self as singleton(ActiveRecord::Base)
      transaction(&block)
    end
  end

  #: [T] (?retries: Integer, ?base_sleep_seconds: Float, ?max_sleep_seconds: Float) { () -> T } -> T
  def retryable_transaction(retries: 4, base_sleep_seconds: 0.2, max_sleep_seconds: MAX_SLEEP_SECONDS, &block)
    klass = self.class #: as singleton(ActiveRecord::Base) & DsqlTransactionable::ClassMethods
    klass.retryable_transaction(retries:, base_sleep_seconds:, max_sleep_seconds:, &block)
  end

  #: [T] () { () -> T } -> T
  def non_idempotent_transaction(&block)
    klass = self.class #: as singleton(ActiveRecord::Base) & DsqlTransactionable::ClassMethods
    klass.non_idempotent_transaction(&block)
  end
end
