# typed: strict
# frozen_string_literal: true

require "connect_rpc_rails/protovalidate"
require "google/rpc/error_details_pb"
require "protobufable/problem"
require "protobufable/problem/information"

module Errors
  # An error the API answers as a problem, typed by a value of the ProblemType enum in
  # proto/rubykaigi/net_aid/problem.proto.
  class ApiError < StandardError
    include Protobufable::Problem::Typeable

    #: () -> String
    def self.problem_type_enum = "rubykaigi.net_aid.ProblemType"

    #: () -> String
    def self.problem_type_annotation = "rubykaigi.net_aid.problem_type"
  end

  # The request carries no credentials an action requires, or credentials that are refused.
  class Unauthenticated < ApiError
    problem_type :PROBLEM_TYPE_UNAUTHENTICATED
  end

  # An action other than GetViewer and RefreshSession was called without credentials.
  class SignInRequired < Unauthenticated; end

  # The Authorization header is present but carries no bearer token.
  class MalformedAuthorization < Unauthenticated; end

  # A bearer token was refused: an unknown issuer or key, a bad signature, or the wrong audience.
  class BearerTokenRefused < Unauthenticated; end

  # A bearer token is past its expiry.
  class BearerTokenExpired < Unauthenticated; end

  # RefreshSession was called by a request carrying no browser session.
  class NoSessionToRefresh < Unauthenticated; end

  # The session's himari access token has expired, and ViewerService.RefreshSession renews it.
  class SessionExpired < ApiError
    problem_type :PROBLEM_TYPE_SESSION_EXPIRED
  end

  # himari refused to refresh the session, which is cleared.
  class SessionRevoked < ApiError
    problem_type :PROBLEM_TYPE_SESSION_REVOKED
  end

  # The caller may not perform the action the request names.
  class PermissionDenied < ApiError
    problem_type :PROBLEM_TYPE_PERMISSION_DENIED
  end

  # No role of the caller permits the RPC's action.
  class ActionDenied < PermissionDenied; end

  # The resource the request names does not exist.
  class NotFound < ApiError
    problem_type :PROBLEM_TYPE_NOT_FOUND
  end

  # The request conflicts with the current state of the resource.
  class Conflict < ApiError
    problem_type :PROBLEM_TYPE_CONFLICT
  end

  # The resource is not in a state that allows the request.
  class FailedPrecondition < ApiError
    problem_type :PROBLEM_TYPE_FAILED_PRECONDITION
  end

  # The record the request would save fails validation.
  #
  # An error on an attribute that the request's Input message declares as a field is published as a
  # google.rpc.BadRequest violation of that field. Any other error, :base included, names no field
  # and concerns the request as a whole.
  class InvalidRecord < ApiError
    include Protobufable::Problem::Information

    problem_type :PROBLEM_TYPE_INVALID_RECORD

    # field_prefix is the path of the Input within the request, such as "input". With json_names,
    # fields are spelled as ProtoJSON spells them, for a request that came in as JSON.
    #: (record: ActiveRecord::Base, ?input_class: singleton(Google::Protobuf::AbstractMessage)?,
    #|  ?field_prefix: String, ?json_names: bool) -> void
    def initialize(record:, input_class: nil, field_prefix: "", json_names: false)
      @record = record #: ActiveRecord::Base
      @input_class = input_class #: singleton(Google::Protobuf::AbstractMessage)?
      @field_prefix = field_prefix #: String
      @json_names = json_names #: bool
      super(detail: record.errors.full_messages.join("; "))
    end

    #: () -> Array[untyped]
    def problem_information
      super + [Google::Rpc::BadRequest.new(field_violations:)]
    end

    #: () -> Array[Google::Rpc::BadRequest::FieldViolation]
    private def field_violations
      @record.errors.map do |error|
        field = field_path(error.attribute)
        Google::Rpc::BadRequest::FieldViolation.new(
          field: field || "",
          description: field ? error.message : error.full_message,
          reason: ConnectRpcRails::MessageValidatable.reason(error.type.to_s),
        )
      end
    end

    # The Input field an attribute of the same name maps to, or nil when the Input has none. An
    # autosaved association's attribute, such as :"contact.email", maps through the Input's message
    # field of the association's name. An association the Input names by ID, such as :plan, maps to
    # its `_id` field.
    #: (Symbol) -> String?
    private def field_path(attribute)
      return if attribute == :base

      descriptor = @input_class&.descriptor #: Google::Protobuf::Descriptor?
      names = attribute.to_s.split(".").map do |segment|
        field = descriptor&.lookup(segment) || descriptor&.lookup("#{segment}_id") #: Google::Protobuf::FieldDescriptor?
        return unless field

        subtype = field.subtype
        descriptor = (subtype if subtype.is_a?(Google::Protobuf::Descriptor))
        @json_names ? field.json_name : field.name
      end

      [*(@field_prefix unless @field_prefix.empty?), *names].join(".")
    end
  end

  # The server failed to answer the request.
  class Internal < ApiError
    problem_type :PROBLEM_TYPE_INTERNAL
  end

  # A service the server depends on could not be reached.
  class Unavailable < ApiError
    problem_type :PROBLEM_TYPE_UNAVAILABLE
  end

  # himari or another trusted issuer could not be reached to verify or renew credentials.
  class IssuerUnavailable < Unavailable; end
end
