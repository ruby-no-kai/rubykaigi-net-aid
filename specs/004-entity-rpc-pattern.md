# 004-entity-rpc-pattern

## Summary

The common Connect RPC shape every entity follows, so that adding an entity is mostly declaration: bootstrap a branch (all rows at a `head_seq`, cacheable on S3/CloudFront for frozen branches), pull or stream Changes after a `seq`, and submit Mutations carrying client-generated ids and an idempotency key. It covers per-field last-writer-wins, insert-only entities, lookup by TypeID or natural key, and how a Rails model, Alba resource and proto message are tied together per entity.

The frontend, agents and rubykaigi-net automation all use this API.

## Motivation

- The README asks for "a common pattern to manipulate or hydrate data on/from Rails backend (common RPC pattern per model)". There are about 35 entities in the domain model; hand-designing each one's API would drift.
- Local-first clients (006) do not query per screen. They load one Plan branch and its Fleet branch in full, then follow the change feed, so reads are generic and writes are where entity-specific logic lives.
- Offline clients retry. Every write must be idempotent by a client-chosen key, and must accept ids the client generated while offline (a newly registered asset assigned to a device before syncing).
- Agents and automation need a plain, documented API too: lookups by natural key (`rk26kor` / `es-tra-01.venue`, `rk-aph26a3`), not only by TypeID.

## Explanation

### Shared messages

```proto
// proto/rubykaigi/net_aid/row.proto
// Columns every branched row carries.
message Row {
  string id = 1;          // TypeID with the entity's prefix
  string lineage = 2;     // TypeID, same prefix; equal across branches for the same thing
  string branch_id = 3;
  int64 updated_seq = 4;
  google.protobuf.Timestamp created_at = 5;
  google.protobuf.Timestamp updated_at = 6;
}

// proto/rubykaigi/net_aid/mutation.proto
// Carried by every write request.
message MutationHeader {
  string mutation_id = 1;              // client-generated UUID (mut_ TypeID); the idempotency key
  map<string, int64> base_seqs = 2;    // branch id -> seq the client had applied
  google.protobuf.Timestamp client_time = 3;
}

// Returned by every write.
message MutationResult {
  string mutation_id = 1;
  map<string, int64> seqs = 2;         // branch id -> seq of the ChangeSet this write produced
  repeated string overwritten_fields = 3; // fields another writer had changed after base_seqs
}

// Addresses a branch by id or by a name people use.
message BranchRef {
  oneof ref {
    string branch_id = 1;
    string episode_slug = 2; // that Episode's Plan branch
    bool fleet_main = 3;
  }
}
```

### Sync (generic)

```proto
service SyncService {
  // Every row of one branch, consistent at head_seq.
  rpc Bootstrap(SyncServiceBootstrapRequest) returns (SyncServiceBootstrapResponse) {
    option idempotency_level = NO_SIDE_EFFECTS;
  }
  // Changes after a seq, in order.
  rpc PullChanges(SyncServicePullChangesRequest) returns (SyncServicePullChangesResponse) {
    option idempotency_level = NO_SIDE_EFFECTS;
  }
}

message SyncServiceBootstrapRequest {
  BranchRef branch = 1;
  int64 at_seq = 2;           // 0 on the first page; the first page's head_seq on later pages
  string page_token = 3;
}
message SyncServiceBootstrapResponse {
  Branch branch = 1;          // includes head_seq
  int64 at_seq = 2;           // the seq this image is consistent at
  oneof image {
    PlanImage plan = 3;
    FleetImage fleet = 4;
    string cached_url = 5;    // frozen branches: a signed CloudFront URL of the full serialised image
  }
  string next_page_token = 6; // empty on the last page
}

// One repeated field per Plan entity, added by each entity spec.
message PlanImage {
  repeated Site sites = 1;
  repeated Location locations = 2;
  // ...
}
message FleetImage {
  repeated Product products = 1;
  // ...
}

message SyncServicePullChangesRequest {
  BranchRef branch = 1;
  int64 after_seq = 2;
  int32 limit = 3;            // ChangeSets, default 100, max 1000
}
message SyncServicePullChangesResponse {
  repeated ChangeSet change_sets = 1;
  int64 head_seq = 2;
  bool has_more = 3;
}

message ChangeSet {
  string id = 1;
  int64 seq = 2;
  Actor actor = 3;
  string mutation_id = 4;
  google.protobuf.Timestamp committed_at = 5;
  repeated Change changes = 6;
}

message Change {
  string entity_id = 1;
  Op op = 2;
  repeated string changed_fields = 3;
  oneof entity {             // after-image; unset on delete
    Site site = 10;
    Location location = 11;
    // ... one per entity, numbered per entity spec
  }
  enum Op { OP_UNSPECIFIED = 0; OP_UPSERT = 1; OP_DELETE = 2; }
}
```

