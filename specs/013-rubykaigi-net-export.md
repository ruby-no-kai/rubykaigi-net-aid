# 013-rubykaigi-net-export

## Summary

Exports a Plan branch at a `seq` as one protojson file per model (`sites.json`, `prefixes.json`, `devices.json` …), with rows referencing each other by natural key, and opens one pull request per export against rubykaigi-net using a GitHub token from sts-cat. The PR touches only files whose content changed.

It replaces `hosts.txt`. Moving `gen-hosts.rb`, Kea reservations, `es-*` CNAMEs and the host lists onto the new files is tracked here as consumer-side work.

## Motivation

- Today the `addresses` tab is copied by hand into rubykaigi-net's `hosts.txt` (TSV: `dc network cidr ip name iface mac`, ~450 lines). Copying is manual, lossy (no status, no role, no VLAN) and easy to forget.
- Several other lists in rubykaigi-net are hand-kept copies of the same facts:
  - `k8s/dhcp/config/reservations_asset_tag.libsonnet`: asset tag → mgmt octet table for Kea client-id reservations.
  - `k8s/dhcp/config/subnet_*.libsonnet`: per-subnet DUID/MAC reservations (`wire-01-venue`).
  - `route53/rubykaigi.net.route`: `es-<area>-NN.venue` → `<asset-tag>.venue` CNAMEs, rewritten per Episode (`docs/sops/es-mapping.md`).
  - `glazed/glazed.jsonnet` and `k8s/prom/snmp.jsonnet`: device name lists by platform (`ios(name, 'venue')` for every `es-*`).
  - `tf/glazed/trapbridge.tf`: loopback address → node map.
  - `k8s/prom/cloudprober.jsonnet` / `gen-cloudprober.rb`: targets and the per-Episode exclusion list.
  - itamae node attributes (addresses, DUIDs, ASNs).
- Each list drifts independently. One export from one branch at one `seq` makes them all agree, and a PR makes the change reviewable.
- Agents working on rubykaigi-net (Claude Code with the `rknet-topology` skill) read these files; structured JSON is easier for them than TSV.

## Explanation

### Output files

Written under `data/net-aid/` in rubykaigi-net. TODO(interview): directory name and whether per-Episode subdirectories are needed (only one Episode is live at a time). Proposed: `data/net-aid/` with a `meta.json`.

| File | Message | Rows |
|---|---|---|
| `meta.json` | `ExportMeta` | episode slug, branch id, seq, exported_at, actor, app URL |
| `sites.json` | `SiteList { repeated Site sites }` | all Sites |
| `locations.json` | `LocationList` | |
| `asns.json` | `AsnList` | |
| `roles.json` | `RoleList` | |
| `aggregates.json` | `AggregateList` | |
| `vlans.json` | `VlanList` (VLAN groups inlined or separate `vlan_groups.json`) | |
| `prefixes.json` | `PrefixList` | |
| `ip_ranges.json` | `IpRangeList` | |
| `devices.json` | `DeviceList` | |
| `interfaces.json` | `InterfaceList` | |
| `ip_addresses.json` | `IpAddressList` | |
| `links.json` | `LinkList` | |

- Each file holds the same entity messages the API serves (008–010), in ProtoJSON with `preserve_proto_fieldnames` (snake_case) and defaults omitted. TODO(interview): emit defaults so consumers need not know proto defaults? Proposed: emit defaults for enums and bools; it is friendlier to jsonnet.
- Rows are sorted by natural key, one field per line (pretty-printed, 2-space indent, trailing newline), so PR diffs are readable.
- Row metadata (`updated_seq`, timestamps, `branch_id`) is omitted; `id` and `lineage` are kept.

### References by natural key

Every reference field carries the natural key alongside the TypeID, as an export-only `<name>_ref`:

```json
{
  "id": "dev_01j…",
  "name": "es-tra-01",
  "site_id": "site_01j…",
  "site_ref": "venue",
  "location_ref": "tra",
  "fqdn": "es-tra-01.venue.rubykaigi.net",
  "platform": "PLATFORM_IOS",
  "status": "STATUS_DEPLOYED",
  "primary_ip4_ref": "10.33.100.31/24",
  "asset_tag": "rk-srnp19a2"
}
```

