# frozen_string_literal: true

require "rails_helper"
require "semantic_logger/test/capture_log_events"

RSpec.describe "Browser sign-in" do
  let(:get_viewer) { connect_method("ViewerService", "GetViewer") }

  before { stub_trusted_jwks }

  def viewer = connect_call(get_viewer, Rk::NetAid::ViewerServiceGetViewerRequest.new).viewer

  it "routes no provider that is not configured" do
    get "/auth/github"
    expect(response).to have_http_status(:not_found)
  end

  describe "starting a sign-in" do
    around do |example|
      ActionController::Base.allow_forgery_protection = true
      example.run
    ensure
      ActionController::Base.allow_forgery_protection = false
    end

    before { https! }

    it "answers a page posting to OmniAuth's request phase with a CSRF token" do
      get "/auth/himari"

      expect(response).to have_http_status(:ok)
      expect(response.body).to include('action="/auth/himari"', 'method="post"', 'name="authenticity_token"')
    end

    it "refuses a POST without the page's CSRF token" do
      post "/auth/himari"
      expect(URI(response.location).path).to eq("/auth/failure")
    end

    it "logs why OmniAuth failed" do
      logger = SemanticLogger::Test::CaptureLogEvents.new
      allow(Auth::SessionsController).to receive(:logger).and_return(logger)
      post "/auth/himari"

      get response.location

      expect(response).to have_http_status(:unauthorized)
      expect(logger.events.find { it.message.start_with?("Completed") }.payload).to include(
        authn_failure: :sign_in_failed, authn_sign_in_error: "ActionController::InvalidAuthenticityToken",
      )
    end

    it "logs no sign-in error that is not a plain word" do
      logger = SemanticLogger::Test::CaptureLogEvents.new
      allow(Auth::SessionsController).to receive(:logger).and_return(logger)

      get "/auth/failure", params: {message: "<script>"}

      payload = logger.events.find { it.message.start_with?("Completed") }.payload
      expect(payload).to include(authn_failure: :sign_in_failed)
      expect(payload).not_to have_key(:authn_sign_in_error)
    end

    it "redirects to himari with PKCE and offline access" do
      get "/auth/himari"
      token = response.body[/name="authenticity_token" value="([^"]+)"/, 1]

      post "/auth/himari", params: {authenticity_token: token}

      location = URI(response.location)
      query = Rack::Utils.parse_query(location.query)
      expect("#{location.scheme}://#{location.host}#{location.path}").to eq("#{AuthnHelper::HIMARI}/oidc/authorize")
      expect(query).to include("client_id" => "net-aid", "scope" => "openid offline_access", "code_challenge_method" => "S256")
    end
  end

  describe "the himari callback" do
    it "signs the browser in and returns to the path it started from" do
      https!
      get "/auth/himari", params: {return_to: "/devices/sw-1?tab=ports"}
      sign_in_as(roles: %w[admin])

      expect(response).to redirect_to("https://www.example.com/devices/sw-1?tab=ports")
      expect(viewer).to have_attributes(roles: %w[admin])
      expect(viewer.actor).to have_attributes(issuer: "himari", subject: "github_1", display_name: "octocat")
      expect(viewer.actor.credential_id).to match(/\A\h{8}-\h{4}-\h{4}-\h{4}-\h{12}\z/)
    end

    ["//evil.invalid/", "https://evil.invalid/", "/\\evil.invalid", "devices", "/devices\n"].each do |return_to|
      it "returns to / instead of #{return_to.inspect}" do
        https!
        get "/auth/himari", params: {return_to:}
        sign_in_as

        expect(response).to redirect_to("https://www.example.com/")
      end
    end

    it "tags its Completed line with the Actor it signs in" do
      logger = SemanticLogger::Test::CaptureLogEvents.new
      allow(Auth::SessionsController).to receive(:logger).and_return(logger)

      sign_in_as(sub: "github_1")

      tags = logger.events.find { it.message.start_with?("Completed") }.named_tags
      expect(tags).to include(actor_issuer: "himari", actor_subject: "github_1", credential_id: match(/\A\h{8}-/))
    end

    it "sets the session cookie with its security attributes" do
      sign_in_as

      cookie = response.headers["set-cookie"].then { Array(it).join("\n") }.lines.find { it.start_with?("__Host-Http-netaid-sess=") }
      expect(cookie).to include("path=/", "secure", "httponly", "samesite=lax", "expires=")
      expect(cookie).not_to include("domain=")
    end

    it "keeps the sign-in's credential_id but not a session from before it" do
      sign_in_as(sub: "github_1")
      first = viewer.actor.credential_id
      sign_in_as(sub: "github_2")

      expect(viewer.actor).to have_attributes(subject: "github_2")
      expect(viewer.actor.credential_id).not_to eq(first)
    end

    it "refuses an access token minted for another client" do
      logger = SemanticLogger::Test::CaptureLogEvents.new
      allow(Auth::SessionsController).to receive(:logger).and_return(logger)
      https!
      OmniAuth.config.test_mode = true
      OmniAuth.config.mock_auth[:himari] = OmniAuth::AuthHash.new(
        provider: "himari", uid: "github_1",
        credentials: {token: himari_access_token(client_id: "net-aid-cli"), expires_at: Time.now.to_i + 3600},
      )

      get "/auth/himari/callback"

      expect(response).to have_http_status(:unauthorized)
      expect(logger.events.find { it.message.start_with?("Completed") }.payload).to include(authn_failure: :wrong_audience)
      expect(viewer.actor).to be_nil
    ensure
      OmniAuth.config.test_mode = false
      OmniAuth.config.mock_auth.delete(:himari)
    end
  end

  describe "the himari callback while himari's JWKS cannot be fetched" do
    it "answers the failure page as unavailable" do
      logger = SemanticLogger::Test::CaptureLogEvents.new
      allow(Auth::SessionsController).to receive(:logger).and_return(logger)
      stub_request(:get, "#{AuthnHelper::HIMARI}/public/jwks").to_return(status: 500, body: "")

      sign_in_as

      expect(response).to have_http_status(:service_unavailable)
      expect(logger.events.find { it.message.start_with?("Completed") }.payload).to include(authn_failure: :jwks_unavailable)
      expect(viewer.actor).to be_nil
    end
  end

  describe "the session cookie" do
    def session_cookie = Array(response.headers["set-cookie"]).join("\n").lines.find { it.start_with?("__Host-Http-netaid-sess=") }

    it "is not rewritten by a request that only reads the session" do
      sign_in_as
      viewer

      expect(session_cookie).to be_nil
    end

    it "is not set for an anonymous caller" do
      https!
      viewer

      expect(session_cookie).to be_nil
    end

    it "keeps its expiry when a sign-in starts over a signed-in session" do
      sign_in_as
      get "/auth/himari", params: {return_to: "/devices"}

      expect(session_cookie).to include("expires=")
      expect(viewer.actor).to be_present
    end
  end

  describe "the developer sign-in" do
    it "signs in with the subject, name and roles the form took" do
      https!
      get "/auth/developer/callback", params: {subject: "dev_1", name: "Developer", roles: "operator, admin"}

      expect(viewer).to have_attributes(roles: %w[operator admin])
      expect(viewer.actor).to have_attributes(issuer: "developer", subject: "dev_1", display_name: "Developer")
    end
  end

  describe "POST /auth/sign_out" do
    it "clears the session" do
      sign_in_as
      post "/auth/sign_out"

      expect(response).to redirect_to("https://www.example.com/")
      expect(viewer.actor).to be_nil
    end

    it "refuses a cross-site request" do
      sign_in_as
      post "/auth/sign_out", headers: {"Sec-Fetch-Site" => "cross-site", "Origin" => "https://evil.invalid"}

      expect(response).to have_http_status(:forbidden)
      expect(viewer.actor).to be_present
    end
  end

  describe "an expired session" do
    it "answers session-expired without refreshing" do
      token_endpoint = stub_request(:post, "#{AuthnHelper::HIMARI}/public/oidc/token")
      sign_in_as(expires_in: 60)

      travel(61.seconds) do
        error = connect_call(get_viewer, Rk::NetAid::ViewerServiceGetViewerRequest.new)
        expect(error.status).to eq(401)
        expect(problem_type_of(error)).to eq("session-expired")
      end
      expect(token_endpoint).not_to have_been_requested
    end

    it "logs why" do
      logger = SemanticLogger::Test::CaptureLogEvents.new
      allow(Api::Viewer::ViewersController).to receive(:logger).and_return(logger)
      sign_in_as(expires_in: 60)

      travel(61.seconds) { connect_call(get_viewer, Rk::NetAid::ViewerServiceGetViewerRequest.new) }

      line = logger.events.find { it.message.start_with?("Completed") }
      expect(line.level).to eq(:info)
      expect(line.payload).to include(authn_failure: :session_expired)
    end
  end

  it "prefers the session to a bearer token" do
    sign_in_as(sub: "github_1")
    response = connect_call(get_viewer, Rk::NetAid::ViewerServiceGetViewerRequest.new,
      headers: {"Authorization" => "Bearer #{himari_access_token(sub: "github_9")}"})

    expect(response.viewer.actor.subject).to eq("github_1")
  end
end
