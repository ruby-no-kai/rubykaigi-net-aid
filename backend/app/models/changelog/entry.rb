# typed: strict
# frozen_string_literal: true

# One row touched by a Changelog.write, coalesced into the single Change it produces.
class Changelog::Entry
  #: Integer
  attr_reader :ordinal

  #: String
  attr_reader :branch_id

  # The row's image when the write first touched it, or nil for a row the write created.
  #: (ordinal: Integer, record: Branched, before: Google::Protobuf::AbstractMessage?) -> void
  def initialize(ordinal:, record:, before:)
    @ordinal = ordinal
    @branch_id = record.changelog_branch_id #: String
    @id = record.id.to_s #: String
    @lineage = record.read_attribute(:lineage).to_s #: String
    @before = before
    @after = nil #: Branched?
    @destroyed = false #: bool
  end

  #: (Branched) -> void
  def saved(record)
    @after = record.changelog_snapshot
    @destroyed = false
  end

  #: () -> void
  def destroyed
    @after = nil
    @destroyed = true
  end

  # The changes row this entry inserts, or nil for a row that produces no Change.
  #: (seq: Integer, ordinal: Integer) -> Hash[Symbol, untyped]?
  def change_row(seq:, ordinal:)
    image, op, changed_fields = image_op_and_changed_fields
    return unless image

    {
      branch_id: @branch_id,
      seq:,
      entity_type: image.class.descriptor.name,
      entity_id: @id,
      entity_lineage: @lineage,
      ordinal:,
      op:,
      data: JSON.parse(image.class.encode_json(image, preserve_proto_fieldnames: true)),
      changed_fields:
    }
  end

  # False for a row created and destroyed in the same write, and for a row whose every save or
  # destroy in the write was aborted by a later callback.
  #: () -> bool
  def written? = @destroyed ? !@before.nil? : !@after.nil?

  #: () -> ([Google::Protobuf::AbstractMessage, String, Array[String]] | [nil, nil, nil])
  private def image_op_and_changed_fields
    before = @before
    if @destroyed
      return [nil, nil, nil] unless before

      return [before, Change::OP_DELETE, []]
    end

    saved = @after
    return [nil, nil, nil] unless saved

    after = saved.changelog_image
    [after, Change::OP_UPSERT, before ? changed_fields(before, after) : []]
  end

  #: (Google::Protobuf::AbstractMessage, Google::Protobuf::AbstractMessage) -> Array[String]
  private def changed_fields(before, after)
    after.class.descriptor.filter_map do |field|
      field.name if field.get(before) != field.get(after)
    end
  end
end
