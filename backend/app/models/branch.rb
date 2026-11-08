# typed: strict
# frozen_string_literal: true

# One line of history of one dataset. Its head_seq is the seq of its latest ChangeSet, and only
# Changelog advances it.
class Branch < ApplicationRecord
  include TypeidRails::Identifiable

  id_prefix "br"

  DATASET_PLAN = "DATASET_PLAN" #: String
  DATASET_FLEET = "DATASET_FLEET" #: String
  STATE_PREPARING = "STATE_PREPARING" #: String
  STATE_READY = "STATE_READY" #: String

  # The scope_key of every Fleet branch. Plan branches are scoped by their Episode's uuid.
  FLEET_SCOPE_KEY = "fleet" #: String
  MAIN_NAME = "main" #: String

  validates :dataset, inclusion: {in: ProtoEnum.names(Rk::NetAid::Branch::Dataset.descriptor)}
  validates :state, inclusion: {in: ProtoEnum.names(Rk::NetAid::Branch::State.descriptor)}
  validates :name, presence: true, length: {maximum: 64}
  validates :scope_key, presence: true
  validates :episode_id, presence: true, if: ->(branch) { branch.plan? }
  validates :episode_id, absence: true, if: ->(branch) { branch.fleet? }

  before_validation :assign_scope_key

  # The only writable Fleet branch.
  #: () -> Branch
  def self.fleet_main = find_by!(scope_key: FLEET_SCOPE_KEY, name: MAIN_NAME)

  #: () -> bool
  def plan? = dataset == DATASET_PLAN

  #: () -> bool
  def fleet? = dataset == DATASET_FLEET

  #: () -> bool
  def writable? = state == STATE_READY && !is_frozen

  # The opaque position of the branch at its latest ChangeSet.
  #: () -> String
  def cursor = Changelog::Cursor.encode(branch_id: id, seq: head_seq)

  #: () -> void
  private def assign_scope_key
    return if scope_key.present?

    self.scope_key = fleet? ? FLEET_SCOPE_KEY : episode_id.to_s
  end
end
