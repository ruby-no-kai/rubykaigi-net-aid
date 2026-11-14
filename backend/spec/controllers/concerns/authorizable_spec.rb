# frozen_string_literal: true

require "rails_helper"

RSpec.describe Authorizable, type: :controller do
  controller(Api::Viewer::ApplicationController) do
    def index
      authorize!("netaid:CreateSite")
      render json: {}
    end
  end

  let(:payload) { {} }

  around do |example|
    subscriber = ActiveSupport::Notifications.subscribe("process_action.action_controller") do |event|
      payload.replace(event.payload)
    end
    example.run
  ensure
    ActiveSupport::Notifications.unsubscribe(subscriber)
  end

  before do
    stub_trusted_jwks
    routes.draw { get "index" => "api/viewer/application#index" }
  end

  def call_as(token)
    request.headers["Authorization"] = "Bearer #{token}" if token
    get :index
  end

  it "lets a caller whose role allows the action through" do
    call_as(himari_access_token(roles: %w[operator]))

    expect(response).to have_http_status(:ok)
    expect(payload.keys).not_to include(:authz_denied_action)
  end

  it "denies a caller whose role does not allow the action" do
    call_as(himari_access_token(roles: %w[viewer]))

    expect(response).to have_http_status(:forbidden)
    expect(payload).to include(error_class: "Errors::ActionDenied", problem_type: :"permission-denied", authz_denied_action: "netaid:CreateSite")
  end

  it "denies a caller with no role" do
    call_as(himari_access_token(roles: nil))

    expect(response).to have_http_status(:forbidden)
  end

  it "answers an anonymous caller as unauthenticated" do
    call_as(nil)

    expect(response).to have_http_status(:unauthorized)
    expect(payload).to include(error_class: "Errors::SignInRequired", problem_type: :unauthenticated, authz_denied_action: "netaid:CreateSite")
  end
end
