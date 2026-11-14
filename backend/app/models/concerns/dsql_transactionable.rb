# typed: strict
# frozen_string_literal: true

# OCC-aware transactions for DSQL, included in ApplicationRecord. DSQL rejects a conflicting
# transaction at commit instead of waiting on a lock, so idempotent blocks are retried, as are
# PostgreSQL's deadlock victims.
#
# @requires_ancestor: ActiveRecord::Base
module DsqlTransactionable
  extend ActiveSupport::Concern

  module ClassMethods
    #: [T] (?retries: Integer, ?base_sleep_seconds: Float) { () -> T } -> T
    def retryable_transaction(retries: 4, base_sleep_seconds: 0.2, &block)
      #: self as singleton(ActiveRecord::Base)
      attempts = 0

      begin
        transaction(&block)
      rescue ActiveRecord::SerializationFailure, ActiveRecord::Deadlocked => e
        if (e.is_a?(ActiveRecord::Deadlocked) || e.dsql_retryable?) && attempts < retries
          attempts += 1
          RequestLogContext.increment(:occ_retries)
          sleep_time = base_sleep_seconds * (2**(attempts - 1)) * (0.5 + (0.5 * rand))
          Rails.logger.warn("Transaction conflict detected, retrying transaction (#{attempts}/#{retries}), waiting #{format("%.2f", sleep_time)}s: #{e.message}")
          sleep(sleep_time)
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

  #: [T] (?retries: Integer, ?base_sleep_seconds: Float) { () -> T } -> T
  def retryable_transaction(retries: 4, base_sleep_seconds: 0.2, &block)
    klass = self.class #: as singleton(ActiveRecord::Base) & DsqlTransactionable::ClassMethods
    klass.retryable_transaction(retries:, base_sleep_seconds:, &block)
  end

  #: [T] () { () -> T } -> T
  def non_idempotent_transaction(&block)
    klass = self.class #: as singleton(ActiveRecord::Base) & DsqlTransactionable::ClassMethods
    klass.non_idempotent_transaction(&block)
  end
end
