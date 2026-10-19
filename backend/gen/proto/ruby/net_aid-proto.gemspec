# frozen_string_literal: true

Gem::Specification.new do |spec|
  spec.name = "net_aid-proto"
  spec.version = "0.0.0"
  spec.authors = [ "RubyKaigi" ]
  spec.summary = "rubykaigi-net-aid Protocol Buffers messages, generated from proto/"
  spec.homepage = "https://github.com/ruby-no-kai/rubykaigi-net-aid"

  # Read from disk rather than git so freshly generated files load before they are committed.
  spec.files = [
    File.basename(__FILE__),
    *Dir.glob([ "lib/**/*.rb", "sig/**/*.rbs" ], base: __dir__)
  ]
  spec.require_paths = [ "lib" ]

  # The generated code targets the runtime of the protoc release pinned in mise.toml.
  spec.add_dependency("google-protobuf", "~> 4.36")
end
