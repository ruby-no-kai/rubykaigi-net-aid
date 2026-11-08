# 003-episodes-and-branch-lifecycle

## Summary

Episode and the operations that move branches through their life: start an Episode by forking a Plan branch from any earlier one, close an Episode (freeze its Plan branch, snapshot Fleet main, repoint `fleet_branch`), and take a Fleet snapshot at any other moment. Copies are eager and run as chunked background jobs within DSQL's per-transaction limits, and a branch stays `preparing`, rejecting writes, until its copy finishes.

In-branch references are rewritten through a lineage map while copying, and cross-dataset Device fills are remapped to the target Fleet branch. Importing past Episodes from their sheets builds on these operations and is specified in 012.

## Motivation

- Each RubyKaigi and Kaigi on Rails starts from an earlier network: `rk26kor` from `rk26`, `rk27` from `rk26` (not from `rk26kor`). Today that is "copy last year's spreadsheet and edit"; the app needs the same, from any earlier Episode.
- Closed Episodes must stay readable as they were, including which physical asset filled each device, even after those assets move, break or are disposed.
- The Fleet keeps one live timeline, but audits and Episode closes want a frozen point to refer back to.
- The data is small (hundreds to a few thousand rows per table), so eager copies keep every read a plain `where branch_id = ?`, at the cost of a copy job that has to respect DSQL's 3,000-row and 10 MiB transaction limits.

## Explanation

### Episode

| Field | Notes |
|---|---|
| `slug` | unique: `rk26`, `rk26kor`; also the `#rk26` interface-description tag |
| `name` | "RubyKaigi 2026" |
| `organizer` | `rk`, `kor` |
| `starts_on`, `ends_on`, `venue_name` | |
| `status` | `planning → setup → live → teardown → closed` |
| `plan_branch_id` | the Episode's main Plan branch |
| `fleet_branch_id` | Fleet main while open; the Fleet snapshot taken at close |

- `status` moves freely among the open states by `UpdateEpisode`. Only `CloseEpisode` sets `closed`, and a closed Episode never reopens. `TODO(interview)`: is reopening needed, e.g. to fix a mistake after close?
- Episode and Branch rows are global, not branched, and are not in any branch's changelog. Clients refetch them with `ListEpisodes`. `TODO(interview)`: put Episode changes in a global feed for clients?

### Operations

```proto
service EpisodeService {
  rpc ListEpisodes(EpisodeServiceListEpisodesRequest) returns (EpisodeServiceListEpisodesResponse) {
    option idempotency_level = NO_SIDE_EFFECTS;
  }
  rpc GetEpisode(EpisodeServiceGetEpisodeRequest) returns (EpisodeServiceGetEpisodeResponse) { // by id or slug
    option idempotency_level = NO_SIDE_EFFECTS;
  }
  rpc CreateEpisode(EpisodeServiceCreateEpisodeRequest) returns (EpisodeServiceCreateEpisodeResponse);
  rpc UpdateEpisode(EpisodeServiceUpdateEpisodeRequest) returns (EpisodeServiceUpdateEpisodeResponse);
  rpc CloseEpisode(EpisodeServiceCloseEpisodeRequest) returns (EpisodeServiceCloseEpisodeResponse);
}

service BranchService {
  rpc ListBranches(BranchServiceListBranchesRequest) returns (BranchServiceListBranchesResponse) {
    option idempotency_level = NO_SIDE_EFFECTS;
  }
  rpc GetBranch(BranchServiceGetBranchRequest) returns (BranchServiceGetBranchResponse) {
    option idempotency_level = NO_SIDE_EFFECTS;
  }
  rpc CreateFleetSnapshot(BranchServiceCreateFleetSnapshotRequest) returns (BranchServiceCreateFleetSnapshotResponse);
}

message EpisodeServiceCreateEpisodeRequest {
  MutationHeader header = 1;
  EpisodeInput input = 2;          // slug, name, organizer, dates, venue_name
  string source_plan_branch_id = 3; // empty: an empty root Plan branch
}
```

| Operation | Role | Effect |
|---|---|---|
| Create an Episode (fork) | admin | new Episode with a `preparing` Plan branch whose `parent` is the source; copy job copies every Plan row at the source's head; fills are rewritten to Fleet main; branch becomes `ready` |
| Create an Episode (empty) | admin | new Episode with a `ready`, empty root Plan branch; used by imports (012) and the very first Episode |
| Close an Episode | admin | Plan branch becomes `preparing`; Fleet main is snapshotted; fills are rewritten to the snapshot; Plan branch is frozen; `fleet_branch_id` points at the snapshot; status `closed` |
| Fleet snapshot | admin | new frozen Fleet branch copied from Fleet main's head, named by the caller (`audit-2026-11`) |

