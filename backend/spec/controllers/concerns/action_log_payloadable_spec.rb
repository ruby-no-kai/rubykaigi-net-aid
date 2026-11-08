# frozen_string_literal: true

require "rails_helper"

RSpec.describe ActionLogPayloadable, type: :controller do
  controller(Api::Viewer::ApplicationController) do
    def index
      render json: {}
    end

    def count
      RequestLogContext.increment(:changes_written)
      render json: {}
    end

    def problem
      raise Errors::PermissionDenied
    end

    def connect_error
      raise ConnectRpcRails::Error.new(:unavailable, "try later")
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
    routes.draw do
      get "index" => "api/viewer/application#index"
      get "count" => "api/viewer/application#count"
      get "problem" => "api/viewer/application#problem"
      get "connect_error" => "api/viewer/application#connect_error"
    end
  end

  it "adds request details" do
    request.headers["User-Agent"] = "RSpec"

    get :index

    expect(payload).to include(ip: "0.0.0.0", user_agent: "RSpec")
  end

  it "truncates the user agent" do
    request.headers["User-Agent"] = "a" * 300

    get :index

    expect(payload.fetch(:user_agent)).to eq("a" * 255)
  end

  it "adds the request log context counters" do
    get :count

    expect(payload).to include(changes_written: 1)
  end

  it "adds no error fields on success" do
    get :index

    expect(payload.keys).not_to include(:error_class, :problem_type, :connect_code)
  end

  it "adds the class, problem type and Connect code of a rescued problem" do
    get :problem

    expect(payload).to include(
      error_class: "Errors::PermissionDenied", problem_type: "permission-denied", connect_code: "permission_denied",
    )
  end

  it "adds the class and Connect code of a rescued Connect error" do
    get :connect_error

    expect(payload).to include(error_class: "ConnectRpcRails::Error", connect_code: "unavailable")
    expect(payload.keys).not_to include(:problem_type)
  end
end
