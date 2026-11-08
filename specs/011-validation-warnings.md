# 011-validation-warnings

## Summary

A per-branch framework for rules that warn instead of rejecting, computed on the server, served through the API and shown next to the affected rows. This spec defines the framework and the organisation, IPAM and device rules: duplicate addresses, addresses outside every Prefix, Prefixes outside every Aggregate, devices without a primary IP. Later specs add their own rules to it.

## Motivation

- Many inconsistencies are normal while planning: a duplicate address mid-renumbering, a device not yet given an address, a Prefix typed before its Aggregate. Rejecting them would block work; ignoring them is how the sheet ended up with `10.33.22.150–155` duplicated.
- Offline clients submit mutations that were valid on their copy but conflict with others' edits. Last-writer-wins accepts them; a warning is how anyone notices.
- Several later specs have rules of the same shape: tag/product mismatch (014), fill/category mismatch (016), shipment shortfalls (018), inventory findings (017), cable topology (019). One framework avoids five ad-hoc ones.
- The sheet's cross-check columns (`ある?`, XLOOKUP results) were warnings in disguise.

## Explanation

### What a warning is

```proto
message Warning {
  string code = 1; // stable: ip_address.duplicate, prefix.outside_aggregate
  Severity severity = 2;
  string branch_id = 3;
  Subject subject = 4; // the row it is shown on
  repeated Subject related = 5; // other rows involved (the other duplicate address)
  string message = 6; // English, human-readable: "10.33.22.150/24 is also assigned to es-tra-02"
  map<string, string> params = 7; // for client-side formatting and filtering

  message Subject {
    string entity_type = 1; // proto message name: rubykaigi.net_aid.IpAddress
    string id = 2;
  }

  enum Severity {
    SEVERITY_UNSPECIFIED = 0;
    SEVERITY_INFO = 1;
    SEVERITY_WARNING = 2;
    SEVERITY_ERROR = 3; // still not rejected, but blocks exports? see TODO
  }
}
```

- Warnings are not stored; they are a function of a branch's state at a `seq`. TODO(interview): exception for inventory session findings (017), which are stored at close per the domain model.
- TODO(interview): should `SEVERITY_ERROR` block exports (013)? Proposed: export shows them and asks to confirm, never blocks.
- No acknowledgement or suppression in v1. TODO(interview): needed for known-accepted warnings (e.g. an intentional duplicate)? Proposed: a per-row `suppressed_warning_codes` later, not now.

### RPC

```proto
service WarningService {
  rpc ListWarnings(WarningServiceListWarningsRequest) returns (WarningServiceListWarningsResponse) {
    option idempotency_level = NO_SIDE_EFFECTS;
  }
}

message WarningServiceListWarningsRequest {
  string branch_id = 1;
  repeated string codes = 2; // filter; empty = all
  optional Warning.Subject subject = 3; // only warnings on/related to this row
}

message WarningServiceListWarningsResponse {
  int64 seq = 1; // the branch seq the warnings were computed at
  repeated Warning warnings = 2;
}
```