- A client that applied up to `seq` N calls `PullChanges(after_seq: N)` until `has_more` is false; nothing is missed.
- Lambda responses are capped at 6 MB and the function URL setup does not stream, so `Bootstrap` of an open branch is paginated (by table, then by `id`, a few MB per page).
- Pages of one bootstrap are not read in one transaction. Each page returns rows as they are now, and the client then pulls Changes after the first page's `at_seq`; replaying those Changes over the pages converges to a consistent image (after-images are idempotent upserts). `TODO(interview)`: confirm this "fuzzy image + catch-up" approach.
- Frozen branches: the full image is generated once when the branch freezes, stored on S3 and served through CloudFront; `Bootstrap` answers a signed `cached_url` with no pages. `TODO(interview)`: binary protobuf or protojson for the cached file; gzip/brotli.
- Live updates: clients short-poll `PullChanges` every few seconds while in the foreground (006). Connect server streaming is not available in connect_rpc_rails on Lambda. Long-polling (`wait_ms`) or a push channel (AppSync Events, API Gateway WebSocket) stay as later options.

### Per-entity services

For an entity `Site` in the Plan:

```proto
service SiteService {
  rpc GetSite(SiteServiceGetSiteRequest) returns (SiteServiceGetSiteResponse) {
    option idempotency_level = NO_SIDE_EFFECTS;
  }
  rpc ListSites(SiteServiceListSitesRequest) returns (SiteServiceListSitesResponse) {
    option idempotency_level = NO_SIDE_EFFECTS;
  }
  rpc CreateSite(SiteServiceCreateSiteRequest) returns (SiteServiceCreateSiteResponse);
  rpc UpdateSite(SiteServiceUpdateSiteRequest) returns (SiteServiceUpdateSiteResponse);
  rpc DeleteSite(SiteServiceDeleteSiteRequest) returns (SiteServiceDeleteSiteResponse);
}

message SiteServiceGetSiteRequest {
  BranchRef branch = 1;
  oneof key {
    string id = 2;      // TypeID
    string lineage = 3;
    string slug = 4;    // natural key
  }
}

message SiteServiceCreateSiteRequest {
  MutationHeader header = 1;
  BranchRef branch = 2;
  string id = 3;        // optional client-generated TypeID; server generates when empty
  SiteInput input = 4;
}

message SiteServiceUpdateSiteRequest {
  MutationHeader header = 1;
  string id = 2;
  SiteInput input = 3;
  google.protobuf.FieldMask update_mask = 4; // required; fields of SiteInput
}

message SiteServiceDeleteSiteRequest {
  MutationHeader header = 1;
  string id = 2;
}

message SiteServiceCreateSiteResponse {
  MutationResult result = 1;
  Site site = 2;
}
```

Rules:

