# 008-plan-organisation

## Summary

The first Plan entities: Site, Location (nested within a Site) and Asn, with their editing UI. They are small on purpose, and prove the branch, changelog, RPC and sync patterns end to end before the larger IPAM and device models are built on them.

## Motivation

- Every later Plan entity hangs off a Site or a Location: Devices, Prefixes, VlanGroups, Waypoints. They have to exist first.
- The sheet's `locations` tab (`[tra] Hall C/メイン`, code, number) and `asns` tab (`65010 er.venue`) are small, and their shapes are simple: a slug, a name, an optional parent.
- 002 (branches and changelog), 004 (entity RPC pattern) and 006 (local-first sync) are abstract until one real entity goes through them. Building three tiny entities here, with UI, exposes the gaps in those specs while they are cheap to fix.
- Site is the `<dc>` in `<host>.<dc>.rubykaigi.net`. It is a fixed, well-known vocabulary (`hnd`, `nrt`, `itm`, `venue`, `apne1`, `usw2`, `transit`, `hot`, `tkyk`) that several later specs refer to by slug.

## Explanation

### Entities

```proto
// site: the <dc> in <host>.<dc>.rubykaigi.net.
message Site {
  string id = 1;
  string lineage = 2;
  string branch_id = 3;
  int64 updated_seq = 4;
  google.protobuf.Timestamp created_at = 5;
  google.protobuf.Timestamp updated_at = 6;

  string slug = 10; // unique per branch: hnd, nrt, itm, venue, apne1, usw2, transit, hot, tkyk
  Kind kind = 11;
  string description = 12;

  enum Kind {
    KIND_UNSPECIFIED = 0;
    KIND_POP = 1;
    KIND_VENUE = 2;
    KIND_CLOUD = 3;
    KIND_EXTERNAL = 4;
    KIND_STAGING = 5;
    KIND_LAB = 6;
  }
}

// loc: an area inside a Site, as in NetBox.
// A second building at the venue (venue2 at RK2026) is a top-level Location under venue.
message Location {
  // Row fields 1–6 as above
  string site_id = 10;
  string slug = 11; // unique per (branch, site): tra, fo0, lb0, noc
  string name = 12; // Hall C/メイン
  optional string parent_id = 13; // a Location in the same Site
}

// asn: devices link to their ASN.
message Asn {
  // Row fields 1–6 as above
  int64 number = 10; // unique per branch
  string name = 11; // er.venue
}
```

- TODO(interview): Row fields inline per message, or a shared `RowMeta row = 1` sub-message as in the tentative proto? Proposed: a shared `RowMeta` (004 decides; this spec follows).
- Slugs: lowercase `[a-z0-9-]+`, 1–32 chars. Location slugs are short codes (`tra`, `lb0`) used in device names (`es-tra-01`) and cable IDs (`@noc`), so they are unique within a Site, not globally.
- Location nesting: parent must be in the same Site, no cycles. Depth is unbounded but in practice one or two levels (`venue2` → `hall-x`).
- TODO(interview): should Location slug be unique per Site or per branch? Cable IDs (`@noc`) and device names (`es-tra-01`) only make sense at the venue, so per-Site is enough. Proposed: per Site.
- Asn `number`: 1–4294967295. The `name` is free text, usually a device FQDN without the domain.

### RPCs

One service per entity, following 004:

| Service | RPCs |
|---|---|
| `rubykaigi.net_aid.SiteService` | `CreateSite`, `UpdateSite`, `DeleteSite` |
| `rubykaigi.net_aid.LocationService` | `CreateLocation`, `UpdateLocation`, `DeleteLocation` |
| `rubykaigi.net_aid.AsnService` | `CreateAsn`, `UpdateAsn`, `DeleteAsn` |

- Reads go through `SyncService.Bootstrap` / `PullChanges` (004). No per-entity `List`/`Get` RPCs, unless 004 adds a generic lookup by natural key for agents.
- TODO(interview): do agents and scripts need `GetSite(slug)` / `ListLocations(site)` directly, or is bootstrap plus client-side filtering enough? Proposed: rely on 004's generic lookup.
- Every write carries `MutationHeader header` (client-generated mutation id, base seqs) and an `input`:

