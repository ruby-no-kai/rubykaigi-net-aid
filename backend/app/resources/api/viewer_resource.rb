# typed: strict
# frozen_string_literal: true

module Api
  # The Viewer of a signed-in caller, built from its Actor.
  class ViewerResource < Api::ApplicationResource
    with_protobuf Rk::NetAid::Viewer do
      attribute(:signed_in) { true }
      one :actor, resource: Api::ActorResource, source: proc { self }
      attributes :roles
    end
  end
end
