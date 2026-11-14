# typed: strict
# frozen_string_literal: true

module Auth
  # Signs a browser in through OmniAuth and out again. ActionController::Base supplies the CSRF
  # token that omniauth-rails_csrf_protection requires on the POST starting a sign-in.
  class SessionsController < ActionController::Base # rubocop:disable Rails/ApplicationController
    include ActionLogPayloadable

    # SameSite=Lax keeps the cookie off a cross-site POST, and the origin check refuses one.
    skip_forgery_protection only: :destroy
    before_action :verify_same_origin!, only: :destroy

    # Answers a page that POSTs to OmniAuth's request phase, keeping `return_to` for the callback.
    #: () -> void
    def new
      session[:return_to] = safe_return_to(params[:return_to])
      @sign_in_path = "/auth/#{params.require(:provider)}" #: String?
      render :new
    end

    #: () -> void
    def create
      auth = request.env["omniauth.auth"] or raise ActionController::BadRequest, "no OmniAuth result"
      return_to = safe_return_to(session[:return_to])
      browser_session = browser_session_for(auth)

      reset_session
      browser_session.store(session)
      redirect_to return_to
    rescue Authn::BearerVerifier::Failure => e
      RequestLogContext.add_fields(**{authn_failure: e.reason, authn_issuer: e.issuer&.truncate(255)}.compact)
      render :failure, status: :unauthorized
    rescue Authn::IssuerUnavailable => e
      RequestLogContext.add_fields(**e.log_fields)
      render :failure, status: :service_unavailable
    end

    #: () -> void
    def failure
      render :failure, status: :unauthorized
    end

    #: () -> void
    def destroy
      reset_session
      redirect_to "/", status: :see_other
    end

    # Only a path on this origin, starting with a single `/`, so sign-in is no open redirect.
    #: (untyped) -> String
    private def safe_return_to(value)
      return "/" unless value.is_a?(String) && value.match?(%r{\A/(?![/\\])[^\\[:cntrl:]]*\z})

      value
    end

    #: (OmniAuth::AuthHash) -> Authn::BrowserSession
    private def browser_session_for(auth)
      provider = auth.fetch("provider")
      case provider
      when "himari"
        credentials = auth.fetch("credentials")
        Authn::BrowserSession.sign_in(
          access_token: credentials.fetch("token"),
          refresh_token: credentials["refresh_token"],
          expires_at: Integer(credentials.fetch("expires_at")),
        )
      when "developer"
        subject = auth.fetch("uid").to_s
        info = auth.fetch("info")
        Authn::BrowserSession.developer(
          subject:, name: info["name"].presence || subject, roles: info["roles"].to_s.split(/[\s,]+/).compact_blank,
        )
      else
        raise ActionController::BadRequest, "unknown provider #{provider.inspect}"
      end
    end

    #: () -> void
    private def verify_same_origin!
      fetch_site = request.headers["Sec-Fetch-Site"]
      origin = request.headers["Origin"]
      return if (fetch_site.nil? || fetch_site == "same-origin") && (origin.nil? || origin == request.base_url)

      head :forbidden
    end
  end
end
