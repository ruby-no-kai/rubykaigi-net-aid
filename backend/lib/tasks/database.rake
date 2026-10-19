# frozen_string_literal: true

require_relative "../dsql"

# Schema is managed by psqldef from db/schema/*.sql; Rails' migration and schema tasks do not apply.
# db:create and db:drop stay as Rails defines them, for local PostgreSQL.
Rake::Task.tasks.each do |task|
  case task.name
  when /\Adb:schema:/, /\Adb:migrate(:|\z)/, "db:rollback", "db:setup", "db:prepare", /\Adb:test:/
    task.clear
  end
end

# Runs against local PostgreSQL (docker-compose.yml) or Aurora DSQL, chosen by the configured host.
module DatabaseTasks
  PERMISSION_ROLES = %w[app_admin app_user].freeze

  # Schema files are written for PostgreSQL; DSQL only builds indexes asynchronously.
  DSQL_INDEX_PATTERN = /\bcreate(\s+unique)?\s+index\b(?!\s+async\b)/i

  def self.database_config
    database = ::Rails.application.config_for(:database)
    if ENV.key?("DATABASE_URL")
      database = database.merge(
        ActiveRecord::DatabaseConfigurations::ConnectionUrlResolver.new(ENV["DATABASE_URL"]).to_hash,
      )
    end
    database
  end

  # In development, dev and test databases are maintained together.
  def self.target_configs
    if ENV["DATABASE_URL"] || ENV["SKIP_TEST_DATABASE"] || !Rails.env.development?
      [ database_config ]
    else
      [ database_config, Rails.application.config_for(:database, env: "test") ]
    end
  end

  def self.dsql?(config)
    Dsql.host?(config[:host])
  end

  def self.target_schema(config)
    config.fetch(:schema_search_path, "public")
  end

  def self.schema_sql(config)
    sql = Dir[Rails.root.join("db", "schema", "*.sql")].sort.map { File.read(_1) }.join("\n")
    dsql?(config) ? sql.gsub(DSQL_INDEX_PATTERN) { "create#{$1} index async" } : sql
  end

  def self.run(cmd, env:)
    p cmd
    system(env, *cmd, exception: true)
  end

  def self.pg_env(config)
    {
      "PGHOST" => config[:host]&.to_s,
      "PGPORT" => config[:port]&.to_s,
      "PGUSER" => config[:username]&.to_s,
      "PGPASSWORD" => config[:password]&.to_s,
      "PGDATABASE" => config.fetch(:database).to_s,
      "PGSSLMODE" => config[:sslmode]&.to_s,
      "PGSSLROOTCERT" => config[:sslrootcert]&.to_s
    }
  end

  def self.dsql_env(config)
    {
      "PGHOST" => config.fetch(:host),
      "PGUSER" => config.fetch(:username),
      "PGOPTIONS" => "--search_path=#{target_schema(config)}"
    }
  end

  # Runs a command through script/pdsql, retrying OCC conflicts (OC000/OC001); DDL conflicts with
  # concurrent DDL and async index completion on the same cluster.
  def self.pdsql(*args, env: {}, retry_occ: false)
    cmd = [ Rails.root.join("script", "pdsql").to_s, "--", *args ]
    p cmd
    retries = 0
    loop do
      output = +""
      IO.popen(env, cmd, err: [ :child, :out ]) do |io|
        io.each_line do |line|
          $stdout.write(line)
          output << line
        end
      end
      status = $?
      break output if status.success?

      oc_error = output[/\(OC00[01]\)/]
      if retry_occ && oc_error && retries < 15
        retries += 1
        interval = [ 0.1 * (2**retries), 20.0 ].min * (1 + rand * 0.5)
        $stdout.puts "pdsql failed with #{oc_error}, retrying in #{interval.round(1)}s (#{retries}/15)..."
        sleep(interval)
        next
      end

      raise "Command failed with exit status #{status.exitstatus}: #{cmd.first}"
    end
  end

  # BEFORE_APPLY_SQL, split naively on ';', so statements must not contain one in a literal.
  def self.before_apply_statements
    ENV["BEFORE_APPLY_SQL"].to_s.split(";").map(&:strip).reject(&:empty?).map { "#{_1};" }
  end

  def self.before_apply(config)
    stmts = before_apply_statements
    return if stmts.empty?

    puts "Running before-apply SQL: #{ENV["BEFORE_APPLY_SQL"]}"
    if dsql?(config)
      # One statement per psql invocation: DSQL runs one DDL per transaction, and an OCC retry must
      # not re-run a statement that already succeeded.
      stmts.each do |stmt|
        pdsql("psql", "-v", "ON_ERROR_STOP=1", "-c", stmt, env: dsql_env(config), retry_occ: true)
      end
      wait_for_jobs(config)
    else
      run([ "psql", "-v", "ON_ERROR_STOP=1", "-c", stmts.join("\n") ], env: pg_env(config))
    end
  end

  # On DSQL, the roles are bootstrapped once per cluster as admin.
  def self.ensure_permission_roles(config)
    sql = PERMISSION_ROLES.map do |role|
      "DO $$ BEGIN CREATE ROLE #{role}; EXCEPTION WHEN duplicate_object THEN NULL; END $$;"
    end
    sql << "GRANT app_user TO app_admin;"
    run([ "psql", "-v", "ON_ERROR_STOP=1", "-q", "-c", sql.join("\n") ], env: pg_env(config).merge("PGOPTIONS" => "-c client_min_messages=warning"))
  end

  def self.psqldef(args, config: database_config)
    Tempfile.open("schema.sql") do |f|
      f.write(schema_sql(config))
      f.flush
      common_args = [
        "--config-inline", JSON.generate({ target_schema: target_schema(config) }),
        # Grants only widen; narrowing one needs a manual REVOKE via BEFORE_APPLY_SQL.
        "--config-inline", JSON.generate({ manage: { privilege: PERMISSION_ROLES.map { { target: _1 } } } }),
        "--file", f.path,
        *args
      ]

      if dsql?(config)
        pdsql(
          "psqldef",
          "--user", config.fetch(:username),
          "--host", config.fetch(:host),
          # DSQL allows one DDL statement per transaction.
          "--config-inline", "disable_ddl_transaction: true",
          *common_args,
          "postgres",
          env: dsql_env(config),
          retry_occ: true,
        )
      else
        env = pg_env(config)
        run(
          [
            "psqldef",
            # psqldef takes the password from PGPASSWORD; flags for the rest keep the command readable in logs.
            *(env["PGHOST"] ? [ "--host", env["PGHOST"] ] : []),
            *(env["PGPORT"] ? [ "--port", env["PGPORT"] ] : []),
            *(env["PGUSER"] ? [ "--user", env["PGUSER"] ] : []),
            *common_args,
            env.fetch("PGDATABASE")
          ],
          env:,
        )
      end
    end
  end

  # DSQL caches catalog snapshots per connection; reusing one (even after reconnect!) never sees
  # a job finish or indisvalid flip to true. Each poll opens a fresh connection with a fresh token.
  def self.with_fresh_connection(config)
    password = DsqlAuthTokenGenerator.new.call(host: config.fetch(:host), port: 5432, user: config.fetch(:username))
    pg = PG.connect(
      host: config.fetch(:host),
      user: config.fetch(:username),
      password:,
      dbname: "postgres",
      sslmode: "verify-full",
      sslrootcert: Dsql.ssl_root_cert,
    )
    begin
      yield pg
    ensure
      pg.close
    end
  end

  # Polls until the block returns no pending items; each is described in progress output.
  def self.wait_until_empty(what, timeout: 200, interval: 2)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
    loop do
      pending = yield
      break if pending.empty?

      remaining = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
      abort "Timed out waiting for #{what}: #{pending.join(", ")}" if remaining <= 0

      puts "Waiting for #{pending.size} #{what}: #{pending.join(", ")} (#{remaining.round}s remaining)"
      sleep interval
    end
  end

  def self.wait_for_jobs(config)
    return unless dsql?(config)

    wait_until_empty("DSQL async job(s)") do
      with_fresh_connection(config) do |pg|
        pg.exec("SELECT job_id, status FROM sys.jobs WHERE status NOT IN ('completed', 'failed')")
          .map { |j| "#{j["job_id"]} (#{j["status"]})" }
      end
    end
  end

  def self.wait_for_indexes(config)
    return unless dsql?(config)

    sql = <<~SQL
      SELECT c.relname AS index_name
      FROM pg_index i
      JOIN pg_class c ON c.oid = i.indexrelid
      JOIN pg_class t ON t.oid = i.indrelid
      JOIN pg_namespace n ON n.oid = t.relnamespace
      WHERE n.nspname = $1
        AND i.indisunique = true
        AND i.indisvalid = false
    SQL
    wait_until_empty("unique index(es) to become valid") do
      with_fresh_connection(config) do |pg|
        pg.exec_params(sql, [ target_schema(config) ]).map { |r| r["index_name"] }
      end
    end
  end
