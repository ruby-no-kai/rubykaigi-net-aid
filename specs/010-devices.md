# 010-devices

## Summary

Device and Interface in the Plan: the logical nodes named `<name>.<site>.rubykaigi.net`, their interfaces and assigned addresses, primary IPv4 and IPv6, ASN, platform, required category and status. The fill columns (an Asset or a StockLine) are declared here and populated by 016.

It replaces the sheet's `devices` tab and the device half of `addresses`.

## Motivation

- The sheet keeps devices in two places: `addresses` (`dc`, `name`, `iface`, `mac` per address row) and `devices` (`ID`, 場所, SKU, 備考, asset tag, MAC). They drift: a device renamed in one tab stays under the old name in the other.
- A device is the thing every downstream consumer is keyed on: DNS names (`gen-hosts.rb`), glazed/SNMP/trapbridge lists by platform, cloudprober targets, the `es-*` CNAMEs, WLC rename commands, labels.
- Status is scattered: the cloudprober exclusion list, "not deployed" notes in remarks, the `回収済` column. One `status` field replaces all three.
- Stock planning (`device-sum`) counts devices per category against what the Fleet holds. That needs a `required_category` on each Device.
- The same name exists at several Sites (`tun-01` at `hnd`, `nrt`, `itm`, `venue`), so the natural key is `(site, name)`.

## Explanation

### Entities

Row fields as in 008.

```proto
// dev: a logical node. FQDN is derived: <name>.<site>.rubykaigi.net.
message Device {
  string site_id = 10;
  string name = 11; // unique per (branch, site): es-tra-01, tun-01, ap-lb0-01
  optional string location_id = 12;
  string role = 13; // output only, derived from the name prefix: br, er, cs, as, es, ap, tun, nat, wire, wlc, …
  Platform platform = 14;
  Category required_category = 15; // Fleet category vocabulary (014); for stock planning
  oneof fill { // declared here, set by 016
    string asset_id = 16; // into the Episode's fleet_branch
    string stock_line_id = 17;
  }
  google.protobuf.Timestamp mounted_at = 18; // 016
  Actor mounted_by = 19; // 016
  Status status = 20;
  optional string primary_ip4_id = 21;
  optional string primary_ip6_id = 22;
  optional string asn_id = 23;
  string description = 24;
  string fqdn = 25; // output only

  enum Platform {
    PLATFORM_UNSPECIFIED = 0; PLATFORM_JUNOS = 1; PLATFORM_NEC_IX = 2; PLATFORM_IOS = 3;
    PLATFORM_AIREOS = 4; PLATFORM_LINUX = 5; PLATFORM_AWS = 6; PLATFORM_OTHER = 7;
  }
  enum Status {
    STATUS_UNSPECIFIED = 0; STATUS_PLANNED = 1; STATUS_DEPLOYED = 2; STATUS_NOT_DEPLOYED = 3; STATUS_COLLECTED = 4;
  }
}

// iface
message Interface {
  string device_id = 10;
  string name = 11; // unique per device: lo, ge-0/0/5.10, irb.1000, me0, venue2-vlan1000
  optional string mac = 12; // canonical aa:bb:cc:dd:ee:ff; stored as 12 hex chars
  string description = 13;
}
```

- `role` is derived from the name (`es-tra-01` → `es`, `ap-lb0-01` → `ap`). TODO(interview): keep it derived, or make it a stored field with a default from the name? Proposed: derived for now; becomes stored if a name ever breaks the convention.
- Name grammar: `<role>-<rest>`, lowercase `[a-z0-9-]`. Labels (015) parse `es-tra-01` into role `es`, location `tra`, number `01`. The parser is shared and lives in `DeviceName`.
- `location_id` and the name's location part (`tra`) can disagree; that is a warning, not an error. TODO(interview): derive `location_id` from the name when the name has a location part? Proposed: default it on create, keep it editable.
- `status` default: `planned`. Transitions are free-form here; 016 sets `deployed` on assignment and `collected` on return.
- Primary IPs must be IpAddresses assigned to one of the device's Interfaces, of the right family.

