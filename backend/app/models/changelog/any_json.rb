# typed: strict
# frozen_string_literal: true

# Messages stored as the ProtoJSON of a google.protobuf.Any, so a stored message names its own type.
module Changelog::AnyJson
  # Generated messages share no public base class to test against.
  #: (untyped) -> bool
  def self.message?(value)
    klass = value.class
    klass.respond_to?(:descriptor) && klass.descriptor.is_a?(Google::Protobuf::Descriptor)
  end

  #: (Google::Protobuf::AbstractMessage) -> Hash[String, untyped]
  def self.dump(message)
    JSON.parse(Google::Protobuf::Any.encode_json(Google::Protobuf::Any.pack(message), preserve_proto_fieldnames: true))
  end

  #: (untyped json) -> Google::Protobuf::AbstractMessage
  def self.load(json)
    unpack(Google::Protobuf::Any.decode_json(JSON.generate(json)))
  end

  #: (Google::Protobuf::Any) -> Google::Protobuf::AbstractMessage
  def self.unpack(any)
    type_name = any.type_url.rpartition("/").last
    descriptor = Google::Protobuf::DescriptorPool.generated_pool.lookup(type_name)
    raise ArgumentError, "no message type #{type_name.inspect} is loaded" unless descriptor.is_a?(Google::Protobuf::Descriptor)

    Must.because(any.unpack(descriptor.msgclass)) { "the Any holds the type it was looked up by" }
  end
end
