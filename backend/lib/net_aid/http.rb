# typed: strict
# frozen_string_literal: true

module NetAid
  # The HTTPX session outbound requests start from, naming the app in its User-Agent.
  module Http
    USER_AGENT = "rubykaigi-net-aid (+https://github.com/ruby-no-kai/rubykaigi-net-aid)" #: String

    #: (timeout: Integer) -> HTTPX::Session
    def self.session(timeout:)
      HTTPX.with(
        headers: {"user-agent" => USER_AGENT},
        timeout: {connect_timeout: timeout, request_timeout: timeout},
      )
    end
  end
end
