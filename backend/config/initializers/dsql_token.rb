# typed: strict
# frozen_string_literal: true

require_relative "../../lib/dsql"

# Mints DSQL IAM auth tokens for pg-aws_rds_iam (`aws_rds_iam_auth_token_generator=dsql` in DATABASE_URL).
class DsqlAuthTokenGenerator
  #: (host: String, port: Integer, user: String) -> String
  def call(host:, port:, user:)
    generate_token(host:, user:)
  end

  #: (host: String, user: String) -> String
  private def generate_token(host:, user:)
    token_generator = Aws::DSQL::AuthTokenGenerator.new(
      credentials: Aws::CredentialProviderChain.new.resolve,
    )

    auth_token_params = {
      endpoint: host,
      region: Dsql.region_of(host),
      expires_in: 15 * 60
    }

    case user
    when "admin"
      token_generator.generate_db_connect_admin_auth_token(auth_token_params)
    else
      token_generator.generate_db_connect_auth_token(auth_token_params)
    end
  end
end

PG::AWS_RDS_IAM.auth_token_generators.add :dsql do
  DsqlAuthTokenGenerator.new
end
