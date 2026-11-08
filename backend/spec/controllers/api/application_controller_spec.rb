# frozen_string_literal: true

require "rails_helper"

RSpec.describe Api::ApplicationController, type: :controller do
  controller(Api::Viewer::ApplicationController) do
    def conflict
      raise ActiveRecord::SerializationFailure, "change conflicts with another transaction, please retry: (OC001)"
    end
  end

  before do
    routes.draw { post "conflict" => "api/viewer/application#conflict" }
  end

  it "answers OCC conflicts that outlast the retries as unavailable" do
    request.headers["Connect-Protocol-Version"] = "1"

    post :conflict

    expect(response).to have_http_status(:service_unavailable)
    body = JSON.parse(response.body)
    expect(body).to include("code" => "unavailable", "message" => "Service Unavailable")
  end
end
