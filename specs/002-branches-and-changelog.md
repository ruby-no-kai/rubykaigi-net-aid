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
Changelog.write(mutation: request.header, branches: [episode.plan_branch, Branch.fleet_main],
                rpc: "rubykaigi.net_aid.DeviceService/AssignFill", payload: request) do
  device = Device.on(episode.plan_branch).find(device_id)
  asset = Asset.on(Branch.fleet_main).find(asset_id)
  device.update!(asset_id: asset.id, status: :deployed, mounted_at: Time.current)
  asset.update!(status: :deployed)
  Rk::NetAid::DeviceServiceAssignFillResponse.new(...) # the block returns the RPC's response
end
# => Changelog::Result(mutation_id:, response:, cursors: {"br_plan..." => "...", "br_fleet..." => "..."})
```

- `mutation:` is the request's `MutationHeader` (004), or `nil` for server-originated writes (jobs, imports, fork copies), which journal no Mutation. A write with a `mutation` also takes `rpc:` (the full RPC name) and `payload:` (the request message) to journal, and raises `ArgumentError` without them.
- `Changelog.write` opens its own transaction. It does not nest (`ArgumentError`), and called while a joinable transaction is already open it raises `Changelog::TransactionOpen` rather than join it, so a journalled rejection can never commit the caller's writes. A transactional test fixture's transaction is not joinable, so a write inside one runs in a savepoint.
- The ChangeSet records `Current.actor`. A job started by a request carries the starting Actor, serialised into its job data when it is enqueued, and sets `Current.actor` from it, for its `rescue_from`, `retry_on` and `discard_on` handlers too. A job performed inline runs as its caller. A job with no human starter records issuer `system` and the job class name as subject. Every job is enqueued only once the enclosing transaction commits.
- `branches:` lists every branch the block may write. Saving a row whose `branch_id` is not declared raises `Changelog::UndeclaredBranch` (a bug, not a problem answer).
- A written branch must be `STATE_READY` and not frozen, or the write raises a subclass of `Errors::BranchNotWritable` (`PROBLEM_TYPE_BRANCH_NOT_WRITABLE`, `branch-not-writable`, 412). A frozen branch raises `Errors::BranchFrozen`, which is journalled. A branch still being prepared raises `Errors::BranchNotReady`, which is not: the branch becomes writable, so a retry with the same `mutation_id` must run again.
- A branch's `seq` is taken lazily, on the block's first write to it. A declared branch the block never writes gets no ChangeSet, its `head_seq` is not consumed, and its row is not locked, so declaring a branch costs nothing unless it is written.
- On PostgreSQL taking a `seq` row-locks the branch, so two writes touching two branches in opposite orders can deadlock. `retryable_transaction` retries the victim (`ActiveRecord::Deadlocked`) as it retries an OCC conflict, and a retried attempt takes the `seq`s of the branches its failed attempt wrote before running the block, sorted by id, so the pair does not deadlock again.
- A save or destroy aborted by a later callback records no Change. A row's last completed save in the write still does.
- The block returns the RPC's response message. It is stored with the Mutation, and a replay returns the stored message even if the entities have changed since.
- The block may run more than once (OCC retry), so it must read everything inside itself.
- OCC retries use `retryable_transaction`'s defaults (4 retries). Exhausting them answers Connect `unavailable` and journals nothing, so the client's outbox (006) retries later with the same `mutation_id`. The same holds for deadlock retries.
- A unique violation (`ActiveRecord::RecordNotUnique`) raised by the block means a concurrent write committed a row with the same key first, such as two clients creating one row. The write runs once more, so a block that checks for the row sees it and raises its own rejection. A violation on the retry too raises `Errors::DuplicateRow`, a subclass of `Errors::Conflict` (409, Connect `aborted`), and journals nothing. A violation on `mutations.id` is the duplicate-request race below, not this.
- Replaying a `mutation_id` that was already applied or rejected returns the stored outcome (the response, or the problem) without running the block, provided the rpc, the actor's issuer and subject, and the payload all match the journalled request. The payload is compared as a decoded message, so a re-encoded retry still matches. A mismatch raises `Errors::MutationIdReused`, a subclass of `Errors::Conflict`, and journals nothing.
- Only deterministic rejections are journalled: an `Errors::Rejection` or `ActiveRecord::RecordInvalid` raised by the block. `Errors::Rejection` is a marker module for problems that follow from the request and the data it names alone, so a retry would meet them again. `Errors::NotFound`, `Errors::FailedPrecondition`, `Errors::InvalidRecord` and `Errors::BranchFrozen` include it, and so does any subclass of theirs; a new problem class includes it only when that holds. Any other failure stores nothing, so the client's retry with the same `mutation_id` applies once the cause is gone: a bug, a timeout, OCC retries exhausted, and problems that are not rejections, such as `Errors::Internal`, `Errors::ResyncRequired`, `Errors::PermissionDenied`, `Errors::BranchNotReady` and `Errors::DuplicateRow`.

### Reading history

- `Change.on(branch).after(cursor).limit(n)`: the sync feed (exposed by `SyncService.PullChanges`, 004). Callers never filter on `seq` directly.
- `Change.on(branch).for_entity(id)`: one row's history, newest first, for "what did this overwrite". A delete Change carries the row's before-image in `data`, so its last state is in the delete itself.
- `Mutation.find(id)`: the request as sent, including rejected ones.

### Logging

Each `Changelog.write` reports on the request's canonical line (021). A write with a `mutation` reports `mutation_id` and `mutation_outcome` whatever its outcome:

| Field | Kind | Value |
|---|---|---|
| `mutation_id` | payload | the request's `mutation_id` |
| `mutation_outcome` | payload | `OUTCOME_APPLIED`, `OUTCOME_REJECTED`, `replayed` when a stored outcome was returned, `reused` when the `mutation_id` belongs to another request (`Errors::MutationIdReused`), or `failed` when the write raised and journalled nothing |
| `occ_retries` | counter | OCC and deadlock retries taken by `retryable_transaction` |
| `change_sets_written` | counter | ChangeSets inserted |
| `changes_written` | counter | Changes inserted, `insert_all!` included |

### Changing the ordering strategy

The per-branch counter may later give way to per-domain counters or time-ordered ids (see [Considered Alternatives](#considered-alternatives)). To keep that a server deploy plus a client release:

- The wire carries an opaque `string cursor`, never an `int64 seq`. Today it encodes the branch's `seq`. Clients store and echo it without interpreting it (004, 006).
- The server can answer `PROBLEM_TYPE_RESYNC_REQUIRED` (`resync-required`, 412) to a cursor it no longer understands. The client drops its copy of that branch and bootstraps again. The outbox is unaffected, because Mutations replay by `mutation_id` and the header's `base_cursors` (stored as `mutations.base_seqs`) are informational only.
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
- Only deterministic rejections are stored; a failure a retry could get past is not.
- Writers racing on one row or on two branches never answer a 500: a unique-key race answers `conflict`, and a deadlock is retried.

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
    head_seq bigint not null default 0,    -- seq of the branch's latest ChangeSet
    is_frozen boolean not null default false, -- frozen would clash with Object#frozen? in Active Record
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
    data jsonb,                            -- protojson after-image; the before-image on delete
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
    payload jsonb not null,                -- protojson google.protobuf.Any of the request as sent
    base_seqs jsonb not null,              -- {"<branch uuid>": seq}, from the header's cursors
    client_time timestamp(6) with time zone,
    received_at timestamp(6) with time zone not null default now(),
    outcome varchar(32) not null,          -- OUTCOME_APPLIED, OUTCOME_REJECTED
    response jsonb,                        -- protojson google.protobuf.Any of the response, for replay
    error jsonb                            -- protojson protobufable.ProblemDetails, for rejections
);
create index idx_mutations_actor on mutations (actor_issuer, actor_subject, received_at);
```

