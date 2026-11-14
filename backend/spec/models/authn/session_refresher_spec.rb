# frozen_string_literal: true

require "rails_helper"

RSpec.describe Authn::SessionRefresher, type: :model do
  let(:browser_session) do
    Authn::BrowserSession.sign_in(
      access_token: himari_access_token(client_id: "net-aid"), refresh_token: "refresh-1", expires_at: Time.now.to_i + 60,
    )
  end

  before { stub_trusted_jwks }

  it "raises Revoked caused by the refusal when the refreshed access token is refused" do
    stub_request(:post, "#{AuthnHelper::HIMARI}/public/oidc/token").to_return(
      status: 200,
      headers: {"Content-Type" => "application/json"},
      body: JSON.generate(access_token: himari_access_token(client_id: "amc"), token_type: "Bearer", expires_in: 3600),
    )

    expect { described_class.new.refresh(browser_session) }.to raise_error(described_class::Revoked) { |error|
      expect(error.cause).to have_attributes(class: Authn::BearerVerifier::Failure, reason: :wrong_audience)
    }
  end
end
