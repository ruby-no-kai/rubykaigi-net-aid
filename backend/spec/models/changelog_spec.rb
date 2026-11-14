# frozen_string_literal: true

require "rails_helper"

RSpec.describe Changelog, :committing, type: :model do
  let(:branch) { create_branch }
  let(:actor) { test_actor }

  before do
    Current.actor = actor
    allow(ApplicationRecord).to receive(:sleep)
  end

  def write(branches: [branch], mutation: nil, payload: nil, &block)
    payload ||= write_request(mutation) if mutation
    described_class.write(mutation:, branches:, rpc: (ChangelogSpike::RPC if mutation), payload:, &block)
  end

  def response(device_id = "") = ChangelogSpike::WriteResponse.new(device_id:)

  describe "seq" do
    it "takes the next seq of the branch per write" do
      3.times { |i| write { SpikeRack.create!(branch:, name: "r#{i}") } }

      expect(ChangeSet.on(branch).order(:seq).pluck(:seq)).to eq([1, 2, 3])
      expect(branch.reload.head_seq).to eq(3)
      expect(SpikeRack.on(branch).order(:name).pluck(:updated_seq)).to eq([1, 2, 3])
    end

    it "takes no seq on a declared branch the block does not write" do
      other = create_branch(name: "snapshot")

      result = write(branches: [branch, other]) { SpikeRack.create!(branch:, name: "r") }

      expect(other.reload.head_seq).to eq(0)
      expect(ChangeSet.on(other)).to be_empty
      expect(result.cursors.keys).to eq([branch.id])
    end

    it "writes one ChangeSet per touched branch in one transaction" do
      plan = create_branch(dataset: Branch::DATASET_PLAN)

      result = write(branches: [plan, branch]) do
        SpikeRack.create!(branch: plan, name: "p")
        SpikeRack.create!(branch:, name: "f")
      end

      expect(ChangeSet.pluck(:branch_id, :seq)).to contain_exactly([plan.id, 1], [branch.id, 1])
      expect(result.cursors).to eq(
        plan.id => Changelog::Cursor.encode(branch_id: plan.id, seq: 1),
        branch.id => Changelog::Cursor.encode(branch_id: branch.id, seq: 1),
      )
    end

    it "keeps the seq gap-free when a ChangeSet ends up with no Changes" do
      write do
        rack = SpikeRack.create!(branch:, name: "r")
        rack.destroy!
      end

      expect(ChangeSet.on(branch).pluck(:seq)).to eq([1])
      expect(Change.on(branch)).to be_empty
    end
  end

  describe "branches" do
    it "refuses a frozen branch" do
      branch.update!(is_frozen: true)

      expect { write { SpikeRack.create!(branch:, name: "r") } }.to raise_error(Errors::BranchNotWritable)
      expect(branch.reload.head_seq).to eq(0)
      expect(SpikeRack.count).to eq(0)
    end

    it "refuses a branch still being prepared" do
      branch.update!(state: Branch::STATE_PREPARING)

      expect { write { SpikeRack.create!(branch:, name: "r") } }.to raise_error(Errors::BranchNotReady)
    end

    it "raises on a write to an undeclared branch" do
      other = create_branch(name: "other")

      expect { write { SpikeRack.create!(branch: other, name: "r") } }.to raise_error(Changelog::UndeclaredBranch)
      expect(SpikeRack.count).to eq(0)
    end

    it "does not nest" do
      expect { write { write { nil } } }.to raise_error(ArgumentError, /does not nest/)
    end

    it "refuses to run inside an open transaction, journalling nothing" do
      header = mutation_header

      expect do
        ApplicationRecord.retryable_transaction do
          write(mutation: header) { raise Errors::FailedPrecondition }
        end
      end.to raise_error(Changelog::TransactionOpen)
      expect(Mutation.count).to eq(0)
      expect(described_class).not_to be_writing
    end
  end

  describe "Changes" do
    it "records an upsert with the after-image of a created row" do
      rack = nil
      write { rack = SpikeRack.create!(branch:, name: "r") }

      change = Change.on(branch).sole
      expect(change).to have_attributes(
        seq: 1, ordinal: 1, op: Change::OP_UPSERT, entity_type: "rubykaigi.net_aid.spike.Rack",
        entity_id: TypeidRails.to_uuid(rack.id), entity_lineage: TypeidRails.to_uuid(rack.id), changed_fields: [],
      )
      expect(ChangelogSpike::RackMessage.decode_json(change.data.to_json)).to eq(
        ChangelogSpike::RackMessage.new(id: rack.id, lineage: rack.id, name: "r"),
      )
    end

    it "coalesces a create and an update into one upsert" do
      write do
        device = SpikeDevice.create!(branch:, name: "d")
        device.update!(position_x: 3)
      end

      change = Change.on(branch).sole
      expect(change).to have_attributes(op: Change::OP_UPSERT, changed_fields: [])
      expect(change.data).to include("position" => {"x" => 3})
    end

    it "lists the top-level fields an update changed, comparing composite fields by value" do
      device = nil
      write { device = SpikeDevice.create!(branch:, name: "d", position_x: 1) }

      write do
        reloaded = SpikeDevice.find(device.id)
        reloaded.update!(position_y: 2)
        reloaded.update!(name: "e")
      end

      expect(Change.on(branch).find_by(seq: 2).changed_fields).to eq(%w[name position])
    end

    it "lists no field for a composite field set back to its value" do
      device = nil
      write { device = SpikeDevice.create!(branch:, name: "d", position_x: 1) }

      write do
        reloaded = SpikeDevice.find(device.id)
        reloaded.update!(position_x: 2)
        reloaded.update!(position_x: 1, name: "e")
      end

      expect(Change.on(branch).find_by(seq: 2).changed_fields).to eq(%w[name])
    end

    it "records a delete carrying the before-image of an updated then destroyed row" do
      rack = nil
      write { rack = SpikeRack.create!(branch:, name: "before") }

      write do
        reloaded = SpikeRack.find(rack.id)
        reloaded.update!(name: "after")
        reloaded.destroy!
      end

      change = Change.on(branch).find_by(seq: 2)
      expect(change).to have_attributes(op: Change::OP_DELETE, changed_fields: [])
      expect(change.data).to include("name" => "before")
    end

    it "orders Changes by first touch so a parent precedes its children" do
      write do
        rack = SpikeRack.create!(branch:, name: "r")
        device = SpikeDevice.create!(branch:, name: "d", spike_rack: rack)
        rack.update!(name: "renamed")
        device.update!(name: "e")
      end

      expect(Change.on(branch).order(:ordinal).pluck(:entity_type, :ordinal)).to eq(
        [["rubykaigi.net_aid.spike.Rack", 1], ["rubykaigi.net_aid.spike.Device", 2]],
      )
    end

    it "records nothing for a create aborted by a later callback" do
      saved = nil
      write { saved = SpikeDevice.new(branch:, name: "d", abort_save: true).save }

      expect(saved).to be(false)
      expect(Change.on(branch)).to be_empty
      expect(ChangeSet.on(branch).pluck(:seq)).to eq([1])
    end

    it "records nothing for an update or destroy aborted by a later callback" do
      device = nil
      write { device = SpikeDevice.create!(branch:, name: "d") }

      write do
        reloaded = SpikeDevice.find(device.id)
        reloaded.abort_save = true
        reloaded.abort_destroy = true
        reloaded.update(name: "e")
        reloaded.destroy
      end

      expect(Change.on(branch).where(seq: 2)).to be_empty
      expect(SpikeDevice.find(device.id).name).to eq("d")
    end

    it "keeps the last completed save of a row whose later save is aborted" do
      write do
        device = SpikeDevice.create!(branch:, name: "d")
        device.abort_save = true
        device.update(name: "e")
      end

      expect(Change.on(branch).sole.data).to include("name" => "d")
    end

    it "skips a save that changes nothing" do
      rack = nil
      write { rack = SpikeRack.create!(branch:, name: "r") }

      write { SpikeRack.find(rack.id).save! }

      expect(branch.reload.head_seq).to eq(1)
    end

    it "records the actor on the ChangeSet" do
      write { SpikeRack.create!(branch:, name: "r") }

      expect(ChangeSet.sole).to have_attributes(
        actor_issuer: "himari", actor_subject: "github_1", actor_display_name: "octocat",
        actor_credential_id: "cred-1", actor_user_agent: "rspec", mutation_id: nil,
      )
    end
  end

  describe "reading history" do
    it "follows the feed after a cursor" do
      cursors = 3.times.map { |i| write { SpikeRack.create!(branch:, name: "r#{i}") }.cursors.fetch(branch.id) }

      expect(Change.on(branch).after(cursors.first).pluck(:seq)).to eq([2, 3])
      expect(Change.on(branch).after(cursors.last)).to be_empty
    end

    it "lists one row's history newest first" do
      rack = nil
      write { rack = SpikeRack.create!(branch:, name: "a") }
      write { SpikeRack.find(rack.id).update!(name: "b") }

      expect(Change.on(branch).for_entity(rack.id).map { it.data.fetch("name") }).to eq(%w[b a])
    end
  end

  describe "the Mutation journal" do
    let(:header) { mutation_header(client_time: Google::Protobuf::Timestamp.new(seconds: 1_800_000_000)) }

    it "journals an applied Mutation with its response" do
      result = write(mutation: header) do
        response(SpikeDevice.create!(branch:, name: "d").id)
      end

      mutation = Mutation.sole
      expect(mutation).to have_attributes(
        id: header.mutation_id, rpc: ChangelogSpike::RPC, outcome: Mutation::OUTCOME_APPLIED,
        actor_issuer: "himari", actor_subject: "github_1", client_time: Time.zone.at(1_800_000_000),
      )
      expect(mutation.payload_message).to eq(write_request(header))
      expect(mutation.response_message).to eq(result.response)
      expect(ChangeSet.sole.mutation_id).to eq(header.mutation_id)
      expect(result.mutation_id).to eq(header.mutation_id)
    end

    it "records the seqs of the header's cursors and leaves out those it cannot read" do
      header.base_cursors[branch.id] = Changelog::Cursor.encode(branch_id: branch.id, seq: 7)
      header.base_cursors["br_other"] = "v0.garbage"

      write(mutation: header) { response }

      expect(Mutation.sole.base_seqs).to eq(TypeidRails.to_uuid(branch.id) => 7)
    end

    it "replays an applied Mutation without running the block again" do
      first = write(mutation: header) { response(SpikeDevice.create!(branch:, name: "d").id) }
      runs = 0

      replayed = write(mutation: header) do
        runs += 1
        response("other")
      end

      expect(runs).to eq(0)
      expect(replayed).to eq(first)
      expect(SpikeDevice.count).to eq(1)
    end

    it "replays a payload re-encoded by the client" do
      write(mutation: header) { response("d") }
      reencoded = ChangelogSpike::WriteRequest.decode(ChangelogSpike::WriteRequest.encode(write_request(header)))

      expect(write(mutation: header, payload: reencoded) { response("other") }.response).to eq(response("d"))
    end

    it "journals a rejected Mutation with its problem and writes nothing else" do
      expect do
        write(mutation: header) do
          SpikeRack.create!(branch:, name: "r")
          raise Errors::FailedPrecondition.new(detail: "no")
        end
      end.to raise_error(Errors::FailedPrecondition)

      mutation = Mutation.sole
      expect(mutation.outcome).to eq(Mutation::OUTCOME_REJECTED)
      expect(mutation.error_details).to have_attributes(
        type: "https://aid.rubykaigi.net/problems/failed-precondition", status: 412, detail: "no",
      )
      expect(SpikeRack.count).to eq(0)
      expect(branch.reload.head_seq).to eq(0)
    end

    it "journals a RecordInvalid as the invalid-record problem on the request's input" do
      expect { write(mutation: header) { SpikeDevice.create!(branch:, name: "") } }.to raise_error(ActiveRecord::RecordInvalid)

      details = Mutation.sole.error_details
      expect(details.type).to eq("https://aid.rubykaigi.net/problems/invalid-record")
      violations = details.information.map { it.unpack(Google::Rpc::BadRequest) }.sole.field_violations
      expect(violations.map { [it.field, it.reason] }).to eq([%w[input.name BLANK]])
    end

    it "replays a rejected Mutation with the stored problem" do
      expect { write(mutation: header) { raise Errors::FailedPrecondition.new(detail: "no") } }.to raise_error(Errors::FailedPrecondition)

      expect { write(mutation: header) { response } }.to raise_error(Changelog::ReplayedRejection) { |error|
        expect(error.to_problem).to have_attributes(
          type: "https://aid.rubykaigi.net/problems/failed-precondition", status: 412, detail: "no", title: "Failed Precondition",
        )
      }
    end

    it "replays the field violations of a rejected Mutation" do
      expect { write(mutation: header) { SpikeDevice.create!(branch:, name: "") } }.to raise_error(ActiveRecord::RecordInvalid)

      expect { write(mutation: header) { response } }.to raise_error(Changelog::ReplayedRejection) { |error|
        expect(error.problem_information.sole.field_violations.map(&:field)).to eq(%w[input.name])
      }
    end

    it "journals a write to a frozen branch as rejected" do
      branch.update!(is_frozen: true)

      expect { write(mutation: header) { SpikeRack.create!(branch:, name: "r") } }.to raise_error(Errors::BranchFrozen)
      expect(Mutation.sole.outcome).to eq(Mutation::OUTCOME_REJECTED)
    end

    it "journals nothing for a write to a branch still being prepared, so its retry applies once ready" do
      branch.update!(state: Branch::STATE_PREPARING)
      expect { write(mutation: header) { SpikeRack.create!(branch:, name: "r") } }.to raise_error(Errors::BranchNotReady)
      expect(Mutation.count).to eq(0)

      branch.update!(state: Branch::STATE_READY)
      write(mutation: header) { response(SpikeRack.create!(branch:, name: "r").id) }
      expect(Mutation.sole.outcome).to eq(Mutation::OUTCOME_APPLIED)
    end

    [
      Errors::Internal.new(detail: "down"),
      Errors::ResyncRequired.new(detail: "stale"),
      Errors::PermissionDenied.new(detail: "no"),
    ].each do |error|
      it "journals nothing for #{error.class}, a problem that is not an Errors::Rejection" do
        expect { write(mutation: header) { raise error } }.to raise_error(error.class)

        expect(Mutation.count).to eq(0)
      end
    end

    it "journals a NotFound as rejected" do
      expect { write(mutation: header) { raise Errors::NotFound } }.to raise_error(Errors::NotFound)

      expect(Mutation.sole.outcome).to eq(Mutation::OUTCOME_REJECTED)
    end

    it "journals nothing for a failure that is not a rejection" do
      expect { write(mutation: header) { raise "bug" } }.to raise_error(RuntimeError)

      expect(Mutation.count).to eq(0)
    end

    it "raises Conflict when a mutation_id is reused for another payload" do
      write(mutation: header) { response }

      expect { write(mutation: header, payload: write_request(header, name: "other")) { response } }
        .to raise_error(Errors::MutationIdReused)
      expect(Mutation.count).to eq(1)
    end

    it "raises Conflict when a mutation_id is reused by another actor" do
      write(mutation: header) { response }
      Current.actor = test_actor(subject: "github_2")

      expect { write(mutation: header) { response } }.to raise_error(Errors::MutationIdReused)
    end

    it "answers a duplicate that loses the race with the winner's outcome" do
      winner = nil
      loser = write(mutation: header) do
        winner ||= Thread.new do
          ActiveRecord::Base.connection_pool.with_connection do
            Current.actor = actor
            write(mutation: header) { response("winner") }
          end
        end.value
        response("loser")
      end

      expect(loser.response).to eq(response("winner"))
      expect(Mutation.sole.response_message).to eq(response("winner"))
    end

    it "requires the rpc and payload it journals" do
      expect { described_class.write(mutation: header, branches: [branch]) { response } }.to raise_error(ArgumentError)
    end
  end

  describe "unique-key races" do
    let(:header) { mutation_header }
    let(:device_id) { TypeidRails.generate(prefix: "sdev", version: 7) }

    def commit_device_elsewhere
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          Current.actor = actor
          described_class.write(mutation: nil, branches: [branch]) { SpikeDevice.create!(branch:, id: device_id, name: "other") }
        end
      end.join
    end

    it "retries once so the block can reject the row it now sees" do
      attempts = 0

      expect do
        write(mutation: header) do
          attempts += 1
          raise Errors::FailedPrecondition.new(detail: "taken") if SpikeDevice.exists?(device_id)

          commit_device_elsewhere if attempts == 1
          SpikeDevice.create!(branch:, id: device_id, name: "d")
        end
      end.to raise_error(Errors::FailedPrecondition)

      expect(attempts).to eq(2)
      expect(Mutation.sole.outcome).to eq(Mutation::OUTCOME_REJECTED)
    end

    it "answers DuplicateRow, journalling nothing, when the retry meets the violation again" do
      attempts = 0

      expect do
        write(mutation: header) do
          attempts += 1
          commit_device_elsewhere if attempts == 1
          SpikeDevice.create!(branch:, id: device_id, name: "d")
        end
      end.to raise_error(Errors::DuplicateRow) { |error| expect(error.to_problem.status).to eq(409) }

      expect(attempts).to eq(2)
      expect(Mutation.count).to eq(0)
      expect(SpikeDevice.sole.name).to eq("other")
    end
  end

  describe "OCC conflicts" do
    it "retries the block on a conflict" do
      attempts = 0
      write do
        attempts += 1
        SpikeRack.create!(branch:, name: "r#{attempts}")
        trigger_dsql_conflict! if attempts == 1
      end

      expect(attempts).to eq(2)
      expect(SpikeRack.pluck(:name)).to eq(%w[r2])
      expect(ChangeSet.pluck(:seq)).to eq([1])
      expect(RequestLogContext.counters[:occ_retries]).to eq(1)
    end

    it "retries the block when PostgreSQL picks it as a deadlock victim" do
      attempts = 0
      write do
        attempts += 1
        SpikeRack.create!(branch:, name: "r#{attempts}")
        raise ActiveRecord::Deadlocked, "deadlock detected" if attempts == 1
      end

      expect(attempts).to eq(2)
      expect(SpikeRack.pluck(:name)).to eq(%w[r2])
    end

    it "journals nothing when the retries run out" do
      expect { write(mutation: mutation_header) { trigger_dsql_conflict! } }.to raise_error(ActiveRecord::SerializationFailure)

      expect(Mutation.count).to eq(0)
      expect(RequestLogContext.counters[:occ_retries]).to eq(4)
    end
  end

  describe "logging" do
    it "reports the mutation and the rows written" do
      header = mutation_header
      write(mutation: header) do
        SpikeRack.create!(branch:, name: "r")
        SpikeRack.create!(branch:, name: "s")
        response
      end

      expect(RequestLogContext.log_payload).to include(
        mutation_id: header.mutation_id, mutation_outcome: Mutation::OUTCOME_APPLIED, change_sets_written: 1, changes_written: 2,
      )
    end

    it "reports a rejection" do
      expect { write(mutation: mutation_header) { raise Errors::FailedPrecondition } }.to raise_error(Errors::FailedPrecondition)

      expect(RequestLogContext.log_payload).to include(mutation_outcome: Mutation::OUTCOME_REJECTED)
    end

    it "reports a write to a branch still being prepared as failed" do
      header = mutation_header
      branch.update!(state: Branch::STATE_PREPARING)

      expect { write(mutation: header) { SpikeRack.create!(branch:, name: "r") } }.to raise_error(Errors::BranchNotReady)

      expect(RequestLogContext.log_payload).to include(mutation_id: header.mutation_id, mutation_outcome: "failed")
    end

    it "reports a unique-key race as failed" do
      header = mutation_header

      expect { write(mutation: header) { raise ActiveRecord::RecordNotUnique, "duplicate key" } }.to raise_error(Errors::DuplicateRow)

      expect(RequestLogContext.log_payload).to include(mutation_id: header.mutation_id, mutation_outcome: "failed")
    end

    it "reports a failure that is not a rejection as failed" do
      header = mutation_header

      expect { write(mutation: header) { raise "bug" } }.to raise_error(RuntimeError)

      expect(RequestLogContext.log_payload).to include(mutation_id: header.mutation_id, mutation_outcome: "failed")
    end

    it "reports a reused mutation_id" do
      header = mutation_header
      write(mutation: header) { response }
      RequestLogContext.reset

      expect { write(mutation: header, payload: write_request(header, name: "other")) { response } }.to raise_error(Errors::MutationIdReused)

      expect(RequestLogContext.log_payload).to eq(mutation_id: header.mutation_id, mutation_outcome: "reused")
    end

    it "reports a replay" do
      header = mutation_header
      write(mutation: header) { response }
      RequestLogContext.reset

      write(mutation: header) { response }

      expect(RequestLogContext.log_payload).to eq(mutation_id: header.mutation_id, mutation_outcome: "replayed")
    end
  end
end
