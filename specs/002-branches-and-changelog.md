# 002-branches-and-changelog

## Summary

The versioning core every Plan and Fleet table builds on: Branch, the `Row` columns (`branch_id`, `lineage`, `updated_seq`, timestamps), and the append-only changelog of ChangeSet, Change and Mutation. A write transaction increments `branches.head_seq` and uses it as its `seq`, so each branch's log is gap-free in commit order on DSQL. Each touched row gets one coalesced Change with its full image, and every authorised client request is journalled, deterministic rejections included. A transaction touching several branches writes one ChangeSet per branch.

This spec defines the model concern and the write path that entity specs reuse. It adds no domain entities of its own.

## Motivation

- Plan data must be versioned per Episode, forkable from any earlier Episode, and readable after the Episode closes. The Fleet has one continuous timeline with snapshots. Both need the same notion of "a branch at a version".
- Local-first clients (006) bootstrap a branch and then need every later change in order, with no gaps, so that "I have applied up to N" is a complete statement. DSQL sequences hand out cached blocks with gaps and out of commit order, so they cannot provide this.
- Conflicts resolve last-writer-wins, and the requirement is that no submitted update is ever lost. That is only acceptable if every overwritten value and every rejected request can still be found and restored.
- Inventory scans from offline phones arrive late and in bulk. The journal must make retried uploads idempotent.
- Building this once, as a concern plus one write entry point, keeps every entity spec (008 onwards) small.

## Explanation

### Concepts

| Name | TypeID | What |
|---|---|---|
| Branch | `br` | one line of history of one dataset (`plan` or `fleet`); a frozen branch is a snapshot |
| ChangeSet | `cs` | one per branch per committed transaction, numbered by `seq` |
| Change | `c` | one per touched row in a ChangeSet, with the row's full after-image and the proto fields that changed |
| Mutation | `mut` | one API request from a client, applied or rejected; its id is the client's idempotency key |

- `seq` starts at 1 on each branch and increases by exactly 1 per ChangeSet, in commit order.
- `seq` is an internal detail of `Changelog`. Outside it, a branch's position is an opaque cursor (see [Changing the ordering strategy](#changing-the-ordering-strategy)).
- A row's `updated_seq` is the `seq` of the ChangeSet that last wrote it.
- A row saved several times in one write gets one Change, carrying its final state: created then updated is one upsert, updated then destroyed is one delete, created then destroyed is nothing. Changes in a ChangeSet carry an `ordinal` in the order their rows were first touched, so a client applying them in order sees a parent before its children.
- `changed_fields` lists the top-level proto fields whose value differs between the row's before-image (its state when the write first touched it) and its after-image. It is empty for a create or a delete.
- `lineage` is the `id` of the row's first incarnation. It is equal across branches for "the same thing", unique within a branch, and never a foreign key.

### Declaring a branched entity

```ruby
# app/models/site.rb
class Site < ApplicationRecord
  include Branched
  id_prefix "site"
  natural_key :slug              # unique index (branch_id, slug); lookups by natural key
  changelog_resource Api::SiteResource # after-image of each Change
end

# app/models/inventory_scan.rb
class InventoryScan < ApplicationRecord
  include Branched
  id_prefix "scan"
  insert_only!                   # update and destroy raise
  changelog_resource Api::InventoryScanResource
end
```

`Branched` provides:

- `belongs_to :branch`; `Site.on(branch)` scope (`where(branch_id:)`)
- `lineage` defaulting to `id` on create
- `updated_seq` set from the enclosing `Changelog.write`
- `Site.find_by_natural_key!(branch, "venue")`, `Site.find_by_lineage(branch, lineage)`
- recording of an upsert or delete Change on save and destroy

### Writing

All writes to branched tables go through `Changelog.write`, which opens the transaction.

