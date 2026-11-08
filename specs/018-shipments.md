# 018-shipments

## Summary

Shipments of containers between depots (warehouse → office → venue → warehouse). Insert-only ShipmentItems are recorded when a shipment is marked shipped, taken from pack-session scans or inherited from the contents of containers that travel unopened. A shipment is validated against its Episode's Device fills, and the warehouse request form (入庫申請) is exported from it.

## Motivation

- Moves are recorded today as a new `containers20xx` tab per trip, copied by hand from the previous one, and the warehouse request (入庫申請 / とりだす) is another tab plus `cardboard-measurement` for box sizes.
- The venue check (017) needs to know what was supposed to arrive, and what already left, to report anything left behind.
- Before the Episode, someone has to confirm that the requested boxes contain enough APs and PoE switches for the plan. Today that is `device-sum` against a guess of box contents.
- Kaigi on Rails takes a subset of what RubyKaigi takes; picking which boxes to pull from the warehouse is a recurring decision.

## Explanation

### Concepts

| Entity | TypeID | What it is |
|---|---|---|
| Shipment | `ship` | Containers moving from one Depot to another, labelled with an Episode |
| ShipmentItem | `shipi` | Insert-only record of one thing that left in a shipment: an Asset, or a StockLine with a quantity, in a Container or hand-carried |

