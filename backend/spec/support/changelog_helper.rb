# frozen_string_literal: true

require "google/protobuf/descriptor_pb"

# Toy Branched models for specs of the changelog, backed by test-only tables and messages built at
# load time, as no domain entity exists to exercise it with.
module ChangelogSpike
  PACKAGE = "rubykaigi.net_aid.spike"

  TABLES = {
    "spike_racks" => <<~SQL,
      id uuid primary key,
      branch_id uuid not null,
      lineage uuid not null,
      updated_seq bigint not null,
      name varchar(64) not null,
      created_at timestamp(6) with time zone not null default now(),
      updated_at timestamp(6) with time zone not null default now()
    SQL
    "spike_devices" => <<~SQL,
      id uuid primary key,
      branch_id uuid not null,
      lineage uuid not null,
      updated_seq bigint not null,
      spike_rack_id uuid,
      name varchar(64) not null,
      position_x integer not null default 0,
      position_y integer not null default 0,
      created_at timestamp(6) with time zone not null default now(),
      updated_at timestamp(6) with time zone not null default now()
    SQL
    "spike_scans" => <<~SQL
      id uuid primary key,
      branch_id uuid not null,
      lineage uuid not null,
      updated_seq bigint not null,
      tag varchar(64) not null,
      created_at timestamp(6) with time zone not null default now(),
      updated_at timestamp(6) with time zone not null default now()
    SQL
  }.freeze

  INDEXES = [
    "create unique index if not exists idx_spike_racks_branch_lineage on spike_racks (branch_id, lineage)",
    "create unique index if not exists idx_spike_racks_branch_name on spike_racks (branch_id, name)",
    "create unique index if not exists idx_spike_devices_branch_lineage on spike_devices (branch_id, lineage)"
  ].freeze

  def self.create_tables!
    connection = ActiveRecord::Base.connection
    TABLES.each do |table, columns|
      connection.drop_table(table) if connection.table_exists?(table)
      connection.execute("create table #{table} (#{columns})")
    end
    INDEXES.each { connection.execute(it) }
  end

  def self.field(name, number, type, type_name: nil, label: :LABEL_OPTIONAL)
    Google::Protobuf::FieldDescriptorProto.new(name:, number:, type:, type_name:, label:, json_name: name.camelize(:lower))
  end

  def self.message(name, *fields)
    Google::Protobuf::DescriptorProto.new(name:, field: fields)
  end

  def self.register_messages!
    file = Google::Protobuf::FileDescriptorProto.new(
      name: "rubykaigi/net_aid/spike.proto",
      package: PACKAGE,
      syntax: "proto3",
      dependency: ["rubykaigi/net_aid/mutation.proto"],
      message_type: [
        message("Rack", field("id", 1, :TYPE_STRING), field("lineage", 2, :TYPE_STRING), field("name", 3, :TYPE_STRING)),
        message("Position", field("x", 1, :TYPE_INT32), field("y", 2, :TYPE_INT32)),
        message(
          "Device",
          field("id", 1, :TYPE_STRING), field("lineage", 2, :TYPE_STRING), field("rack_id", 3, :TYPE_STRING),
          field("name", 4, :TYPE_STRING), field("position", 5, :TYPE_MESSAGE, type_name: ".#{PACKAGE}.Position"),
        ),
        message("Scan", field("id", 1, :TYPE_STRING), field("tag", 2, :TYPE_STRING)),
        message("DeviceInput", field("name", 1, :TYPE_STRING)),
        message(
          "WriteRequest",
          field("header", 1, :TYPE_MESSAGE, type_name: ".rubykaigi.net_aid.MutationHeader"),
          field("input", 2, :TYPE_MESSAGE, type_name: ".#{PACKAGE}.DeviceInput"),
        ),
        message("WriteResponse", field("device_id", 1, :TYPE_STRING))
      ],
    )
    Google::Protobuf::DescriptorPool.generated_pool.add_serialized_file(Google::Protobuf::FileDescriptorProto.encode(file))
  end

  def self.msgclass(name) = Google::Protobuf::DescriptorPool.generated_pool.lookup("#{PACKAGE}.#{name}").msgclass

  RPC = "#{PACKAGE}.SpikeService/Write".freeze

  create_tables!
  register_messages!

  RackMessage = msgclass("Rack")
  PositionMessage = msgclass("Position")
  DeviceMessage = msgclass("Device")
  ScanMessage = msgclass("Scan")
  WriteRequest = msgclass("WriteRequest")
  WriteResponse = msgclass("WriteResponse")
  DeviceInput = msgclass("DeviceInput")
