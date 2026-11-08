# 012-network-sheet-import

## Summary

Imports an Episode's "Network Data" spreadsheet (`networks`, `addresses`, `asns`, `locations`, `devices`) into a Plan branch. It seeds the first live Episode, and rebuilds past Episodes (rk25, rk26 …) as frozen branches for reference. It also establishes the importer structure that the asset sheet import (014) and the repeated cable import (019) reuse.

## Motivation

- Every Episode so far lives in its own "<name> - Network Data" spreadsheet. The first Episode planned in the app needs to start from the last one's data, not from an empty branch.
- Past Episodes (rk25, rk25kor, rk26, rk26kor) are the reference people look up ("what was at `tra` last year?"). Rebuilding them as frozen branches makes that lookup work in the app, and gives forks a parent.
- The sheet's shapes need translating, not copying: `network` names split into Role, VLAN and scope (009), address rows become Device + Interface + IpAddress (010). Doing that by hand for ~460 addresses per Episode is not realistic.
- Cables (019) are imported repeatedly from the sheet for good; the asset sheet (014) once. All three need the same pieces: fetch a tab, map rows, match existing rows, report problems, write in chunks.

## Explanation

### Usage

- From the UI: `/<episode>/import` → choose source (Google Sheets URL or uploaded XLSX) → pick tabs → dry run → review report → apply.
- From the CLI (operators, past Episodes): `bin/rails import:network_sheet[<episode>,<source>] DRY_RUN=1`.
- Through the API, for agents:

```proto
service ImportService {
  rpc CreateImport(ImportServiceCreateImportRequest) returns (ImportServiceCreateImportResponse);
  rpc GetImport(ImportServiceGetImportRequest) returns (ImportServiceGetImportResponse) {
    option idempotency_level = NO_SIDE_EFFECTS;
  }
  rpc ApplyImport(ImportServiceApplyImportRequest) returns (ImportServiceApplyImportResponse);
}

message Import {
  string id = 1; // imp_…
  Kind kind = 2; // network_sheet; asset_sheet (014); cables (019)
  string branch_id = 3;
  Source source = 4;
  State state = 5; // pending, planned, applying, applied, failed
  Report report = 6;
  Actor actor = 7;
  google.protobuf.Timestamp created_at = 8;
  google.protobuf.Timestamp applied_at = 9;
  int64 applied_seq = 10;

  message Source {
    oneof source {
      string google_sheet_id = 1;
      string upload_key = 2; // XLSX uploaded to S3 via a presigned URL
    }
    repeated string tabs = 3;
  }

  message Report {
    repeated EntityCount counts = 1; // per entity type: create, update, delete, unchanged
    repeated Problem problems = 2; // row-level: tab, row number, column, message, severity
  }
}
```

- `CreateImport` fetches and parses, computes the plan (what would be created/updated), and returns the report. Nothing is written to the branch.
- `ApplyImport` runs the plan as a background job against the branch, writing through `Changelog.write` in chunks. The branch stays writable; the importer writes as its Actor.
- TODO(interview): Google Sheets API access (a service account the sheet is shared with) vs XLSX upload only? Proposed: both; Sheets for convenience, XLSX for sheets nobody can share with the service account. Past Episodes are one-off and could use XLSX.

### Modes

| Mode | Target | Behaviour |
|---|---|---|
| Seed | an empty or new Plan branch | create everything |
| Past Episode | a new Plan root branch for a past Episode | create everything, then freeze (003) |
| Re-import | an existing branch | match by natural key, update changed fields, report rows absent from the sheet; never delete without `prune: true` |

- TODO(interview): is re-import of the Network Data sheet needed at all, once the app is the source of truth? Proposed: only during the transition Episode, while some people still edit the sheet. Cables (019) are the real re-import case.

### Tab mappings

| Tab | Columns | Produces |
|---|---|---|
| `locations` | `[tra] Hall C/メイン`, code, number | Location (slug `tra`, name `Hall C/メイン`) under Site `venue`; `number` ignored |
| `asns` | asn, name | Asn |
| `networks` | name, 使途, CIDR4, CIDR6, VLAN id, default gateway, dhcp pool | Role, VlanGroup + Vlan, Prefix (v4 and v6), IpRange (`dhcp_pool`), Aggregate (from a fixed list) |
| `addresses` | dc, network, CIDR, IP, name, iface, mac, update, configured?, remark | Device (site=`dc`, name), Interface (iface, mac), IpAddress (IP with the prefix length of CIDR, configured_at, remark) |
| `devices` | ID, 種別, 場所, SKU, 備考, 調達先, asset tag, MAC | Device (location from 場所, required category from SKU, description from 備考); asset tag → fill (see below) |

