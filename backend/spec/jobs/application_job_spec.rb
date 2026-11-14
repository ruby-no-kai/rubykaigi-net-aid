# frozen_string_literal: true

require "rails_helper"
require "semantic_logger/test/capture_log_events"

RSpec.describe ApplicationJob, type: :job do
  include ActiveJob::TestHelper

  let(:job_class) do
    stub_const("ActorProbeJob", Class.new(described_class) do
      def perform = Current.actor
    end)
  end

  let(:actor) do
    Actor.new(issuer: "himari", subject: "github_1", display_name: "octocat", credential_id: "cred-1", user_agent: "rspec", roles: %w[operator])
  end

  it "runs as the Actor that enqueued it" do
    Current.actor = actor
    job_data = job_class.new.serialize
    Current.reset

    job = job_class.new
    job.deserialize(job_data)

    expect(job.perform_now).to eq(actor)
  end

  it "captures the Actor current at enqueue, not when the job was built" do
    job = job_class.new
    Current.actor = actor
    job_data = job.serialize
    Current.reset

    restored = job_class.new
    restored.deserialize(job_data)

    expect(restored.perform_now).to eq(actor)
  end

  it "runs as a system Actor named by the job class when nobody enqueued it" do
    job_data = job_class.new.serialize
    job = job_class.new
    job.deserialize(job_data)

    expect(job.perform_now).to eq(Actor.system("ActorProbeJob"))
  end

  it "runs inline as its caller" do
    Current.actor = actor

    expect(job_class.perform_now).to eq(actor)
  end

  it "runs inline as a system Actor when there is no caller" do
    expect(job_class.perform_now).to eq(Actor.system("ActorProbeJob"))
  end

  it "hands an inline caller its own Actor back" do
    Current.actor = actor

    job_class.perform_now

    expect(Current.actor).to eq(actor)
  end

  it "runs discard_on and retry_on handlers as the starting Actor" do
    handled_as = []
    failing_class = stub_const("FailingProbeJob", Class.new(described_class) do
      discard_on(ArgumentError) { |_job, _error| handled_as << Current.actor }

      def perform = raise(ArgumentError)
    end)
    Current.actor = actor
    job_data = failing_class.new.serialize
    Current.reset

    job = failing_class.new
    job.deserialize(job_data)
    job.perform_now

    expect(handled_as).to eq([actor])
    expect(Current.actor_maybe).to be_nil
  end

  it "carries the starting Actor into a retry" do
    retry_class = stub_const("RetryProbeJob", Class.new(described_class) do
      retry_on ArgumentError, wait: 0, attempts: 2

      def perform = raise(ArgumentError)
    end)
    Current.actor = actor
    job_data = retry_class.new.serialize
    Current.reset

    job = retry_class.new
    job.deserialize(job_data)
    job.perform_now

    retried = enqueued_jobs.sole
    expect(retried.fetch(ActorJob::SERIALIZED_KEY)).to eq(actor.serialize)
  end

  it "enqueues only once the enclosing transaction commits" do
    ApplicationRecord.retryable_transaction do
      job_class.perform_later
      expect(enqueued_jobs).to be_empty
    end

    expect(enqueued_jobs.map { it.fetch("job_class") }).to eq(["ActorProbeJob"])
  end

  it "holds jobs outside ApplicationJob until commit too" do
    expect(ActiveJob::Base.enqueue_after_transaction_commit).to be(true)
  end

  it "tags its Performed line with the Actor" do
    logger = SemanticLogger::Test::CaptureLogEvents.new
    allow(ActiveJob::Base).to receive(:logger).and_return(logger)

    job_class.perform_now

    performed = logger.events.find { it.message.start_with?("Performed ActorProbeJob") }
    expect(performed.named_tags).to include(actor_issuer: "system", actor_subject: "ActorProbeJob")
  end
end
