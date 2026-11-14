# frozen_string_literal: true

require "rails_helper"

RSpec.describe ConnectForgeryProtection, type: :request do
  let(:rpc) { connect_method("ViewerService", "GetViewer") }
  let(:request_message) { Rk::NetAid::ViewerServiceGetViewerRequest.new }

  before { allow(Rails.logger).to receive(:warn).and_call_original }

  it "refuses a POST without Connect-Protocol-Version as a Connect protocol error" do
    post rpc.path, params: "{}", headers: { "Content-Type" => "application/json" }
    error = connect_response(rpc, :json)

    expect(error.status).to eq(400)
    expect(error.code).to eq("invalid_argument")
    expect(error.detail(Protobufable::ProblemDetails)).to be_nil
    expect(error.detail(Google::Rpc::RequestInfo).request_id).to be_present
    expect(Rails.logger).to have_received(:warn).with(/reason=:missing_connect_protocol_version/)
  end

  it "refuses a request whose Sec-Fetch-Site names another site" do
    error = connect_call(rpc, request_message, headers: { "Sec-Fetch-Site" => "cross-site" })

    expect(error.status).to eq(403)
    expect(error.code).to eq("permission_denied")
    expect(problem_type_of(error)).to eq("permission-denied")
    expect(Rails.logger).to have_received(:warn).with(/reason=:cross_site fetch_site="cross-site"/)
  end

  it "refuses a request whose Origin names another origin" do
    error = connect_call(rpc, request_message, headers: { "Origin" => "https://attacker.invalid" })

    expect(error.status).to eq(403)
    expect(error.code).to eq("permission_denied")
    expect(problem_type_of(error)).to eq("permission-denied")
    expect(Rails.logger).to have_received(:warn).with(/reason=:cross_origin origin="https:\/\/attacker.invalid"/)
  end

  it "answers a request from this origin" do
    response_message = connect_call(rpc, request_message, headers: {
      "Sec-Fetch-Site" => "same-origin",
      "Origin" => "http://www.example.com"
    })

    expect(response_message).to be_a(Rk::NetAid::ViewerServiceGetViewerResponse)
    expect(Rails.logger).not_to have_received(:warn)
  end

  it "answers a request the viewer made directly" do
    expect(connect_call(rpc, request_message, headers: { "Sec-Fetch-Site" => "none" }))
      .to be_a(Rk::NetAid::ViewerServiceGetViewerResponse)
  end

  it "answers a GET without Connect-Protocol-Version" do
    expect(connect_call(rpc, request_message, via: :get)).to be_a(Rk::NetAid::ViewerServiceGetViewerResponse)
  end

  it "refuses before the request message is validated" do
    filters = Api::Viewer::ViewersController._process_action_callbacks.map(&:filter)
    expect(filters.index(:verify_connect_request_origin!)).to be < filters.index(:validate_connect_message!)
  end
end
