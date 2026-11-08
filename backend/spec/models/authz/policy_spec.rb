# frozen_string_literal: true

require "rails_helper"

RSpec.describe Authz::Policy, type: :model do
  def actor(*roles)
    Actor.new(issuer: "himari", subject: "github_1", display_name: "octocat", credential_id: "c", user_agent: "", roles:)
  end

  def permitted(roles, actions) = actions.select { described_class.permit?(actor(*roles), it) }

  let(:reads) { %w[netaid:GetSite netaid:ListDevices netaid:LookupAsset netaid:Bootstrap netaid:PullChanges netaid:DownloadExport] }
  let(:writes) { %w[netaid:CreateSite netaid:UpdateDevice netaid:AssignFill netaid:ImportCables netaid:PushMutations] }
  let(:admin_only) do
    %w[
      netaid:CreateEpisode netaid:UpdateEpisode netaid:CloseEpisode netaid:CreateFleetSnapshot
      netaid:CreateImport netaid:ApplyImport netaid:RestoreMutation
    ]
  end

  it "lets anyone, even an anonymous caller, call GetViewer and RefreshSession" do
    expect(described_class.permit?(nil, "netaid:GetViewer")).to be(true)
    expect(described_class.permit?(nil, "netaid:RefreshSession")).to be(true)
    expect(described_class.permit?(actor, "netaid:GetViewer")).to be(true)
  end

  it "denies an anonymous caller everything else" do
    expect(described_class.permit?(nil, "netaid:GetSite")).to be(false)
  end

  it "denies a caller with no recognised role" do
    expect(permitted(%w[], reads)).to eq([])
    expect(permitted(%w[guest], reads)).to eq([])
  end

  it "lets a viewer read" do
    expect(permitted(%w[viewer], reads + writes + admin_only)).to eq(reads)
  end

  it "does not match a pattern's prefix only" do
    expect(described_class.permit?(actor("viewer"), "netaid:Bootstraps")).to be(false)
    expect(described_class.permit?(actor("viewer"), "other:GetSite")).to be(false)
  end

  it "lets an operator read and write, but not run admin-only actions" do
    expect(permitted(%w[operator], reads + writes + admin_only)).to eq(reads + writes)
  end

  it "lets an admin do everything" do
    expect(permitted(%w[admin], reads + writes + admin_only)).to eq(reads + writes + admin_only)
  end

  it "lets an exporter read and create exports" do
    expect(permitted(%w[exporter], reads + writes + %w[netaid:CreateExport])).to eq(reads + %w[netaid:CreateExport])
  end

  it "keeps an admin's grants when the admin is also an operator" do
    expect(permitted(%w[operator admin], admin_only)).to eq(admin_only)
  end

  it "accepts the Episode a request targets" do
    expect(described_class.permit?(actor("operator"), "netaid:CreateSite", episode: "rk26")).to be(true)
  end
end
