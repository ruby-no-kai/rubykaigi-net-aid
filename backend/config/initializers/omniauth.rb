# typed: strict
# frozen_string_literal: true

Rails.application.config.middleware.use OmniAuth::Builder do
  #: self as OmniAuth::Builder
  authn = Rails.configuration.x.authn

  provider :himari,
    site: authn.himari_issuer,
    client_id: authn.session_client_id,
    client_secret: authn.session_client_secret,
    scope: "openid offline_access",
    pkce: true

  if authn.developer_sign_in
    provider :developer, fields: %i[subject name roles], uid_field: :subject
  end
end

OmniAuth.config.logger = Rails.logger
