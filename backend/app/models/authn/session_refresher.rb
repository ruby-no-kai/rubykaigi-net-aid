# typed: strict
# frozen_string_literal: true

module Authn
  # Renews a browser session's himari tokens with its refresh token. himari re-runs its rules on a
  # refresh, so role changes and removals take effect here.
  class SessionRefresher
    TIMEOUT = 10 #: Integer

    # himari refused the refresh, or the session holds nothing to refresh with. The session is left
    # as it is, as a refresh in another tab may have just rewritten it.
    class Revoked < Errors::ApiError
      problem_type :PROBLEM_TYPE_SESSION_REVOKED

      #: (String) -> void
      def initialize(message)
        super(message, detail: "The session could not be refreshed. Sign in again.")
      end

      #: () -> Hash[Symbol, untyped]
      def log_fields = {authn_failure: :session_revoked}
    end

    # Raises Issuer::IssuerUnavailable when himari cannot be reached or answers other than a grant or a
    # refusal.
    #: (BrowserSession) -> BrowserSession
    def refresh(browser_session)
      refresh_token = browser_session.refresh_token or raise Revoked, "the session holds no refresh token"

      grant = request_grant(refresh_token)
      refreshed = browser_session.refreshed(
        access_token: grant.fetch("access_token"),
        refresh_token: grant["refresh_token"],
        expires_at: Time.now.to_i + Integer(grant.fetch("expires_in")),
      )
      raise Revoked, "the refreshed session names another subject" unless refreshed.actor.subject == browser_session.actor.subject

      refreshed
    rescue BearerVerifier::Failure => e
      raise Revoked, "the refreshed access token is refused: #{e.reason}"
    end

    #: (String) -> Hash[String, untyped]
    private def request_grant(refresh_token)
      authn = Rails.configuration.x.authn
      uri = Must.be_a(URI("#{authn.himari_issuer}/public/oidc/token"), URI::HTTP)
      response = NetAid::Http.session(timeout: TIMEOUT)
        .plugin(:basic_auth)
        .basic_auth(authn.session_client_id, authn.session_client_secret.to_s)
        .post(uri.to_s, form: {"grant_type" => "refresh_token", "refresh_token" => refresh_token})
      if response.is_a?(HTTPX::ErrorResponse)
        raise Issuer::IssuerUnavailable.new(:refresh_unavailable, url: uri.to_s), cause: response.error
      end

      body = parse_body(response)
      return body if (200..299).cover?(response.status) && body.is_a?(Hash)
      raise Revoked, "himari refused the refresh" if body.is_a?(Hash) && body["error"] == "invalid_grant"

      raise Issuer::IssuerUnavailable.new(:refresh_unavailable, url: uri.to_s, answer: "HTTP #{response.status}")
    end

    #: (HTTPX::Response) -> untyped
    private def parse_body(response)
      JSON.parse(response.body.to_s)
    rescue JSON::ParserError
      nil
    end
  end
end
