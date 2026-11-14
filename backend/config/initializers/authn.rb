# typed: strict
# frozen_string_literal: true

# Loaded outside the autoloader, as the session store is built during initialization.
require_relative "../../lib/net_aid/session_cookie_store"

Rails.application.configure do
  # The absolute cap himari puts on a sign-in through its refresh token's lifetime.
  config.x.authn.session_lifetime = 14.days

  # The browser holds its himari sign-in in an encrypted cookie session, which an API-only app
  # leaves out of the middleware stack.
  config.session_store NetAid::SessionCookieStore,
    key: "__Host-Http-netaid-sess", path: "/", secure: true, httponly: true, same_site: :lax,
    expire_after: config.x.authn.session_lifetime
  config.middleware.use ActionDispatch::Cookies
  config.middleware.use config.session_store, config.session_options

  config.x.authn.himari_issuer = "https://idp.rubykaigi.net"
  config.x.authn.himari_client_ids = %w[net-aid net-aid-cli]
  # The confidential client the browser signs in through.
  config.x.authn.session_client_id = "net-aid"
  config.x.authn.session_client_secret = ENV.fetch("NET_AID_HIMARI_CLIENT_SECRET", nil)
  config.x.authn.developer_sign_in = false
  config.x.authn.audience = "https://aid.rubykaigi.net"
  config.x.authn.github_actions_issuer = "https://token.actions.githubusercontent.com"
  # sts:GetWebIdentityToken issuers trusted for aws-sts callers, each a per-account
  # https://<id>.tokens.sts.global.api.aws.
  config.x.authn.aws_issuers = []

  case Rails.env
  when "development"
    # The confidential client of sign-ins to a local server.
    config.x.authn.himari_client_ids += %w[net-aid-local]
    config.x.authn.session_client_id = "net-aid-local"
    config.x.authn.developer_sign_in = true
  when "test"
    config.x.authn.session_client_secret = "test-secret"
    config.x.authn.developer_sign_in = true
  when "production"
    # Browser sign-in cannot work without it, so its absence fails boot.
    config.x.authn.session_client_secret = ENV.fetch("NET_AID_HIMARI_CLIENT_SECRET")
  end

  # Merged once autoloading is up, as Authn::MachineRoles lives in app/.
  config.after_initialize do
    config.x.authn.machine_roles = Authn::MachineRoles.merge(
      {
        "github-actions" => {"repo:ruby-no-kai/rubykaigi-net:ref:refs/heads/master" => %w[exporter]},
        "aws-sts" => {}
      },
      # Same shape as JSON. A subject in both gets the union of their roles.
      ENV.fetch("NET_AID_MACHINE_ROLES", nil),
    )
  end
end
