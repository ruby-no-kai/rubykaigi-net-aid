# frozen_string_literal: true

require "rails_helper"

RSpec.describe Changelog::Context, :committing, type: :model do
  let(:branch) { create_branch }

  before { Current.actor = test_actor }

  # rubocop:disable Rails/SkipsModelValidations -- Changelog::Context#insert_all! validates each row
  describe "#insert_all!" do
    it "inserts the rows with an upsert Change each" do
      scans = %w[rk-1 rk-2 rk-3].map { SpikeScan.new(branch:, tag: it) }

      Changelog.write(mutation: nil, branches: [branch]) { Changelog.current.insert_all!(scans) }

      expect(SpikeScan.order(:tag).pluck(:tag, :updated_seq)).to eq([["rk-1", 1], ["rk-2", 1], ["rk-3", 1]])
      expect(SpikeScan.all).to all(have_attributes(lineage: be_present, created_at: be_present))
      expect(Change.on(branch).order(:ordinal).map { [it.op, it.ordinal, it.data.fetch("tag")] }).to eq(
        [[Change::OP_UPSERT, 1, "rk-1"], [Change::OP_UPSERT, 2, "rk-2"], [Change::OP_UPSERT, 3, "rk-3"]],
      )
      expect(RequestLogContext.counters[:changes_written]).to eq(3)
    end

    it "keeps client-supplied ids" do
      id = TypeidRails.generate(prefix: "sscan", version: 7)

      Changelog.write(mutation: nil, branches: [branch]) { Changelog.current.insert_all!([SpikeScan.new(branch:, tag: "rk-1", id:)]) }

      expect(SpikeScan.sole).to have_attributes(id:, lineage: id)
    end

    it "raises on the first invalid row and inserts nothing" do
      devices = [SpikeDevice.new(branch:, name: "d"), SpikeDevice.new(branch:, name: "")]

      expect { Changelog.write(mutation: nil, branches: [branch]) { Changelog.current.insert_all!(devices) } }
        .to raise_error(ActiveRecord::RecordInvalid)
      expect(SpikeDevice.count).to eq(0)
      expect(Change.count).to eq(0)
    end

    it "takes rows of one model only" do
      rows = [SpikeScan.new(branch:, tag: "rk-1"), SpikeRack.new(branch:, name: "r")]

      expect { Changelog.write(mutation: nil, branches: [branch]) { Changelog.current.insert_all!(rows) } }.to raise_error(ArgumentError)
    end
  end
  # rubocop:enable Rails/SkipsModelValidations
end
