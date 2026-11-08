# 017-inventory-scanning

## Summary

Inventory sessions in which several scanners (phones or barcode scanners) count at once, possibly offline for a while. Scans are insert-only sightings that update an asset's whereabouts, or a stock line's count, following the latest `scanned_at`. Closing a session computes findings against its expected set: missing assets, unchecked boxes, uncounted stock lines and manifest shortfalls.

It replaces the `inventory-check-*` tabs and their cross-check columns.

## Motivation

- Today a check is a spreadsheet tab per run (`inventory-check-*`, `kor26出庫`) where people paste asset URLs from a QR reader, strip them to tags with formulas, and cross-check with an `ある?` XLOOKUP column. Two people scanning means two columns (thread-1 / thread-2) merged by eye.
- The most important finding, an AP left on a ceiling after teardown, is only noticed if someone remembers to compare against what was deployed.
- Venues and the warehouse often have poor connectivity. Scans must be recorded offline and never lost (domain model requirement: inventory tracking data must never be lost).
- Whereabouts and stock counts in 014 need a source of truth: sightings.

## Explanation

### Concepts

| Entity | TypeID | What it is |
|---|---|---|
| InventorySession | `inv` | One counting run at one Depot: `pack`, `check`, `receive`, or `audit` |
| InventorySessionScanner | `scanner` | One phone or scanner taking part in a session |
| InventoryScan | `scan` | One sighting, insert-only |

Session kinds:

| Kind | Where | Expected set |
|---|---|---|
| `pack` | Office (prep), for a Shipment | Contents of the containers requested by the Shipment (018); scans become its ShipmentItems |
| `check` | Venue, before return | Assets in ShipmentItems that arrived at the venue for the Episode, minus those that left, plus assets filling the Episode's Devices that no shipment recorded |
| `receive` | Any depot, on arrival | ShipmentItems of the arriving Shipment |
| `audit` | Warehouse or anywhere | Assets last seen at this depot |

### Scans

- A scan is a sighting of one subject (an Asset, or a StockLine with a counted `quantity`) in a Container, or loose at the session's Depot.
- Packing scans pair a container with an item: scan the box tag, then everything put in it. The box stays "current" until another box tag is scanned.
- A loose sighting (no container) is allowed only in `check` and `audit` sessions; the asset's whereabouts becomes the Depot.
- Counting an untagged item: pick the Product (or type free text) and enter a quantity. A count in a box with no stock line for that item creates one.
- The scan's `id` is generated on the device, so a retried upload never duplicates it. The same asset scanned by two scanners is fine.
- `scanned_at` is the device clock. Derived whereabouts (Asset `container_id`/`depot_id`) and stock line quantities follow the scan with the latest `scanned_at`, not commit order, so a scanner uploading late never overrides a newer sighting.
- Missing items are never scanned. They surface as findings at close.

### Scanner lifecycle

1. A person opens the session on their phone and joins: the client creates an InventorySessionScanner with a stable `device_id` (generated once per browser install, kept in IndexedDB).
2. Scans accumulate locally and upload in batches (`RecordScans`), each upload reporting `pending_scans`.
3. "I'm done" sets `finished_at`. A scanner is finished when `finished_at` is set and `pending_scans` is 0.
4. Findings are computed from the union of all scanners' scans once every joined scanner has finished. Closing earlier is allowed but raises `scanner_unfinished` naming them.

### Findings (computed at close, stored, recomputable)

| Kind | Meaning |
|---|---|
| `asset_missing` | Expected here, not scanned by any scanner. At a venue check: left behind (the main finding) |
| `container_unchecked` | A container at this depot with no scans |
| `manifest_shortfall` | Per container, fewer than the ContainerManifest expects (by product or category) |
| `manifest_excess` | More than expected |
| `outside_exclusive_manifest` | Something not on the manifest in a `manifest_exclusive` container |
| `stock_uncounted` | A stock line in a scanned container that nobody counted |
| `asset_in_multiple_containers` | Seen in two boxes by different scanners; latest `scanned_at` wins, but someone should look |
| `scanner_unfinished` | Joined but not finished or not fully uploaded at close |
| `not_packed` | Seen loose at the venue, never scanned into a container before close; cannot ship |

