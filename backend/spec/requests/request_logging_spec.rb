# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Request logging" do
  let(:rpc) { connect_method("ViewerService", "GetViewer") }

  # Tags on a line logged where the Completed line is, after the callback chain has unwound.
  def completed_line_tags
    named_tags = nil
    subscriber = ActiveSupport::Notifications.subscribe("process_action.action_controller") do
      log = SemanticLogger::Log.new("Test", :info)
      SemanticLogger::Logger.call_subscribers(log)
      named_tags = log.named_tags
    end
    yield
    named_tags
  ensure
    ActiveSupport::Notifications.unsubscribe(subscriber)
  end

  it "tags the Completed line with the request id and the RPC's action" do
    tags = completed_line_tags { connect_call(rpc, Rk::NetAid::ViewerServiceGetViewerRequest.new) }

    expect(tags).to eq(request_id: response.request.request_id, handler: "netaid:GetViewer")
  end

  it "tags a call a callback refused" do
    tags = completed_line_tags do
      connect_call(rpc, Rk::NetAid::ViewerServiceGetViewerRequest.new, headers: {"Sec-Fetch-Site" => "cross-site"})
    end

    expect(tags).to include(handler: "netaid:GetViewer")
  end

  it "names no handler for a method the service does not declare" do
    tags = completed_line_tags do
      post "/rubykaigi.net_aid.ViewerService/Nope", params: "{}",
        headers: {"Content-Type" => "application/json", "Connect-Protocol-Version" => "1"}
    end

    expect(response).to have_http_status(:not_found)
    expect(tags.keys).to eq([:request_id])
  end
end
