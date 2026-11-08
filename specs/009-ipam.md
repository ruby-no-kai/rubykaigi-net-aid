# 009-ipam

## Summary

NetBox-style IP address management in the Plan: Aggregate, Role, VlanGroup, Vlan, Prefix, IpRange and IpAddress, plus Link, which allocates a point-to-point prefix pair and its four addresses. Addresses, prefixes and MACs are stored as canonical text with a sortable fixed-width hex key, so containment is a range scan on DSQL.

It replaces the sheet's `networks` tab and the address half of `addresses`.

## Motivation

- The `networks` tab mixes three ideas in one `network` name: function (`mgmt`, `life`), place (`mgmt2` for venue2, `tkyk-mgmt`) and held blocks (`aws`, `onpremises`, `pa`). Consumers then reverse-engineer meaning from names.
- The `addresses` tab's CIDR column is free text, copied by hand from `networks`. Nothing checks that an address is inside its network, or that it is unique (`10.33.22.150–155` are duplicated today).
- Point-to-point links are allocated by hand: find the next free /31 in `link`, the matching `ca22:<N>::/124`, type four addresses on the two devices. It is error-prone and the most repeated IPAM task.
- The team already knows NetBox, so its vocabulary (Aggregate, Prefix with status `container`, Role, VLAN group, IP range) carries over with no training.
- DSQL has `inet` only at query runtime and cannot index `bytea`, so the storage scheme has to be decided once, here.

### Sheet name mapping

| Sheet `network` | Role | Scope | Notes |
|---|---|---|---|
| `mgmt` | `mgmt` | VlanGroup `venue` (vid 1000) | |
| `mgmt2` | `mgmt` | VlanGroup `venue2` (vid 1000, Location `venue2`) | |
| `tkyk-mgmt` | `mgmt` | Site `tkyk` | |
| `lo` | `loopback` | none | `is_pool` |
| `link` | `p2p` | none | holds Link prefixes |
| `aws` | `cloud` | Site `apne1` | under Aggregate `10.33.128.0/18` |
| `onpremises`, `kaigi` | none | none | container prefixes |
| `pa` | `public` | none | under Aggregate `192.50.220.152/29` etc. |

## Explanation

### Entities

All carry the Row fields (`id`, `lineage`, `branch_id`, `updated_seq`, timestamps) as in 008.

```proto
// Shared by addresses, prefixes and ranges. Output carries all fields; input takes `text` only.
message IpValue {
  Family family = 1;
  string text = 2; // canonical: 10.33.0.0/24, 2001:df0:8500:ca00::1/64
  string key = 3; // fixed-width lowercase hex: 8 chars (v4) or 32 (v6)
  int32 prefix_length = 4;
  enum Family { FAMILY_UNSPECIFIED = 0; FAMILY_IPV4 = 1; FAMILY_IPV6 = 2; }
}

// agg: a top-level block we hold or use.
message Aggregate {
  IpValue prefix = 10; // unique per branch
  string source = 11; // RFC 1918, APNIC, transit PA, AWS
  string description = 12;
}

// role: a function vocabulary shared by prefixes and VLANs.
message Role {
  string slug = 10; // unique per branch: loopback, p2p, mgmt, life, air, usr, cast, public, cloud, nat64-outer
  string name = 11;
}

// vlg: a scope where VLAN ids are unique.
message VlanGroup {
  string name = 10; // unique per branch: venue, venue2
  oneof scope { string site_id = 11; string location_id = 12; }
}

message Vlan {
  string group_id = 10;
  int32 vid = 11; // 1–4094, unique per group
  string name = 12;
  optional string role_id = 13;
}

// pfx: parents and children come from containment.
message Prefix {
  IpValue prefix = 10; // unique per branch (see TODO below)
  Status status = 11;
  optional string role_id = 12;
  optional string vlan_id = 13;
  optional string site_id = 14;
  optional string location_id = 15;
  bool is_pool = 16; // every address usable, no network/broadcast (loopbacks)
  optional string gateway = 17; // full address; input accepts ::a style suffix shorthand
  int32 dhcp_subnet_id = 18; // output only, derived
  string description = 19;
  enum Status { STATUS_UNSPECIFIED = 0; STATUS_CONTAINER = 1; STATUS_ACTIVE = 2; STATUS_RESERVED = 3; STATUS_DEPRECATED = 4; }
}

// iprange: informational only, since Kea pools stay in rubykaigi-net.
message IpRange {
  IpValue start = 10;
  IpValue end = 11;
  string role = 12; // dhcp_pool, …
  string description = 13;
}

// ip
message IpAddress {
  IpValue address = 10; // with prefix length, as NetBox stores it
  Status status = 11;
  Role role = 12;
  optional string interface_id = 13; // 010
  optional string dns_name = 14; // override; normally derived from the interface
  Dns dns = 15;
  DhcpIdentifierType dhcp_identifier_type = 16;
  string dhcp_identifier = 17; // exported as a Kea reservation (013)
  google.protobuf.Timestamp configured_at = 18;
  google.protobuf.Timestamp verified_at = 19;
  string remark = 20;
  string prefix_id = 21; // output only: the narrowest containing non-container Prefix
  enum Status { STATUS_UNSPECIFIED = 0; STATUS_ACTIVE = 1; STATUS_RESERVED = 2; STATUS_DEPRECATED = 3; STATUS_DHCP = 4; }
  enum Role { ROLE_UNSPECIFIED = 0; ROLE_LOOPBACK = 1; ROLE_ANYCAST = 2; ROLE_VIP = 3; }
  enum Dns { DNS_UNSPECIFIED = 0; DNS_EMIT = 1; DNS_SKIP = 2; }
  enum DhcpIdentifierType { DHCP_IDENTIFIER_TYPE_UNSPECIFIED = 0; DHCP_IDENTIFIER_TYPE_HW_ADDRESS = 1; DHCP_IDENTIFIER_TYPE_DUID = 2; DHCP_IDENTIFIER_TYPE_CLIENT_ID = 3; }
}

// link: a point-to-point link built on the address model.
message Link {
  string a_interface_id = 10;
  string z_interface_id = 11;
  string prefix4_id = 12; // /31 or /30
  string prefix6_id = 13; // /124 or /127
  string description = 14;
}
```

