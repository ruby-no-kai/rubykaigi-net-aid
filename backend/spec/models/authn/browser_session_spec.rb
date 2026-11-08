# frozen_string_literal: true

require "rails_helper"

RSpec.describe Authn::BrowserSession, type: :model do
  let(:session) { {} }

  it "round-trips through the cookie session" do
    described_class.developer(subject: "octocat", name: "Octocat", roles: %w[operator]).store(session)

    loaded = described_class.load(session)
    expect(loaded.actor).to have_attributes(issuer: "developer", subject: "octocat", display_name: "Octocat", roles: %w[operator], user_agent: "")
    expect(loaded.expires_at).to be_within(5).of(Time.now.to_i + described_class::DEVELOPER_LIFETIME)
    expect(loaded).to have_attributes(access_token: nil, refresh_token: nil)
  end

  it "reads a session it cannot decode as signed out" do
    expect(described_class.load({})).to be_nil
    expect(described_class.load({described_class::SESSION_KEY => "not base64!"})).to be_nil
    expect(described_class.load({described_class::SESSION_KEY => Base64.strict_encode64("\xFF\xFF")})).to be_nil
    expect(described_class.load({described_class::SESSION_KEY => Base64.strict_encode64("")})).to be_nil
  end
end
