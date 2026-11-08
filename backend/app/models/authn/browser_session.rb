# typed: strict
# frozen_string_literal: true

module Authn
  # A browser's sign-in, as its cookie session holds it: the Actor, its roles, and the himari
  # tokens that renew them.
  class BrowserSession
    SESSION_KEY = "authn" #: String
    # A session written in another shape reads as signed out.
    FORMAT = 1 #: Integer
    DEVELOPER_ISSUER = "developer" #: String
    DEVELOPER_LIFETIME = 3600 #: Integer

    #: (ActionDispatch::Request::Session) -> BrowserSession?
    def self.load(session)
      data = session[SESSION_KEY]
      return unless data.is_a?(Hash) && data["format"] == FORMAT

      new(
        actor: Actor.new(
          issuer: data.fetch("issuer"),
          subject: data.fetch("subject"),
          display_name: data.fetch("display_name"),
          credential_id: data.fetch("credential_id"),
          user_agent: "",
          roles: data.fetch("roles"),
        ),
        expires_at: data.fetch("expires_at"),
        access_token: data["access_token"],
        refresh_token: data["refresh_token"],
      )
    end

    # A himari sign-in, whose Actor and roles come from the access token.
    #: (access_token: String, refresh_token: String?, expires_at: Integer) -> BrowserSession
    def self.sign_in(access_token:, refresh_token:, expires_at:)
      actor = verify(access_token).with(credential_id: SecureRandom.uuid)
      new(actor:, expires_at:, access_token:, refresh_token:)
    end

    # A development sign-in through OmniAuth's developer strategy, which has nothing to refresh.
    #: (subject: String, name: String, roles: Array[String]) -> BrowserSession
    def self.developer(subject:, name:, roles:)
      actor = Actor.new(
        issuer: DEVELOPER_ISSUER, subject:, display_name: name, credential_id: SecureRandom.uuid, user_agent: "", roles:,
      )
      new(actor:, expires_at: Time.now.to_i + DEVELOPER_LIFETIME, access_token: nil, refresh_token: nil)
    end

    # Raises BearerVerifier::Failure unless the token is a himari access token for the client the
    # browser signs in through.
    #: (String) -> Actor
    def self.verify(access_token)
      authn = Rails.configuration.x.authn
      issuer = Issuers::Himari.new(url: authn.himari_issuer, audiences: [authn.session_client_id])
      BearerVerifier.new(issuers: {issuer.url => issuer}).verify(access_token, user_agent: "")
    end

    #: Actor
    attr_reader :actor

    # When the access token expires, in seconds since the epoch.
    #: Integer
    attr_reader :expires_at

    #: String?
    attr_reader :access_token

    #: String?
    attr_reader :refresh_token

    #: (actor: Actor, expires_at: Integer, access_token: String?, refresh_token: String?) -> void
    def initialize(actor:, expires_at:, access_token:, refresh_token:)
      @actor = actor
      @expires_at = expires_at
      @access_token = access_token
      @refresh_token = refresh_token
    end

    #: () -> bool
    def expired? = Time.now.to_i >= expires_at

    # The session after a refresh, keeping the sign-in's credential_id, and its refresh token
    # unless himari rotated it.
    #: (access_token: String, refresh_token: String?, expires_at: Integer) -> BrowserSession
    def refreshed(access_token:, refresh_token:, expires_at:)
      self.class.new(
        actor: self.class.verify(access_token).with(credential_id: actor.credential_id),
        expires_at:,
        access_token:,
        refresh_token: refresh_token || self.refresh_token,
      )
    end

    #: (user_agent: String) -> Actor
    def actor_for(user_agent:) = actor.with(user_agent:)

    #: (ActionDispatch::Request::Session) -> void
    def store(session)
      session[SESSION_KEY] = {
        "format" => FORMAT,
        "issuer" => actor.issuer,
        "subject" => actor.subject,
        "display_name" => actor.display_name,
        "credential_id" => actor.credential_id,
        "roles" => actor.roles,
        "expires_at" => expires_at,
        "access_token" => access_token,
        "refresh_token" => refresh_token
      }.compact
    end
  end
end
