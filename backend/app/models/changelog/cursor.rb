# typed: strict
# frozen_string_literal: true

require "base64"

# The opaque position of a branch that clients store and echo back. Clients never interpret it, so
# its encoding can change with a new version prefix.
class Changelog::Cursor
  VERSION_PREFIX = "v1." #: String
  PATTERN = /\A(?<branch>\h{8}-\h{4}-\h{4}-\h{4}-\h{12}):(?<seq>0|[1-9]\d{0,18})\z/ #: Regexp

  #: Integer
  attr_reader :seq

  #: (branch_id: String, seq: Integer) -> String
  def self.encode(branch_id:, seq:)
    "#{VERSION_PREFIX}#{Base64.urlsafe_encode64("#{branch_uuid(branch_id)}:#{seq}", padding: false)}"
  end

  # The seq a cursor of the branch encodes. Raises Errors::ResyncRequired for a cursor of another
  # version or another branch.
  #: (String cursor, branch_id: String) -> Integer
  def self.decode(cursor, branch_id:)
    parsed = parse(cursor)
    raise Errors::ResyncRequired.new(detail: "The cursor belongs to another branch.") unless parsed.branch_uuid == branch_uuid(branch_id)

    parsed.seq
  end

  # Raises Errors::ResyncRequired for a cursor this server does not understand.
  #: (String cursor) -> Changelog::Cursor
  def self.parse(cursor)
    payload = cursor.delete_prefix(VERSION_PREFIX)
    raise unknown_cursor if payload == cursor

    match = PATTERN.match(Base64.urlsafe_decode64(payload))
    raise unknown_cursor unless match

    new(branch_uuid: match[:branch].to_s.downcase, seq: Integer(match[:seq], 10))
  rescue ArgumentError
    raise unknown_cursor
  end

  #: (String) -> String
  private_class_method def self.branch_uuid(branch_id)
    TypeidRails.to_uuid(branch_id, expected_prefix: "br") || branch_id.downcase
  end

  #: () -> Errors::ResyncRequired
  private_class_method def self.unknown_cursor
    Errors::ResyncRequired.new(detail: "The cursor is not one this server understands.")
  end

  #: (branch_uuid: String, seq: Integer) -> void
  def initialize(branch_uuid:, seq:)
    @branch_uuid = branch_uuid #: String
    @seq = seq #: Integer
  end

  #: String
  attr_reader :branch_uuid
end
