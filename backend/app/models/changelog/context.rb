# typed: strict
# frozen_string_literal: true

# The state of one attempt of a Changelog.write: the seq taken on each branch it wrote, and every
# row it touched, in the order first touched.
class Changelog::Context
  BUMP_SQL = <<~SQL #: String
    update branches set head_seq = head_seq + 1, updated_at = now() where id = ?
    returning head_seq, state, is_frozen
  SQL

  # Counts of what #flush! inserted.
  Stats = Data.define(:change_sets, :changes)

  #: (branches: Array[Branch]) -> void
  def initialize(branches:)
    @declared_branch_ids = branches.map(&:id).to_set #: Set[String]
    @seqs = {} #: Hash[String, Integer]
    @entries = {} #: Hash[[String, String], Changelog::Entry]
  end

  # The seq this write uses on a branch, taken on the first call for that branch. Taking it updates
  # the branch's row, which serialises writers of one branch.
  #: (String branch_id) -> Integer
  def seq_for(branch_id)
    @seqs[branch_id] ||= bump(branch_id)
  end

  # Cursors of the branches this write produced a ChangeSet on, keyed by branch id.
  #: () -> Hash[String, String]
  def cursors
    @seqs.to_h { |branch_id, seq| [branch_id, Changelog::Cursor.encode(branch_id:, seq:)] }
  end

  # Records a row on its first touch in this write, capturing its image as it was in the database.
  #: (Branched) -> void
  def track(record)
    @entries[entry_key(record)] ||= Changelog::Entry.new(
      ordinal: @entries.size,
      record:,
      before: (record.changelog_image(in_database: true) unless record.new_record?),
    )
  end

  #: (Branched) -> void
  def saved(record) = entry_for(record).saved(record)

  #: (Branched) -> void
  def destroyed(record) = entry_for(record).destroyed

  # Inserts unsaved rows of one Branched model in bulk, with an upsert Change each. Raises
  # ActiveRecord::RecordInvalid on the first row that fails validation. The instances stay unsaved,
  # so later changes to these rows go through records loaded afresh.
  #: (Array[Branched]) -> void
  def insert_all!(records)
    first = records.first
    return unless first

    model = first.branched_class
    raise ArgumentError, "insert_all! takes rows of one model" unless records.all? { it.instance_of?(model) }
    raise ArgumentError, "insert_all! takes unsaved rows" unless records.all?(&:new_record?)

    now = Time.current
    rows = records.map { insert_row(it, now) }
    model.insert_all!(rows)

    records.each do |record|
      track(record)
      saved(record)
    end
  end

  # Inserts the ChangeSets and Changes of this write.
  #: (actor: Actor, mutation_id: String?) -> Changelog::Context::Stats
  def flush!(actor:, mutation_id:)
    change_sets = @seqs.map do |branch_id, seq|
      {branch_id:, seq:, mutation_id:, **Changelog.actor_columns(actor)}
    end
    ChangeSet.insert_all!(change_sets) unless change_sets.empty?

    changes = change_rows
    Change.insert_all!(changes) unless changes.empty?

    Stats.new(change_sets: change_sets.size, changes: changes.size)
  end

  #: () -> Array[Hash[Symbol, untyped]]
  private def change_rows
    ordinals = {} #: Hash[String, Integer]
    @entries.values.sort_by(&:ordinal).filter_map do |entry|
      next unless entry.written?

      branch_id = entry.branch_id
      ordinal = ordinals.fetch(branch_id, 0) + 1
      ordinals[branch_id] = ordinal
      entry.change_row(seq: @seqs.fetch(branch_id), ordinal:)
    end
  end

  #: (Branched, ActiveSupport::TimeWithZone) -> Hash[String, untyped]
  private def insert_row(record, now)
    record.validate!
    record[:updated_seq] = seq_for(record.changelog_branch_id)
    record[:created_at] ||= now if record.has_attribute?(:created_at)
    record[:updated_at] ||= now if record.has_attribute?(:updated_at)
    record.attributes.slice(*record.branched_class.column_names)
  end

  #: (String) -> Integer
  private def bump(branch_id)
    raise Changelog::UndeclaredBranch, "#{branch_id} is written but not declared in branches:" unless @declared_branch_ids.include?(branch_id)

    uuid = TypeidRails.to_uuid(branch_id, expected_prefix: "br")
    row = Branch.connection.select_one(Branch.sanitize_sql_array([BUMP_SQL, uuid]), "Changelog bump")
    raise ActiveRecord::RecordNotFound.new("No branch #{branch_id}", "Branch", "id", branch_id) unless row

    if ActiveModel::Type::Boolean.new.cast(row.fetch("is_frozen"))
      raise Errors::BranchFrozen.new(detail: "The branch #{branch_id} is frozen.")
    end
    unless row.fetch("state") == Branch::STATE_READY
      raise Errors::BranchNotReady.new(detail: "The branch #{branch_id} is not ready for writes yet.")
    end

    Integer(row.fetch("head_seq"))
  end

  #: (Branched) -> Changelog::Entry
  private def entry_for(record)
    @entries.fetch(entry_key(record)) { raise ArgumentError, "#{record.class.name} #{record.id} was not touched in this write" }
  end

  #: (Branched) -> [String, String]
  private def entry_key(record)
    [record.branched_class.base_class.name.to_s, record.id.to_s]
  end
end