- `IpAddress.prefix_id` (derived) replaces the sheet's free-text CIDR column. It is computed on read, not stored. TODO(interview): compute in the server resource (costs a containment query per address on bootstrap) or let the client derive it from the Prefix pool? Proposed: client-side, with a server helper for exports.
- TODO(interview): Prefix uniqueness. NetBox allows duplicates (VRFs). We have no VRFs. Proposed: unique per branch.
- `dhcp_subnet_id`: derived from the VLAN id for VLAN-backed prefixes, else from the prefix. TODO(interview): exact rule, matching what rubykaigi-net's Kea config uses today.
- `gateway` shorthand: input `::a` on a v6 prefix becomes `<prefix>::a`. v4 has no shorthand.
- `Dns` default (unspecified) means "emit if the address has an interface and its device has a name". `DNS_SKIP` replaces addresses the sheet left without a name.

### Containment and derived structure

- Parent/child of Prefixes, Prefix→IpRange and Prefix→IpAddress are all derived by containment, never stored, as in NetBox.
- Aggregates are top-level; a Prefix outside every Aggregate is a warning (011).
- The UI shows a Prefix tree: Aggregates at the top, container Prefixes, then active Prefixes, with utilisation (used addresses / size).

### RPCs

| Service | RPCs |
|---|---|
| `AggregateService` | `CreateAggregate`, `UpdateAggregate`, `DeleteAggregate` |
| `RoleService` | `CreateRole`, `UpdateRole`, `DeleteRole` |
| `VlanGroupService` / `VlanService` | Create / Update / Delete |
| `PrefixService` | Create / Update / Delete, `AllocatePrefix` (next free child of a given length under a parent) |
| `IpRangeService` | Create / Update / Delete |
| `IpAddressService` | Create / Update / Delete, `AllocateIpAddress` (next free address in a Prefix) |
| `LinkService` | `CreateLink`, `UpdateLink`, `DeleteLink` |

- All writes carry `MutationHeader header` (004).
- `CreateLink(a_interface_id, z_interface_id, v4_length = 31|30, v6_length = 124|127)`:
  1. find the next free pair: a /31 (or /30) in the Prefix with role `p2p` and family v4, and the matching `ca22:<N>::/124` (or /127) — `<N>` derived from the v4 offset. TODO(interview): exact v4→v6 pairing rule, as used in rubykaigi-net today.
  2. create two Prefixes (role `p2p`, status active) and four IpAddresses: A end gets the first usable of each (even v4 or `.1` of a /30; `::a`, or `::0` of a /127), Z end the second.
  3. create the Link. All in one transaction, one ChangeSet.
