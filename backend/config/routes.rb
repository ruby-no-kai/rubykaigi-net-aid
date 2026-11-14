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
    rpc "RefreshSession" => "api/viewer/viewers"
  end

  # OmniAuth answers POST /auth/<provider> and the callback before routing, then hands the callback
  # to the app with the result.
  providers = ["himari", *("developer" if Rails.configuration.x.authn.developer_sign_in)]
  scope "auth", controller: "auth/sessions" do
    get ":provider", action: :new, constraints: {provider: Regexp.union(providers)}, as: :sign_in
    get ":provider/callback", action: :create, constraints: {provider: Regexp.union(providers)}
    get "failure", action: :failure
    post "sign_out", action: :destroy, as: :sign_out
  end
end