```proto
message SiteServiceCreateSiteRequest {
  MutationHeader header = 1;
  string branch_id = 2;
  string id = 3; // client-generated TypeID (site_…)
  SiteInput input = 4;
}

message SiteServiceUpdateSiteRequest {
  MutationHeader header = 1;
  string id = 2;
  SiteInput input = 3;
  repeated string field_mask = 4; // .proto names of input fields to write
}

message SiteServiceDeleteSiteRequest {
  MutationHeader header = 1;
  string id = 2;
}

message SiteInput {
  string slug = 1 [(buf.validate.field).string.pattern = "^[a-z0-9-]{1,32}$"];
  Site.Kind kind = 2;
  string description = 3;
}
```

- Delete is refused (`failed_precondition`, problem type `in-use`) while anything references the row: a Location under the Site, a Device at the Location, a child Location. TODO(interview): refuse, or cascade/clear references? Proposed: refuse for Site and Location; Asn clears `Device.asn_id` with a warning.
- Renaming a slug is allowed. Natural keys derived from it (FQDNs, cable IDs) change with it; nothing stores them.

### UI

Routes live under the Episode (005): `/<episode>/…`. All three screens read from the local object pool (006) and write through the outbox.

- `/<episode>/sites`: table of Sites (slug, kind, description, device count once 010 lands). Inline "New site" row. Click a row to edit in a side panel.
- `/<episode>/sites/<site>/locations`: tree of Locations under a Site, indented by parent. Each node shows slug, name, child and device counts. Actions: add child, edit, move (change parent), delete. Drag-to-reparent is optional.
- `/<episode>/asns`: table of ASNs (number, name). Inline add and edit.
- Frozen branches (closed Episodes) render read-only: no add/edit controls, a banner naming the Episode as closed.
- Edits made offline show a pending marker until the server acknowledges them; a rejected mutation shows its error on the row and offers to discard or retry.
- TODO(interview): is a generic table/editor component (driven by the proto descriptor) worth building here, for reuse by 009/010? Proposed: build simple hand-written screens first; extract once 009 shows the pattern.

### Initial data

- Seed Sites for a new Plan root: `hnd` (pop), `nrt` (pop), `itm` (pop), `venue` (venue), `apne1` (cloud), `usw2` (cloud), `transit` (external), `hot` (staging), `tkyk` (lab). TODO(interview): confirm the kinds for `transit`, `hot` and `tkyk`.
- Locations and ASNs come from 012 (sheet import) for real Episodes. In development, `db/seeds.rb` creates one Episode with these Sites and a few Locations.

## Drawbacks

- Three trivial entities each get a service, a controller, a resource, a table and a screen. Boilerplate is visible from day one; 004 must keep it small or this spec will show it.
- Building UI before IPAM means the first screens exercise sync on data nobody edits often. Real concurrency problems surface later, with addresses and scans.

## Considered Alternatives

- Hard-coding Sites as a static vocabulary (like Category): rejected, since Sites change across Episodes (`venue2` buildings, new cloud regions, `tkyk` lab) and belong to the Plan branch like everything else.
- Location as a single flat table without nesting: the sheet has none, but `venue2` at RK2026 is a building containing rooms, and NetBox nests Locations. Nesting is cheap to keep.
- Starting the vertical slice with Prefix instead: more useful, but the address storage scheme (009) would get tangled with the pattern work.

## Prior Art

- NetBox: Site, Location (nested, scoped to a Site), ASN. Field names follow NetBox where they overlap.
- The Network Data sheet's `locations` and `asns` tabs.

## Security and Privacy Considerations

- Writes require a role allowed to edit the Plan (001). Reads require any signed-in role.
- No personal data. Descriptions are free text and may mention venue room names, which are public.

## Mission Scope

### Out of scope

- Devices, VlanGroups, Prefixes and Waypoints referencing Sites and Locations (009, 010, 019).
- Importing `locations` and `asns` from the sheet (012).
- Location floor plans or coordinates.
- Location `number` (retired in the sheet).

### Expected Outcomes

- A Plan branch can hold Sites, Locations and ASNs, created and edited from the UI and the API.
- Every write lands in the changelog and reaches other open clients through `PullChanges`.
- Edits made offline are kept and submitted on reconnect.
- A closed Episode's Sites and Locations are browsable read-only.
- The per-entity boilerplate (schema file, model, input, resource, controller, routes, client store binding, screen) is documented as a checklist that 009 onwards follow.

## Implementation Plan

### Schema

