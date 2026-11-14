# typed: strict
# frozen_string_literal: true

module Authn
  # Signing keys of each trusted issuer, kept until a token names a key the cached set lacks.
  module JwksCache
    # The least time between two fetches of one JWKS, so tokens naming unknown keys cannot make
    # every request fetch.
    REFETCH_INTERVAL = 60 #: Integer
    # How long a failed fetch answers for its JWKS, so an issuer outage is not fetched per request.
    FAILURE_INTERVAL = 10 #: Integer
    TIMEOUT = 5 #: Integer

    Entry = Data.define(:keys, :fetched_at)
    Failure = Data.define(:error, :failed_at)

    @entries = Concurrent::Map.new #: Concurrent::Map
    @failures = Concurrent::Map.new #: Concurrent::Map
    # One lock per URL, so a slow issuer holds up only its own tokens.
    @locks = Concurrent::Map.new #: Concurrent::Map

    # The signing key `kid` names in the JWKS at `url`, or nil when the JWKS has none. Raises
    # IssuerUnavailable when the JWKS has to be fetched and cannot be.
    #: (String url, String kid) -> JWT::JWK::KeyBase?
    def self.find(url, kid)
      entry = @entries[url] #: Entry?
      key = entry && find_in(entry, kid)
      return key if key

      lock = @locks.compute_if_absent(url) { Thread::Mutex.new } #: Thread::Mutex
      lock.synchronize do
        entry = @entries[url]
        entry = refresh(url) if entry.nil? || entry.fetched_at < monotonic_now - REFETCH_INTERVAL
        find_in(entry, kid)
      end
    end

    #: () -> void
    def self.clear
      @entries.clear
      @failures.clear
    end

    #: (Entry, String) -> JWT::JWK::KeyBase?
    private_class_method def self.find_in(entry, kid)
      entry.keys.find { |key| key[:kid] == kid && (key[:use].nil? || key[:use] == "sig") }
    end

    #: (String) -> Entry
    private_class_method def self.refresh(url)
      failure = @failures[url] #: Failure?
      if failure && failure.failed_at >= monotonic_now - FAILURE_INTERVAL
        raise IssuerUnavailable.new("jwks_unavailable", url:), cause: failure.error
      end

      begin
        keys = fetch(url)
      rescue StandardError => e
        @failures[url] = Failure.new(error: e, failed_at: monotonic_now)
        raise IssuerUnavailable.new("jwks_unavailable", url:)
      end
      @failures.delete(url)
      @entries[url] = Entry.new(keys:, fetched_at: monotonic_now)
    end

    #: (String) -> JWT::JWK::Set
    private_class_method def self.fetch(url)
      Must.be_a(URI(url), URI::HTTP)
      response = NetAid::Http.session(timeout: TIMEOUT).get(url, headers: {"accept" => "application/json"})
      response.raise_for_status
      JWT::JWK::Set.new(JSON.parse(response.to_s))
    end

    #: () -> Float
    private_class_method def self.monotonic_now = Process.clock_gettime(Process::CLOCK_MONOTONIC).to_f
  end
end