Kinds: `carrier` (a parcel service or the warehouse's truck) and `hand_carry` (staff bringing items themselves; may have no containers).

### Lifecycle

| Status | Set by | Effect |
|---|---|---|
| `requested` | `CreateShipment` | Containers chosen (とりだす); validation shown; 入庫申請 form downloadable |
| `packing` | `StartPacking` or a `pack` session (017) linked to it | Optional; only boxes opened and repacked need it |
| `shipped` | `MarkShipped` | ShipmentItems recorded container by container; containers' depot becomes "in transit" TODO(interview): or stays at `from` until received? |
| `received` | `MarkReceived` | Containers' depot becomes `to_depot`; loose items' depot too |

Recording ShipmentItems at `MarkShipped`, per container:

- If the container was scanned in this shipment's `pack` session (or, for a return from a venue, the venue `check` session), its items come from those scans (`source = scan`, `source_scan_id` set).
- Otherwise it travelled unopened, and its items are inherited from its current contents: assets last seen in it and its stock lines (`source = inherited`).
- Hand-carried items (no container) come from the session's loose scans or are added explicitly.

Warehouse → office → venue usually ships boxes unopened, so both legs normally inherit.

### Validation (warnings, never rejections)

Against the Episode's Plan, using Device fills and required categories only:

- Per Category, Devices in the Plan requiring it must be covered by assets of that category in the requested containers, plus assets already at the destination.
- Untagged fills (stock lines) must be in a requested container.
- An asset already filling a Device (rare before the venue, e.g. a pre-configured router) must be in a requested container or already at the destination.
- A retired (lost or disposed) container cannot be added; that is a hard rejection.
- ContainerManifests are not used here; they are for box checks (017).

Shown on the shipment page as a coverage table: category, needed, in requested boxes, already at destination, shortfall.

### 入庫申請 / outbound request form

- Export per shipment for the warehouse (Stockmamoru): box tag, note (個品備考), W/D/H in cm, count. Inbound (入庫申請) for returns, outbound (出庫) for とりだす.
- Format: XLSX matching the warehouse's template. TODO(interview): attach the warehouse's template file to the spec; which columns are fixed?
- Box dimensions come from Container (`width_cm`, `depth_cm`, `height_cm`), replacing `cardboard-measurement`.

### API

| Service | RPC | Notes |
|---|---|---|
| `ShipmentService` | `CreateShipment` | from, to, kind, episode label, container ids; `MutationHeader header` |
| | `UpdateShipment` | field mask; containers editable until shipped |
| | `StartPacking` | creates or links a `pack` session (017) |
| | `MarkShipped` | records ShipmentItems; `shipped_at` |
| | `MarkReceived` | `received_at`; optionally starts a `receive` session |
| | `AddHandCarriedItems` | explicit items without containers |
| | `ValidateShipment` | `NO_SIDE_EFFECTS`; the coverage table |
| | `DownloadWarehouseRequest` | `DownloadedFile` (015) |

- `MarkShipped` is idempotent per mutation id; calling it twice does not duplicate items.
- Shipped shipments cannot change containers. Corrections are a new Shipment, or items recorded in the next session. TODO(interview): allow "unship" by an admin, voiding items?

### Screens

- `/<episode>/shipments` and `/fleet/shipments`: list with route, status, box count.
- Shipment page: containers with contents preview (inherited or scanned), coverage table, actions per status, download.
- Container picker for とりだす: boxes at the from-depot, with contents summary and manifest, filterable by category; "take the same boxes as rk26kor" shortcut. TODO(interview): worth it? Proposed: copy containers from a previous shipment.

### Usual route for one Episode

1. Warehouse → office: `CreateShipment` with chosen boxes; download the outbound form; `MarkShipped` when the warehouse ships; `MarkReceived` at the office.
2. Office prep: boxes opened and repacked get a `pack` session tied to the next shipment.
3. Office → venue: `CreateShipment`, `MarkShipped` (scan-sourced for packed boxes, inherited for the rest), `MarkReceived` at the venue.
4. Venue teardown: `check` session (017); return shipment venue → warehouse records items from the check session's scans. Devices become `collected` (016).
5. Warehouse: download 入庫申請; `MarkReceived` when it is stored.

## Drawbacks

- Inherited items are only as good as the last scan of each box; an unopened box with stale contents ships stale records.
- Status transitions are manual. Forgetting `MarkShipped` leaves the venue check's expected set empty. Mitigation: the check session warns when no arriving shipment exists for the Episode.
- Containers in transit belong to no depot for a while, which complicates "what is at the warehouse" queries.

## Considered Alternatives

- Recording every move as scans only (no Shipment): rejected, unopened boxes would need every item rescanned at every leg.
- Updating ShipmentItems as boxes change: rejected, items are insert-only so the record of what left is never lost.
- Validating against ContainerManifests: rejected, manifests are rough expectations; fills and categories are what the plan needs.

## Prior Art

- `containers2022`, `containers2024`, `containers2024kor`, `containers2025tokyo12` tabs (とりだす column), `入庫申請`, `cardboard-measurement`.
- Warehouse management "advance shipping notice" and packing lists.

## Security and Privacy Considerations

- Depot addresses appear on the warehouse form; downloads require an authenticated Fleet role.
- Carrier tracking numbers, if added, are not secret but stay internal. TODO(interview): record a tracking number on the shipment?

## Mission Scope

### Out of scope

- Cables, which travel in temporary boxes in the shipping cargo (JITBOX) and are not tracked as containers (019).
- Carrier booking or cost.
- Scanning itself (017).

### Expected Outcomes

- Each leg of an Episode's logistics is a Shipment with recorded items.
- The venue check's expected set is built from shipments, so left-behind assets are found.
- The warehouse forms are downloads, not tabs.

## Implementation Plan

### Schema (Fleet tables)

```sql
-- db/schema/shipments.sql
create table shipments (
    id uuid primary key,
    branch_id uuid not null,
    lineage uuid not null,
    updated_seq bigint not null,
    from_depot_id uuid not null,
    to_depot_id uuid not null,
    episode_id uuid,
    kind smallint not null,
    status smallint not null,
    requested_at timestamp(6) with time zone,
    shipped_at timestamp(6) with time zone,
    received_at timestamp(6) with time zone,
    note text,
    created_at timestamp(6) with time zone not null default now(),
    updated_at timestamp(6) with time zone not null default now()
);

-- db/schema/shipment_containers.sql (repeated container_ids; DSQL has no array columns)
create table shipment_containers (
    id uuid primary key,
    branch_id uuid not null,
    lineage uuid not null,
    updated_seq bigint not null,
    shipment_id uuid not null,
    container_id uuid not null,
    created_at timestamp(6) with time zone not null default now(),
    updated_at timestamp(6) with time zone not null default now()
);
create unique index idx_shipment_containers_pair on shipment_containers (branch_id, shipment_id, container_id);

-- db/schema/shipment_items.sql
create table shipment_items (
    id uuid primary key,
    branch_id uuid not null,
    lineage uuid not null,
    updated_seq bigint not null,
    shipment_id uuid not null,
    container_id uuid,
    asset_id uuid,
    stock_line_id uuid,
    quantity integer,
    source smallint not null,
    source_scan_id uuid,
    created_at timestamp(6) with time zone not null default now(),
    updated_at timestamp(6) with time zone not null default now()
);
create index idx_shipment_items_shipment on shipment_items (branch_id, shipment_id);
create index idx_shipment_items_asset on shipment_items (branch_id, asset_id);
```

- `MarkShipped` for a large shipment (tens of boxes, a few hundred items) fits one transaction under 3,000 rows. TODO(interview): chunk if a return ships everything at once (~260 assets + stock lines)? Proposed: single transaction, with a guard that fails loudly near the limit.
- In-transit representation: TODO(interview): `containers.depot_id` null plus `in_shipment_id`, or keep `from` until received. Proposed: `in_shipment_id` column on `containers`.

### Code

- `app/models/shipment.rb`, `shipment_container.rb`, `shipment_item.rb` (insert-only).
- `app/models/shipments/mark_shipped.rb`: per container, chooses scan vs inherited source; writes items and container transit state in one `Changelog.write` on Fleet main.
- `app/models/shipments/mark_received.rb`: moves containers and loose items to `to_depot`; asset whereabouts for assets in moved containers stay `container_id` (the container moved, not the asset).
- `app/models/shipments/validation.rb`: coverage per category from the Episode's Plan Devices (`required_category`, fills; read from the Plan branch) and Fleet contents of requested containers.
- `app/models/shipments/warehouse_request.rb`: XLSX writer (shares 015's writer).
- `proto/rubykaigi/net_aid/shipment.proto`, `shipment_service.proto`; `app/controllers/api/shipment/`.

### Warnings (011)

| Code | Rule |
|---|---|
| `shipment_category_shortfall` | Requested boxes and destination stock do not cover the Plan's required categories |
| `shipment_fill_not_requested` | An asset filling a Device is neither in a requested box nor at the destination |
| `shipment_no_arrival_for_episode` | A venue check starts with no received shipment for the Episode |
| `container_without_dimensions` | A requested container has no W/D/H (needed by the warehouse form) |

### Tests

- `MarkShipped`: scan-sourced vs inherited per container; idempotent replay.
- Validation fixtures: rk26kor-sized plan against a subset of boxes.
- Warehouse form fixture against the current 入庫申請 tab.

## Current Status

Draft: rough content populated, not yet reviewed. Interview not started.

Open questions:
- Container state while in transit.
- The warehouse form template and its fixed columns.
- Correcting a shipped shipment ("unship").
- Transaction size for a full return shipment.
- Copying the container set from a previous shipment.
- Tracking numbers.
