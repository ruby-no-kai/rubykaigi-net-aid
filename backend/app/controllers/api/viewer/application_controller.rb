# typed: strict
# frozen_string_literal: true

module Api
  module Viewer
    # Base of the controllers serving ViewerService.
    class ApplicationController < Api::ApplicationController
      connect_service "rubykaigi.net_aid.ViewerService"
    end
  end
end