- `networks` names → Role and scope follow the mapping table in 009 (`mgmt2` → role `mgmt`, VlanGroup `venue2`). The mapping is a constant in the importer, editable per Episode by a config hash. TODO(interview): unknown network names: create a Role with that slug, or report a problem? Proposed: create the Role and report info.
- Aggregates are not in the sheet. The importer creates the known ones (`10.33.0.0/16`, `2001:df0:8500::/48`, `192.50.220.152/29`, `10.33.128.0/18`) when absent.
- Gateway: v4 as given; v6 suffix `::a` expanded against CIDR6.
- `addresses.update` / `configured?` → `configured_at` (the date when given, else import time when ticked). TODO(interview): exact semantics of the two columns.
- Empty `iface`: Interface `lo` when network is `lo`, else the network name. (010's open question.)
- `devices.SKU` → `required_category` via a lookup of known SKUs to Category; unknown SKUs reported. TODO(interview): should SKU instead pick a Product (014) and derive the category?
- `devices.asset tag` → fill: only when a Fleet branch holding that asset is available (past Episode paired with a rebuilt Fleet snapshot, or Fleet main for the live Episode). Otherwise kept in the description and reported. TODO(interview): import order: 014 asset sheet before this for fills, or a second pass later?
- Rows merged across tabs by `(site, name)`: a Device may appear in `addresses` only, in `devices` only, or both.

### Report problems

- Unparseable IP/CIDR; IP not inside its row's CIDR; duplicate natural keys within the sheet; unknown `dc` (no Site); unknown location code; unknown SKU; asset tag not in the Fleet.
- Each problem carries tab, row number, column and the raw cell, so it can be fixed in the sheet and re-run.

## Drawbacks

- Sheets differ between Episodes (columns added, renamed, retired). Each past Episode may need its own column aliases.
- Google Sheets API access needs a service account and sharing each sheet with it.
- Importing past Episodes into frozen branches creates branches whose history is one big import ChangeSet, not their real history.

## Considered Alternatives

- Manual entry for the first Episode: too many rows.
- A one-off script outside the app: past Episodes and cables need the same machinery repeatedly, and imports should be in the changelog with an Actor.
- CSV per tab: loses tab structure and multi-line cells; XLSX/Sheets keep both.

## Prior Art

- NetBox's bulk CSV import (create/update by natural key, dry run).
- rubykaigi-net's `hosts.txt`, itself a TSV copy of the `addresses` tab.

## Security and Privacy Considerations

- Import requires a Plan editor role on the target branch; importing into a new past-Episode branch requires the operator role (001).
- The Google service account credentials are a secret (007). Read-only scope (`spreadsheets.readonly`).
- Uploaded XLSX files go to a private S3 prefix with a lifecycle rule (e.g. 30 days). They may contain the `cost` tab; the importer never reads tabs it was not asked for.

## Mission Scope

### Out of scope

- Cables tabs (019) and asset sheet (014); they reuse the framework.
- `ap-*`, `*-tepra`, `入庫申請`, `inventory-check-*`, `cost` tabs.
- Writing back to the sheet.

### Expected Outcomes

- rk26kor's sheet imports into a Plan branch with a report of problems, and the result matches the sheet's `hosts.txt` export (checked by 013's export diff).
- rk25, rk25kor, rk26 are available as frozen Plan branches.
- 014 and 019 build their importers on the same `Importers::Base` and `Import` record.

## Implementation Plan

### Structure

| File | Content |
|---|---|
| `backend/app/models/import.rb` | `Import` record (`id_prefix "imp"`), not branched; holds source, state, report (jsonb via `Protobufable::JsonType` with an internal message) |
| `backend/app/models/importers/base.rb` | fetch → parse → plan → apply; chunked writes through `Changelog.write` |
| `backend/app/models/importers/sources/google_sheet.rb`, `xlsx.rb` | tab readers returning rows as `Hash[String, String]` with row numbers |
| `backend/app/models/importers/network_sheet.rb` | tab mappers above |
| `backend/app/models/importers/plan.rb` | the computed plan: per entity, creates/updates keyed by natural key, with client-style ids generated up front |
| `backend/app/jobs/apply_import_job.rb` | runs `ApplyImport` |
| `backend/lib/tasks/import.rake` | CLI entry |
| `backend/app/controllers/api/import/imports_controller.rb` | RPCs |

- Gems: `google-apis-sheets_v4` (or plain REST with `googleauth`), `roo` for XLSX. TODO(interview): pick.
- Chunking: ≤ 3,000 mutated rows per transaction (DSQL), counting Change rows too, so ~1,000 entity rows per chunk. Each chunk is one ChangeSet; the whole import is one Mutation record with the Import id.
- Plan computation reads the branch once; applying re-checks `head_seq` and refuses if the branch moved since planning. TODO(interview): refuse, or re-plan automatically?
- Ordering within apply: Sites (seeded, 008), Locations, Asns, Roles, Aggregates, VlanGroups, Vlans, Prefixes, IpRanges, Devices, Interfaces, IpAddresses, then Device primary IPs.

### Schema sketch

```sql
-- db/schema/imports.sql
create table imports (
    id uuid primary key default gen_random_uuid(),
    kind smallint not null,
    branch_id uuid not null,
    source jsonb not null,
    state smallint not null,
    report jsonb,
    actor jsonb not null,
    applied_seq bigint,
    applied_at timestamp(6) with time zone,
    created_at timestamp(6) with time zone not null default now(),
    updated_at timestamp(6) with time zone not null default now()
);

create index idx_imports_branch on imports (branch_id, created_at);
```

### Past Episodes

- Per Episode: create the Episode (003) with a root Plan branch, run the import, freeze. Pair with a Fleet snapshot rebuilt from that year's `containers20xx` tab (014) where one exists.
- Column aliases per Episode in `config/importers/network_sheet.yml`. TODO(interview): confirm the sheet IDs for rk25, rk25kor, rk26, rk26kor.

### Testing

- Fixture XLSX trimmed from rk26kor (`spec/fixtures/files/network_sheet_rk26kor.xlsx`) with expected entity counts and a handful of spot checks.

## Current Status

Draft: rough content populated, not yet reviewed. Interview not started.

Open questions:

- Sources: Google Sheets API, XLSX upload, or both.
- Re-import of the Network Data sheet needed beyond the transition.
- Unknown network names: create Role or report.
- `update` / `configured?` semantics.
- SKU → category vs SKU → Product.
- Fill import order relative to 014.
- Apply after the branch moved: refuse or re-plan.
- Gems for Sheets and XLSX.
- Sheet IDs of past Episodes.
