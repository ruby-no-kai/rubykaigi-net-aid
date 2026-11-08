# typed: strict
# frozen_string_literal: true

# The authenticated caller of a request, as the changelog records it. `roles` decides
# authorisation and is not recorded.
Actor = Data.define(:issuer, :subject, :display_name, :credential_id, :user_agent, :roles)

class Actor
  # The length an Actor keeps of a user agent.
  USER_AGENT_LIMIT = 255 #: Integer

  # The issuer of server-originated work that no person or machine started.
  SYSTEM_ISSUER = "system" #: String

  #: (String?) -> String
  def self.truncate_user_agent(user_agent)
    user_agent.to_s.truncate(USER_AGENT_LIMIT, omission: "")
  end

  # The Actor of work with no human starter, such as a scheduled job, named by what runs it.
  #: (String subject) -> Actor
  def self.system(subject)
    new(issuer: SYSTEM_ISSUER, subject:, display_name: subject, credential_id: "", user_agent: "", roles: [])
  end

  # The inverse of #serialize, for an Actor carried in a job's arguments.
  #: (Hash[String, untyped]) -> Actor
  def self.deserialize(hash)
    new(
      issuer: hash.fetch("issuer"),
      subject: hash.fetch("subject"),
      display_name: hash.fetch("display_name"),
      credential_id: hash.fetch("credential_id"),
      user_agent: hash.fetch("user_agent"),
      roles: hash.fetch("roles"),
    )
  end

  #: () -> Hash[String, untyped]
  def serialize = to_h.stringify_keys

  # The named tags identifying the Actor on every log line of its request.
  #: () -> Hash[Symbol, String]
  def log_tags = {actor_issuer: issuer, actor_subject: subject, credential_id:}
end
