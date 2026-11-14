# frozen_string_literal: true

require "rails_helper"

RSpec.describe Changelog, type: :model do
  it "writes inside a transactional fixture" do
    branch = create_branch
    Current.actor = test_actor

    described_class.write(mutation: nil, branches: [branch]) { SpikeRack.create!(branch:, name: "r") }

    expect(ChangeSet.on(branch).pluck(:seq)).to eq([1])
  end
end
