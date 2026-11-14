# typed: strict
# frozen_string_literal: true

# Rails 8.1 dropped config.active_job.enqueue_after_transaction_commit, so it is set on
# ActiveJob::Base, which every job inherits from, ApplicationJob or not.
ActiveSupport.on_load(:active_job) do
  #: self as singleton(ActiveJob::Base)
  self.enqueue_after_transaction_commit = true
end
