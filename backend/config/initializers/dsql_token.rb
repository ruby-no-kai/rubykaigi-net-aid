# frozen_string_literal: true

require_relative "../../lib/dsql"

# Mints DSQL IAM auth tokens for pg-aws_rds_iam (`aws_rds_iam_auth_token_generator=dsql` in DATABASE_URL).
class DsqlAuthTokenGenerator
  def call(host:, port:, user:)
    # A token signed at travelled time fails with "Signature not yet current"; TimeHelpers cannot be suspended, Timecop can.
    if defined?(Timecop)
      Timecop.return { generate_token(host:, user:) }
    else
      generate_token(host:, user:)
    end
  end

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
