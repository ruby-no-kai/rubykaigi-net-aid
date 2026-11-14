# typed: strict
# frozen_string_literal: true

# Request-scoped state that the application reads. The executor resets it per request and per job.
class Current < ActiveSupport::CurrentAttributes
  attribute :actor

  #: () -> Actor?
  def self.actor_maybe = instance.actor_maybe

  #: () -> Actor
  def self.actor = instance.actor

  #: () -> Actor?
  def actor_maybe = attributes[:actor]

  #: () -> Actor
  def actor = Must.because(actor_maybe) { "Current.actor is set once Authenticatable resolves the caller" }
end
