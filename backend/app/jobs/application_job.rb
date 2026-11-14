# frozen_string_literal: true
# typed: strict

class ApplicationJob < ActiveJob::Base
  include ActorJob

  self.enqueue_after_transaction_commit = true
end
