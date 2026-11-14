# frozen_string_literal: true

require "rails_helper"

RSpec.describe Changelog::Cursor do
  let(:branch_id) { TypeidRails.generate(prefix: "br") }

  it "round-trips a seq of a branch" do
    cursor = described_class.encode(branch_id:, seq: 42)

    expect(cursor).to start_with("v1.")
    expect(described_class.decode(cursor, branch_id:)).to eq(42)
    expect(described_class.decode(cursor, branch_id: TypeidRails.to_uuid(branch_id))).to eq(42)
  end

  it "requires a resync for a cursor of another branch" do
    cursor = described_class.encode(branch_id:, seq: 1)

    expect { described_class.decode(cursor, branch_id: TypeidRails.generate(prefix: "br")) }.to raise_error(Errors::ResyncRequired)
  end

  it "requires a resync for an unknown version" do
    cursor = described_class.encode(branch_id:, seq: 1).sub("v1.", "v2.")

    expect { described_class.decode(cursor, branch_id:) }.to raise_error(Errors::ResyncRequired)
  end

  it "requires a resync for a malformed cursor" do
    ["v1.", "v1.!!!", "v1.#{Base64.urlsafe_encode64("nope:1", padding: false)}", "42"].each do |cursor|
      expect { described_class.decode(cursor, branch_id:) }.to raise_error(Errors::ResyncRequired)
    end
  end

  it "reads the largest bigint seq and requires a resync for one beyond it" do
    uuid = TypeidRails.to_uuid(branch_id)
    encode = ->(seq) { "v1.#{Base64.urlsafe_encode64("#{uuid}:#{seq}", padding: false)}" }

    expect(described_class.decode(encode.call((2**63) - 1), branch_id:)).to eq((2**63) - 1)
    expect { described_class.decode(encode.call(2**63), branch_id:) }.to raise_error(Errors::ResyncRequired)
    expect { described_class.decode(encode.call(9_999_999_999_999_999_999), branch_id:) }.to raise_error(Errors::ResyncRequired)
  end
end
