# frozen_string_literal: true

require "rails_helper"

RSpec.describe Branch, type: :model do
  it "scopes Fleet branches together and Plan branches by Episode" do
    fleet = described_class.new(dataset: Branch::DATASET_FLEET, name: "main", state: Branch::STATE_READY)
    episode_id = SecureRandom.uuid
    plan = described_class.new(dataset: Branch::DATASET_PLAN, name: "main", state: Branch::STATE_READY, episode_id:)

    expect([fleet, plan]).to all(be_valid)
    expect(fleet.scope_key).to eq("fleet")
    expect(plan.scope_key).to eq(episode_id)
  end

  it "requires an Episode on a Plan branch only" do
    expect(described_class.new(dataset: Branch::DATASET_PLAN, name: "main", state: Branch::STATE_READY)).not_to be_valid
    expect(described_class.new(dataset: Branch::DATASET_FLEET, name: "main", state: Branch::STATE_READY, episode_id: SecureRandom.uuid)).not_to be_valid
  end

  it "accepts only stored enum value names" do
    expect(described_class.new(dataset: "DATASET_UNSPECIFIED", name: "main", state: Branch::STATE_READY)).not_to be_valid
    expect(described_class.new(dataset: Branch::DATASET_FLEET, name: "main", state: "ready")).not_to be_valid
  end

  it "names its dataset" do
    expect(described_class.new(dataset: Branch::DATASET_PLAN)).to be_plan
    expect(described_class.new(dataset: Branch::DATASET_FLEET)).to be_fleet
  end

  it "is writable when ready and not frozen" do
    expect(described_class.new(state: Branch::STATE_READY)).to be_writable
    expect(described_class.new(state: Branch::STATE_READY, is_frozen: true)).not_to be_writable
    expect(described_class.new(state: Branch::STATE_PREPARING)).not_to be_writable
  end

  it "finds Fleet main" do
    main = create_branch
    create_branch(name: "rk26-close")

    expect(described_class.fleet_main).to eq(main)
  end

  it "has one Fleet main" do
    create_branch

    expect { create_branch }.to raise_error(ActiveRecord::RecordNotUnique)
  end

  it "gives a cursor at its head" do
    branch = create_branch(head_seq: 4)

    expect(Changelog::Cursor.decode(branch.cursor, branch_id: branch.id)).to eq(4)
  end
end
