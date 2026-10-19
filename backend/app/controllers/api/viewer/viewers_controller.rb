# typed: strict
# frozen_string_literal: true

module Api
  module Viewer
    class ViewersController < Api::Viewer::ApplicationController
      #: () -> Rk::NetAid::ViewerServiceGetViewerResponse
      def get_viewer
        Rk::NetAid::ViewerServiceGetViewerResponse.new(viewer: Rk::NetAid::Viewer.new(signed_in: false))
      end
    end
  end
end