- Clients refetch when their synced seq passes the response's `seq` (debounced). TODO(interview): push warnings through the change feed instead? Proposed: no; separate RPC, polled on change.
- Cross-dataset rules (a Plan Device's fill vs the Fleet) evaluate against the Episode's `fleet_branch`; such warnings appear on the Plan branch's list.

### Rules in this spec

| Code | Severity | Subject | Condition |
|---|---|---|---|
| `ip_address.duplicate` | warning | IpAddress | another IpAddress in the branch has the same address (ignoring prefix length) and neither is `deprecated`; roles `anycast`/`vip` exempt |
| `ip_address.outside_prefix` | warning | IpAddress | no non-container Prefix contains it |
| `ip_address.prefix_length_mismatch` | info | IpAddress | its prefix length differs from the containing Prefix's |
| `prefix.outside_aggregate` | warning | Prefix | no Aggregate contains it |
| `prefix.gateway_outside` | warning | Prefix | gateway not inside the Prefix |
| `vlan.scope_conflict` | warning | Prefix | Prefix's site/location differs from its VLAN group's scope |
| `device.no_primary_ip` | info | Device | no primary IPv4 and no primary IPv6 (`status` planned/deployed only) |
| `device.location_name_mismatch` | info | Device | name's location part (`tra`) differs from `location_id`'s slug |
| `link.address_mismatch` | warning | Link | its addresses are not on its interfaces, or not in its prefixes |
| `interface.mac_duplicate` | warning | Interface | another Interface in the branch has the same MAC |

Rules added by later specs (listed so the framework covers them): tag kind vs product (014), container disposed while holding things (014), fill vs required category (016), label batch overlap (015), shipment shortfalls (018), inventory session findings (017), cable topology and JJ count (019).

### UI

- A warnings badge in the Episode header with the count by severity; click opens `/<episode>/warnings`, a list grouped by code with links to subjects.
- Rows in tables (addresses, prefixes, devices) show an icon with the warning messages on hover.
- Detail pages list their warnings at the top.
- TODO(interview): show warnings client-side immediately after a local edit (by running some rules in the browser)? Proposed: no; server is the only evaluator, and the badge shows "checking…" while the change is unsynced.

## Drawbacks

- Recomputing every rule over a branch on demand is wasteful as rules grow. With a few thousand rows per branch it is milliseconds per rule, but cable and inventory rules are heavier.
- Warnings that are not stored cannot be "first seen at" or audited.
- Server-only evaluation means offline users see stale warnings.

## Considered Alternatives

- Rejecting on write (model validations): blocks offline mutations and the planning workflow. Hard invariants (format, uniqueness of natural keys) still reject.
- Storing warnings as rows updated incrementally on every write: correct but every rule needs an incremental form; deferred until on-demand computation is too slow.
- Client-side evaluation only: duplicates the rules in TypeScript and cannot see rows outside the loaded pair.

## Prior Art

- NetBox's duplicate-IP and orphan-prefix reports (custom scripts/reports).
- Linters: rule code, severity, location, message.
- The sheet's XLOOKUP cross-checks.

## Security and Privacy Considerations

- Same read access as the branch itself (001).
- Messages quote addresses, names and tags; no personal data beyond Actor names already visible.

## Mission Scope

### Out of scope

- Rules owned by later specs (they register into this framework).
- Suppression/acknowledgement of warnings.
- Notifications (Slack etc.) on new warnings.

### Expected Outcomes

- `ListWarnings` returns the rules above for any branch, frozen ones included.
- Adding a rule is one class plus a spec, no framework change.
- The UI shows warnings next to the affected rows and in a branch-wide list.

## Implementation Plan

### Framework

- `backend/app/models/warnings.rb`: registry; `Warnings.compute(branch, codes: nil, subject: nil) -> Array[Warnings::Warning]`.
- `backend/app/models/warnings/rule.rb`: base class. Each rule declares `code`, `severity`, `subject_type`, and implements `call(context) -> Enumerable[Warning]`.
- `backend/app/models/warnings/context.rb`: per-computation memo of the branch's rows loaded once (`context.ip_addresses`, `context.prefixes`, …) and the Episode's `fleet_branch` for cross-dataset rules, so rules do not each query the tables.
- Rules: `backend/app/models/warnings/ip_address_duplicate.rb`, `ip_address_outside_prefix.rb`, … one file per rule.
- Containment uses the hex keys from 009 (`IpValue`), in Ruby over the loaded rows (sorted interval sweep), not in SQL.

### Caching

- Cache key: `[branch_id, head_seq, fleet_branch_id, fleet head_seq, rule version]`. Frozen branches cache forever.
- TODO(interview): cache store on Lambda (no shared memory): `Rails.cache` on DSQL? S3? Or compute every time? Proposed: compute every time at first; add an S3-backed cache for frozen branches if needed.

### Controller

- `backend/app/controllers/api/warning/warnings_controller.rb` with `list_warnings`; `Api::WarningResource` bound to `Rk::NetAid::Warning`.
- Response always carries the `seq` the context was read at; read the branch row and all tables in one read-only transaction for a consistent view.

### Testing

- One spec per rule with minimal rows; a framework spec for filtering by code and subject.

## Current Status

Draft: rough content populated, not yet reviewed. Interview not started.

Open questions:

- Stored warnings for inventory sessions vs computed for the rest.
- Whether `SEVERITY_ERROR` blocks exports.
- Suppression of accepted warnings.
- Delivery: separate RPC (proposed) vs the change feed.
- Client-side preview of warnings.
- Cache store on Lambda.
