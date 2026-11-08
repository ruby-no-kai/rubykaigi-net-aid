# frozen_string_literal: true

require "webmock/rspec"

# Mints bearer tokens signed by test keys, served from stubbed JWKS endpoints of each trusted
# issuer.
module AuthnHelper
  HIMARI = "https://idp.rubykaigi.net"
  GITHUB_ACTIONS = "https://token.actions.githubusercontent.com"
  AWS = "https://aws-issuer.tokens.sts.global.api.aws"
  AUDIENCE = "https://aid.rubykaigi.net"

  def self.rsa_key = @rsa_key ||= JWT::JWK.new(OpenSSL::PKey::RSA.generate(2048), {kid: "rsa-1", use: "sig", alg: "RS256"})
  def self.ec_key = @ec_key ||= JWT::JWK.new(OpenSSL::PKey::EC.generate("prime256v1"), {kid: "ec-1", use: "sig", alg: "ES256"})

  def stub_jwks(url, keys: [AuthnHelper.rsa_key, AuthnHelper.ec_key])
    stub_request(:get, url).to_return(
      status: 200,
      headers: {"Content-Type" => "application/json"},
      body: JSON.generate(JWT::JWK::Set.new(keys).export),
    )
  end

  def stub_trusted_jwks
    {
      himari: stub_jwks("#{HIMARI}/public/jwks"),
      github_actions: stub_jwks("#{GITHUB_ACTIONS}/.well-known/jwks"),
      aws: stub_jwks("#{AWS}/.well-known/jwks.json")
    }
  end

  def sign_token(claims, key: AuthnHelper.rsa_key, header: {})
    alg = key[:alg]
    JWT.encode(claims, key.signing_key, alg, {kid: key[:kid], typ: "JWT", **header})
  end

  def standard_claims(iss:, aud:, sub:)
    now = Time.now.to_i
    {iss:, aud:, sub:, iat: now, nbf: now, exp: now + 3600, jti: SecureRandom.uuid}
  end

  def himari_access_token(sub: "github_1", name: "octocat", roles: %w[operator], client_id: "net-aid-cli", **overrides)
    claims = standard_claims(iss: HIMARI, aud: client_id, sub:).merge(client_id:, name:, roles:, scope: "openid")
    sign_token(claims.merge(overrides).compact, header: {typ: "at+jwt"})
  end

  def himari_id_token(sub: "github_1", client_id: "net-aid-cli")
    sign_token(standard_claims(iss: HIMARI, aud: client_id, sub:).merge(name: "octocat", roles: %w[admin]))
  end

  def github_actions_token(sub: "repo:ruby-no-kai/rubykaigi-net:ref:refs/heads/master", **overrides)
    claims = standard_claims(iss: GITHUB_ACTIONS, aud: AUDIENCE, sub:).merge(
      repository: "ruby-no-kai/rubykaigi-net", workflow: "export", run_number: "42", run_id: "1234", run_attempt: "2",
    )
    sign_token(claims.merge(overrides).compact)
  end

  def aws_token(sub: "arn:aws:iam::123456789012:role/netaid-refresher", **overrides)
    sign_token(standard_claims(iss: AWS, aud: AUDIENCE, sub:).merge(overrides).compact, key: AuthnHelper.ec_key)
  end

  def with_machine_roles(mapping)
    authn = Rails.configuration.x.authn
    original = authn.machine_roles
    authn.machine_roles = mapping
    yield
  ensure
    authn.machine_roles = original
  end
end

RSpec.configure do |config|
  config.include AuthnHelper

  config.around do |example|
    authn = Rails.configuration.x.authn
    original = authn.aws_issuers
    authn.aws_issuers = [AuthnHelper::AWS]
    Authn::JwksCache.clear
    example.run
  ensure
    authn.aws_issuers = original
  end
end
