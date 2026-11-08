# frozen_string_literal: true

require "rails_helper"

RSpec.describe Branched, :committing, type: :model do
  let(:branch) { create_branch }

  before { Current.actor = test_actor }

  def write(&) = Changelog.write(mutation: nil, branches: [branch], &)

  it "defaults id to a UUIDv7 and lineage to id" do
    rack = write { SpikeRack.create!(branch:, name: "r") }.response

    expect(TypeidRails.parse(rack.id).uuid[14]).to eq("7")
    expect(rack.lineage).to eq(rack.id)
    expect(rack.lineage).to start_with("srack_")
  end

  it "keeps a client-supplied id and lineage" do
    id = TypeidRails.generate(prefix: "srack", version: 7)
    lineage = TypeidRails.generate(prefix: "srack", version: 7)

    rack = write { SpikeRack.create!(branch:, name: "r", id:, lineage:) }.response

    expect(rack.reload).to have_attributes(id:, lineage:)
  end

  it "keeps a belongs_to to another Branched model by TypeID" do
    device = write do
      rack = SpikeRack.create!(branch:, name: "r")
      SpikeDevice.create!(branch:, name: "d", spike_rack_id: rack.id)
    end.response

    expect(device.reload.spike_rack.name).to eq("r")
  end

  it "rejects a duplicate natural key within a branch" do
    write { SpikeRack.create!(branch:, name: "r") }

    expect { write { SpikeRack.create!(branch:, name: "r") } }.to raise_error(ActiveRecord::RecordInvalid, /Name has already been taken/)
  end

  it "allows the same natural key on another branch" do
    other = create_branch(name: "other")

    Changelog.write(mutation: nil, branches: [branch, other]) do
      SpikeRack.create!(branch:, name: "r")
      SpikeRack.create!(branch: other, name: "r")
    end

    expect(SpikeRack.where(name: "r").count).to eq(2)
  end

  it "finds rows by natural key and by lineage within a branch" do
    rack = write { SpikeRack.create!(branch:, name: "r") }.response

    expect(SpikeRack.find_by_natural_key!(branch, "r")).to eq(rack)
    expect(SpikeRack.find_by_lineage(branch, rack.lineage)).to eq(rack)
    expect(SpikeRack.on(create_branch(name: "other")).find_by_lineage(branch, rack.lineage)).to be_nil
    expect { SpikeRack.find_by_natural_key!(branch, "s") }.to raise_error(ActiveRecord::RecordNotFound)
  end

  it "refuses a save outside Changelog.write" do
    expect { SpikeRack.create!(branch:, name: "r") }.to raise_error(Changelog::NotWriting)
  end

  it "refuses to move a row to another branch" do
    rack = write { SpikeRack.create!(branch:, name: "r") }.response

    expect { write { rack.update!(branch: create_branch(name: "other")) } }.to raise_error(ActiveRecord::ReadonlyAttributeError)
  end

  describe "insert_only!" do
    it "creates rows" do
      scan = write { SpikeScan.create!(branch:, tag: "rk-1") }.response

      expect(scan).to be_persisted
    end

    it "refuses an update or a destroy" do
      scan = write { SpikeScan.create!(branch:, tag: "rk-1") }.response

      expect { write { SpikeScan.find(scan.id).update!(tag: "rk-2") } }.to raise_error(ActiveRecord::ReadOnlyRecord)
      expect { write { SpikeScan.find(scan.id).destroy! } }.to raise_error(ActiveRecord::ReadOnlyRecord)
    end
  end

  describe "the changelog tables" do
    it "are read-only outside Changelog.write" do
      write { SpikeRack.create!(branch:, name: "r") }

      expect { ChangeSet.sole.update!(seq: 9) }.to raise_error(ActiveRecord::ReadOnlyRecord)
      expect { Change.sole.destroy! }.to raise_error(ActiveRecord::ReadOnlyRecord)
      expect { Mutation.create!(id: TypeidRails.generate(prefix: "mut")) }.to raise_error(ActiveRecord::ReadOnlyRecord)
    end
  end
end