```ruby
Changelog.write(mutation: header, branches: [episode.plan_branch, Branch.fleet_main]) do
  device = Device.on(episode.plan_branch).find(device_id)
  asset = Asset.on(Branch.fleet_main).find(asset_id)
  device.update!(asset_id: asset.id, status: :deployed, mounted_at: Time.current)
  asset.update!(status: :deployed)
  Rk::NetAid::DeviceServiceAssignFillResponse.new(...) # the block returns the RPC's response
end
# => Changelog::Result(mutation_id:, response:, cursors: {"br_plan..." => "...", "br_fleet..." => "..."})
```

- `mutation:` is the request's `MutationHeader` (004), or `nil` for server-originated writes (jobs, imports, fork copies), which journal no Mutation.
- The ChangeSet records `Current.actor`. A job started by a request carries the starting Actor, serialised into its arguments, and sets `Current.actor` from it. A job with no human starter records issuer `system` and the job class name as subject.
- `branches:` lists every branch the block may write. Saving a row whose `branch_id` is not declared raises `Changelog::UndeclaredBranch` (a bug, not a problem answer).
- A written branch must be `STATE_READY` and not frozen, or the write raises `Errors::BranchNotWritable` (`PROBLEM_TYPE_BRANCH_NOT_WRITABLE`, `branch-not-writable`, 412).
- A branch's `seq` is taken lazily, on the block's first write to it. A declared branch the block never writes gets no ChangeSet, its `head_seq` is not consumed, and its row is not locked, so declaring a branch costs nothing unless it is written.
- The block returns the RPC's response message. It is stored with the Mutation, and a replay returns the stored message even if the entities have changed since.
- The block may run more than once (OCC retry), so it must read everything inside itself.
- OCC retries use `retryable_transaction`'s defaults (4 retries). Exhausting them answers Connect `unavailable` and journals nothing, so the client's outbox (006) retries later with the same `mutation_id`.
- Replaying a `mutation_id` that was already applied or rejected returns the stored outcome (the response, or the problem) without running the block, provided the rpc, the actor's issuer and subject, and the payload all match the journalled request. The payload is compared as a decoded message, so a re-encoded retry still matches. A mismatch raises `Errors::Conflict` and journals nothing.
- Only deterministic rejections are journalled: a problem (`Problem::Detailable`) or `ActiveRecord::RecordInvalid` raised by the block. Any other failure (a bug, a timeout, OCC retries exhausted) stores nothing, so the client's retry with the same `mutation_id` applies once the cause is gone.

### Reading history

- `Change.on(branch).after(cursor).limit(n)`: the sync feed (exposed by `SyncService.PullChanges`, 004). Callers never filter on `seq` directly.
- `Change.on(branch).for_entity(id)`: one row's history, newest first, for "what did this overwrite". A delete Change carries the row's before-image in `data`, so its last state is in the delete itself.
- `Mutation.find(id)`: the request as sent, including rejected ones.

### Logging

Each `Changelog.write` reports on the request's canonical line (021):

| Field | Kind | Value |
|---|---|---|
| `mutation_id` | payload | the request's `mutation_id` |
| `mutation_outcome` | payload | `OUTCOME_APPLIED`, `OUTCOME_REJECTED`, or `replayed` when a stored outcome was returned |
| `occ_retries` | counter | OCC retries taken by `retryable_transaction` |
| `change_sets_written` | counter | ChangeSets inserted |
| `changes_written` | counter | Changes inserted, `insert_all!` included |

### Changing the ordering strategy

