# typed: strict
# frozen_string_literal: true

module Api
  module Viewer
    class ViewersController < Api::Viewer::ApplicationController
      #: () -> Rk::NetAid::ViewerServiceGetViewerResponse
      def get_viewer
        Rk::NetAid::ViewerServiceGetViewerResponse.new(viewer: viewer_message)
      end

      #: () -> Rk::NetAid::Viewer
      private def viewer_message
        actor = Current.actor_maybe
        actor ? Api::ViewerResource.new(actor).as_protobuf : Rk::NetAid::Viewer.new(signed_in: false)
      end
    end
  end
end
