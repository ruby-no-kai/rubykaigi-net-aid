# typed: strict
# frozen_string_literal: true

# One touched row in a ChangeSet, with the row's protojson image in `data`: its after-image on an
# upsert, its last state on a delete.
class Change < ApplicationRecord
  include TypeidRails::Identifiable

  id_prefix "c"

  OP_UPSERT = "OP_UPSERT" #: String
  OP_DELETE = "OP_DELETE" #: String

  # Rows of any Branched model, so the column takes a TypeID of any prefix and reads back a UUID.
  attribute :entity_id, TypeidRails::PolymorphicType.new
  attribute :entity_lineage, TypeidRails::PolymorphicType.new

  belongs_to :branch

  scope :on, ->(branch) { where(branch_id: branch.id) }
  # One row's history, newest first.
  scope :for_entity, ->(id) { where(entity_id: id).order(seq: :desc, ordinal: :desc) }

  # The sync feed after a cursor, in the order a client applies it. Chained after .on, whose
  # branch the cursor must belong to.
  #: (String cursor) -> ActiveRecord::Relation
  def self.after(cursor)
    relation = all
    branch_id = relation.where_values_hash["branch_id"]
    raise ArgumentError, "Change.after is chained after Change.on(branch)" unless branch_id.is_a?(String)

    relation.where(seq: (Changelog::Cursor.decode(cursor, branch_id:) + 1)..).order(:seq, :ordinal)
  end

  # Only Changelog.write inserts Changes, and nothing updates them.
  #: () -> bool
  def readonly? = super || !Changelog.writing?
end
