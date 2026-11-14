# frozen_string_literal: true

require "rails_helper"
require "semantic_logger/test/capture_log_events"

RSpec.describe DsqlTransactionable, type: :model do
  let(:logger) { SemanticLogger::Test::CaptureLogEvents.new }

  before do
    allow(ApplicationRecord).to receive(:sleep)
    allow(Rails).to receive(:logger).and_return(logger)
  end

  def deadlock_first(attempts_to_fail)
    attempts = 0
    ApplicationRecord.retryable_transaction do
      attempts += 1
      raise ActiveRecord::Deadlocked, "deadlock detected" if attempts <= attempts_to_fail
    end
    attempts
  end

  it "logs each retry with its exception apart from the message" do
    deadlock_first(1)

    event = logger.events.sole
    expect(event.level).to eq(:warn)
    expect(event.message).to eq("Transaction conflict detected, retrying transaction")
    expect(event.payload).to include(attempts: 1, retries: 4, sleep_seconds: a_kind_of(Float))
    expect(event.exception).to be_a(ActiveRecord::Deadlocked)
  end
end