- `DeleteLink` deletes the Link only. TODO(interview): also delete its prefixes and addresses? Proposed: an option `release_addresses = true` by default.
- Allocation is server-side because "next free" must see every committed row. Offline clients cannot allocate; the UI disables those actions while offline. TODO(interview): acceptable? Proposed: yes, IPAM edits happen at desks.
- Allocations race under OCC: two concurrent `CreateLink` calls pick the same pair. The unique index on `(branch_id, key, prefix_length)` makes one fail, and `retryable_transaction` reruns it with a fresh read.

### UI

- `/<episode>/ipam/prefixes`: tree with utilisation bars; filter by role, site, VLAN, family. "Allocate child" action.
- `/<episode>/ipam/prefixes/<cidr>`: Prefix detail: addresses in it (listing gaps as "free" rows, as NetBox does), ranges, child prefixes.
- `/<episode>/ipam/addresses`: flat table like the sheet's `addresses` tab: address, prefix, device, interface, MAC, DHCP identifier, status, configured/verified, remark. Sortable, filterable, inline editable. This is the screen that replaces the sheet day to day.
- `/<episode>/ipam/vlans`: VLAN groups and VLANs.
- `/<episode>/ipam/links`: Links with both ends and their prefixes; "New link" dialog choosing two interfaces.
- Natural-key URLs: prefixes and addresses by text (`/ipam/prefixes/10.33.1.0_24`).

## Drawbacks

- Text + hex key duplicates information and must be kept consistent by the model. A row written by raw SQL could disagree.
- Derived containment means every tree render is a computation. With ~100 prefixes and ~460 addresses it is cheap, but it moves work to the client.
- Server-side allocation means Link creation does not work offline.
- More entities than the sheet: someone used to typing a `network` name now picks a Role, a VLAN and a scope.

## Considered Alternatives

- Storing `inet`/`cidr` columns: DSQL supports `inet` only at query runtime, not as a column type.
- `bytea` keys: DSQL cannot index `bytea`. The hex text key switches to `bytea` (and `bytes` in the API) once it can.
- Storing parent prefix ids: denormalised, and every insert of a container would need to rewrite children. NetBox derives too.
- One `Network` entity like the sheet: keeps the mixed naming problem.
- Integer keys (two `bigint`s for v6): orderable but awkward for prefix ranges; hex strings sort correctly as text with `collate "C"`.

## Prior Art

- NetBox IPAM: Aggregate, Prefix (status container/active/reserved/deprecated, `is_pool`), IP range, IP address (with prefix length, status, role, DNS name), VLAN group with scope, VLAN, Role.
- rubykaigi-net's `hosts.txt` and the `link` network allocation convention.

## Security and Privacy Considerations

- Writes require a Plan editor role (001).
- DHCP identifiers and MACs are device identifiers, not personal data. Addresses of the venue network are internal but not secret.

## Mission Scope

### Out of scope

- Device and Interface (010). This spec defines `IpAddress.interface_id` and `Link.*_interface_id` as references to them.
- Kea pools and options (stay in rubykaigi-net); IpRange is informational.
- VRFs, NAT mappings, DNS zones.
- Import from the sheet (012) and export (013).

### Expected Outcomes

- The `networks` and the address half of `addresses` can be maintained in the app.
- Containment is correct for v4 and v6, including /31, /127 and pool prefixes.
- `CreateLink` allocates a pair and four addresses in one call, safe under concurrent calls.
- Duplicate-address and outside-prefix conditions show as warnings (rules registered in 011).

## Implementation Plan

### Storage scheme

- `family smallint` (4 or 6), `key varchar(32) collate "C"` (8 or 32 hex chars of the network/host address), `prefix_length smallint`, `text varchar(64)` canonical.
- Containment of X in prefix P: same family, `X.key between P.key and P.last_key`, `X.prefix_length >= P.prefix_length`. Store `last_key` (the broadcast/last address) too so it is a plain range test. TODO(interview): store `last_key` or compute it in the query? Proposed: store.
- `inet` casts still work inside queries (`text::inet <<= …`) for ad-hoc checks and specs.
- `IpValue` parsing/canonicalisation in `backend/app/models/ip_value.rb` (`Data.define(:family, :text, :key, :last_key, :prefix_length)`), built on `IPAddr`. Shared with MACs (`mac_value.rb`, 12 hex chars) used by 010 and 014.
- Models expose `ip_value` composed from the columns (`composed_of` or a custom attribute type).

