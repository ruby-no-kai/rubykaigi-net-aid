# typed: strict
# frozen_string_literal: true

# One per branch per committed Changelog.write, numbered by a seq that is gap-free per branch.
class ChangeSet < ApplicationRecord
  include TypeidRails::Identifiable

  id_prefix "cs"

  belongs_to :branch
  belongs_to :mutation, optional: true

  scope :on, ->(branch) { where(branch_id: branch.id) }

  # Only Changelog.write inserts ChangeSets, and nothing updates them.
  #: () -> bool
  def readonly? = super || !Changelog.writing?
end