Untagged items never raise `asset_missing`. A stock line counted 0 stays as a "refill" reminder.

### Phone flow

1. `/<episode>/inventory` or `/fleet/inventory`: list sessions, start one (kind, depot, optional Shipment).
2. Join. The scanner screen shows the current container, the last scans, and a running count per container against its manifest.
3. Scan a box tag → current container. Scan asset tags → sightings in it. Tap "+ count" for untagged items.
4. Scan "loose" (a button, or a printed "LOOSE" QR) to clear the current container. TODO(interview): print a special QR for loose, or just a button? Proposed: button plus optional QR.
5. Offline: everything works, a badge shows pending scans. Uploads resume on reconnect.
6. "Done" → finished. The session owner sees all scanners' state and closes; findings appear with links to each asset or box.

Hardware barcode scanners in keyboard mode feed the same input field. TODO(interview): support Bluetooth HID scanners explicitly (focus handling, Enter suffix)? Proposed: yes, as a text field that is always focused.

### API

| Service | RPC | Notes |
|---|---|---|
| `InventoryService` | `StartSession` | kind, depot, episode label, optional shipment |
| | `JoinSession` | returns the InventorySessionScanner |
| | `RecordScans` | up to N scans per call, `pending_scans`, `MutationHeader header`; idempotent per scan id |
| | `FinishScanner` | |
| | `CloseSession` | computes and stores findings; `force` to close with unfinished scanners |
| | `RecomputeFindings` | after late uploads to a closed session |
| | `GetExpectedSet` | `NO_SIDE_EFFECTS`; for the progress view |

- `RecordScans` accepts scans for a closed session (late upload) and marks findings stale. TODO(interview): reject instead? Proposed: accept, since data must never be lost; findings are recomputed.
- Batch size: TODO(interview): bounded by DSQL's 3,000 mutated rows per transaction; each scan touches the scan row plus at most one asset or stock line, proposed limit 500 scans per call.

## Drawbacks

- Device clocks decide derived state. A phone with a wrong clock can pin an asset's whereabouts. Mitigation: the client records server-time offset at its last sync and sends both; TODO(interview): correct `scanned_at` by the offset?
- Findings depend on shipments (018) being recorded faithfully. A shipment nobody recorded makes its assets "unexpected" rather than "missing".
- Insert-only scans grow without bound. At a few thousand per Episode this is small.

## Considered Alternatives

- Last-writer-wins on whereabouts by commit order: rejected, an offline scanner uploading late would overwrite newer sightings.
- One scanner per session: rejected, real checks run with two or more people.
- Recording takes and returns of consumables: rejected (014), nobody records them.
- Computing findings live instead of at close: shown live as progress, but stored at close so a report stays stable.

## Prior Art

- The `inventory-check-*` and `kor26出庫` tabs.
- Linear-style offline outbox (006) for upload; warehouse stock-take apps (cycle counting).

## Security and Privacy Considerations

- Scans record the Actor and device id; device ids are random, not hardware identifiers.
- Insert-only tables refuse updates and deletes at the API. A mistaken scan is corrected by a newer scan, not by deletion. TODO(interview): allow an operator to void a scan (a `voided_at` column)? Proposed: yes, admin only, for scans of the wrong session.
- Camera access is requested only on the scanner screen.

## Mission Scope

### Out of scope

- Shipments and ShipmentItems (018); this spec only links a session to its Shipment and provides the scans.
- Assigning assets to Devices (016).
- Native apps; the scanner is the web app (005).

### Expected Outcomes

- Every inventory check is a session with stored findings, replacing the `inventory-check-*` tabs.
- Left-behind APs are reported at the venue check before the return shipment leaves.
- Asset whereabouts and stock counts in 014 are kept current by scans.

## Implementation Plan

### Schema (Fleet tables)

