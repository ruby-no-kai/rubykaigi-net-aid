# frozen_string_literal: true

require "rails_helper"
require "semantic_logger/test/capture_log_events"

RSpec.describe "Bearer authentication" do
  let(:rpc) { connect_method("ViewerService", "GetViewer") }
  let(:logger) { SemanticLogger::Test::CaptureLogEvents.new }

  before do
    stub_trusted_jwks
    allow(Api::Viewer::ViewersController).to receive(:logger).and_return(logger)
  end

  def get_viewer(token, user_agent: "net-aid-test/1")
    connect_call(rpc, Rk::NetAid::ViewerServiceGetViewerRequest.new,
      headers: {"Authorization" => "Bearer #{token}", "User-Agent" => user_agent})
  end

  def completed_line = logger.events.find { it.message.start_with?("Completed") }

  it "signs in a person or agent with a himari access token" do
    viewer = get_viewer(himari_access_token(jti: "j-1", roles: %w[admin])).viewer

    expect(viewer).to eq(Rk::NetAid::Viewer.new(
      actor: Rk::NetAid::Actor.new(
        issuer: "himari", subject: "github_1", display_name: "octocat", credential_id: "net-aid-cli/j-1",
        user_agent: "net-aid-test/1",
      ),
      roles: %w[admin],
    ))
    expect(completed_line.named_tags).to include(
      actor_issuer: "himari", actor_subject: "github_1", credential_id: "net-aid-cli/j-1",
    )
  end

  it "signs in a GitHub Actions workflow run" do
    viewer = get_viewer(github_actions_token).viewer

    expect(viewer.actor).to have_attributes(issuer: "github-actions", display_name: "ruby-no-kai/rubykaigi-net export #42")
    expect(viewer.roles).to eq(%w[exporter])
  end

  it "signs in an AWS IAM role through STS" do
    arn = "arn:aws:iam::123456789012:role/netaid-refresher"
    viewer = with_machine_roles("aws-sts" => {arn => %w[operator]}) { get_viewer(aws_token(sub: arn)).viewer }

    expect(viewer.actor).to have_attributes(issuer: "aws-sts", subject: arn, display_name: "netaid-refresher")
    expect(viewer.roles).to eq(%w[operator])
  end

  it "truncates the user agent the Actor keeps" do
    expect(get_viewer(himari_access_token, user_agent: "a" * 300).viewer.actor.user_agent).to eq("a" * 255)
  end

  it "answers an anonymous caller as signed out" do
    response = connect_call(rpc, Rk::NetAid::ViewerServiceGetViewerRequest.new)
    expect(response.viewer).to eq(Rk::NetAid::Viewer.new)
  end

  {
    "an expired token" => [-> { himari_access_token(exp: Time.now.to_i - 60, iat: Time.now.to_i - 3600) }, "expired", AuthnHelper::HIMARI],
    "a token for another audience" => [-> { himari_access_token(client_id: "amc") }, "wrong_audience", AuthnHelper::HIMARI],
    "a token from an untrusted issuer" => [
      -> { sign_token(standard_claims(iss: "https://idp.invalid", aud: "net-aid-cli", sub: "x")) }, "unknown_issuer", "https://idp.invalid"
    ],
    "an ID token" => [-> { himari_id_token }, "id_token_as_bearer", AuthnHelper::HIMARI],
    "a token naming an unknown kid" => [
      -> { sign_token(JWT.decode(himari_access_token, nil, false).first, key: AuthnHelper.other_rsa_key(kid: "gone"), header: {typ: "at+jwt"}) },
      "unknown_kid", AuthnHelper::HIMARI
    ]
  }.each do |description, (token, reason, issuer)|
    it "refuses #{description}" do
      error = get_viewer(instance_exec(&token))

      expect(error.code).to eq("unauthenticated")
      expect(problem_type_of(error)).to eq("unauthenticated")
      expect(completed_line.level).to eq(:info)
      error_class = reason == "expired" ? "Authn::BearerVerifier::Expired" : "Authn::BearerVerifier::Failure"
      expect(completed_line.payload).to include(authn_failure: reason, authn_issuer: issuer, error_class:)
      expect(completed_line.named_tags.keys).not_to include(:actor_subject)
    end
  end

  it "answers unavailable when the issuer's JWKS cannot be fetched" do
    stub_request(:get, "#{AuthnHelper::HIMARI}/public/jwks").to_timeout

    error = get_viewer(himari_access_token)

    expect(error.code).to eq("unavailable")
    expect(problem_type_of(error)).to eq("unavailable")
    expect(completed_line.payload).to include(
      authn_failure: "jwks_unavailable", authn_unavailable_cause: start_with("HTTPX::"),
    )
  end

  it "refuses an Authorization header of another scheme" do
    error = connect_call(rpc, Rk::NetAid::ViewerServiceGetViewerRequest.new, headers: {"Authorization" => "Basic Zm9vOmJhcg=="})
    expect(problem_type_of(error)).to eq("unauthenticated")
  end

  it "never logs the token" do
    token = himari_access_token(client_id: "amc")
    get_viewer(token)

    expect(logger.events.map { it.to_h.to_json }.join).not_to include(token)
  end

  it "signs in a caller holding no role, who may still call GetViewer" do
    viewer = get_viewer(himari_access_token(roles: nil)).viewer
    expect(viewer).to have_attributes(roles: [])
  end
end