### Schema sketches

```sql
-- db/schema/prefixes.sql
create table prefixes (
    id uuid primary key,
    lineage uuid not null,
    branch_id uuid not null,
    updated_seq bigint not null,
    family smallint not null,
    key varchar(32) collate "C" not null,
    last_key varchar(32) collate "C" not null,
    prefix_length smallint not null,
    text varchar(64) not null,
    status smallint not null,
    role_id uuid,
    vlan_id uuid,
    site_id uuid,
    location_id uuid,
    is_pool boolean not null default false,
    gateway_key varchar(32) collate "C",
    description text not null default '',
    created_at timestamp(6) with time zone not null default now(),
    updated_at timestamp(6) with time zone not null default now()
);

create unique index idx_prefixes_branch_value on prefixes (branch_id, family, key, prefix_length);
create unique index idx_prefixes_branch_lineage on prefixes (branch_id, lineage);
```

```sql
-- db/schema/ip_addresses.sql
create table ip_addresses (
    id uuid primary key,
    lineage uuid not null,
    branch_id uuid not null,
    updated_seq bigint not null,
    family smallint not null,
    key varchar(32) collate "C" not null,
    prefix_length smallint not null,
    text varchar(64) not null,
    status smallint not null,
    role smallint not null default 0,
    interface_id uuid,
    dns_name varchar(253),
    dns smallint not null default 0,
    dhcp_identifier_type smallint not null default 0,
    dhcp_identifier varchar(255),
    configured_at timestamp(6) with time zone,
    verified_at timestamp(6) with time zone,
    remark text not null default '',
    created_at timestamp(6) with time zone not null default now(),
    updated_at timestamp(6) with time zone not null default now()
);

create index idx_ip_addresses_branch_value on ip_addresses (branch_id, family, key);
create unique index idx_ip_addresses_branch_lineage on ip_addresses (branch_id, lineage);
create index idx_ip_addresses_interface on ip_addresses (interface_id);
```

- Addresses are not unique (duplicates are a warning, not an error), so `idx_ip_addresses_branch_value` is non-unique. Allocation therefore cannot rely on a unique index for addresses; `AllocateIpAddress` and `CreateLink` serialise on the containing Prefix row (`lock!`) instead. TODO(interview): confirm this conflict strategy on DSQL.
- `aggregates`, `roles`, `vlan_groups`, `vlans`, `ip_ranges`, `links` follow the same shape. `vlans` unique on `(branch_id, group_id, vid)`; `roles` on `(branch_id, slug)`; `vlan_groups` on `(branch_id, name)`.

### Backend files

| File | Content |
|---|---|
| `proto/rubykaigi/net_aid/ipam.proto` | entity messages and inputs |
| `proto/rubykaigi/net_aid/*_service.proto` | services listed above |
| `backend/app/models/ip_value.rb`, `mac_value.rb` | value objects |
| `backend/app/models/concerns/ip_valued.rb` | column mapping for models holding an IpValue |
| `backend/app/models/aggregate.rb`, `role.rb`, `vlan_group.rb`, `vlan.rb`, `prefix.rb`, `ip_range.rb`, `ip_address.rb`, `link.rb` | models (`Branched`) |
| `backend/app/models/ipam/allocator.rb` | next-free search for prefixes and addresses, link pairing |
| `backend/app/controllers/api/…` | controllers per service |
| `backend/app/resources/api/…` | resources |

- Fork (003): `vlan_id`, `role_id`, `site_id`, `location_id`, `group_id`, `interface_id`, `*_interface_id`, `prefix*_id` are rewritten through the lineage map.

### Frontend

- `frontend/src/lib/ip.ts`: parsing and containment matching the server's `IpValue` (shared test vectors in `spec/fixtures/ip_values.json`, used by both RSpec and Vitest).
- Prefix tree and address table components; containment index built in memory from the pool.

## Current Status

Draft: rough content populated, not yet reviewed. Interview not started.

Open questions:

- Derived `IpAddress.prefix_id`: server or client.
- Prefix uniqueness per branch.
- `dhcp_subnet_id` derivation rule.
- v4→v6 pairing rule for p2p links.
- `DeleteLink` releasing addresses.
- Allocation offline (proposed: online only).
- Store `last_key` or compute.
- Allocation conflict strategy on DSQL (lock the Prefix row).
