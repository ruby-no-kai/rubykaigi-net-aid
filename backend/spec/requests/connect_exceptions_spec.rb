# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Connect error from the exceptions app", :escaping_exceptions do
  it "answers a route nothing serves in the Connect error shape" do
    post "/rubykaigi.net_aid.NoSuchService/Nope", params: "{}",
      headers: {"Content-Type" => "application/json", "Connect-Protocol-Version" => "1"}
    expect(response.media_type).to eq("application/json")
    body = JSON.parse(response.body)
    expect(body.fetch("code")).to eq("not_found")
    expect(body.fetch("details").map { it.fetch("type") }).to include("google.rpc.RequestInfo")
  end
end