- Device: `site_ref`, `location_ref`, `primary_ip4_ref`, `primary_ip6_ref`, `asn_ref`, and `asset_tag` (the filled Asset's tag, from 016) plus `asset_macs` (Ethernet MACs of the fill).
- Interface: `device_ref` (`es-tra-01.venue`).
- IpAddress: `interface_ref` (`irb.1000@cs-01.venue`), `device_ref`, `prefix_ref`, `role_ref`, `vlan_ref`, and the derived `dns_names` it should emit.
- Prefix: `role_ref`, `vlan_ref` (`venue/1000`), `site_ref`, `location_ref`.
- TODO(interview): put `_ref` fields in the API messages themselves (useful to agents too) or only in export-specific messages? Proposed: export-specific `Export*` wrapper messages in `proto/rubykaigi/net_aid/export/`, so the API stays lean.

### Triggering an export

```proto
service ExportService {
  rpc CreateExport(ExportServiceCreateExportRequest) returns (ExportServiceCreateExportResponse);
  rpc GetExport(ExportServiceGetExportRequest) returns (ExportServiceGetExportResponse) {
    option idempotency_level = NO_SIDE_EFFECTS;
  }
  rpc ListExports(ExportServiceListExportsRequest) returns (ExportServiceListExportsResponse) {
    option idempotency_level = NO_SIDE_EFFECTS;
  }
}

message Export {
  string id = 1; // exp_…
  string branch_id = 2;
  int64 seq = 3; // pinned at request time
  Target target = 4; // TARGET_RUBYKAIGI_NET_PR, TARGET_DOWNLOAD (zip of the same files)
  State state = 5; // queued, running, opened, no_changes, failed
  string pull_request_url = 6;
  repeated string changed_files = 7;
  Actor actor = 8;
  string error = 9;
  google.protobuf.Timestamp created_at = 10;
}
```

- UI: an "Export to rubykaigi-net" button on the Episode page; shows warnings (011) first and asks to confirm; then shows the PR link.
- Each export pins the branch's `head_seq` at request time, so the files are reproducible (`GET` the same export again gives the same bytes).
- A PR is opened on a new branch `net-aid/<episode>/<seq>` against `master`, titled `net-aid: <episode> @ <seq>`, with a body listing per-file row counts added/changed/removed and a link back to the app. It touches only changed files; with no changes, no PR (`no_changes`).
- TODO(interview): when an earlier export PR is still open, update it (force-push its branch) or open another? Proposed: update the open one and comment nothing; title changes to the new seq.
- Agents and CI may also call `CreateExport` (001 machine roles), or fetch files with `TARGET_DOWNLOAD`.

### Consumer migration (rubykaigi-net side)

| Consumer | Today | After |
|---|---|---|
| `gen-hosts.rb` | reads `hosts.txt`, emits A/AAAA/PTR, `<iface>.<fqdn>`, `<network>.<fqdn>` CNAMEs, `-dc.f.` CNAMEs, `deadman.conf` | reads `devices.json`, `interfaces.json`, `ip_addresses.json`; primary = Device's primary IPs (not "first row"); `<network>` CNAME from the address's Role/VLAN name |
| Kea asset-tag reservations | hand-kept `reservations_asset_tag.libsonnet` | generated from `ip_addresses.json` rows with `dhcp_identifier_type = CLIENT_ID`; libsonnet reads a generated JSON |
| Kea DUID/MAC reservations | hand-kept in `subnet_*.libsonnet` | generated per Prefix (by `dhcp_subnet_id`) from `ip_addresses.json`; pools and options stay hand-kept |
| `es-*` CNAMEs | hand-edited in `rubykaigi.net.route` per SOP | generated into `route53/hosts.json` (or a new template) from Devices with role `es` and `asset_tag` |
| glazed / SNMP node lists | hard-coded name lists | from `devices.json` by `platform` and `status` |
| trapbridge `trap_nodes` | hard-coded loopback → node | from loopback-role addresses and their devices |
| cloudprober exclusions | per-Episode list | from Device `status` (`not_deployed`, `collected` excluded) |
| itamae attributes | hand-kept | TODO(interview): which attributes, and whether itamae reads JSON directly |

- `hosts.txt` stays until `gen-hosts.rb` switches; then it is deleted. The TSV is not produced by the app.
- TODO(interview): who does the rubykaigi-net changes, in which order, and are they tracked as part of this spec's checklist or as rubykaigi-net issues? Proposed: this spec's checklist names them; implemented as rubykaigi-net PRs.
- Verification: during the transition, a script in rubykaigi-net renders `hosts.json` from both `hosts.txt` and the export and diffs them.

## Drawbacks

- Consumers must be rewritten; until then both formats coexist.
- One file per model makes consumers join (device → interface → address). Simple for Ruby, more verbose for jsonnet.
- The app needs write access to rubykaigi-net (a PR-opening token), a new privileged path into the infrastructure repo.
- Exports at a pinned seq can be stale by the time the PR merges; nothing forces re-export.

## Considered Alternatives

- One file per consumer (hosts, kea, cnames): couples the app to every consumer's needs; each consumer change would need an app change.
- Keep `hosts.txt` TSV: loses status, role, VLAN, fills; its only merit was pasting from the sheet.
- Consumers call the API at build time: needs credentials in every build and makes rubykaigi-net's outputs depend on live app state; files in the repo are reviewable and reproducible.
- Pushing directly to `master`: no review.

## Prior Art

- NetBox export templates and NetBox-as-source-of-truth pipelines that commit generated configs to git.
- rubykaigi-net's own `route53/hosts.json` (generated JSON consumed by roadworker templates).

## Security and Privacy Considerations

- The GitHub token comes from sts-cat with a trust policy scoped to rubykaigi-net and the export Lambda's identity; permissions `contents: write`, `pull_requests: write` only. TODO(interview): sts-cat scope and policy file.
- Exports never push to protected branches; merges are human.
- Files include MACs, DUIDs and asset tags; rubykaigi-net is a public repository. TODO(interview): confirm that publishing MACs/DUIDs is acceptable (they are already in `hosts.txt` and libsonnet files publicly). Proposed: same as today.
- Only Plan data is exported; no Actor identities beyond the export's own actor in `meta.json` and the PR body.
- Creating an export requires the Plan editor or operator role (001).

## Mission Scope

### Out of scope

- WLC commands, Tepra labels, warehouse forms (015, 016, 018).
- Fleet exports (asset lists) to rubykaigi-net.
- Auto-merging PRs or applying Route53/Kea changes.
- Scheduled exports.

### Expected Outcomes

- One click (or one RPC) opens a PR to rubykaigi-net with the changed model files.
- Re-exporting at the same seq produces byte-identical files.
- `gen-hosts.rb` and the Kea, CNAME, glazed, SNMP, trapbridge and cloudprober inputs are generated from the export, and `hosts.txt` is removed.

## Implementation Plan

### Backend

| File | Content |
|---|---|
| `proto/rubykaigi/net_aid/export.proto`, `export_service.proto` | `Export`, service |
| `proto/rubykaigi/net_aid/export/files.proto` | `ExportMeta`, `Export*` row messages with `_ref` fields, `*List` wrappers |
| `backend/app/models/export.rb` | `Export` record (`id_prefix "exp"`), not branched |
| `backend/app/models/exporters/rubykaigi_net.rb` | builds files from a branch at a seq |
| `backend/app/models/exporters/natural_keys.rb` | id → natural key maps per entity type |
| `backend/app/models/github/pull_request_publisher.rb` | branch, commit, PR via the GitHub REST API (`octokit`) |
| `backend/app/models/sts_cat.rb` | token exchange: Lambda's OIDC/IAM identity → GitHub installation token |
| `backend/app/jobs/run_export_job.rb` | runs an export |
| `backend/app/controllers/api/export/exports_controller.rb` | RPCs |

- Reading at a pinned seq: the branch's current tables reflect `head_seq`, not an older seq. TODO(interview): export only at head (seq = head at job start), or reconstruct an older seq from the changelog? Proposed: always head at job start; `seq` records which head it was. Frozen branches are always at head.
- Diffing: fetch the current files from rubykaigi-net's default branch (contents API) and compare bytes; commit only differences via the Git Data API (one tree, one commit).
- Serialisation: `Google::Protobuf.encode_json` with `preserve_proto_fieldnames: true`, re-parsed and pretty-printed with sorted rows.

### Schema sketch

```sql
-- db/schema/exports.sql
create table exports (
    id uuid primary key default gen_random_uuid(),
    branch_id uuid not null,
    seq bigint,
    target smallint not null,
    state smallint not null,
    pull_request_url text,
    changed_files jsonb,
    actor jsonb not null,
    error text,
    created_at timestamp(6) with time zone not null default now(),
    updated_at timestamp(6) with time zone not null default now()
);

create index idx_exports_branch on exports (branch_id, created_at);
```

### rubykaigi-net work (separate PRs there)

1. Add `data/net-aid/` from the first export.
2. Switch `gen-hosts.rb` to read the export; diff against `hosts.txt` output; delete `hosts.txt`.
3. Generate Kea reservations (asset tag client-ids, DUIDs, MACs) from the export.
4. Generate `es-*` CNAMEs; retire the manual SOP steps 2–3 in `docs/sops/es-mapping.md`.
5. Generate glazed, SNMP, trapbridge and cloudprober inputs.

### Testing

- Golden-file spec: a fixture branch exported to `spec/fixtures/export/*.json`.
- Publisher spec with WebMock against GitHub API.

## Current Status

Draft: rough content populated, not yet reviewed. Interview not started.

Open questions:

- From 002 review: an export records an opaque branch version (cursor), never a bare `seq`, in anything stored or shown (PR branch names included).
- Output directory and `meta.json`.
- Emit proto defaults or not.
- `_ref` fields in API messages or export-only messages.
- Updating an open export PR vs opening another.
- sts-cat scope and policy.
- Publishing MACs/DUIDs in a public repo (same as today?).
- Export at head only vs historical seq.
- Ownership and order of rubykaigi-net consumer changes; itamae attributes.
