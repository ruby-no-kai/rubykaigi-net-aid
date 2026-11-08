# typed: strict
# frozen_string_literal: true

require "net/http"

module Authn
  # Signing keys of each trusted issuer, kept until a token names a key the cached set lacks.
  module JwksCache
    # The least time between two fetches of one JWKS, so tokens naming unknown keys cannot make
    # every request fetch.
    REFETCH_INTERVAL = 60 #: Integer
    TIMEOUT = 5 #: Integer

    Entry = Data.define(:keys, :fetched_at)

    @entries = {} #: Hash[String, Entry]
    @lock = Thread::Mutex.new #: Thread::Mutex

    # The signing key `kid` names in the JWKS at `url`, or nil when the JWKS has none.
    #: (String url, String kid) -> JWT::JWK::KeyBase?
    def self.find(url, kid)
      entry = @entries[url]
      key = entry && find_in(entry, kid)
      return key if key

      @lock.synchronize do
        entry = @entries[url]
        if entry.nil? || entry.fetched_at < monotonic_now - REFETCH_INTERVAL
          entry = Entry.new(keys: fetch(url), fetched_at: monotonic_now)
          @entries[url] = entry
        end
        find_in(entry, kid)
      end
    end

    #: () -> void
    def self.clear
      @lock.synchronize { @entries.clear }
    end

    #: (Entry, String) -> JWT::JWK::KeyBase?
    private_class_method def self.find_in(entry, kid)
      entry.keys.find { |key| key[:kid] == kid && (key[:use].nil? || key[:use] == "sig") }
    end

    #: (String) -> JWT::JWK::Set
    private_class_method def self.fetch(url)
      uri = Must.be_a(URI(url), URI::HTTP)
      response = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https", open_timeout: TIMEOUT, read_timeout: TIMEOUT) do |http|
        http.get(uri.request_uri, "Accept" => "application/json")
      end
      response.value
      JWT::JWK::Set.new(JSON.parse(response.body))
    end

    #: () -> Float
    private_class_method def self.monotonic_now = Process.clock_gettime(Process::CLOCK_MONOTONIC).to_f
  end
end
