# typed: strict
# frozen_string_literal: true

# Enum columns hold the full name of a proto enum value, such as STATE_READY.
module ProtoEnum
  # Every value name of the enum except its zero value, which is never stored.
  #: (Google::Protobuf::EnumDescriptor) -> Array[String]
  def self.names(descriptor)
    names = [] #: Array[String]
    descriptor.each { |name, number| names << name.to_s unless number.zero? }
    names
  end
end