- Every table grants all privileges to `app_admin`. `app_user` gets `select, insert, update, delete` on `branches`, but only `select, insert` on `change_sets`, `changes` and `mutations`, which are append-only. Indexes become `async` on DSQL.
- `scope_key` exists because `episode_id` is NULL for Fleet branches, and NULLs are distinct in a unique index, so `(dataset, episode_id, name)` would allow two Fleet `main` branches.
- Arrays cannot be column types on DSQL, hence `jsonb` for `changed_fields` and `base_seqs`. They are never queried by content.
- `mutations.payload` and `mutations.response` hold a `google.protobuf.Any`, so a stored message names its own type for replay and for 020.
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
  - `after_save` / `after_destroy` register the row with `Changelog.current`, which keeps one entry per row: first-touch ordinal, before-image, final record or deletion. An entry never saved or destroyed, because a later callback aborted every save, produces no Change.
- `app/models/changelog.rb`:

  ```ruby
  #: [T] (mutation: Rk::NetAid::MutationHeader?, branches: Array[Branch], ?rpc: String?,
  #|      ?payload: Google::Protobuf::AbstractMessage?) { (Changelog::Context) -> T } -> Changelog::Result
  def self.write(mutation:, branches:, rpc: nil, payload: nil, &block)
  ```

  0. Raise `ArgumentError` inside another `Changelog.write`, and `Changelog::TransactionOpen` inside a joinable transaction.

  1. If `mutation` is set and a `mutations` row exists for its id, compare rpc, actor and payload. Equal: return its stored outcome. Different: raise `Errors::MutationIdReused`.
  2. `ApplicationRecord.retryable_transaction`:
     1. The declared branches are not read; only their ids are kept. A branch's `seq` is assigned on the block's first write to it, or before the block on a retried attempt for the branches the failed attempt wrote, in id order: `update branches set head_seq = head_seq + 1, updated_at = now() where id = $1 returning head_seq, state, is_frozen`. A frozen branch raises `Errors::BranchFrozen`, and a state other than `STATE_READY` raises `Errors::BranchNotReady`. The `RETURNING` is the writability check, so an unwritten branch adds nothing to the read set. Freezing a branch writes the same row, so a write racing a freeze conflicts and retries against the frozen state.
     2. Run the block with a fresh `Changelog::Context` in `Changelog.current` (an `ActiveSupport::IsolatedExecutionState` slot).
     3. Coalesce: for each touched row, build its after-image (for a deletion, `data` is the before-image) with its `changelog_resource`, compute `changed_fields` against the before-image, and drop rows created and destroyed in the same write. Insert one `change_sets` row per touched branch and all `changes` with `insert_all`.
     4. Insert the `mutations` row (`outcome: OUTCOME_APPLIED`, `response` from the block's return value).
  3. Two requests with the same id racing: the loser fails either with an OCC conflict (both in flight), which `retryable_transaction` retries, or with a unique violation on `mutations.id` (the winner already committed). `Changelog.write` rescues an `ActiveRecord::RecordNotUnique` raised outside the block, looks the winner's row up, and answers as step 1 does with it. With no such row, the violation propagates.
  4. A unique violation raised by the block becomes `Errors::DuplicateRow` and step 2 runs once more. A second one propagates.
  5. On an `Errors::Rejection` or `ActiveRecord::RecordInvalid` raised by the block: roll back, record the Mutation as `OUTCOME_REJECTED` with the problem document in `error`, in its own `retryable_transaction`, then re-raise. Other exceptions propagate without a journal entry.
- `Changelog::Context#insert_all!(records)`: for fork copies, imports and batched scans. Takes unsaved instances of one `Branched` model, runs their validations (raising `ActiveRecord::RecordInvalid` on the first failure), assigns `id`, `lineage` and `updated_seq`, builds after-images, and inserts the rows and their upsert Changes with `insert_all`. Inserts only; updates go through ordinary saves.
- `ActiveRecord::SerializationFailure` and `ActiveRecord::Deadlocked` escaping `retryable_transaction` are mapped to Connect `unavailable` in `Api::ApplicationController`.
- RuboCop cop `Changelog/BulkWrite` (`backend/rubocop/changelog_bulk_write.rb`, next to `Dsql/TransactionOccAwareness`) flags, outside `app/models/changelog.rb` and `app/models/changelog/`:
  - `insert_all`, `upsert_all`, `update_all`, `delete_all`, `delete_by`, `update_column`, `update_columns`, `update_counters`, `increment!` and `decrement!`
  - `insert`, `insert!` and `upsert` given a Hash
  - `insert_all!` unless called on `Changelog.current`
  - `touch` unless called on `FileUtils`
  - `delete` with no arguments on a receiver, and `delete` with arguments on a constant other than `ENV`, `File` and `Dir`

  It cannot tell a `Branched` receiver statically, so non-branched callers disable it inline.
- In `app/models/errors.rb`: the `Errors::Rejection` marker; `Errors::BranchNotWritable` with its subclasses `Errors::BranchFrozen` and `Errors::BranchNotReady`; `Errors::MutationIdReused` and `Errors::DuplicateRow`, both subclasses of `Errors::Conflict`; `Errors::ResyncRequired`. `PROBLEM_TYPE_BRANCH_NOT_WRITABLE` and `PROBLEM_TYPE_RESYNC_REQUIRED` in `problem.proto`. In `app/models/changelog.rb`, the bug errors `Changelog::UndeclaredBranch`, `Changelog::NotWriting` and `Changelog::TransactionOpen`.
- `Changelog::Cursor`: encodes and decodes the opaque cursor (today base64url of `<branch uuid>:<seq>` with a version prefix `v1.`); an unknown version, a cursor for another branch, or a `seq` beyond the bigint range raises `Errors::ResyncRequired`.
- Transaction size: a write of N rows mutates about 2N rows (rows plus Changes) plus one ChangeSet. Callers that write many rows (fork copy, imports, bulk scans) chunk at ~1,000 rows per `Changelog.write` to stay under DSQL's 3,000 rows and 10 MiB.

### Spike

The domain model leaves "lineage in Rails" as a spike. Do it first, on local PostgreSQL:

- one `Branched` toy model with a `belongs_to` to another, both using `typeid_rails` with client-supplied UUIDv7 ids
- `Changelog.write` from several threads, asserting gap-free `seq`
- coalescing and `changed_fields` on a model with a composite proto field

### Tests

Everything runs on local PostgreSQL; there is no DSQL test cluster. PostgreSQL serialises concurrent `head_seq` bumps with a row lock where DSQL aborts and retries, so both reach the same gap-free result. The DSQL retry path is exercised with `trigger_dsql_conflict!`. Real DSQL behaviour under concurrent load is verified only by design and in production.

- model specs for `Branched`: id and lineage defaults, natural key uniqueness, `insert_only!`
- `Changelog.write`: seq increments, lazy bump, multi-branch and its atomicity, frozen and preparing branch rejection, undeclared branch, an open transaction, coalescing, `changed_fields`, delete before-image, aborted saves and destroys, replay of applied and rejected Mutations, replay mismatch (rpc, actor, payload), duplicate-id race, which problems are journalled, unique-key race, OCC and deadlock retry and exhaustion, the logged outcome of each path
- concurrency: several threads write one branch and two branches at once; `seq` is 1..N with no gaps and every Change has its ChangeSet; two writers locking two branches in opposite orders both commit
- `Changelog/BulkWrite`: every flagged form, and the same names on non-record receivers
- `Changelog::Cursor`: round trip, unknown version, wrong branch and an out-of-range `seq` raise `ResyncRequired`
- `insert_all!`: validation failure, Changes recorded per row

## Current Status

Implementation complete.

### Checklist

- [x] Spike on local PostgreSQL: toy `Branched` models with `typeid_rails` and client UUIDv7 ids, threaded `Changelog.write`, coalescing with a composite proto field
- [x] `db/schema/branches.sql`, `change_sets.sql`, `changes.sql`, `mutations.sql`
- [x] `Branch` (`Branch.fleet_main`, `#writable?`, `#plan?`, `#fleet?`)
- [x] Read-only `ChangeSet`, `Change`, `Mutation` models
- [x] `Branched` concern: id and lineage defaults, `natural_key`, `changelog_resource`, `insert_only!`, `on`, `find_by_natural_key!`, `find_by_lineage`, before-image capture, registration with the context
- [x] `Changelog.write`: lazy bump, coalescing and `changed_fields`, ChangeSets and Changes, Mutation journal with stored response, replay and mismatch, duplicate-id race, rejection journalling
- [x] `Changelog::Context#insert_all!`
- [x] `Changelog::Cursor`
- [x] `Errors::BranchNotWritable`, `Errors::ResyncRequired`, `PROBLEM_TYPE_BRANCH_NOT_WRITABLE` and `PROBLEM_TYPE_RESYNC_REQUIRED` (both 412)
- [x] Map an escaping `ActiveRecord::SerializationFailure` to Connect `unavailable`
- [x] Job Actor propagation (starting Actor serialised into the job data at enqueue, else `system`)
- [x] `Changelog/BulkWrite` cop
- [x] Canonical log line fields and counters (021); `occ_retries` incremented from `DsqlTransactionable#retryable_transaction`
- [x] Specs listed under Tests

### Updates

- 2026-11-08: Interview complete. Follow-ups outside this spec: 004 and 006 use the opaque `string cursor` and handle `RESYNC_REQUIRED`; 003 and 013 record an opaque branch version instead of a bare `seq`; spec 020 (history and restore) to be written.
- 2026-11-08: Spike done on local PostgreSQL with toy models in `spec/support/changelog_helper.rb` (`SpikeRack`, `SpikeDevice` with a `belongs_to` and a composite `position` field, insert-only `SpikeScan`) on test-only tables, and their messages built into the descriptor pool at load time. Client-supplied UUIDv7 TypeIDs, `belongs_to` by TypeID, threaded writes on one and two branches, coalescing and `changed_fields` over a message field all work as designed. `lineage` gets the model's TypeID type, so it reads as `<prefix>_...` like `id`.
- 2026-11-08: Schema and models. Deviation: the `branches.frozen` column is `is_frozen`, because Active Record refuses a `frozen` attribute (`frozen?` clashes with `Object#frozen?`, `DangerousAttributeError`). The proto field stays `frozen`. `Branch.fleet_main` only finds the row; creating Fleet main is left to 003.
- 2026-11-08: Protos added for what 002 stores before 004 lands: `branch.proto` (`Branch` with `Dataset` and `State`, without `head_seq`/`forked_at_seq`, as seqs never go on the wire), `mutation.proto` (`MutationHeader`, `Mutation` with `Outcome`), `sync.proto` (`Change` with `Op`, without the entity `oneof`). 004 extends these files. `MutationHeader` carries `map<string, string> base_cursors` instead of 004's draft `map<string, int64> base_seqs`, following the opaque-cursor rule; `Changelog.write` decodes them into `mutations.base_seqs` and leaves out any cursor it cannot read. `mutation_id` is validated as a `mut_` TypeID with a CEL rule.
- 2026-11-08: `Changelog.write`, `Changelog::Context` (with `insert_all!`), `Changelog::Cursor` and the journal. Notes:
  - The declared branches are not reloaded at the start of the transaction; only their ids are used, and the bump's `RETURNING state, is_frozen` is the writability check, so an unwritten branch adds nothing to the read set.
  - `mutations.payload` and `mutations.response` hold the ProtoJSON of a `google.protobuf.Any`, so a stored message names its own type for replay and for 020. `mutations.error` holds the `protobufable.ProblemDetails` the Connect error carries, `information` included.
  - A replayed rejection is raised as `Changelog::ReplayedRejection`, a `Problem::Detailable` rendering the stored document. A journalled `RecordInvalid` becomes `Errors::InvalidRecord` on the payload's `input` field with proto field names, so a replay of a JSON request names fields in snake_case where the first answer used ProtoJSON names.
  - A save that changes nothing takes no seq and records no Change. A branch whose only Changes cancel out (created then destroyed) still gets its ChangeSet, keeping `seq` gap-free.
  - `ordinal` is numbered from 1 per ChangeSet after coalescing.
  - The after-image is built at the end of the write from a detached copy of the row taken at its last save, so later in-memory edits to the instance do not leak into it.
  - `Changelog.write` requires `Current.actor` (raising otherwise) and does not nest. A write with a `mutation` requires `rpc:` and `payload:`.
  - `branch_id` and `lineage` are `attr_readonly` on Branched rows.
  - Specs that commit are tagged `:committing` (no transactional fixture, tables emptied afterwards). `trigger_dsql_conflict!` raises SQLSTATE 40001 with an OC001 message from PL/pgSQL, which aborts the transaction as DSQL does.
- 2026-11-08: `Errors::BranchNotWritable` and `Errors::ResyncRequired` with their problem types. `Errors.problem_details_for` builds the `ProblemDetails` both the journal and `ConnectExceptions` use. `ActiveRecord::SerializationFailure` maps to Connect `unavailable` through `map_connect_errors`.
- 2026-11-08: Logging. `mutation_id` and `mutation_outcome` are payload fields; `occ_retries`, `change_sets_written` and `changes_written` are counters (`RequestLogContext.increment` learns `by:`). Counters are added after the transaction commits, so retried attempts are not counted twice. `problem_type` on the Completed line is read from the problem document, so a replayed rejection reports its stored type.
- 2026-11-08: Jobs. `ApplicationJob` captures `Current.actor` when the job is built, carries it in the serialized job data (`netaid_actor`), and performs with it as `Current.actor`, or with `Actor.system(<job class>)` when none started it, adding the Actor's tags to the Performed line. A job performed inline restores the caller's `Current.actor`.
- 2026-11-08: `Changelog/BulkWrite` cop with specs, excluded for `app/models/changelog.rb` and `app/models/changelog/`.
- 2026-11-08: Implementation complete. Open points for the spec author:
  - The cop flags exactly the six listed methods. `insert`, `insert!`, `upsert` and `insert_all!` on a model skip callbacks too but are not flagged; `insert_all!` shares its name with `Changelog::Context#insert_all!`.
  - `MutationHeader.base_cursors` replaces the `base_seqs` map of 004's draft; 004 and 006 should adopt it.
- 2026-11-08: Review fixes.
  - A preparing branch raises `Errors::BranchNotReady` (a `BranchNotWritable`), which is not journalled, so the retry applies once the branch is ready. A frozen branch is still journalled as rejected.
  - `app_user` gets only `select, insert` on `change_sets`, `changes` and `mutations`.
  - `Changelog/BulkWrite` also flags `delete_by`, `update_counters`, `increment!`, `decrement!`, a model's `insert_all!` (not `Changelog.current`'s), `insert`/`insert!`/`upsert` given a Hash, `touch` (not `FileUtils`'s) and an argument-less `delete`. `Changelog::Context#touch` is renamed `#track` so it does not trip the cop.
- 2026-11-14: Validation fixes.
  - A save or destroy aborted by a later callback records no Change, instead of failing the write.
  - `Changelog.write` raises `Changelog::TransactionOpen` inside a joinable transaction instead of joining it.
  - Only `Errors::Rejection` problems and `RecordInvalid` are journalled. The marker is on `NotFound`, `FailedPrecondition`, `InvalidRecord` and the new `BranchFrozen`, which a frozen branch raises.
  - A unique violation from the block runs the write once more, then raises `Errors::DuplicateRow` (`conflict`, Connect `aborted`) without journalling.
  - `retryable_transaction` retries deadlock victims, and a retried `Changelog.write` takes the seqs of the branches its failed attempt wrote in id order first. An escaping `Deadlocked` answers `unavailable`.
  - `mutation_outcome` is logged for every write with a mutation, adding `reused` and `failed`.
  - A cursor whose `seq` exceeds the bigint range answers `resync-required`.
  - `Changelog/BulkWrite` flags `delete` with arguments on a constant receiver.
  - Expected Outcomes gain the two above on rejections and races.
  - Spec body brought in line with the code: `is_frozen`, the delete before-image in `changes.data`, `Any` storage, `base_cursors`, the write algorithm and signature, the cop list, the errors and the grants.
- 2026-11-14: Review fixes.
  - `ActorJob`, included in `ApplicationJob`, captures the starting Actor when the job is serialised at enqueue rather than when it is built, and also sets it around `rescue_from`, `retry_on` and `discard_on` handlers. A job performed inline runs as its caller.
  - Every job, `ActiveJob::Base` included, is enqueued after the enclosing transaction commits (`config/initializers/active_job.rb`).
