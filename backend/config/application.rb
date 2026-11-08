# frozen_string_literal: true
# typed: strict

require_relative "boot"

require "rails"
# Pick the frameworks you want:
require "active_model/railtie"
require "active_job/railtie"
require "active_record/railtie"
# require "active_storage/engine"
require "action_controller/railtie"
# require "action_mailer/railtie"
# require "action_mailbox/engine"
# require "action_text/engine"
require "action_view/railtie"
# require "action_cable/engine"
# require "rails/test_unit/railtie"

# Require the gems listed in Gemfile, including any gems
# you've limited to :test, :development, or :production.
Bundler.require(*Rails.groups)

module Netaid
  class Application < Rails::Application
    # Initialize configuration defaults for originally generated Rails version.
    config.load_defaults 8.1

    # Please, add to the `ignore` list any other `lib` subdirectories that do
    # not contain `.rb` files, or that should not be reloaded or eager loaded.
    # Common ones are `templates`, `generators`, or `middleware`, for example.
    config.autoload_lib(ignore: %w[assets tasks dsql.rb])

    # Configuration for the application, engines, and railties goes here.
    #
    # These settings can be overridden in specific environments using the files
    # in config/environments, which are processed later.
    #
    # config.time_zone = "Central Time (US & Canada)"
    # config.eager_load_paths << Rails.root.join("extras")

    # Only loads a smaller set of middleware suitable for API only apps.
    # Middleware like session, flash, cookies can be added back manually.
    # Skip views, helpers and assets when generating a new resource.
    config.api_only = true

    # Completed carries everything Started does, so Started logs at debug.
    config.rails_semantic_logger.started = false

    # The browser holds its himari sign-in in an encrypted cookie session, which an API-only app
    # leaves out of the middleware stack.
    config.session_store :cookie_store, key: "__Host-netaid-sess", path: "/", secure: true, httponly: true, same_site: :lax
    config.middleware.use ActionDispatch::Cookies
    config.middleware.use config.session_store, config.session_options

    config.x.authn.himari_issuer = "https://idp.rubykaigi.net"
    config.x.authn.himari_client_ids = %w[net-aid net-aid-cli]
    # The confidential client the browser signs in through.
    config.x.authn.session_client_id = "net-aid"
    config.x.authn.session_client_secret = ENV.fetch("NET_AID_HIMARI_CLIENT_SECRET", nil)
    # The absolute cap himari puts on a sign-in through its refresh token's lifetime.
    config.x.authn.session_lifetime = 14.days
    config.x.authn.developer_sign_in = false
    config.x.authn.audience = "https://aid.rubykaigi.net"
    config.x.authn.github_actions_issuer = "https://token.actions.githubusercontent.com"
    # sts:GetWebIdentityToken issuers trusted for aws-iam callers, each a per-account
    # https://<id>.tokens.sts.global.api.aws.
    config.x.authn.aws_issuers = []
    # Merged once autoloading is up, as Authn::MachineRoles lives in app/.
    config.after_initialize do
      config.x.authn.machine_roles = Authn::MachineRoles.merge(
        {
          "github-actions" => {"repo:ruby-no-kai/rubykaigi-net:ref:refs/heads/master" => %w[exporter]},
          "aws-iam" => {}
        },
        # Same shape as JSON. A subject in both gets the union of their roles.
        ENV.fetch("NET_AID_MACHINE_ROLES", nil),
      )
    end
  end
end
