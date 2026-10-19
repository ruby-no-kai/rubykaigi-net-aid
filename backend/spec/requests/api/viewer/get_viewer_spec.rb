# frozen_string_literal: true

require "rails_helper"

RSpec.describe "ViewerService.GetViewer" do
  let(:rpc) { connect_method("ViewerService", "GetViewer") }
  let(:expected) { Rk::NetAid::ViewerServiceGetViewerResponse.new(viewer: Rk::NetAid::Viewer.new(signed_in: false)) }

  it "answers a JSON POST" do
    expect(connect_call(rpc, Rk::NetAid::ViewerServiceGetViewerRequest.new)).to eq(expected)
  end

  it "answers GET and binary POST as JSON POST" do
    request = Rk::NetAid::ViewerServiceGetViewerRequest.new
    expect(connect_call(rpc, request, via: :get)).to eq(expected)
    expect(connect_call(rpc, request, codec: :proto)).to eq(expected)
  end

  it "refuses a POST without Connect-Protocol-Version" do
    post rpc.path, params: "{}", headers: { "Content-Type" => "application/json" }
    error = connect_response(rpc, :json)
    expect(error.code).to eq("invalid_argument")
    expect(error.detail(Google::Rpc::RequestInfo).request_id).to be_present
  end

  it "refuses a cross-site request" do
    error = connect_call(rpc, Rk::NetAid::ViewerServiceGetViewerRequest.new, headers: { "Sec-Fetch-Site" => "cross-site" })
    expect(error.code).to eq("permission_denied")
  end
end

RSpec.describe "Connect error from the exceptions app", :escaping_exceptions do
  it "answers a route nothing serves in the Connect error shape" do
    post "/rubykaigi.net_aid.NoSuchService/Nope", params: "{}",
      headers: { "Content-Type" => "application/json", "Connect-Protocol-Version" => "1" }
    expect(response.media_type).to eq("application/json")
    body = JSON.parse(response.body)
    expect(body.fetch("code")).to eq("not_found")
    expect(body.fetch("details").map { it.fetch("type") }).to include("google.rpc.RequestInfo")
  end
end
