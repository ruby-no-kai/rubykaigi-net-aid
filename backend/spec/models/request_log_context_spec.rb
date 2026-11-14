# frozen_string_literal: true

require "rails_helper"
require "semantic_logger/test/capture_log_events"

RSpec.describe RequestLogContext, type: :model do
  include ActiveJob::TestHelper

  def log_with(named_tags: {}, payload: nil)
    SemanticLogger::Log.new("Test", :info).tap do |log|
      log.named_tags = named_tags
      log.payload = payload
    end
  end

  describe ".apply" do
    it "adds the context tags to the log's named tags" do
      described_class.add_tags(handler: "netaid:GetViewer")
      log = log_with(named_tags: {request_id: "r_1"})

      described_class.apply(log)

      expect(log.named_tags).to eq(request_id: "r_1", handler: "netaid:GetViewer")
    end

    it "keeps the value from an enclosing tagged block on a shared key" do
      described_class.add_tags(handler: "netaid:GetViewer")
      log = log_with(named_tags: {handler: "netaid:CreateSite"})

      described_class.apply(log)

      expect(log.named_tags).to eq(handler: "netaid:CreateSite")
    end

    it "leaves the log untouched when no tags were added" do
      log = log_with(named_tags: {request_id: "r_1"})

      described_class.apply(log)

      expect(log.named_tags).to eq(request_id: "r_1")
    end

    it "merges the counters into a job's Performed line" do
      described_class.increment(:occ_retries)
      log = log_with(payload: {event_name: "perform.active_job", job_class: "NoopJob"})

      described_class.apply(log)

      expect(log.payload).to eq(event_name: "perform.active_job", job_class: "NoopJob", occ_retries: 1)
    end

    it "leaves the payload of other lines alone" do
      described_class.increment(:occ_retries)
      log = log_with(payload: {event_name: "perform_start.active_job"})

      described_class.apply(log)

      expect(log.payload).to eq(event_name: "perform_start.active_job")
    end
  end

  describe ".log_payload" do
    it "is empty when nothing was counted" do
      expect(described_class.log_payload).to eq({})
    end

    it "reports each counter by name" do
      described_class.increment(:occ_retries)
      described_class.increment(:occ_retries)
      described_class.increment(:changes_written)

      expect(described_class.log_payload).to eq(occ_retries: 2, changes_written: 1)
    end

    it "reports the added fields beside the counters" do
      described_class.add_fields(authn_failure: :expired)
      described_class.increment(:occ_retries)

      expect(described_class.log_payload).to eq(authn_failure: :expired, occ_retries: 1)
    end
  end

  it "counts enqueued jobs" do
    job = stub_const("NoopJob", Class.new(ApplicationJob) { def perform; end })

    expect { job.perform_later }.to change { described_class.counters[:jobs_enqueued] }.by(1)
  end

  it "does not count a job whose enqueue was aborted" do
    job = stub_const("AbortedJob", Class.new(ApplicationJob) do
      before_enqueue { throw :abort }
      def perform; end
    end)

    job.perform_later

    expect(described_class.counters).not_to have_key(:jobs_enqueued)
  end

  it "applies to every log line through SemanticLogger's on_log hook" do
    described_class.add_tags(handler: "netaid:GetViewer")
    log = log_with

    SemanticLogger::Logger.call_subscribers(log)

    expect(log.named_tags).to include(handler: "netaid:GetViewer")
  end

  it "puts the counters of a job on its Performed line" do
    logger = SemanticLogger::Test::CaptureLogEvents.new
    allow(ActiveJob::Base).to receive(:logger).and_return(logger)
    job = stub_const("CountingJob", Class.new(ApplicationJob) { def perform = RequestLogContext.increment(:widgets_made) })

    job.perform_now

    performed = logger.events.find { it.message.start_with?("Performed CountingJob") }
    expect(performed.payload).to include(widgets_made: 1)
  end
end
