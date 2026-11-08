# typed: strict
# frozen_string_literal: true

require "connect_rpc_rails/protovalidate"
require "protobufable/connect"

module Api
  # Base of the controllers serving the Connect services in proto/, one action per RPC. Each service
  # has a base controller of its own under Api::<Service>, calling `connect_service`.
  class ApplicationController < ActionController::API
    include ConnectRpcRails::Controller
    include ConnectRpcRails::MessageValidatable
    include Protobufable::Connect::ProblemRescuable
    include ConnectForgeryProtection
    include ConnectRequestInfo
    include HandlerLogTaggable
    include ActionLogPayloadable

    wrap_parameters false

    rescue_from ActiveRecord::RecordInvalid, with: :render_invalid_record
    # OCC conflicts that outlast retryable_transaction's retries; the client retries later.
    map_connect_errors(ActiveRecord::SerializationFailure => :unavailable)

    before_action :verify_connect_request_origin!
    include Authenticatable
    include Authorizable

    # A classified exception's message can quote internals, so only the status text goes out.
    #: (Exception) -> ConnectRpcRails::Error
    private def connect_error_for(exception)
      error = super
      return error if exception.is_a?(ConnectRpcRails::Error) || exception.is_a?(Problem::Detailable)

      message = Rack::Utils::HTTP_STATUS_CODES.fetch(error.http_status) { error.code.to_s }
      ConnectRpcRails::Error.new(error.code, message, details: error.details)
    end

    # A Create or Update request carries its <Resource>Input in a field named `input`, whose fields
    # the record's attributes map onto by name.
    #: (ActiveRecord::RecordInvalid) -> void
    private def render_invalid_record(error)
      json_names = ConnectRpcRails::Codec::Json == connect_codec
      input_field = connect_request.class.descriptor.lookup("input") #: Google::Protobuf::FieldDescriptor?
      field_prefix = input_field ? (json_names ? input_field.json_name : input_field.name) : ""

      render_problem_detailable(Errors::InvalidRecord.new(
        record: error.record,
        input_class: input_field&.subtype&.msgclass,
        field_prefix:,
        json_names:,
      ))
    end
  end
end
