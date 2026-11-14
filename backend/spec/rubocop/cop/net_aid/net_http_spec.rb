# frozen_string_literal: true

require "rubocop"
require "rubocop/rspec/support"
require_relative "../../../../rubocop/net_http"

RSpec.describe RuboCop::Cop::NetAid::NetHttp, :config do
  include RuboCop::RSpec::ExpectOffense

  it "flags Net::HTTP" do
    expect_offense(<<~RUBY)
      Net::HTTP.get(uri)
      ^^^^^^^^^ Use HTTPX with config.x.http.user_agent instead of Net::HTTP.
    RUBY
  end

  it "flags a constant under Net::HTTP once" do
    expect_offense(<<~RUBY)
      ::Net::HTTP::Post.new(uri)
      ^^^^^^^^^^^ Use HTTPX with config.x.http.user_agent instead of Net::HTTP.
    RUBY
  end

  it "flags requiring net/http" do
    expect_offense(<<~RUBY)
      require "net/http"
      ^^^^^^^^^^^^^^^^^^ Use HTTPX with config.x.http.user_agent instead of Net::HTTP.
    RUBY
  end

  it "accepts other Net constants" do
    expect_no_offenses("Net::OpenTimeout")
  end
end