- All three return at once with the Episode or Branch in `preparing`. Clients watch `GetBranch` until `ready` (`TODO(interview)`: or a push notification through the sync stream).
- Writes to a `preparing` branch are rejected with `branch_not_writable`, and the frontend shows the branch read-only with progress.
- A fork's source can be any Plan branch, frozen or not. Forking an open Episode copies it at a consistent `seq` (see Implementation Plan), recorded as `forked_at_seq`.
- Forking warns, in the result and in the target's first ChangeSet note, for every fill cleared because its asset or stock line no longer exists on Fleet main.
- Merge is not offered. Cherry-picking one entity across branches by lineage is `TODO(interview)`: in scope here, or later?

### What is copied

| Dataset | Copied | Not copied |
|---|---|---|
| Plan (fork) | organisation, IPAM, devices and interfaces, links, ASNs, waypoints, cables and segments | LabelExport and LabelBatch: per-Episode print artefacts, meaningless for a new Episode's labels |
| Fleet (snapshot) | every Fleet table, insert-only history included (InventorySession, InventorySessionScanner, InventoryScan, Shipment, ShipmentItem), so a snapshot stays readable for its old sessions and shipments | |

- Each model declares its policy (`copy_on_fork false` in `Branched`).
- `TODO(interview)`: cables and their segment statuses (`ordered`, `received` …) and CableOrders are consumed per Episode; copy them on fork with app-owned state reset, or not copy them at all and re-import from the sheet?
- Device fills follow the domain model: copied, then remapped to Fleet main, and cleared with a warning when the asset or stock line is gone from main. `TODO(interview)`: 016 proposes clearing every fill on fork instead, since fills are set at the venue and last Episode's fill is rarely this Episode's. Keep the remap, clear all, or keep as a hint only?

### What a forked branch looks like

- Every row has a new `id` and the source row's `lineage`.
- References inside the branch point at the new rows.
- Device fills point into Fleet main (forks) or the new snapshot (close).
- The branch's changelog starts with one ChangeSet per copied chunk, so a client that bootstraps from `seq` 0 by replaying Changes sees a full image.

## Drawbacks

- An open source branch keeps changing during a fork; consistency needs a catch-up phase, which is the most intricate part of this spec.
- Closing an Episode blocks Plan writes until the close job finishes (expected seconds to a minute).
- Every snapshot duplicates the whole Fleet, insert-only history included (~260 assets, a few hundred stock lines, plus every scan and shipment item so far). History grows every Episode, so snapshot cost grows too. `TODO(interview)`: acceptable, or copy only history since the previous snapshot and resolve older rows from that snapshot?

## Considered Alternatives

- Lazy, copy-on-write branches: no copy job, but every read must resolve "my row, or my ancestor's row at fork seq", and the domain model chose eager copies for plain reads.
- Storing a lineage map table per fork: needs extra writes and lookups. Deterministic ids (below) make the map a pure function.
- Forking only from frozen branches: avoids the catch-up phase, but `rk27` planning may start before `rk26kor` closes, and an audit snapshot of Fleet main must not stop scanning.
- Closing without snapshotting the Fleet (keeping fills pointing at Fleet main): history would show today's asset, not the one used.

## Prior Art

- Git branches and tags, reduced to linear history without merge.
- Neon / PlanetScale branching (eager or copy-on-write database branches).
- NetBox "branching" plugin, which also copies objects per branch.

## Security and Privacy Considerations

- Lifecycle operations are admin-only (001).
- Copy jobs run as the admin who started them; the Actor on their ChangeSets is that person, so history shows who forked or closed.
- A frozen branch is immutable to every caller, admins included. Corrections after close need a reopen operation, which is not offered yet.

## Mission Scope

### Out of scope

- Importing past Episodes and rebuilding their Fleet snapshot from `containers20xx` tabs (012, 014). This spec only provides the empty root Plan branch and a way to create a frozen Fleet branch with no parent (`TODO(interview)`: expose as an admin-only RPC or a rake task?).
- Branch diff views and cherry-picks.
- Deleting Episodes or branches.

### Expected Outcomes

- An admin can create `rk27` from `rk26` and get a writable copy whose rows share lineage with `rk26`'s.
- Closing `rk26kor` leaves its Plan branch frozen and its fills resolving into a frozen Fleet snapshot.
- A Fleet snapshot can be taken while scanners keep writing to Fleet main, and is consistent at its `forked_at_seq`.
- Copy jobs survive Lambda timeouts and retries without duplicating rows.

## Implementation Plan

### Schema

```sql
-- db/schema/episodes.sql
create table episodes (
    id uuid primary key default gen_random_uuid(),
    slug varchar(32) not null,
    name varchar(255) not null,
    organizer varchar(8) not null,      -- rk, kor
    starts_on date,
    ends_on date,
    venue_name varchar(255),
    status varchar(16) not null,        -- planning, setup, live, teardown, closed
    plan_branch_id uuid not null,
    fleet_branch_id uuid not null,
    created_at timestamp(6) with time zone not null default now(),
    updated_at timestamp(6) with time zone not null default now()
);
create unique index idx_episodes_slug on episodes (slug);
```

Additions to `branches` (002), decided at table creation since columns cannot change later:

```sql
    copy_source_branch_id uuid,         -- set while preparing
    copy_cursor jsonb,                  -- {"table": "devices", "after_id": "...", "phase": "bulk|catchup|remap"}
    copy_error text
```

### Deterministic ids

- A copied row's id is `UUIDv5(namespace: target_branch.id, name: source_row.id)`.
- Any in-branch foreign key is rewritten with the same function, so chunks can be copied in any table order and a retried chunk produces the same ids (`insert ... on conflict (id) do nothing`).
- Fleet main is a root branch, so every row on it has `id == lineage`. Remapping a fill from a snapshot back to Fleet main is therefore `asset_id := snapshot_row.lineage`, then checking that the row exists on main.
- `TODO(interview)`: confirm UUIDv5 ids are acceptable next to client-generated UUIDv7 (they sort randomly, which only affects index locality).

### Reference declarations

Entity models declare their references so the copier can rewrite them:

```ruby
class Device < ApplicationRecord
  include Branched
  branched_reference :site_id, :location_id, :primary_ip4_id, :primary_ip6_id, :asn_id
  fleet_reference :asset_id, to: "Asset"
  fleet_reference :stock_line_id, to: "StockLine"
end
```

- `Branched.registry` lists every branched model per dataset; the copier walks it.
- A spec asserts that every `*_id` column of a branched model is declared as a reference or explicitly ignored.

### Copy job

`BranchCopyJob` (`app/jobs/branch_copy_job.rb`), arguments `target_branch_id`. One run processes chunks until ~10 minutes have passed, then re-enqueues itself with the cursor saved on the branch (Lambda's 15-minute limit).

1. Bulk phase: note the source's `head_seq` as `S0`. For each model in the registry, read source rows ordered by `id` in chunks of ~1,000, rewrite ids and references, and insert them with one `Changelog.write` per chunk (`Changelog::Context#record_bulk`, 002).
2. Catch-up phase: apply source Changes with `seq > S0` to the target: an upsert after-image becomes an upsert of the rewritten row, a delete becomes a delete. Repeat until caught up to the source's `head_seq` `Sn`.
3. Finish, in one transaction: re-read the source's `head_seq`; if it moved past `Sn`, go back to step 2. Otherwise set `forked_at_seq = Sn`, `state = ready`, clear the cursor.
- A frozen source skips step 2.
- Fill remapping happens during row rewrite for Plan forks (to Fleet main, clearing missing fills and collecting warnings).
- On an unrecoverable error, `copy_error` is set and the branch stays `preparing`. `TODO(interview)`: retry from the admin UI, or discard the branch?

### Close job

`EpisodeCloseJob`:

1. Set the Plan branch `preparing` (rejects writes; in-flight writes either committed before or fail).
2. Create the Fleet snapshot branch and run the copy job phases against Fleet main inline.
3. Rewrite every fill in the Plan branch: `asset_id := UUIDv5(snapshot.id, asset_id)`, in chunks through `Changelog.write`, so clients see the change.
4. In one transaction: freeze the Plan branch, set it `ready`, set `episodes.fleet_branch_id` and `status = closed`.

### Code

- `app/models/episode.rb`, with `Episode.fork!(source:, input:, actor:)`, `#close!(actor:)`.
- `app/models/fleet_snapshot.rb` or `Branch.snapshot_fleet!(name:, actor:)`.
- `app/models/branch_copier.rb`: the phases above, independent of ActiveJob for testing.
- Controllers `Api::Episode::EpisodesController`, `Api::Branch::BranchesController`.
- Proto files `proto/rubykaigi/net_aid/episode.proto`, `episode_service.proto`, `branch.proto`, `branch_service.proto`.
- Bootstrap: `rake netaid:bootstrap` creates Fleet main (`dataset fleet`, `name main`, root, `ready`) if missing; `bin/setup` and the first deploy run it.

### Tests

- `BranchCopier` with a toy registry: ids deterministic, references rewritten, re-running a chunk is a no-op
- catch-up: writes to the source during the bulk phase appear in the target, deletes included
- close: fills point at the snapshot, Plan branch frozen, writes rejected while `preparing`
- fork from a closed Episode: fills point at Fleet main; a disposed-and-deleted asset clears the fill with a warning

## Current Status

Draft: rough content populated, not yet reviewed. Interview not started.

Open questions:

- From 001/002 review: forks and exports record an opaque branch version (cursor), not a bare `seq`; `branches` gains `scope_key` (Episode uuid or `fleet`) with a unique index on `(scope_key, name)`; enum columns hold full proto enum value names.
- reopening a closed Episode
- a global feed for Episode and Branch changes
- snapshot cost of copying insert-only Fleet history every time
- copying cables, segment state and orders on fork
- fills on fork: remap to Fleet main (domain model) vs clear all (016's proposal)
- deterministic UUIDv5 ids for copies
- failure handling for copy jobs
- cherry-picks: here or later
- how to create a parentless frozen Fleet branch for imports
