# frozen_string_literal: true

require "rails_helper"

RSpec.describe Authz::Statement, type: :model do
  it "matches patterns where * matches any run of characters" do
    statement = described_class.new(effect: :allow, actions: %w[netaid:Get* netaid:*Export netaid:Bootstrap])

    expect(%w[netaid:Get netaid:GetSite netaid:CreateExport netaid:Bootstrap].map { statement.match?(it) }).to all(be(true))
    expect(%w[netaid:ListSites netaid:Bootstrap2 xnetaid:GetSite].map { statement.match?(it) }).to all(be(false))
  end

  it "treats other characters literally" do
    expect(described_class.new(effect: :allow, actions: %w[netaid:Get.]).match?("netaid:GetX")).to be(false)
  end

  it "matches every action outside not_actions" do
    statement = described_class.new(effect: :allow, not_actions: %w[netaid:Restore* netaid:CreateEpisode])

    expect(%w[netaid:CreateSite netaid:CreateEpisodes].map { statement.match?(it) }).to all(be(true))
    expect(%w[netaid:RestoreMutation netaid:CreateEpisode].map { statement.match?(it) }).to all(be(false))
  end

  it "takes exactly one of actions and not_actions" do
    expect { described_class.new(effect: :allow) }.to raise_error(ArgumentError)
    expect { described_class.new(effect: :allow, actions: %w[a], not_actions: %w[b]) }.to raise_error(ArgumentError)
  end
end
