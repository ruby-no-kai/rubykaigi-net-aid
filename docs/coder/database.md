# Database

The backend persists to Amazon Aurora DSQL in production and to standard PostgreSQL 16 locally. DSQL is based on PostgreSQL 16, so stay on that major version locally.

Paths below are relative to `backend/`.

## Local development

`docker-compose.yml` runs PostgreSQL 16 (user and password `netaid`). `config/database.yml` discovers the published port with `docker compose port db 5432`, so the container must be running before Rails connects. Setting `DATABASE_URL` bypasses the container.

```sh
docker compose up -d --wait db   # bin/setup does this unless DATABASE_URL is set
bin/rails db:prepare             # create netaid_development / netaid_test and apply the schema
```

In development, `db:migrate` applies the schema to both the development and test databases. Set `SKIP_TEST_DATABASE=1` to skip the test database.

## Schema

The schema is managed declaratively with [psqldef](https://github.com/sqldef/sqldef), not with ActiveRecord migrations. There is no `db/migrate/` and no `schema.rb`.

- `db/schema/*.sql` holds one file per table: its `CREATE TABLE`, indexes and `GRANT`s. The files are concatenated in sorted order and handed to psqldef as the desired state.
- `rake db:migrate` diffs the desired state against the live database and applies the difference. `rake db:migrate:status` shows the plan without applying it.
- Drops (`DROP TABLE`, `DROP COLUMN`, `DROP INDEX`) are skipped unless `ENABLE_DROP=1`. Read the dry run first.
- `BEFORE_APPLY_SQL='...' rake db:migrate` runs statements before the diff, for changes psqldef cannot express (revokes, dropping something to recreate it). Statements are split on `;`, so do not put `;` inside a literal.
- Rename a table or column with psqldef's `-- @renamed from=old_name` annotation, and remove it once every environment has applied it.
- Ship a schema change in the same commit as the code that uses it.

psqldef is pinned in `mise.toml` (repo root) and in `Dockerfile`; bump both together.

```sql
-- db/schema/widgets.sql
create table widgets (
    id uuid primary key default gen_random_uuid(),
    name varchar(64) not null,
    created_at timestamp(6) with time zone not null default now(),
    updated_at timestamp(6) with time zone not null default now()
);

create index idx_widgets_name on widgets (name);

grant all privileges on widgets to app_admin;
grant select, insert, update, delete on widgets to app_user;
```

### Identifiers

Primary keys are `uuid` columns defaulting to `gen_random_uuid()`. Models expose them as [TypeIDs](https://github.com/sorah/typeid_rails) (`widget_0wp9c9wd1d90msb3z67p5eb0v5`) while the column stays a plain UUID:

```ruby
class Widget < ApplicationRecord
  include TypeidRails::Identifiable
  id_prefix "widget"
end
```

`ApplicationRecord` includes `TypeidRails::AssociationSupport`, so `belongs_to` foreign keys read and write TypeIDs of the target model. An identifier with the wrong prefix matches no row. Raw UUIDs are still accepted on assignment.

### Writing schema for DSQL

Write plain PostgreSQL that DSQL also accepts.

- Write indexes as `create index` / `create unique index`. When the target is a DSQL host, the rake task rewrites them to `create index async` / `create unique index async`, which is the only form DSQL accepts.
- `NOT NULL` cannot be added to an existing column, and a column's type cannot be changed. Decide both when the table is created. After release, changing either means add a new column, backfill, switch, then drop the old one.
- DSQL lacks some PostgreSQL features (triggers, `TRUNCATE`, among others). Check the [DSQL documentation](https://docs.aws.amazon.com/aurora-dsql/latest/userguide/working-with-postgresql-compatibility.html) before using anything beyond plain tables, indexes and grants.
- Keep tables narrow: every row read is part of a transaction's conflict surface.

### Roles

Every table grants to two permission roles; psqldef manages these grants (`manage.privilege`) but never revokes them.

| Role | Privileges |
|---|---|
| `app_admin` | DDL + DML (member of `app_user`) |
| `app_user` | DML only |

Locally, `db:migrate` creates both roles if they are missing. On DSQL they are bootstrapped once per cluster (see below).

## Aurora DSQL

### Connecting

Production connects through `DATABASE_URL`, which supplies the host, login role and schema:

```
postgres://app_netaid@<id>.dsql.<region>.on.aws/postgres?schema_search_path=netaid_prd&aws_rds_iam_auth_token_generator=dsql
```

- Authentication is IAM only. `pg-aws_rds_iam` asks `DsqlAuthTokenGenerator` (`config/initializers/dsql_token.rb`) for a token on each new connection. The `admin` role gets the admin token variant.
- TLS is verified against AmazonRootCA1 (`data/amazonroot.pem`).
- DSQL closes sessions after an hour, so pooled connections are recycled after about 45 minutes (`max_age`). Advisory locks are disabled.
- `config/initializers/dsql_monkey.rb` patches the PostgreSQL adapter for statements DSQL rejects. The patches also apply locally, where they are harmless.

`script/pdsql` runs psql, or any libpq tool after `--`, with a fresh IAM token. It connects as `admin` unless `-U` says otherwise and takes the host from `-h`, `PGHOST` or `DATABASE_URL`:

```sh
script/pdsql -h <id>.dsql.<region>.on.aws
script/pdsql -h <id>.dsql.<region>.on.aws -U app_netaid -- psql -c '\dt'
```

### Applying the schema

The rake tasks detect a DSQL host and change behaviour:

- psqldef runs through `script/pdsql` with `disable_ddl_transaction` (DSQL allows one DDL statement per transaction) and retries OCC conflicts (`OC000`/`OC001`).
- `BEFORE_APPLY_SQL` statements run one psql invocation each, then the task waits for async jobs.
- Index builds are asynchronous. `rake db:wait_for_jobs` waits for them, and `rake db:wait_for_indexes` waits for unique indexes to become valid. Both are no-ops on PostgreSQL.
- `db:prepare` skips `db:create`; DSQL only has the `postgres` database.

Pre-deploy step:

```sh
bundle exec rails db:migrate db:wait_for_jobs
```

Old code keeps running against the new schema during a rollout, so every change must be compatible with the previous release: add first, switch code, drop later with `ENABLE_DROP=1`. Deploy code that relies on a new unique index only after it is valid.

### Bootstrapping a cluster

Run once per cluster as `admin`, one statement per `script/pdsql -- psql -c '...'` invocation:

```sql
CREATE ROLE app_admin;
CREATE ROLE app_user;
GRANT app_user TO app_admin;
CREATE ROLE app_netaid WITH LOGIN;
GRANT app_admin TO app_netaid;
ALTER ROLE app_netaid SET search_path TO netaid_prd;
AWS IAM GRANT app_netaid TO '<lambda execution role arn>';
CREATE SCHEMA IF NOT EXISTS netaid_prd AUTHORIZATION app_netaid;
GRANT USAGE ON SCHEMA netaid_prd TO app_user;
GRANT USAGE, CREATE ON SCHEMA netaid_prd TO app_admin;
GRANT app_admin TO admin;
```

The app and the pre-deploy migration use the same login role, so tables are owned by the role that uses them.

## Transactions

DSQL uses optimistic concurrency control: there are no lock waits, and a transaction that conflicts with a concurrent commit fails at commit with `OC000`/`OC001`. There is no `SAVEPOINT`, so transactions cannot nest.

Open every transaction with one of the `DsqlTransactionable` helpers (included in `ApplicationRecord`). A RuboCop cop (`Dsql/TransactionOccAwareness`) rejects bare `transaction` and `with_lock`.

- `retryable_transaction` retries OCC conflicts with jittered exponential backoff. The whole block re-runs, so read everything it depends on inside the block (`reload` records loaded before it).
- `non_idempotent_transaction` does not retry. Use it when the block has external side effects or depends on data read before it.

```ruby
ApplicationRecord.retryable_transaction do
  widget.reload
  widget.update!(name:)
end
```

- A query that returns no rows adds nothing to the read set, so check-then-insert races. Prefer a unique index, or make concurrent transactions conflict on a parent row with `lock!("FOR KEY SHARE")` or `lock!`.
- Keep transactions short and small. Do slow work (HTTP calls, hashing) outside the block.
- Open transactions in one layer (controller or service object), since they cannot nest.

Local PostgreSQL does not reproduce OCC conflicts, so concurrency bugs only surface on DSQL. Reason about them when writing the code.