```sql
-- db/schema/inventory_sessions.sql
create table inventory_sessions (
    id uuid primary key,
    branch_id uuid not null,
    lineage uuid not null,
    updated_seq bigint not null,
    kind smallint not null,
    depot_id uuid not null,
    episode_id uuid,
    shipment_id uuid,
    started_at timestamp(6) with time zone not null,
    closed_at timestamp(6) with time zone,
    findings jsonb,                    -- repeated Warning; null until closed
    findings_stale boolean not null default false,
    note text,
    created_at timestamp(6) with time zone not null default now(),
    updated_at timestamp(6) with time zone not null default now()
);

-- db/schema/inventory_session_scanners.sql
create table inventory_session_scanners (
    id uuid primary key,
    branch_id uuid not null,
    lineage uuid not null,
    updated_seq bigint not null,
    session_id uuid not null,
    device_id varchar(64) not null,
    actor jsonb not null,
    joined_at timestamp(6) with time zone not null,
    finished_at timestamp(6) with time zone,
    last_upload_at timestamp(6) with time zone,
    pending_scans integer not null default 0,
    created_at timestamp(6) with time zone not null default now(),
    updated_at timestamp(6) with time zone not null default now()
);
create unique index idx_inventory_session_scanners_device on inventory_session_scanners (branch_id, session_id, device_id);

-- db/schema/inventory_scans.sql
create table inventory_scans (
    id uuid primary key,               -- client-generated
    branch_id uuid not null,
    lineage uuid not null,
    updated_seq bigint not null,
    session_id uuid not null,
    scanner_id uuid not null,
    container_id uuid,
    asset_id uuid,
    stock_line_id uuid,
    quantity integer,
    scanned_by jsonb not null,
    scanned_at timestamp(6) with time zone not null,
    voided_at timestamp(6) with time zone,
    created_at timestamp(6) with time zone not null default now(),
    updated_at timestamp(6) with time zone not null default now()
);
create index idx_inventory_scans_session on inventory_scans (branch_id, session_id);
create index idx_inventory_scans_asset on inventory_scans (branch_id, asset_id, scanned_at);
```

- Scans are Fleet rows: a Fleet snapshot copies them. TODO(interview): copying every scan into every snapshot is wasteful; keep scans out of snapshots and read them from main by lineage? Proposed: copy, the volume is small and reads stay `where branch_id = ?`.

### Code

- `app/models/inventory_session.rb`, `inventory_session_scanner.rb`, `inventory_scan.rb` (`include Branched`; `InventoryScan` read-only after create).
- `app/models/inventory/record_scans.rb`: inserts scans (skipping ids already present), then for each subject applies the derived update only if `scanned_at` is newer than the asset's `whereabouts_scanned_at` (014) or the stock line's `observed_at`. Creates stock lines for counts in boxes without one. All in one `Changelog.write` on Fleet main.
- `app/models/inventory/expected_set.rb`: builds the expected set per session kind from ShipmentItems (018), Device fills of the Episode (016, Plan branch), and last-seen assets.
- `app/models/inventory/findings.rb`: computes findings from the union of non-voided scans; stored on the session.
- Retry on OCC conflict with the same mutation id (002's write path); duplicate scan ids are no-ops.
- `proto/rubykaigi/net_aid/inventory.proto`, `inventory_service.proto`; `app/controllers/api/inventory/`.

### Frontend

- Scanner screen with camera QR decoding (TODO(interview): library, e.g. `zxing-wasm` or the BarcodeDetector API with fallback) and a keyboard-wedge input.
- Scans stored in the 006 outbox; `RecordScans` batches every few seconds or 50 scans, whichever first.
- Session overview for the owner: scanners, pending counts, live progress against the expected set.

### Warnings (011)

Session findings are stored on the session and also surfaced as branch warnings with codes `inventory_<kind>` while the session is the latest of its depot. TODO(interview): or keep findings only on the session page? Proposed: only on the session page plus a banner on the Episode dashboard.

### Tests

- `RecordScans`: late upload with older `scanned_at` does not move an asset; duplicate scan ids; count creating a stock line.
- Findings fixtures for each kind.
- Expected set for a venue check with hand-carried items and on-site fills.

## Current Status

Draft: rough content populated, not yet reviewed. Interview not started.

Open questions:
- Late uploads to closed sessions: accept and mark findings stale, or reject.
- Correcting `scanned_at` for device clock skew.
- Voiding mistaken scans.
- Scans copied into Fleet snapshots or not.
- QR decoding library and HID scanner support.
- Batch size per `RecordScans` call.
- Whether findings appear as branch warnings (011).