end

class SpikeRackResource < Api::ApplicationResource
  with_protobuf ChangelogSpike::RackMessage do
    attributes :id, :lineage, :name
  end
end

class SpikeDeviceResource < Api::ApplicationResource
  with_protobuf ChangelogSpike::DeviceMessage do
    attributes :id, :lineage, :name
    attribute(:rack_id) { |device| device.spike_rack_id.to_s }
    attribute(:position) { |device| ChangelogSpike::PositionMessage.new(x: device.position_x, y: device.position_y) }
  end
end

class SpikeScanResource < Api::ApplicationResource
  with_protobuf ChangelogSpike::ScanMessage do
    attributes :id, :tag
  end
end

class SpikeRack < ApplicationRecord
  include Branched

  id_prefix "srack"
  natural_key :name
  changelog_resource SpikeRackResource

  has_many :spike_devices, dependent: :destroy
end

class SpikeDevice < ApplicationRecord
  include Branched

  id_prefix "sdev"
  changelog_resource SpikeDeviceResource

  belongs_to :spike_rack, optional: true
  validates :name, presence: true

  attr_accessor :abort_save, :abort_destroy

  before_save { throw :abort if abort_save }
  before_destroy { throw :abort if abort_destroy }
end

class SpikeScan < ApplicationRecord
  include Branched

  id_prefix "sscan"
  insert_only!
  changelog_resource SpikeScanResource
end

module ChangelogHelper
  CLEANED_TABLES = %w[branches change_sets changes mutations spike_racks spike_devices spike_scans].freeze

  def create_branch(dataset: Branch::DATASET_FLEET, name: Branch::MAIN_NAME, **attributes)
    episode_id = SecureRandom.uuid if dataset == Branch::DATASET_PLAN
    Branch.create!(dataset:, name:, state: Branch::STATE_READY, episode_id:, **attributes)
  end

  def test_actor(subject: "github_1")
    Actor.new(issuer: "himari", subject:, display_name: "octocat", credential_id: "cred-1", user_agent: "rspec", roles: %w[operator])
  end

  def mutation_header(mutation_id: TypeidRails.generate(prefix: "mut", version: 7), **fields)
    Rk::NetAid::MutationHeader.new(mutation_id:, **fields)
  end

  def write_request(header, name: "es-tra-01")
    ChangelogSpike::WriteRequest.new(header:, input: ChangelogSpike::DeviceInput.new(name:))
  end

  # Fails the enclosing transaction as DSQL does on an OCC conflict, which local PostgreSQL cannot
  # produce.
  def trigger_dsql_conflict!
    ActiveRecord::Base.connection.execute(<<~SQL)
      do $$ begin
        raise exception 'change conflicts with another transaction, please retry: (OC001)' using errcode = 'serialization_failure';
      end $$
    SQL
  end
end

RSpec.shared_context "with committing writes" do
  self.use_transactional_tests = false

  after do
    connection = ActiveRecord::Base.connection
    ChangelogHelper::CLEANED_TABLES.each { connection.execute("delete from #{it}") }
  end
end

RSpec.configure do |config|
  config.include ChangelogHelper
  config.include_context "with committing writes", :committing
end