end

namespace :db do
  desc "Apply db/schema/*.sql with psqldef (BEFORE_APPLY_SQL runs first, ENABLE_DROP=1 allows drops)"
  task migrate: :environment do
    DatabaseTasks.target_configs.each do |config|
      DatabaseTasks.ensure_permission_roles(config) unless DatabaseTasks.dsql?(config)
      DatabaseTasks.before_apply(config)
      args = []
      args << "--enable-drop" if ENV["ENABLE_DROP"] == "1"
      DatabaseTasks.psqldef(args, config:)
    end
  end

  desc "Show the psqldef plan without applying it"
  task "migrate:status" => :environment do
    DatabaseTasks.psqldef([ "--dry-run" ])
  end

  desc "Create the database (if needed) and apply the schema"
  task setup: [ "db:prepare", "db:seed" ]

  # The DSQL cluster has only the postgres database, so there is nothing to create.
  desc "Create the database (if needed) and apply the schema, without seeding"
  task prepare: :load_config do
    Rake::Task["db:create"].invoke unless DatabaseTasks.dsql?(DatabaseTasks.database_config)
    Rake::Task["db:migrate"].invoke
  end

  desc "Wait for DSQL async jobs (e.g. index builds and drops) to complete; no-op on PostgreSQL"
  task wait_for_jobs: :environment do
    DatabaseTasks.target_configs.each { DatabaseTasks.wait_for_jobs(_1) }
  end

  desc "Wait for DSQL async unique indexes to become valid; no-op on PostgreSQL"
  task wait_for_indexes: :environment do
    DatabaseTasks.target_configs.each { DatabaseTasks.wait_for_indexes(_1) }
  end
end
