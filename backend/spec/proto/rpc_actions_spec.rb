# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Connect RPCs", type: :routing do
  pool = Google::Protobuf::DescriptorPool.generated_pool

  # Every service the app's .proto files declare, so a new service file is covered without listing it.
  service_names = Rails.root.glob("../proto/rubykaigi/**/*.proto").sort.flat_map do |path|
    source = path.read
    package = source[/^package\s+([\w.]+);/, 1]
    source.scan(/^service\s+(\w+)/).map { |(name)| "#{package}.#{name}" }
  end
  rpcs = service_names.flat_map do |service_name|
    service = pool.lookup(service_name) or raise "#{service_name} is not in the generated descriptor pool"
    service.map { [service_name, it] }
  end

  def actor_with(role) = Actor.new(issuer: "test", subject: "s", display_name: "", credential_id: "", user_agent: "", roles: [role])

  it "finds the services in proto/" do
    expect(service_names).to include("rubykaigi.net_aid.ViewerService")
  end

  rpcs.each do |service_name, method|
    describe "#{service_name}/#{method.name}" do
      let(:route) { Rails.application.routes.recognize_path("/#{service_name}/#{method.name}", method: :post) }
      let(:controller_class) { "#{route.fetch(:controller).camelize}Controller".constantize }
      let(:action) do
        controller = controller_class.new
        controller.action_name = route.fetch(:action)
        controller.send(:rpc_action_name_maybe)
      end

      it "is routed to an action serving it" do
        expect(route.fetch(:action)).not_to eq(ConnectRpcRails::Controller::UNKNOWN_METHOD_ACTION)
        expect(controller_class.action_methods).to include(route.fetch(:action))
        expect(controller_class.connect_rpcs.fetch(route.fetch(:action)).name).to eq(method.name)
      end

      it "is authorised as netaid:#{method.name}, which the public or some role is allowed" do
        expect(action).to eq("netaid:#{method.name}")

        allowed = Authz::Policy::PUBLIC_ACTIONS.include?(action) ||
          Authz::Policy::ROLE_STATEMENTS.keys.any? { Authz::Policy.permit?(actor_with(it), action) }
        expect(allowed).to be(true)
      end
    end
  end

  it "routes no RPC the protos do not declare" do
    declared = rpcs.map { |service_name, method| "/#{service_name}/#{method.name}" }
    routed = Rails.application.routes.routes.filter_map do |route|
      path = route.path.spec.to_s
      path if path.match?(%r{\A/[\w.]+/\w+\z}) && route.defaults[:action] != ConnectRpcRails::Controller::UNKNOWN_METHOD_ACTION
    end

    expect(routed - declared).to eq([])
  end

  it "names every RPC uniquely across services, as the authorisation action is the method name alone" do
    expect(rpcs.map { it.last.name }.tally.select { |_, count| count > 1 }.keys).to eq([])
  end
end