```sql
-- db/schema/sites.sql
create table sites (
    id uuid primary key,
    lineage uuid not null,
    branch_id uuid not null,
    updated_seq bigint not null,
    slug varchar(32) not null,
    kind smallint not null,
    description text not null default '',
    created_at timestamp(6) with time zone not null default now(),
    updated_at timestamp(6) with time zone not null default now()
);

create unique index idx_sites_branch_slug on sites (branch_id, slug);
create unique index idx_sites_branch_lineage on sites (branch_id, lineage);
create index idx_sites_branch_seq on sites (branch_id, updated_seq);

grant all privileges on sites to app_admin;
grant select, insert, update, delete on sites to app_user;
```

```sql
-- db/schema/locations.sql
create table locations (
    id uuid primary key,
    lineage uuid not null,
    branch_id uuid not null,
    updated_seq bigint not null,
    site_id uuid not null,
    slug varchar(32) not null,
    name varchar(128) not null default '',
    parent_id uuid,
    created_at timestamp(6) with time zone not null default now(),
    updated_at timestamp(6) with time zone not null default now()
);

create unique index idx_locations_branch_site_slug on locations (branch_id, site_id, slug);
create unique index idx_locations_branch_lineage on locations (branch_id, lineage);
create index idx_locations_parent on locations (parent_id);
```

```sql
-- db/schema/asns.sql
create table asns (
    id uuid primary key,
    lineage uuid not null,
    branch_id uuid not null,
    updated_seq bigint not null,
    number bigint not null,
    name varchar(128) not null default '',
    created_at timestamp(6) with time zone not null default now(),
    updated_at timestamp(6) with time zone not null default now()
);

create unique index idx_asns_branch_number on asns (branch_id, number);
create unique index idx_asns_branch_lineage on asns (branch_id, lineage);
```

- `id` has no default: clients generate it (004). Server-created rows use `SecureRandom.uuid_v7`. TODO(interview): UUIDv7 for client ids too, so ids sort by creation? Proposed: yes.
- Enum columns are `smallint` holding the proto enum number.
- No foreign key constraints (DSQL does not enforce them); referential checks are model validations inside the write transaction.
- Whether `(branch_id, updated_seq)` is indexed per table depends on 004's bootstrap query. Listed here as the expected shape.

### Backend

| File | Content |
|---|---|
| `proto/rubykaigi/net_aid/site.proto`, `location.proto`, `asn.proto` | entity messages and inputs |
| `proto/rubykaigi/net_aid/site_service.proto`, … | services |
| `backend/app/models/site.rb`, `location.rb`, `asn.rb` | `include Branched`, `id_prefix "site"` / `"loc"` / `"asn"`, validations |
| `backend/app/resources/api/site_resource.rb`, … | Alba resources bound with `with_protobuf` |
| `backend/app/controllers/api/site/sites_controller.rb`, … | one action per RPC, writing through `Changelog.write` |
| `backend/config/routes.rb` | `connect_service` blocks |
| `backend/spec/requests/…` | request specs per RPC |

- Validations: slug format and uniqueness per branch (DB index is the source of truth; the model check gives a readable error), parent in the same Site and same branch, no cycles (walk parents inside the transaction).
- Writes: the controller builds the change and calls `Changelog.write(branch:, mutation:) { |tx| … }` (002), which bumps `head_seq`, sets `updated_seq`, and records Change rows.
- Fork (003): Locations' `site_id` and `parent_id` are rewritten through the lineage map. This spec registers those references with whatever registry 003 defines.

### Frontend

| File | Content |
|---|---|
| `frontend/src/models/site.ts`, `location.ts`, `asn.ts` | pool bindings for the generated messages (006) |
| `frontend/src/routes/episode/sites.tsx`, `locations.tsx`, `asns.tsx` | screens |
| `frontend/src/components/…` | location tree, inline editable table |

### Checklist for later entity specs

Written up at the end of this spec's implementation, as `docs/coder/adding-an-entity.md`: schema file, model, proto message + input + service, resource, controller + route, request spec, lineage references for forks, frontend model binding, screen.

## Current Status

Draft: rough content populated, not yet reviewed. Interview not started.

Open questions:

- Row fields inline or shared sub-message (decided by 004).
- Location slug uniqueness scope (proposed: per Site).
- Delete behaviour for referenced rows (proposed: refuse; Asn clears).
- Direct lookup RPCs for agents, or 004's generic lookup.
- Generic descriptor-driven editor now or later.
- Site kinds for `transit`, `hot`, `tkyk`.
- UUIDv7 for client-generated ids.