| Rule | Behaviour |
|---|---|
| Idempotency | a repeated `mutation_id` returns the stored response or error; the write never applies twice |
| Client ids | `Create*` accepts an `id`; the prefix must match the entity. Creating an id that exists under a different `mutation_id` is `already_exists` |
| Per-field LWW | `Update*` applies only the fields in `update_mask`. Concurrent updates of different fields both survive; for the same field, the later commit wins |
| Overwrites | when a masked field was changed by a ChangeSet after the client's `base_seqs`, the write still applies and the field is listed in `overwritten_fields` so the client can tell the user |
| Deletes | deleting an already-deleted id succeeds (a delete Change exists); a never-existing id is `not_found`. Rows still referenced are rejected with `in_use` unless the entity spec says otherwise |
| Insert-only | entities such as `InventoryScan` and `ShipmentItem` have only `Create*` (or a batch command), no update or delete |
| Domain commands | operations that are more than a field edit get named RPCs on the entity's service (`DeviceService.AssignFill`, `LinkService.AllocateLink`). They carry `MutationHeader` and may write several branches |
| Branch | the target branch is `branch` on create and the row's own branch otherwise; it must be `ready` and not frozen |
| Roles | reads need `viewer`, writes `operator` unless the entity spec says otherwise (001) |

- `List*` is for agents and exports: `branch`, optional filters defined per entity, `page_size`, `page_token`. The frontend uses `Bootstrap` instead.
- `TODO(interview)`: a generic `Batch` RPC carrying several entity writes in one Mutation, or only domain commands for multi-row writes?

### History

```proto
service HistoryService {
  rpc ListEntityChanges(...) returns (...) { option idempotency_level = NO_SIDE_EFFECTS; } // one row's Changes, newest first
  rpc GetMutation(...) returns (...) { option idempotency_level = NO_SIDE_EFFECTS; }       // payload and outcome
  rpc ListMutations(...) returns (...) { option idempotency_level = NO_SIDE_EFFECTS; }     // by actor or outcome, for restore
}
```

### For agents

Every RPC is plain HTTP POST with protojson (`Content-Type: application/json`, `Connect-Protocol-Version: 1`), or GET for `NO_SIDE_EFFECTS` ones:

```sh
curl -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' -H 'Connect-Protocol-Version: 1' \
  https://aid.rubykaigi.net/api/rubykaigi.net_aid.DeviceService/GetDevice \
  -d '{"branch":{"episodeSlug":"rk26kor"},"siteSlug":"venue","name":"es-tra-01"}'
```

`TODO(interview)`: the API path prefix behind CloudFront (`/api/` proposed, 007).

## Drawbacks

- `PlanImage`, `FleetImage` and `Change.entity` grow with every entity; they are central files every entity spec edits.
- Field masks are more work for clients than whole-object updates, but whole-object updates would make LWW per row, not per field.
- Polling for changes adds latency (seconds) and Lambda invocations; acceptable for a small team.
- A paginated bootstrap is not a point-in-time image until the client has caught up with Changes after `at_seq`.
- Keeping `List*` alongside `Bootstrap` is two read paths to maintain.

## Considered Alternatives

- `google.protobuf.Any` in Change and Bootstrap: one generic field, but clients lose typing and must keep a type registry. A typed `oneof` keeps TypeScript exhaustive.
- GraphQL or REST: the stack is already Connect and protobuf (docs/coder/api.md).
- One generic `MutateService.Apply(entity_type, op, any)`: fewer RPCs, but domain validation and permissions become stringly typed, and agents lose discoverable methods.
- Optimistic concurrency with version checks (reject on stale `updated_seq`): loses submitted updates, against the requirement. `overwritten_fields` informs instead of rejecting.

## Prior Art

- Linear's sync engine: bootstrap, delta packets, client transactions.
- Replicache: push (mutations with ids) and pull (cookie-based patch).
- Google AIP-134 (update with field mask), AIP-133 (create with client-assigned id), AIP-155 (request ids for idempotency).
- NetBox REST API natural-key filters.

## Security and Privacy Considerations

- Every RPC requires authentication and a role (001). `Bootstrap` returns everything in a branch, so `viewer` is the minimum.
- `cached_url` for frozen branches is a CloudFront signed URL with a short expiry, never a public object. `TODO(interview)`: expiry length.
- Client-generated ids are validated for prefix and UUID version and cannot collide with another branch's rows (UUIDs are global).
- Request size limits: `PullChanges.limit` is capped; batch commands cap their item counts per entity spec.

## Mission Scope

### Out of scope

- The client sync engine and outbox (006).
- Individual entities, which come with their own specs (008 onwards).
- Restore UI.
- Push channels for live updates, unless chosen in the interview.

