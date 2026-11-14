# frozen_string_literal: true

require "rails_helper"

RSpec.describe Authn::JwksCache, type: :model do
  let(:url) { "#{AuthnHelper::HIMARI}/public/jwks" }
  let(:other_url) { "#{AuthnHelper::GITHUB_ACTIONS}/.well-known/jwks" }

  def unavailable_from(url)
    described_class.find(url, "rsa-1")
  rescue Authn::IssuerUnavailable => e
    e
  end

  it "finds a key of the JWKS" do
    stub_jwks(url)
    expect(described_class.find(url, "rsa-1")&.[](:kid)).to eq("rsa-1")
  end

  it "raises IssuerUnavailable, keeping the cause, when the issuer answers an error" do
    stub_request(:get, url).to_return(status: 503, body: "")

    error = unavailable_from(url)
    expect(error).to have_attributes(reason: "jwks_unavailable", url:)
    expect(error.cause).to be_a(Net::HTTPFatalError)
  end

  it "raises IssuerUnavailable when the issuer does not answer" do
    stub_request(:get, url).to_timeout
    expect(unavailable_from(url).cause).to be_a(Net::OpenTimeout)
  end

  it "raises IssuerUnavailable when the JWKS does not parse" do
    stub_request(:get, url).to_return(status: 200, body: "<html>")
    expect(unavailable_from(url).cause).to be_a(JSON::ParserError)
  end

  it "answers a failed fetch from the cache for a while, then fetches again" do
    now = 1000.0
    allow(Process).to receive(:clock_gettime).and_call_original
    allow(Process).to receive(:clock_gettime).with(Process::CLOCK_MONOTONIC) { now }
    stub_request(:get, url).to_return(status: 503, body: "")

    unavailable_from(url)
    expect(unavailable_from(url).cause).to be_a(Net::HTTPFatalError)
    expect(a_request(:get, url)).to have_been_made.once

    stub_jwks(url)
    now += described_class::FAILURE_INTERVAL + 1
    expect(described_class.find(url, "rsa-1")).to be_present
  end

  it "keeps a failure of one issuer from answering for another" do
    stub_request(:get, url).to_return(status: 503, body: "")
    stub_jwks(other_url)

    unavailable_from(url)
    expect(described_class.find(other_url, "rsa-1")).to be_present
  end

  it "fetches one issuer's JWKS while another's fetch is in flight" do
    entered = Thread::Queue.new
    release = Thread::Queue.new
    stub_request(:get, url).to_return do
      entered << true
      release.pop
      {status: 200, headers: {"Content-Type" => "application/json"}, body: JSON.generate(JWT::JWK::Set.new([AuthnHelper.rsa_key]).export)}
    end
    stub_jwks(other_url)

    slow = Thread.new { described_class.find(url, "rsa-1") }
    entered.pop
    begin
      expect(described_class.find(other_url, "rsa-1")).to be_present
    ensure
      release << true
      slow.join
    end
    expect(slow.value).to be_present
  end
end
