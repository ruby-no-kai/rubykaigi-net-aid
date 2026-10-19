# typed: strict
# frozen_string_literal: true

Rails.application.routes.draw do
  # Reveal health status on /up that returns 200 if the app boots with no exceptions, otherwise 500.
  # Can be used by load balancers and uptime monitors to verify that the app is live.
  get "up" => "rails/health#show", as: :rails_health_check

  # One connect_service block per service, as the first block for a service shadows any later one.
  # Outside any namespace, since connect_rpc_rails checks controller paths without its module.
  connect_service "rubykaigi.net_aid.ViewerService" do
    rpc "GetViewer" => "api/viewer/viewers"
  end
end