The per-branch counter may later give way to per-domain counters or time-ordered ids (see [Considered Alternatives](#considered-alternatives)). To keep that a server deploy plus a client release:

- The wire carries an opaque `string cursor`, never an `int64 seq`. Today it encodes the branch's `seq`. Clients store and echo it without interpreting it (004, 006).
- The server can answer `PROBLEM_TYPE_RESYNC_REQUIRED` (`resync-required`, 412) to a cursor it no longer understands. The client drops its copy of that branch and bootstraps again. The outbox is unaffected, because Mutations replay by `mutation_id` and `base_seqs` is informational only.
- Clients do no arithmetic on cursors and never compare `updated_seq`. Their freshness rule is "apply Changes in feed order". `updated_seq` is not part of any API message.
- Exports (013), forks (003) and anything stored or shown to people record an opaque branch version, never a bare `seq` with meaning attached.
- ChangeSets keep `committed_at`, so a time-ordered scheme can be built over existing history.

## Drawbacks

- Every write to a branch conflicts on its `branches` row, so writes to one branch are serialised. Many scanners uploading at once will see OCC retries. Mitigation: scanners batch scans into one Mutation per upload (017), and the ordering can change later without a data migration.
- Full after-images duplicate row data in `changes`. At this data size (thousands of rows, tens of thousands of Changes per Episode) this is negligible.
- Bulk ActiveRecord APIs (`insert_all`, `update_all`, `delete_all`) bypass callbacks and would skip Changes. Bulk inserts go through `Changelog.current.insert_all!`; there is no bulk update or delete.
- A long transaction on a busy branch, such as an import chunk, is the writer most likely to lose the conflict and exhaust its retries.

## Considered Alternatives

- DSQL/PostgreSQL sequences or `updated_at` timestamps as the sync cursor: gaps and out-of-order commits make "everything after N" incomplete.
- Composite primary keys `(branch_id, lineage)`: removes the id remap on fork, but complicates Rails associations and `typeid_rails`. Single-column `id` plus `lineage` was chosen in the domain model.
- Copy-on-write branches (rows shared until changed): saves space, but every read becomes "my branch or my ancestors at fork seq", and the data is small enough to copy eagerly (003).
- Diff-only Changes (changed fields only): smaller, but clients and restore would need to fold history. After-images make each Change self-sufficient.
- Triggers for change capture: DSQL has no triggers.
- Event sourcing (rows derived from the log): reads stay plain table reads here, and the log is an output, not the source.
- Per-domain counters (one per branch per feature area such as ipam, cables, inventory): unrelated activities stop conflicting while cursors stay exact. Cursors become per-domain vectors, `PullChanges` must read all domains in one snapshot so a cross-domain write never arrives half-applied, and concurrent scanning still shares one counter. Deferred; reachable later by starting every domain counter at the current `seq`.
- UUIDv7 change ids read with an overlap window, plus a per-row version: no hot row at all. A UUIDv7 is stamped at transaction start, not commit, so clients must re-read a window longer than the longest write transaction plus clock skew, freezing must drain for that window, and "branch at seq N" becomes "as of watermark T". Deferred; reachable later through `committed_at` and the resync answer.

## Prior Art

- Linear's sync engine: a global `lastSyncId`, full model payloads in sync actions, client transactions. See the README references.
- Replicache / Reflect: client mutation ids, push and pull, server-authoritative order.
- NetBox `ObjectChange`: per-object pre/post change data and request id.
- Dolt and Neon: branching databases, here reduced to eager copies.

## Security and Privacy Considerations

- The changelog and Mutation journal are append-only. No RPC updates or deletes them; restores create new writes.
- Mutation payloads are kept forever and may contain anything a client sent. Credentials never travel in payloads (001), so nothing secret is retained.
- Actor columns record who wrote what; they are visible to every reader of the branch.
- Only requests that passed authentication and authorisation (001) are journalled. Denied requests are logged, not stored.

## Mission Scope

### Out of scope

- Episode and the fork, close and snapshot operations (003).
- Sync RPCs, write RPC shapes, per-field LWW semantics on the wire (004).
- Restore UI and RPCs for overwritten values and rejected Mutations (020). This spec only guarantees the data they need is kept.
- Change retention or compaction.

### Expected Outcomes

- A `Branched` model gets `branch_id`, `lineage`, `updated_seq` and Change recording by including one concern.
- Any number of concurrent writers on one branch produce ChangeSets whose `seq`s are 1, 2, 3, … in commit order.
- A multi-branch write yields one ChangeSet per touched branch, atomically.
- A retried Mutation never applies twice.
- A rejected Mutation is stored with its payload and error.

## Implementation Plan

### Schema

```sql
-- db/schema/branches.sql
create table branches (
    id uuid primary key default gen_random_uuid(),
    dataset varchar(32) not null,          -- DATASET_PLAN, DATASET_FLEET
    episode_id uuid,                       -- plan branches only (003)
    scope_key varchar(64) not null,        -- the Episode's uuid for Plan branches, 'fleet' for Fleet branches
    name varchar(64) not null,             -- main, or a snapshot label
    parent_id uuid,
    forked_at_seq bigint,
    head_seq bigint not null default 0,
    frozen boolean not null default false,
    state varchar(32) not null,            -- STATE_PREPARING, STATE_READY
    created_at timestamp(6) with time zone not null default now(),
    updated_at timestamp(6) with time zone not null default now()
);
create unique index idx_branches_scope_name on branches (scope_key, name);
create index idx_branches_parent on branches (parent_id);
```

```sql
-- db/schema/change_sets.sql
create table change_sets (
    id uuid primary key default gen_random_uuid(),
    branch_id uuid not null,
    seq bigint not null,
    mutation_id uuid,
    actor_issuer varchar(64) not null,
    actor_subject varchar(255) not null,
    actor_display_name varchar(255),
    actor_credential_id varchar(255),
    actor_user_agent varchar(255),
    committed_at timestamp(6) with time zone not null default now()
);
create unique index idx_change_sets_branch_seq on change_sets (branch_id, seq);
create index idx_change_sets_mutation on change_sets (mutation_id);
```

```sql
-- db/schema/changes.sql
create table changes (
    id uuid primary key default gen_random_uuid(),
    branch_id uuid not null,
    seq bigint not null,
    entity_type varchar(64) not null,      -- proto message name, e.g. rubykaigi.net_aid.Site
    entity_id uuid not null,
    entity_lineage uuid not null,
    ordinal integer not null,              -- order of first touch within the ChangeSet
    op varchar(16) not null,               -- OP_UPSERT, OP_DELETE
    data jsonb,                            -- protojson after-image; null on delete
    changed_fields jsonb                   -- array of top-level proto field names; empty on create and delete
);
create index idx_changes_branch_seq on changes (branch_id, seq);
create index idx_changes_branch_entity on changes (branch_id, entity_id, seq);
```

```sql
-- db/schema/mutations.sql
create table mutations (
    id uuid primary key,                   -- client-generated
    actor_issuer varchar(64) not null,
    actor_subject varchar(255) not null,
    actor_display_name varchar(255),
    actor_credential_id varchar(255),
    actor_user_agent varchar(255),
    rpc varchar(255) not null,             -- rubykaigi.net_aid.DeviceService/AssignFill
    payload jsonb not null,                -- protojson request as sent
    base_seqs jsonb not null,              -- {"<branch uuid>": seq}
    client_time timestamp(6) with time zone,
    received_at timestamp(6) with time zone not null default now(),
    outcome varchar(32) not null,          -- OUTCOME_APPLIED, OUTCOME_REJECTED
    response jsonb,                        -- protojson response, for replay
    error jsonb                            -- problem details, for rejections
);
create index idx_mutations_actor on mutations (actor_issuer, actor_subject, received_at);
```

- Grants as in `docs/coder/database.md`. Indexes become `async` on DSQL.
- `scope_key` exists because `episode_id` is NULL for Fleet branches, and NULLs are distinct in a unique index, so `(dataset, episode_id, name)` would allow two Fleet `main` branches.
- Arrays cannot be column types on DSQL, hence `jsonb` for `changed_fields` and `base_seqs`. They are never queried by content.
- Enum columns are `varchar` holding the full proto enum value name (`STATE_READY`), so a value round-trips through `Rk::NetAid::Branch::State.resolve` with no mapping and reads clearly in `psql`. This applies to every enum column of every spec.

Every branched table carries:

```sql
    id uuid primary key,                   -- client-generated (004); server-created rows use SecureRandom.uuid_v7
    branch_id uuid not null,
    lineage uuid not null,
    updated_seq bigint not null,
    created_at timestamp(6) with time zone not null default now(),
    updated_at timestamp(6) with time zone not null default now(),
    -- ...
create unique index idx_<table>_branch_lineage on <table> (branch_id, lineage);
create unique index idx_<table>_branch_<key> on <table> (branch_id, <natural key columns>);
```

### Code

- `app/models/branch.rb`: `Branch.fleet_main`, `#writable?`, `#plan?`, `#fleet?`.
- `app/models/change_set.rb`, `app/models/change.rb`, `app/models/mutation.rb`: read-only models outside `Changelog` (`readonly?` true except during `Changelog.write`).
- `app/models/concerns/branched.rb`:
  - `natural_key(*columns)`, `changelog_resource(klass)`, `insert_only!` class methods
  - `before_validation on: :create` assigns `self.id ||= SecureRandom.uuid_v7`, then `self.lineage ||= id`
  - `before_save` sets `updated_seq` from `Changelog.current.seq_for(branch_id)` and raises outside a `Changelog.write`
  - `before_save` / `before_destroy` on a row's first touch in the write capture its before-image (the `changelog_resource` message built from `attributes_in_database`)
  - `after_save` / `after_destroy` register the row with `Changelog.current`, which keeps one entry per row: first-touch ordinal, before-image, final record or deletion
- `app/models/changelog.rb`:

  ```ruby
  #: (mutation: Rk::NetAid::MutationHeader?, branches: Array[Branch], ?rpc: String, ?payload: Google::Protobuf::AbstractMessage) { (Changelog::Context) -> T } -> Changelog::Result
  def self.write(mutation:, branches:, rpc: nil, payload: nil, &block)
  ```

  1. If `mutation` is set and a `mutations` row exists for its id, compare rpc, actor and payload. Equal: return its stored outcome. Different: raise `Errors::Conflict`.
  2. `ApplicationRecord.retryable_transaction`:
     1. Load the declared branches without locking. A branch's `seq` is assigned on the block's first write to it: `update branches set head_seq = head_seq + 1, updated_at = now() where id = $1 returning head_seq, state, frozen`. If the returned state is not `STATE_READY` or the branch is frozen, raise `Errors::BranchNotWritable`. Freezing a branch writes the same row, so a write racing a freeze conflicts and retries against the frozen state.
     2. Run the block with a fresh `Changelog::Context` in `Changelog.current` (an `ActiveSupport::IsolatedExecutionState` slot).
     3. Coalesce: for each touched row, build its after-image (for a deletion, `data` is the before-image) with its `changelog_resource`, compute `changed_fields` against the before-image, and drop rows created and destroyed in the same write. Insert one `change_sets` row per touched branch and all `changes` with `insert_all`.
     4. Insert the `mutations` row (`outcome: OUTCOME_APPLIED`, `response` from the block's return value).
  3. Two requests with the same id racing: the loser fails either with an OCC conflict (both in flight), which `retryable_transaction` retries, or with a unique violation on `mutations.id` (the winner already committed). `Changelog.write` rescues `ActiveRecord::RecordNotUnique` on that index and restarts from step 1, which now finds the winner's row.
  4. On a `Problem::Detailable` or `ActiveRecord::RecordInvalid` raised by the block: roll back, record the Mutation as `OUTCOME_REJECTED` with the problem document in `error`, in its own `retryable_transaction`, then re-raise. Other exceptions propagate without a journal entry.
- `Changelog::Context#insert_all!(records)`: for fork copies, imports and batched scans. Takes unsaved instances of one `Branched` model, runs their validations (raising `ActiveRecord::RecordInvalid` on the first failure), assigns `id`, `lineage` and `updated_seq`, builds after-images, and inserts the rows and their upsert Changes with `insert_all`. Inserts only; updates go through ordinary saves.
- `ActiveRecord::SerializationFailure` escaping `retryable_transaction` is mapped to Connect `unavailable` in `Api::ApplicationController`.
- RuboCop cop `Changelog/BulkWrite` (`backend/rubocop/changelog_bulk_write.rb`, next to `Dsql/TransactionOccAwareness`) flags `insert_all`, `upsert_all`, `update_all`, `delete_all`, `update_column` and `update_columns` outside `app/models/changelog*`. It cannot tell a `Branched` receiver statically, so non-branched callers disable it inline.
- `Errors::BranchNotWritable` and `Errors::ResyncRequired` in `app/models/errors.rb`; `PROBLEM_TYPE_BRANCH_NOT_WRITABLE` and `PROBLEM_TYPE_RESYNC_REQUIRED` in `problem.proto`.
- `Changelog::Cursor`: encodes and decodes the opaque cursor (today base64url of `<branch uuid>:<seq>` with a version prefix `v1.`); an unknown version or a cursor for another branch raises `Errors::ResyncRequired`.
- Transaction size: a write of N rows mutates about 2N rows (rows plus Changes) plus one ChangeSet. Callers that write many rows (fork copy, imports, bulk scans) chunk at ~1,000 rows per `Changelog.write` to stay under DSQL's 3,000 rows and 10 MiB.

### Spike

The domain model leaves "lineage in Rails" as a spike. Do it first, on local PostgreSQL:

- one `Branched` toy model with a `belongs_to` to another, both using `typeid_rails` with client-supplied UUIDv7 ids
- `Changelog.write` from several threads, asserting gap-free `seq`
- coalescing and `changed_fields` on a model with a composite proto field

### Tests

Everything runs on local PostgreSQL; there is no DSQL test cluster. PostgreSQL serialises concurrent `head_seq` bumps with a row lock where DSQL aborts and retries, so both reach the same gap-free result. The DSQL retry path is exercised with `trigger_dsql_conflict!`. Real DSQL behaviour under concurrent load is verified only by design and in production.

- model specs for `Branched`: id and lineage defaults, natural key uniqueness, `insert_only!`
- `Changelog.write`: seq increments, lazy bump, multi-branch, frozen and preparing branch rejection, undeclared branch, coalescing, `changed_fields`, delete before-image, replay of applied and rejected Mutations, replay mismatch, duplicate-id race, OCC retry and exhaustion
- concurrency: several threads write one branch and two branches at once; `seq` is 1..N with no gaps and every Change has its ChangeSet
- `Changelog::Cursor`: round trip, unknown version and wrong branch raise `ResyncRequired`
- `insert_all!`: validation failure, Changes recorded per row

## Current Status

Interview complete. Implementors MUST keep this section updated as they work.

### Checklist

- [ ] Spike on local PostgreSQL: toy `Branched` models with `typeid_rails` and client UUIDv7 ids, threaded `Changelog.write`, coalescing with a composite proto field
- [ ] `db/schema/branches.sql`, `change_sets.sql`, `changes.sql`, `mutations.sql`
- [ ] `Branch` (`Branch.fleet_main`, `#writable?`, `#plan?`, `#fleet?`)
- [ ] Read-only `ChangeSet`, `Change`, `Mutation` models
- [ ] `Branched` concern: id and lineage defaults, `natural_key`, `changelog_resource`, `insert_only!`, `on`, `find_by_natural_key!`, `find_by_lineage`, before-image capture, registration with the context
- [ ] `Changelog.write`: lazy bump, coalescing and `changed_fields`, ChangeSets and Changes, Mutation journal with stored response, replay and mismatch, duplicate-id race, rejection journalling
- [ ] `Changelog::Context#insert_all!`
- [ ] `Changelog::Cursor`
- [ ] `Errors::BranchNotWritable`, `Errors::ResyncRequired`, `PROBLEM_TYPE_BRANCH_NOT_WRITABLE` and `PROBLEM_TYPE_RESYNC_REQUIRED` (both 412)
- [ ] Map an escaping `ActiveRecord::SerializationFailure` to Connect `unavailable`
- [ ] Job Actor propagation (starting Actor serialised into job arguments, else `system`)
- [ ] `Changelog/BulkWrite` cop
- [ ] Canonical log line fields and counters (021); `occ_retries` incremented from `DsqlTransactionable#retryable_transaction`
- [ ] Specs listed under Tests

### Updates

- 2026-11-08: Interview complete. Follow-ups outside this spec: 004 and 006 use the opaque `string cursor` and handle `RESYNC_REQUIRED`; 003 and 013 record an opaque branch version instead of a bare `seq`; spec 020 (history and restore) to be written.
