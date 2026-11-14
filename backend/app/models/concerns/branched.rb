# typed: strict
# frozen_string_literal: true

# A row of a Plan or Fleet table, which lives on one Branch and is written only inside a
# Changelog.write. Every save and destroy is recorded as a Change of the enclosing write.
#
#   class Site < ApplicationRecord
#     include Branched
#     id_prefix "site"
#     natural_key :slug
#     changelog_resource Api::SiteResource
#   end
#
# @requires_ancestor: ApplicationRecord
module Branched
  extend ActiveSupport::Concern
  include TypeidRails::Identifiable

  included do
    belongs_to :branch
    attr_readonly :branch_id, :lineage

    scope :on, ->(branch) { where(branch_id: branch.id) }

    before_validation :assign_branched_identity, on: :create
    before_save :record_changelog_touch
    after_save :record_changelog_save
    before_destroy :record_changelog_destroy_touch
    after_destroy :record_changelog_destroy
  end

  module ClassMethods
    # Also types lineage as a TypeID of the same prefix, as it is the id of the row's first
    # incarnation.
    #: (?String? prefix, ?strict: bool?, ?fuzzy: bool?) -> String?
    def id_prefix(prefix = nil, strict: nil, fuzzy: nil)
      #: self as singleton(ApplicationRecord)
      result = super
      attribute :lineage, build_typeid_type(prefix, strict:, fuzzy:) if prefix
      result
    end

    # Declares the columns that name a row within its branch, unique per branch.
    #: (*Symbol columns) -> void
    def natural_key(*columns)
      #: self as singleton(ApplicationRecord) & Branched::ClassMethods
      first, *rest = columns
      raise ArgumentError, "natural_key takes at least one column" unless first

      @natural_key_columns = columns #: Array[Symbol]?
      validates first, uniqueness: {scope: [:branch_id, *rest]}
    end

    #: () -> Array[Symbol]
    def natural_key_columns
      #: self as singleton(ApplicationRecord) & Branched::ClassMethods
      @natural_key_columns || raise(NotImplementedError, "#{name} declares no natural_key")
    end

    # Declares the Alba resource whose message is the image of a row in its Changes.
    #: (untyped resource) -> void
    def changelog_resource(resource)
      @changelog_resource = resource #: untyped
    end

    #: () -> untyped
    def changelog_resource_class
      #: self as singleton(ApplicationRecord) & Branched::ClassMethods
      @changelog_resource || raise(NotImplementedError, "#{name} declares no changelog_resource")
    end

    # Rows are created and never updated or destroyed.
    #: () -> void
    def insert_only!
      @insert_only = true #: bool?
    end

    #: () -> bool
    def insert_only? = @insert_only || false

    #: (Branch branch, *untyped values) -> untyped
    def find_by_natural_key!(branch, *values)
      #: self as singleton(ApplicationRecord) & Branched::ClassMethods
      columns = natural_key_columns
      raise ArgumentError, "#{name} is keyed by #{columns.join(", ")}" unless values.size == columns.size

      where(branch_id: branch.id).find_by!(columns.zip(values).to_h)
    end

    #: (Branch branch, String lineage) -> untyped
    def find_by_lineage(branch, lineage)
      #: self as singleton(ApplicationRecord)
      where(branch_id: branch.id).find_by(lineage:)
    end
  end

  #: () -> bool
  def readonly?
    super || (branched_class.insert_only? && persisted?)
  end

  # The row as its changelog_resource message, from its current attributes or, with in_database,
  # from the attributes last read from or written to the database.
  #: (?in_database: bool) -> Google::Protobuf::AbstractMessage
  def changelog_image(in_database: false)
    branched_class.changelog_resource_class.new(changelog_snapshot(in_database:)).as_protobuf
  end

  # A detached copy of the row, so a later in-memory change to this instance does not alter it.
  #: (?in_database: bool) -> Branched
  def changelog_snapshot(in_database: false)
    klass = branched_class
    values = klass.column_names.index_with do |name|
      value = in_database ? attribute_in_database(name) : self[name]
      klass.type_for_attribute(name).serialize(value)
    end
    case (snapshot = klass.instantiate(values))
    when Branched then snapshot
    else raise TypeError, "#{klass.name} instantiated a #{snapshot.class}"
    end
  end

  #: () -> String
  def changelog_branch_id = Must.because(self[:branch_id]) { "branch_id is validated by belongs_to :branch" }

  #: () -> void
  private def assign_branched_identity
    self.id ||= SecureRandom.uuid_v7
    self[:lineage] ||= id
  end

  #: () -> void
  private def record_changelog_touch
    return if persisted? && !has_changes_to_save?

    assign_branched_identity if new_record?
    context = Changelog.current
    self[:updated_seq] = context.seq_for(changelog_branch_id)
    context.track(self)
  end

  #: () -> void
  private def record_changelog_save
    Changelog.current.saved(self) if saved_changes?
  end

  #: () -> void
  private def record_changelog_destroy_touch
    context = Changelog.current
    context.seq_for(changelog_branch_id)
    context.track(self)
  end

  #: () -> void
  private def record_changelog_destroy
    Changelog.current.destroyed(self)
  end

  #: () -> (singleton(ApplicationRecord) & Branched::ClassMethods)
  def branched_class
    self.class #: as singleton(ApplicationRecord) & Branched::ClassMethods
  end
end
