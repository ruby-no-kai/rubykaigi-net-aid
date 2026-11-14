# frozen_string_literal: true

require "rails_helper"

RSpec.describe "ViewerService.GetViewer" do
  let(:rpc) { connect_method("ViewerService", "GetViewer") }
  let(:expected) { Rk::NetAid::ViewerServiceGetViewerResponse.new(viewer: Rk::NetAid::Viewer.new) }

  it "answers a JSON POST" do
    expect(connect_call(rpc, Rk::NetAid::ViewerServiceGetViewerRequest.new)).to eq(expected)
  end

  it "answers GET and binary POST as JSON POST" do
    request = Rk::NetAid::ViewerServiceGetViewerRequest.new
    expect(connect_call(rpc, request, via: :get)).to eq(expected)
    expect(connect_call(rpc, request, codec: :proto)).to eq(expected)
  end

  it "refuses a POST without Connect-Protocol-Version" do
    post rpc.path, params: "{}", headers: {"Content-Type" => "application/json"}
    error = connect_response(rpc, :json)
    expect(error.code).to eq("invalid_argument")
    expect(error.detail(Google::Rpc::RequestInfo).request_id).to be_present
  end

  it "refuses a cross-site request" do
    error = connect_call(rpc, Rk::NetAid::ViewerServiceGetViewerRequest.new, headers: {"Sec-Fetch-Site" => "cross-site"})
    expect(error.code).to eq("permission_denied")
  end
end
