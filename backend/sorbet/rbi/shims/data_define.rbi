# typed: strict

# Sorbet synthesizes the readers of a `Data.define` class without signatures, which a
# `# typed: strict` file cannot supply inline.

class Actor
  sig { returns(String) }
  def issuer; end

  sig { returns(String) }
  def subject; end

  sig { returns(String) }
  def display_name; end

  sig { returns(String) }
  def credential_id; end

  sig { returns(String) }
  def user_agent; end

  sig { returns(T::Array[String]) }
  def roles; end
end

class Authn::JwksCache::Entry
  sig { returns(JWT::JWK::Set) }
  def keys; end

  sig { returns(Float) }
  def fetched_at; end
end

class Authn::JwksCache::Failure
  sig { returns(StandardError) }
  def error; end

  sig { returns(Float) }
  def failed_at; end
end
