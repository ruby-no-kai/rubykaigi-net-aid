# typed: strict
# frozen_string_literal: true

module NetAid
  # The encrypted cookie session store, writing the cookie only when the session's contents change,
  # so a request that merely read the session never puts back tokens a concurrent RefreshSession
  # rotated. Every write carries the store's expire_after.
  class SessionCookieStore < ActionDispatch::Session::CookieStore
    #: (ActionDispatch::Request, untyped, Hash[Symbol, untyped]) -> bool
    private def commit_session?(req, session, options)
      return false unless super

      written = session.to_hash #: Hash[String, untyped]
      read = get_cookie(req) || {} #: Hash[String, untyped]
      contents(written) != contents(read)
    end

    # Rack drops nil values on a write and the store adds a session_id, neither of which changes
    # what the session holds.
    #: (Hash[String, untyped]) -> Hash[String, untyped]
    private def contents(data)
      data.reject { |key, value| value.nil? || key == "session_id" }
    end
  end
end
