# frozen_string_literal: true

require "rails_helper"

RSpec.describe Changelog, :committing, type: :model do
  let(:fleet) { create_branch }
  let(:plan) { create_branch(dataset: Branch::DATASET_PLAN) }

  def in_threads(count, &block)
    count.times.map do |i|
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          Current.actor = test_actor
          block.call(i)
        end
      end
    end.each(&:join)
  end

  it "numbers the ChangeSets of concurrent writers on one branch 1..N" do
    branch = fleet

    in_threads(4) do |i|
      3.times { |j| described_class.write(mutation: nil, branches: [branch]) { SpikeRack.create!(branch:, name: "r#{i}-#{j}") } }
    end

    expect(ChangeSet.on(branch).order(:seq).pluck(:seq)).to eq((1..12).to_a)
    expect(Change.on(branch).distinct.pluck(:seq).sort).to eq((1..12).to_a)
    expect(branch.reload.head_seq).to eq(12)
  end

  it "keeps both branches gap-free under concurrent writes to two branches" do
    branches = [plan, fleet]

    in_threads(4) do |i|
      3.times do |j|
        described_class.write(mutation: nil, branches:) do
          branches.each { SpikeRack.create!(branch: it, name: "r#{i}-#{j}") }
        end
      end
    end

    branches.each do |branch|
      expect(ChangeSet.on(branch).order(:seq).pluck(:seq)).to eq((1..12).to_a)
      expect(Change.on(branch).pluck(:seq).sort).to eq((1..12).to_a)
    end
    expect(ChangeSet.on(plan).pluck(:actor_subject)).to all(eq("github_1"))
  end

  it "recovers two writers that lock two branches in opposite orders" do
    taken = [Queue.new, Queue.new]
    attempts = [0, 0]

    in_threads(2) do |i|
      order = i.zero? ? [plan, fleet] : [fleet, plan]
      described_class.write(mutation: nil, branches: order) do
        attempts[i] += 1
        first, second = order
        SpikeRack.create!(branch: first, name: "t#{i}")
        if attempts[i] == 1
          taken[i].push(true)
          taken[1 - i].pop
        end
        SpikeRack.create!(branch: second, name: "t#{i}")
      end
    end

    expect(attempts.sum).to eq(3)
    [plan, fleet].each { expect(ChangeSet.on(it).order(:seq).pluck(:seq)).to eq([1, 2]) }
  end
end
