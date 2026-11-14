# typed: strict
# frozen_string_literal: true

# The authenticated caller of a request, as the changelog records it. `roles` decides
# authorisation and is not recorded.
Actor = Data.define(:issuer, :subject, :display_name, :credential_id, :user_agent, :roles)

class Actor
  # The length an Actor keeps of a user agent.
  USER_AGENT_LIMIT = 255 #: Integer

  #: (String?) -> String
  def self.truncate_user_agent(user_agent)
    user_agent.to_s.truncate(USER_AGENT_LIMIT, omission: "")
  end

  # The named tags identifying the Actor on every log line of its request.
  #: () -> Hash[Symbol, String]
  def log_tags = {actor_issuer: issuer, actor_subject: subject, credential_id:}
end
