# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Routed RPCs", type: :routing do
  # Every route to a Connect RPC, as [controller class, action name].
  def routed_rpcs
    Rails.application.routes.routes.filter_map do |route|
      controller = route.defaults[:controller]
      next unless controller

      klass = "#{controller.camelize}Controller".safe_constantize
      next unless klass.is_a?(Class) && klass < ConnectRpcRails::Controller && klass.connect_rpcs.key?(route.defaults[:action])

      [klass, route.defaults[:action]]
    end
  end

  def action_of(klass, action_name)
    controller = klass.new
    controller.action_name = action_name
    controller.send(:rpc_action_name_maybe)
  end

  it "routes at least one RPC" do
    expect(routed_rpcs).not_to be_empty
  end

  it "has an authorisation action that some role allows for every RPC" do
    locked_out = routed_rpcs.map { action_of(*it) }.reject do |action|
      Authz::Policy::ROLE_STATEMENTS.keys.any? do |role|
        Authz::Policy.permit?(Actor.new(issuer: "test", subject: "s", display_name: "", credential_id: "", user_agent: "", roles: [role]), action)
      end
    end

    expect(locked_out).to eq([])
  end

  it "names every RPC uniquely across services, as the authorisation action is the method name alone" do
    actions = routed_rpcs.map { action_of(*it) }
    expect(actions.tally.select { |_, count| count > 1 }.keys).to eq([])
  end
end