### Expected Outcomes

- Adding an entity means: a proto message, `<Entity>Input`, a service with the standard RPCs, a model including `Branched`, an Alba resource, a controller declaring the entity, and a field in `PlanImage`/`FleetImage` and `Change.entity`.
- A spec helper (`it_behaves_like "a branched entity service"`) covers idempotency, client ids, field masks, deletes and frozen branches for every entity.
- Agents can read and write by natural key with curl.

## Implementation Plan

### Proto layout

| File | Contents |
|---|---|
| `proto/rubykaigi/net_aid/row.proto` | `Row` |
| `proto/rubykaigi/net_aid/mutation.proto` | `MutationHeader`, `MutationResult`, `BranchRef` |
| `proto/rubykaigi/net_aid/sync.proto`, `sync_service.proto` | `PlanImage`, `FleetImage`, `ChangeSet`, `Change`, `SyncService` |
| `proto/rubykaigi/net_aid/history_service.proto` | `HistoryService` |
| `proto/rubykaigi/net_aid/<entity>.proto`, `<entity>_service.proto` | per entity |

- TypeID fields get a CEL rule checking the prefix (`typeid.site` style, `TODO(interview)`: shared predefined rule or per field).
- `buf lint` keeps `<Service><Method>Request` naming (docs/coder/api.md).

### Rails

- `app/controllers/concerns/entity_actions.rb`:

  ```ruby
  class Api::Site::SitesController < Api::Site::ApplicationController
    entity_actions Site, input: Rk::NetAid::SiteInput, resource: Api::SiteResource
    # defines get_site, list_sites, create_site, update_site, delete_site

    #: (Site, Rk::NetAid::SiteInput, Array[String]) -> void
    private def assign_input(site, input, fields)
      site.slug = input.slug if fields.include?("slug")
      site.kind = input.kind if fields.include?("kind")
      site.description = input.description if fields.include?("description")
    end
  end
  ```

  - `assign_input` is written per entity, keeping explicit field copies (docs/coder/api.md).
  - `create_*`/`update_*`/`delete_*` wrap `Changelog.write(mutation: connect_request.header, branches: [...])`.
  - `overwritten_fields`: compare masked fields against Changes for the row with `seq > base_seqs[branch]`.
- `app/models/branch_ref.rb`: resolves a `BranchRef` to a `Branch`.
- `app/models/sync_image.rb`: builds `PlanImage`/`FleetImage` from `Branched.registry` and each model's resource.
- `app/models/change_renderer.rb`: `Change` row (jsonb protojson) to proto `Change` with the right `oneof` field, keyed by `entity_type`.
- `FrozenImageJob`: on freeze, serialise the Bootstrap response and upload it to S3 (`bootstrap/<branch_id>.binpb`).
- Controllers: `Api::Sync::SyncController`, `Api::History::HistoryController`.
- Problem types: `branch_not_writable`, `already_exists`, `in_use`, `not_found` (check which exist in `problem.proto`).

### Tests

- `spec/support/shared_examples/branched_entity_service.rb`
- Bootstrap pagination: writes between pages converge after pulling Changes from `at_seq` (DSQL only)
- PullChanges pagination and `has_more`
- `cached_url` returned for frozen branches

## Current Status

Draft: rough content populated, not yet reviewed. Interview not started.

Open questions:

- From 001/002 review: Bootstrap and PullChanges carry an opaque `string cursor`, not `int64 seq`; `PROBLEM_TYPE_RESYNC_REQUIRED` (412) forces a re-bootstrap; `updated_seq` is not in any API message; RPC method names must be unique across services (authorisation actions are `netaid:<Method>`), asserted by a route-walking spec; API host is `aid.rubykaigi.net`.
- paginated bootstrap as fuzzy image plus catch-up from `at_seq`
- format and compression of cached frozen-branch images; signed URL expiry
- whether short polling is enough, or long-polling or a push channel is needed later
- generic `Batch` RPC vs domain commands only
- TypeID validation rule shape in proto
- API path prefix behind CloudFront
