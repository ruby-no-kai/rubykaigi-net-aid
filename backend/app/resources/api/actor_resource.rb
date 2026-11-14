# typed: strict
# frozen_string_literal: true

module Api
  class ActorResource < Api::ApplicationResource
    with_protobuf Rk::NetAid::Actor do
      attributes :issuer, :subject, :display_name, :credential_id, :user_agent
    end
  end
end