### Interfaces and addresses

- `IpAddress.interface_id` (009) assigns an address to an Interface. A device's addresses are those on its Interfaces.
- The sheet's `iface` column becomes an Interface; rows without an iface get an Interface named after the network (`mgmt`) or `lo`. TODO(interview): what does the importer (012) do with an empty `iface`? Proposed: `lo` for loopback-role addresses, else the network name.
- The sheet's `mac` column is per address row. In the model it lives on the Interface, falling back to the filled Asset's Ethernet MAC (014) when empty. DHCP identifiers stay on the IpAddress (009).

### RPCs

| Service | RPCs |
|---|---|
| `DeviceService` | `CreateDevice`, `UpdateDevice`, `DeleteDevice`, `RenameDevice` (optional, see below) |
| `InterfaceService` | `CreateInterface`, `UpdateInterface`, `DeleteInterface` |

- All writes carry `MutationHeader header` (004).
- `CreateDevice` accepts nested interfaces and addresses in one request, so "new AP with mgmt address" is one mutation: `DeviceInput` plus `repeated InterfaceDraft interfaces`, each with `repeated IpAddressDraft addresses` (client-generated ids throughout). TODO(interview): nested create, or rely on the client batching three mutations? Proposed: nested; one action, one Mutation.
- `DeleteDevice` deletes its Interfaces and unassigns (not deletes) their IpAddresses. TODO(interview): delete addresses too? Proposed: an option, default unassign.
- Fill fields are not writable through `UpdateDevice`; 016 owns them through its assignment RPCs.
- Lookup by natural key for agents: `rk26kor` / `es-tra-01.venue` (via 004's generic lookup).

### UI

- `/<episode>/devices`: table: FQDN, role, location, platform, required category, status, primary IPs, fill (tag, once 016), ASN. Filters by site, role, location, status. Bulk edit of status and location.
- `/<episode>/devices/<site>/<name>`: detail: fields, Interfaces with their addresses (inline add: "add interface", "assign address" with allocation from a Prefix via 009), primary IP pickers, Links touching it (009), warnings (011), history (from the changelog).
- "New device" dialog: name, site, location, platform, required category; optional first interface + address allocation.
- Stock planning summary (counts by required category) lives in 015's `device-sum` report; the device list shows a count per category in its footer.

## Drawbacks

- Interfaces add a layer the sheet did not have: a loopback-only device now has a Device, an Interface `lo` and an IpAddress.
- Derived `role` ties semantics to naming. A device named against convention gets a wrong role silently.
- Fill columns declared here but owned by 016 split one entity's behaviour across specs.

## Considered Alternatives

- Device keyed by FQDN string: simpler, but renames and site moves would change the key; `(site_id, name)` with a stable `id` handles both.
- MAC on the IpAddress, like the sheet: rejected, since a MAC belongs to an interface; Kea identifiers stay on the address for reservations.
- Storing `fqdn`: derived trivially; storing it would need updating on site slug renames.
- NetBox's DeviceType/DeviceRole/Platform objects: heavier than needed. Category (014) and Product cover types; role is a name prefix.

## Prior Art

- NetBox Device (site, location, role, platform, status, primary IPv4/IPv6, interfaces).
- rubykaigi-net's naming convention (`docs/topology.md`): `<role>-<area>-<NN>.<site>.rubykaigi.net`, `es-*` CNAMEs to asset tags.
- The sheet's `devices` and `addresses` tabs.

## Security and Privacy Considerations

- Writes require a Plan editor role (001).
- `mounted_by` records an Actor (a person) per device; it is visible to every signed-in user. No other personal data.

## Mission Scope

### Out of scope

- Filling devices with assets, pair scanning, LabelBatch assignment (016).
- Labels and `device-sum` report (015).
- WLC commands (016).
- Export of devices to rubykaigi-net (013).
- Cable ends referencing Interfaces (019).
- Config management or pushing configs to devices.

### Expected Outcomes

- The `devices` tab and the device half of `addresses` can be maintained in the app.
- Every address has a device and interface, or is explicitly unassigned.
- Status replaces the cloudprober exclusion list and `回収済`.
- Device count per required category is available for stock planning.

## Implementation Plan

### Schema sketches

```sql
-- db/schema/devices.sql
create table devices (
    id uuid primary key,
    lineage uuid not null,
    branch_id uuid not null,
    updated_seq bigint not null,
    site_id uuid not null,
    name varchar(63) not null,
    location_id uuid,
    platform smallint not null default 0,
    required_category smallint not null default 0,
    asset_id uuid,
    stock_line_id uuid,
    mounted_at timestamp(6) with time zone,
    mounted_by_issuer varchar(64),
    mounted_by_subject varchar(255),
    status smallint not null default 1,
    primary_ip4_id uuid,
    primary_ip6_id uuid,
    asn_id uuid,
    description text not null default '',
    created_at timestamp(6) with time zone not null default now(),
    updated_at timestamp(6) with time zone not null default now()
);

create unique index idx_devices_branch_site_name on devices (branch_id, site_id, name);
create unique index idx_devices_branch_lineage on devices (branch_id, lineage);
create index idx_devices_branch_asset on devices (branch_id, asset_id);
create index idx_devices_branch_stock_line on devices (branch_id, stock_line_id);
```

```sql
-- db/schema/interfaces.sql
create table interfaces (
    id uuid primary key,
    lineage uuid not null,
    branch_id uuid not null,
    updated_seq bigint not null,
    device_id uuid not null,
    name varchar(64) not null,
    mac varchar(12) collate "C",
    description text not null default '',
    created_at timestamp(6) with time zone not null default now(),
    updated_at timestamp(6) with time zone not null default now()
);

create unique index idx_interfaces_device_name on interfaces (device_id, name);
create unique index idx_interfaces_branch_lineage on interfaces (branch_id, lineage);
create index idx_interfaces_branch_mac on interfaces (branch_id, mac);
```

- `mounted_by` as issuer + subject columns. TODO(interview): Actor as columns, an `actors` table, or jsonb? Depends on 002's Actor storage.
- A fill is either `asset_id` or `stock_line_id`, never both: model validation, plus a check constraint (`check (asset_id is null or stock_line_id is null)`) if DSQL accepts it.
- Cross-dataset fill columns are plain UUIDs into the Episode's `fleet_branch`, with no foreign key; 003 remaps them on close and fork. 016 looks devices up by fill through `(branch_id, asset_id)` and `(branch_id, stock_line_id)`.

### Backend files

| File | Content |
|---|---|
| `proto/rubykaigi/net_aid/device.proto`, `device_service.proto`, `interface_service.proto` | messages and services |
| `backend/app/models/device.rb`, `interface.rb` | models (`Branched`), `id_prefix "dev"` / `"iface"` |
| `backend/app/models/device_name.rb` | name grammar: role, location part, number |
| `backend/app/controllers/api/device/…`, `api/interface/…` | controllers |
| `backend/app/resources/api/device_resource.rb`, `interface_resource.rb` | resources; `fqdn` and `role` computed |

- Validations: name format, primary IPs belong to the device and match family, location in the same Site, at most one fill.
- Fork (003): `site_id`, `location_id`, `primary_ip*_id`, `asn_id`, `device_id` rewritten through the lineage map; fills remapped to Fleet main (cleared with a warning when the asset is gone).

### Frontend

- `frontend/src/models/device.ts`, `interface.ts`; `frontend/src/lib/device-name.ts` mirroring `DeviceName` with shared test vectors.
- Device table, detail and new-device dialog.

## Current Status

Draft: rough content populated, not yet reviewed. Interview not started.

Open questions:

- `role` derived or stored.
- `location_id` defaulted from the name.
- Empty `iface` handling on import.
- Nested create of interfaces and addresses.
- `DeleteDevice` and its addresses.
- Actor storage for `mounted_by` (from 002).
