# typed: strict
# frozen_string_literal: true

module Api
  module Viewer
    class ViewersController < Api::Viewer::ApplicationController
      # An expired session is what RefreshSession renews, so it reads the session itself.
      skip_before_action :authenticate, only: :refresh_session

      #: () -> Rk::NetAid::ViewerServiceGetViewerResponse
      def get_viewer
        Rk::NetAid::ViewerServiceGetViewerResponse.new(viewer: viewer_message)
      end

      #: () -> Rk::NetAid::ViewerServiceRefreshSessionResponse
      def refresh_session
        browser_session = current_browser_session_maybe
        raise Errors::NoSessionToRefresh.new(detail: "The request carries no session to refresh.") unless browser_session

        refreshed = Authn::SessionRefresher.new.refresh(browser_session)
        store_browser_session(refreshed)
        authenticated_as(refreshed.actor_for(user_agent: request_user_agent))

        Rk::NetAid::ViewerServiceRefreshSessionResponse.new(viewer: viewer_message)
      end

      #: () -> Rk::NetAid::Viewer
      private def viewer_message
        actor = current_actor_maybe
        actor ? Api::ViewerResource.new(actor).as_protobuf : Rk::NetAid::Viewer.new
      end
    end
  end
end
