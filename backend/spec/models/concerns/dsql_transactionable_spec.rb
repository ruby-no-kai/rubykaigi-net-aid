# frozen_string_literal: true

require "rails_helper"
require "semantic_logger/test/capture_log_events"

RSpec.describe DsqlTransactionable, type: :model do
  let(:logger) { SemanticLogger::Test::CaptureLogEvents.new }

  before do
    allow(ApplicationRecord).to receive(:sleep)
    allow(Rails).to receive(:logger).and_return(logger)
  end

  def deadlock_first(attempts_to_fail, **options)
    attempts = 0
    ApplicationRecord.retryable_transaction(**options) do
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

  it "doubles the wait before each retry up to the cap" do
    allow(ApplicationRecord).to receive(:rand).and_return(1.0)
    waits = []
    allow(ApplicationRecord).to receive(:sleep) { waits << it }

    deadlock_first(5, retries: 5, base_sleep_seconds: 0.25, max_sleep_seconds: 1.0)

    expect(waits).to eq([0.25, 0.5, 1.0, 1.0, 1.0])
  end

  it "jitters each wait down to half" do
    allow(ApplicationRecord).to receive(:rand).and_return(0.0)
    waits = []
    allow(ApplicationRecord).to receive(:sleep) { waits << it }

    deadlock_first(2, base_sleep_seconds: 0.25)

    expect(waits).to eq([0.125, 0.25])
  end

  it "caps the wait at MAX_SLEEP_SECONDS by default" do
    allow(ApplicationRecord).to receive(:rand).and_return(1.0)

    deadlock_first(1, base_sleep_seconds: 60.0)

    expect(ApplicationRecord).to have_received(:sleep).with(DsqlTransactionable::MAX_SLEEP_SECONDS)
  end
end
