# frozen_string_literal: true

require "rails_helper"

RSpec.describe Authn::BearerVerifier, type: :model do
  subject(:verifier) { described_class.new }

  let!(:jwks) { stub_trusted_jwks }

  def verify(token) = verifier.verify(token, user_agent: "RSpec")

  def failure_of(token)
    verify(token)
  rescue Authn::BearerVerifier::Failure => e
    [e.reason, e.issuer]
  end

  describe "himari access tokens" do
    it "maps the claims to an Actor" do
      token = himari_access_token(jti: "j-1")

      expect(verify(token)).to eq(Actor.new(
        issuer: "himari", subject: "github_1", display_name: "octocat", credential_id: "net-aid-cli/j-1",
        user_agent: "RSpec", roles: %w[operator],
      ))
    end

    it "accepts every allowlisted client" do
      expect(verify(himari_access_token(client_id: "net-aid")).credential_id).to start_with("net-aid/")
    end

    it "refuses another client's token" do
      expect(failure_of(himari_access_token(client_id: "amc"))).to eq(["wrong_audience", AuthnHelper::HIMARI])
    end

    it "refuses an ID token" do
      expect(failure_of(himari_id_token)).to eq(["id_token_as_bearer", AuthnHelper::HIMARI])
    end

    it "keeps no roles when the claim is absent" do
      expect(verify(himari_access_token(roles: nil)).roles).to eq([])
    end
  end

  describe "GitHub Actions ID tokens" do
    it "maps the claims to an Actor with the machine roles of its subject" do
      expect(verify(github_actions_token)).to have_attributes(
        issuer: "github-actions",
        subject: "repo:ruby-no-kai/rubykaigi-net:ref:refs/heads/master",
        display_name: "ruby-no-kai/rubykaigi-net export #42",
        credential_id: "1234/2",
        roles: %w[exporter],
      )
    end

    it "grants no roles to a subject matching a mapped one only by prefix" do
      token = github_actions_token(sub: "repo:ruby-no-kai/rubykaigi-net:ref:refs/heads/master-evil")
      expect(verify(token).roles).to eq([])
    end

    it "refuses a token for another audience" do
      expect(failure_of(github_actions_token(aud: "sts.amazonaws.com"))).to eq(["wrong_audience", AuthnHelper::GITHUB_ACTIONS])
    end
  end

  describe "AWS STS tokens" do
    it "maps the claims to an Actor with the machine roles of its role ARN" do
      arn = "arn:aws:iam::123456789012:role/netaid-refresher"
      actor = with_machine_roles("aws-sts" => {arn => %w[operator]}) { verify(aws_token(jti: "j-2")) }

      expect(actor).to have_attributes(
        issuer: "aws-sts", subject: arn, display_name: "netaid-refresher", credential_id: "j-2", roles: %w[operator],
      )
    end
  end

  describe "refusals" do
    it "refuses an expired token" do
      token = himari_access_token(exp: Time.now.to_i - 60, iat: Time.now.to_i - 3600)
      expect(failure_of(token)).to eq(["expired", AuthnHelper::HIMARI])
    end

    it "refuses a token that is not yet valid" do
      expect(failure_of(himari_access_token(nbf: Time.now.to_i + 600))).to eq(["expired", AuthnHelper::HIMARI])
    end

    it "refuses an issuer it does not trust" do
      token = sign_token(standard_claims(iss: "https://idp.invalid", aud: "net-aid-cli", sub: "x"))
      expect(failure_of(token)).to eq(["unknown_issuer", "https://idp.invalid"])
    end

    it "refuses a token signed by another key under a known kid" do
      other = AuthnHelper.other_rsa_key(kid: "rsa-1")
      claims = standard_claims(iss: AuthnHelper::HIMARI, aud: "net-aid-cli", sub: "x").merge(client_id: "net-aid-cli")
      expect(failure_of(sign_token(claims, key: other, header: {typ: "at+jwt"}))).to eq(["bad_signature", AuthnHelper::HIMARI])
    end

    it "refuses an unsigned token" do
      claims = standard_claims(iss: AuthnHelper::HIMARI, aud: "net-aid-cli", sub: "x").merge(client_id: "net-aid-cli")
      token = JWT.encode(claims, nil, "none", {typ: "at+jwt", kid: "rsa-1"})
      expect(failure_of(token)).to eq(["bad_signature", AuthnHelper::HIMARI])
    end

    it "refuses an HMAC token keyed with the public key" do
      claims = standard_claims(iss: AuthnHelper::HIMARI, aud: "net-aid-cli", sub: "x").merge(client_id: "net-aid-cli")
      token = JWT.encode(claims, AuthnHelper.rsa_key.public_key.to_pem, "HS256", {typ: "at+jwt", kid: "rsa-1"})
      expect(failure_of(token)).to eq(["bad_signature", AuthnHelper::HIMARI])
    end

    it "refuses a key whose alg is outside the allowlist" do
      stub_jwks("#{AuthnHelper::HIMARI}/public/jwks", keys: [AuthnHelper.ec_p384_key])
      claims = standard_claims(iss: AuthnHelper::HIMARI, aud: "net-aid-cli", sub: "x").merge(client_id: "net-aid-cli")
      token = sign_token(claims, key: AuthnHelper.ec_p384_key, header: {typ: "at+jwt"})

      expect(failure_of(token)).to eq(["bad_signature", AuthnHelper::HIMARI])
    end

    it "refuses an allowlisted key used with another algorithm" do
      claims = standard_claims(iss: AuthnHelper::HIMARI, aud: "net-aid-cli", sub: "x").merge(client_id: "net-aid-cli")
      token = sign_token(claims, alg: "RS384", header: {typ: "at+jwt"})

      expect(failure_of(token)).to eq(["bad_signature", AuthnHelper::HIMARI])
    end

    it "refuses a token missing a claim its issuer maps" do
      expect(failure_of(github_actions_token(run_id: nil))).to eq(["bad_signature", AuthnHelper::GITHUB_ACTIONS])
    end

    it "refuses something that is not a JWT" do
      expect(failure_of("not-a-jwt")).to eq(["bad_signature", nil])
    end
  end

  describe "signing keys" do
    let(:rotated) { AuthnHelper.other_rsa_key(kid: "rsa-2", use: "sig") }
    let(:rotated_token) { sign_token(JWT.decode(himari_access_token, nil, false).first, key: rotated, header: {typ: "at+jwt"}) }

    describe "a key without alg" do
      let(:rsa) { JWT::JWK.new(AuthnHelper.rfc9500_key("test_rsa2048"), {kid: "rsa-noalg", use: "sig"}) }
      let(:ec) { JWT::JWK.new(AuthnHelper.rfc9500_key("test_ecc_p256"), {kid: "ec-noalg", use: "sig"}) }
      let(:p384) { JWT::JWK.new(OpenSSL::PKey::EC.generate("secp384r1"), {kid: "ec384-noalg", use: "sig"}) }
      let(:claims) { standard_claims(iss: AuthnHelper::HIMARI, aud: "net-aid-cli", sub: "x").merge(client_id: "net-aid-cli") }

      before { stub_jwks("#{AuthnHelper::HIMARI}/public/jwks", keys: [rsa, ec, p384]) }

      it "verifies an RSA key as RS256" do
        expect(verify(sign_token(claims, key: rsa, alg: "RS256", header: {typ: "at+jwt"})).subject).to eq("x")
      end

      it "verifies a P-256 key as ES256" do
        expect(verify(sign_token(claims, key: ec, alg: "ES256", header: {typ: "at+jwt"})).subject).to eq("x")
      end

      it "refuses an RSA key used with another algorithm" do
        expect(failure_of(sign_token(claims, key: rsa, alg: "RS512", header: {typ: "at+jwt"})).first).to eq("bad_signature")
      end

      it "refuses a curve outside the allowlist" do
        expect(failure_of(sign_token(claims, key: p384, alg: "ES384", header: {typ: "at+jwt"})).first).to eq("bad_signature")
      end
    end

    it "refuses a kid the JWKS lacks" do
      expect(failure_of(rotated_token)).to eq(["unknown_kid", AuthnHelper::HIMARI])
    end

    it "caches the JWKS until a token names an unknown kid, then refetches it" do
      now = 1000.0
      allow(Process).to receive(:clock_gettime).and_call_original
      allow(Process).to receive(:clock_gettime).with(Process::CLOCK_MONOTONIC) { now }

      verify(himari_access_token)
      verify(himari_access_token)
      expect(jwks.fetch(:himari)).to have_been_requested.once

      stub_jwks("#{AuthnHelper::HIMARI}/public/jwks", keys: [AuthnHelper.rsa_key, rotated])
      now += Authn::JwksCache::REFETCH_INTERVAL + 1
      expect(verify(rotated_token).subject).to eq("github_1")
    end

    it "refetches at most once per interval" do
      verify(himari_access_token)

      expect(failure_of(rotated_token).first).to eq("unknown_kid")
      expect(failure_of(rotated_token).first).to eq("unknown_kid")
      expect(a_request(:get, "#{AuthnHelper::HIMARI}/public/jwks")).to have_been_made.once
    end
  end
end
