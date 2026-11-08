# frozen_string_literal: true

require "rails_helper"
require "semantic_logger/test/capture_log_events"

RSpec.describe ApplicationJob, type: :job do
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

  it "runs as a system Actor named by the job class when nobody enqueued it" do
    expect(job_class.perform_now).to eq(Actor.system("ActorProbeJob"))
  end

  it "hands an inline caller its own Actor back" do
    Current.actor = actor

    job_class.perform_now

    expect(Current.actor).to eq(actor)
  end

  it "tags its Performed line with the Actor" do
    logger = SemanticLogger::Test::CaptureLogEvents.new
    allow(ActiveJob::Base).to receive(:logger).and_return(logger)

    job_class.perform_now

    performed = logger.events.find { it.message.start_with?("Performed ActorProbeJob") }
    expect(performed.named_tags).to include(actor_issuer: "system", actor_subject: "ActorProbeJob")
  end
end
