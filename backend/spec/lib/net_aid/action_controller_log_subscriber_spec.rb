# frozen_string_literal: true

require "rails_helper"
require "semantic_logger/test/capture_log_events"

RSpec.describe NetAid::ActionControllerLogSubscriber, type: :model do
  let(:logger) { SemanticLogger::Test::CaptureLogEvents.new }

  before do
    allow(ApplicationController).to receive(:logger).and_return(logger)
  end

  def process_action(**payload)
    event = ActiveSupport::Notifications::Event.new(
      "process_action.action_controller",
      0,
      1,
      "id",
      {controller: "ApplicationController", action: "index", method: "POST", path: "/", **payload},
    )
    described_class.new.process_action(event)
    logger.events.last
  end

  it "replaces the upstream subscriber" do
    subscribers = ActiveSupport::LogSubscriber.subscribers.grep(RailsSemanticLogger::ActionController::LogSubscriber)

    expect(subscribers.map(&:class)).to eq([described_class])
  end

  it "names the status and handler in the message" do
    RequestLogContext.add_tags(handler: "netaid:GetViewer")

    expect(process_action(status: 403).message).to eq("Completed 403 netaid:GetViewer")
  end

  it "names the controller and action when there is no handler" do
    expect(process_action(status: 200).message).to eq("Completed 200 application#index")
  end

  [200, 400, 403, 404, 422].each do |status|
    it "logs a #{status} at info" do
      expect(process_action(status:).level).to eq(:info)
    end
  end

  it "logs a 5xx at error" do
    expect(process_action(status: 503).level).to eq(:error)
  end

  it "keeps the class of an unrescued exception" do
    log = process_action(status: 500, exception: ["RuntimeError", "boom"])

    expect(log.level).to eq(:error)
    expect(log.payload).to include(error_class: "RuntimeError")
  end

  it "keeps the rescued exception over an unrescued one" do
    log = process_action(status: 500, error_class: "Errors::Internal", exception: ["RuntimeError", "boom"])

    expect(log.payload).to include(error_class: "Errors::Internal")
  end
end
