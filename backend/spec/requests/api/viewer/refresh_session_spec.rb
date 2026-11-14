# frozen_string_literal: true

require "rails_helper"

RSpec.describe "ViewerService.RefreshSession" do
  let(:rpc) { connect_method("ViewerService", "RefreshSession") }
  let(:get_viewer) { connect_method("ViewerService", "GetViewer") }
  let(:token_url) { "#{AuthnHelper::HIMARI}/public/oidc/token" }

  before { stub_trusted_jwks }

  def refresh = connect_call(rpc, Rk::NetAid::ViewerServiceRefreshSessionRequest.new)
  def viewer = connect_call(get_viewer, Rk::NetAid::ViewerServiceGetViewerRequest.new).viewer

  def stub_grant(roles:, refresh_token: "refresh-2", sub: "github_1")
    stub_request(:post, token_url)
      .with(
        basic_auth: ["net-aid", "test-secret"], headers: {"User-Agent" => NetAid::Http::USER_AGENT},
        body: {"grant_type" => "refresh_token", "refresh_token" => "refresh-1"},
      )
      .to_return(
        status: 200,
        headers: {"Content-Type" => "application/json"},
        body: JSON.generate(
          access_token: himari_access_token(sub:, roles:, client_id: "net-aid"), token_type: "Bearer",
          expires_in: 3600, refresh_token:,
        ),
      )
  end

  it "renews an expired session's tokens and roles, keeping its credential_id" do
    sign_in_as(roles: %w[viewer], expires_in: 60)
    credential_id = viewer.actor.credential_id
    stub_grant(roles: %w[admin])

    travel(61.seconds) do
      expect(refresh.viewer).to have_attributes(roles: %w[admin])
      expect(viewer.actor.credential_id).to eq(credential_id)
      expect(viewer.roles).to eq(%w[admin])
    end
  end

  it "uses the rotated refresh token next time" do
    sign_in_as
    stub_grant(roles: %w[operator], refresh_token: "refresh-2")
    refresh

    rotated = stub_request(:post, token_url).with(body: hash_including("refresh_token" => "refresh-2"))
      .to_return(status: 400, headers: {"Content-Type" => "application/json"}, body: '{"error":"invalid_grant"}')
    refresh
    expect(rotated).to have_been_requested
  end

  def session_cookie_set? = Array(response.headers["set-cookie"]).join("\n").include?("__Host-Http-netaid-sess=")

  it "answers session-revoked when himari refuses the refresh, leaving the cookie alone" do
    sign_in_as
    stub_request(:post, token_url)
      .to_return(status: 400, headers: {"Content-Type" => "application/json"}, body: '{"error":"invalid_grant"}')

    error = refresh

    expect(error.status).to eq(401)
    expect(problem_type_of(error)).to eq("session-revoked")
    expect(session_cookie_set?).to be(false)
  end

  it "answers session-revoked when the refreshed token names another subject, leaving the cookie alone" do
    sign_in_as(sub: "github_1")
    stub_grant(roles: %w[admin], sub: "github_2")

    expect(problem_type_of(refresh)).to eq("session-revoked")
    expect(session_cookie_set?).to be(false)
    expect(viewer.actor.subject).to eq("github_1")
  end

  it "keeps the session another tab's concurrent refresh wrote" do
    sign_in_as(roles: %w[viewer])
    stale_cookie = cookies["__Host-Http-netaid-sess"]
    stub_grant(roles: %w[admin])
    refresh
    stub_request(:post, token_url).with(body: hash_including("refresh_token" => "refresh-1"))
      .to_return(status: 400, headers: {"Content-Type" => "application/json"}, body: '{"error":"invalid_grant"}')

    error = connect_call(rpc, Rk::NetAid::ViewerServiceRefreshSessionRequest.new,
      headers: {"Cookie" => "__Host-Http-netaid-sess=#{CGI.escape(stale_cookie)}"})

    expect(problem_type_of(error)).to eq("session-revoked")
    expect(session_cookie_set?).to be(false)
    expect(viewer).to have_attributes(roles: %w[admin])
  end

  it "rewrites the cookie with its expiry" do
    sign_in_as
    stub_grant(roles: %w[operator])
    refresh

    cookie = Array(response.headers["set-cookie"]).join("\n").lines.find { it.start_with?("__Host-Http-netaid-sess=") }
    expect(cookie).to include("expires=")
  end

  it "answers a developer session, which has nothing to refresh, as revoked" do
    https!
    get "/auth/developer/callback", params: {subject: "dev_1", name: "Developer", roles: "admin"}

    expect(problem_type_of(refresh)).to eq("session-revoked")
  end

  it "answers unavailable without clearing the session when himari answers an error" do
    sign_in_as
    stub_request(:post, token_url).to_return(status: 503, body: "")

    error = refresh
    expect(error.code).to eq("unavailable")
    expect(problem_type_of(error)).to eq("unavailable")
    expect(viewer.actor).to be_present
  end

  it "answers unavailable when himari does not answer" do
    sign_in_as
    stub_request(:post, token_url).to_timeout

    expect(problem_type_of(refresh)).to eq("unavailable")
  end

  it "answers a caller without a session as unauthenticated" do
    expect(problem_type_of(refresh)).to eq("unauthenticated")
  end
end
