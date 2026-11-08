# 014-fleet-catalogue

## Summary

The Fleet's records of what we own and where it is kept: Product and Category, Asset with its tag, AssetMac (including BSSID ranges), PurchaseOrder, Depot, Container, ContainerManifest and StockLine, with direct editing and the asset lifecycle from purchase to disposal. It imports the rubykaigi-network-assets sheet and its `containers20xx` tabs, and makes `nwa.rubykaigi.org/<tag>` open the asset.

## Motivation

- The asset list lives in a standalone spreadsheet ([rubykaigi-network-assets](https://docs.google.com/spreadsheets/d/1u27Eoip0GkvMGRFlqIeH5UZoMCDoXeYDKQ0GOxe7OJ0/edit), `master` tab). Each Episode's Network Data sheet copies parts of it (`devices`, `device-stock`, `device-sum`) and drifts from it.
- Box contents are recorded per move in separate tabs (`containers2022`, `containers2024`, `containers2024kor`, `containers2025tokyo12`), mixing asset tags, untagged devices (`IX2215 * 2 (tun-01,02.rk24)`) and consumables with rough counts (`はさみ 13本`, `2P電源タップ いっぱい`). Nobody can answer "where is `rk-aph26a3` now" without reading several tabs.
- The QR label on every asset points at `nwa.rubykaigi.org/<tag>`, which needs something to resolve to.
- Later Fleet specs (016 fill, 017 inventory, 018 shipments) need a stable catalogue to point at: tags, containers, depots and counted stock.

## Explanation

### Vocabulary

| Entity | TypeID prefix | Natural key | What it is |
|---|---|---|---|
| Product | `prod` | `name` | A model, SKU or consumable type (`AIR-AP2802I-Q-K9`, `SRX300`, `軍手`) |
| Asset | `a` | `tag` | One tagged item; its tag is its identity for life |
| AssetMac | `mac` | (`asset_id`, `kind`, `mac`) | An Ethernet MAC or a masked BSSID range of an asset |
| PurchaseOrder | `po` | `handle` | `rk-po19a` |
| Depot | `depot` | `name` | Somewhere things are kept or sent: Stockmamoru (warehouse), ivry office, sorah's home, a venue |
| Container | `box` | `tag` | A box that travels: `rkc-21b`, `rkb-25c`, `rks-…`, `kor-…`. Containers do not nest |
| ContainerManifest | `man` | — | The paper in each box: "8 apm, 4 aph" |
| StockLine | `stock` | — | A counted holding of an untagged item in a container or depot |

Category is a fixed enum, not a table (static records carry display labels and attributes such as PoE):

| Value | Label |
|---|---|
| `CATEGORY_L3_1G_ROUTER` | L3: 1G Router |
| `CATEGORY_L2_1G` | L2: 1G |
| `CATEGORY_L2_1G_POE_PLUS` | L2: 1G PoE+ |
| `CATEGORY_L2_100M_POE_PLUS` | L2: 100M PoE+ |
| `CATEGORY_WIFI_AP` | Wi-Fi AP |
| `CATEGORY_WLC`, `CATEGORY_TRANSCEIVER`, `CATEGORY_POWER`, `CATEGORY_TOOL`, `CATEGORY_CONSUMABLE`, `CATEGORY_OTHER` | |

### Tag grammar

Asset tags: `<owner>-<kind><yy><batch><number>[+<part>]`

| Part | Example | Meaning |
|---|---|---|
| owner | `rk`, `kor`, `ext` | `ext` marks our own tag on a borrowed item |
| kind | `aph`, `apm`, `srnp`, `wlc`, `r` | Equipment kind; checked against the Product's `tag_kind` |
| yy | `26` | Purchase year (two digits) |
| batch | `a` | Batch letter within the year |
| number | `3` | Sequence within the batch |
| part | `+psu` | An accessory of the parent asset (`rk-wlc19a1+psu` is an accessory of `rk-wlc19a1`) |

- Examples: `rk-aph26a3`, `rk-srnp19a1`, `rk-wlc19a1+psu`, `ext-srnp26a1`.
- Container tags: `rkc-` folding container, `rkb-` cardboard box (being phased out), `rks-` suitcase, `kor-` Kaigi on Rails cargo, followed by `<yy><letter>` (`rkc-26F`, `rkc-21k`).
- Tags are case-insensitive on lookup and stored as written. TODO(interview): normalise to lower case on store? `rkc-26F` exists with an upper-case letter. Proposed: store as written, unique index on `lower(tag)`.
- A tag is never reused, even after disposal. A tag never changes: an item bought later from its lender keeps its `ext-` tag and switches `ownership` to owned.
- A borrowed item carries our `ext-` tag, the lender's `external_id`, or both; at least one is required. Lookups and labels prefer our tag.

### Asset statuses

| Status | Meaning |
|---|---|
| `available` | In stock, not deployed |
| `deployed` | Filling a Device at a venue (set by 016) |
| `lost` | Missing after a check |
| `broken` | Awaiting repair or disposal |
| `disposed` | Gone; row and tag kept forever |

### Whereabouts

- An asset's whereabouts is where it was last seen: a Container, or a Depot (loose). It is updated by scans (017), not assigned: any asset may be packed in any box.
- `location_note` holds a free-text hint ("on Sorah's desk", "lent to X").
- Direct edits of whereabouts are allowed for corrections. TODO(interview): should a direct edit record a synthetic InventoryScan so the "latest scanned_at wins" rule still holds? Proposed: yes, an `audit`-less manual scan with `scanned_at = now`.

### Stock lines

- The quantity is the last observed count, not a balance. A count scan (017) or a direct edit replaces it; nothing records takes and returns.
- Before anyone counts, `quantity_note` holds a rough count ("いっぱい", "残り少し").
- Until a Product exists, `item_text` names the item. Promoting a stock line to a Product is an edit.
- An untagged device stock line (`IX2215 ×2`) can fill a Device (016). Tagging such items later turns them into Assets; the stock line's quantity is reduced by hand.
- A stock line can carry `ownership = borrowed`, a `lender`, and an `episode_id` for a loan for one Episode.

### API

Services under `rubykaigi.net_aid`, all writes carrying `MutationHeader header` and client-generated ids, all targeting Fleet main (the only writable Fleet branch). Reads come from the sync bootstrap and change feed (004); the RPCs below are writes plus a few lookups for agents.

| Service | RPCs |
|---|---|
| `ProductService` | `CreateProduct`, `UpdateProduct`, `DeleteProduct` |
| `AssetService` | `CreateAsset`, `UpdateAsset`, `DeleteAsset`, `LookupTag` (asset or container by tag, any Fleet branch), `SetAssetStatus` |
| `AssetMacService` | `CreateAssetMac`, `UpdateAssetMac`, `DeleteAssetMac` |
| `PurchaseOrderService` | `CreatePurchaseOrder`, `UpdatePurchaseOrder`, `DeletePurchaseOrder` |
| `DepotService` | `CreateDepot`, `UpdateDepot`, `DeleteDepot` |
| `ContainerService` | `CreateContainer`, `UpdateContainer`, `RetireContainer` (lost or disposed), `SetManifest` (replaces a container's manifest lines) |
| `StockLineService` | `CreateStockLine`, `UpdateStockLine`, `DeleteStockLine` |

- `Delete*` on Asset and Container is refused once anything references the row (scans, shipment items, fills); retire with a status instead. Products and depots likewise. TODO(interview): allow hard delete of an asset created by mistake within N minutes and with no references? Proposed: allow when unreferenced.
- `LookupTag` accepts `rk-aph26a3`, `https://nwa.rubykaigi.org/rk-aph26a3`, or a lender ID, and returns the asset or container message. Scanners use the same parsing client-side.

### Screens

- `/fleet/assets`: table with filters (product, category, status, ownership, whereabouts), bulk status change.
- `/fleet/assets/<tag>`: asset page with product, MACs, PO, whereabouts history (from scans and changelog), current fill in the active Episode (from 016), accessories.
- `/fleet/containers`, `/fleet/containers/<tag>`: contents (assets last seen in it, stock lines), manifest, dimensions, depot.
- `/fleet/depots/<name>`, `/fleet/products`, `/fleet/purchase-orders`.
- `/<tag>` (served at `nwa.rubykaigi.org/<tag>`): resolves through `LookupTag` and redirects to the asset or container page. An unknown tag offers "register this asset" on phones, pre-filling the tag.

### Registering a new asset (phone, possibly offline)

1. Scan or type the new tag. The client parses owner, kind, year, batch, number and part, and suggests a Product from `tag_kind`.
2. Pick the Product, enter the serial, scan the MAC label.
3. The client creates the Asset with a client-generated id and queues the mutation (006). It can immediately be used in a fill (016) or a scan (017).

### Import

- `master` tab of rubykaigi-network-assets → Product, Asset, AssetMac, PurchaseOrder. Columns: handle (tag), chassis, serial, mac, system, license, purchased_at, po, price, price-tax, location, comment.
- `ap-annotate` tab → AssetMac with kind `bssid` (`70:b3:17:c7:6a:4?` is a /44).
- `containers20xx` tabs → Container, ContainerManifest, StockLine, and asset whereabouts, as a Fleet snapshot of that year (003) paired with the imported Plan branch (012). The latest tab also seeds Fleet main.
- The importer reuses the 012 structure (dry run, report of unparsed rows, idempotent re-run by natural key).

## Drawbacks

- Whereabouts as "last seen" means the catalogue can be confidently wrong until the next scan. Accepted: the alternative (assignment) was wrong in practice, since anyone repacks anything.
- Stock lines as last-observed counts lose the ability to answer "how many gloves did we use". Not a need today; cost tracking stays in a spreadsheet.
- A single global Fleet main means two Episodes running close together (rk26 and rk26kor) share whereabouts. That is the physical truth, so it is intended.

## Considered Alternatives

- Ledger of moves for stock lines (in/out transactions): rejected, staff take consumables from any box and never record it.
- Containers nesting containers: rejected, boxes do not nest in practice; a suitcase inside a container is recorded as two containers at the same depot.
- Category as a table: rejected for now; a fixed enum keeps validation and reporting (device-sum) simple. Revisit if categories need editing without a deploy.
- Per-Episode Fleet branches: rejected in the domain model; Fleet has its own continuous timeline with snapshots (003).

## Prior Art

- NetBox DCIM: device types (≈ Product), inventory items, sites/locations (≈ Depot).
- Snipe-IT: asset tags, check-in/check-out; check-out is the part we deliberately do not model.
- The existing rubykaigi-network-assets sheet and its `README` tab (tag grammar).

## Security and Privacy Considerations

- Prices, PO numbers and lender details are internal; readable by every authenticated role (001), writable by Fleet editors. TODO(interview): hide `price`/`tax` from a `viewer` role? Proposed: no, all staff can see them today.
- Depot addresses (sorah's home) are personal data: shown only to authenticated users, never in exports to rubykaigi-net (013) or in the public tag redirect.
- `nwa.rubykaigi.org/<tag>` must not reveal anything to unauthenticated visitors beyond a sign-in prompt.

## Mission Scope

### Out of scope

- Cost tracking and budgeting (stays in a spreadsheet).
- Scanning sessions, shipments and fills (017, 018, 016).
- Label printing (015).
- Automation refreshing `system`/`license` from devices (later, through the API).

### Expected Outcomes

- The rubykaigi-network-assets sheet is read-only, replaced by `/fleet`.
- Every printed asset QR code resolves in the app.
- Box contents for past moves are browsable through Fleet snapshots.

## Implementation Plan

### Schema (`backend/db/schema/*.sql`)

Every table carries the `Branched` columns from 002. Natural keys are unique per `(branch_id, key)`; `lineage` unique per branch.

```sql
-- db/schema/products.sql
create table products (
    id uuid primary key,
    branch_id uuid not null,
    lineage uuid not null,
    updated_seq bigint not null,
    name varchar(128) not null,
    sku varchar(128),
    vendor varchar(128),
    category smallint not null,
    tracking smallint not null,        -- 1 tagged, 2 counted
    tag_kind varchar(16),
    platform smallint,
    created_at timestamp(6) with time zone not null default now(),
    updated_at timestamp(6) with time zone not null default now()
);
create unique index idx_products_branch_name on products (branch_id, name);
create unique index idx_products_branch_lineage on products (branch_id, lineage);

-- db/schema/assets.sql
create table assets (
    id uuid primary key,
    branch_id uuid not null,
    lineage uuid not null,
    updated_seq bigint not null,
    tag varchar(64),                   -- null only for borrowed items with external_id
    owner varchar(8),
    kind varchar(16),
    year smallint,
    batch varchar(4),
    number integer,
    part varchar(16),
    parent_id uuid,
    product_id uuid not null,
    serial varchar(128),
    ownership smallint not null,
    lender varchar(128),
    external_id varchar(128),
    system text,
    license text,
    purchase_order_id uuid,
    purchased_on date,
    price bigint,
    tax bigint,
    status smallint not null,
    container_id uuid,                 -- whereabouts: exactly one of container_id, depot_id, or neither
    depot_id uuid,
    whereabouts_scanned_at timestamp(6) with time zone, -- the sighting the whereabouts came from (017)
    location_note text,
    comment text,
    created_at timestamp(6) with time zone not null default now(),
    updated_at timestamp(6) with time zone not null default now()
);
create unique index idx_assets_branch_tag on assets (branch_id, tag);
create index idx_assets_branch_container on assets (branch_id, container_id);
create index idx_assets_branch_external on assets (branch_id, lender, external_id);

-- db/schema/asset_macs.sql
create table asset_macs (
    id uuid primary key,
    branch_id uuid not null,
    lineage uuid not null,
    updated_seq bigint not null,
    asset_id uuid not null,
    kind smallint not null,
    mac char(12) not null,             -- lower-case hex, masked bits zero
    prefix_length smallint not null default 48,
    created_at timestamp(6) with time zone not null default now(),
    updated_at timestamp(6) with time zone not null default now()
);
create index idx_asset_macs_branch_mac on asset_macs (branch_id, mac);
```

Similar tables: `purchase_orders` (unique `handle`), `depots` (unique `name`, `kind`, `address`, `note`), `containers` (unique `tag`, `kind`, `width_cm`/`depth_cm`/`height_cm`, `description`, `depot_id`, `status`, `retired_at`, `manifest_exclusive`), `container_manifests` (`container_id`, `product_id` or `category`, `expected_quantity`, `note`), `stock_lines` (`product_id` or `item_text`, `container_id` or `depot_id`, `quantity`, `quantity_note`, `observed_at`, `observed_in_session_id`, `ownership`, `lender`, `episode_id`).

- `tag` unique index: TODO(interview): DSQL supports expression indexes? If not, store `tag_key` (lower-cased) alongside `tag`.
- MAC lookup by containment (which asset owns BSSID `70:b3:17:c7:6a:42`): range scan on `mac` between the masked base and its upper bound, as in 009's hex keys.

### Models (`backend/app/models/`)

- `Product`, `Asset`, `AssetMac`, `PurchaseOrder`, `Depot`, `Container`, `ContainerManifest`, `StockLine`, each `include Branched` and `id_prefix`.
- `AssetTag` (`Data.define`): parses and formats the tag grammar; `AssetTag.parse("rk-wlc19a1+psu")` → owner `rk`, kind `wlc`, year 2019, batch `a`, number 1, part `psu`. Also `ContainerTag`.
- `TagLookup`: resolves a scanned string (tag, URL, lender ID) to an asset or container in a given Fleet branch. Shared by `AssetService.LookupTag`, 016 and 017.
- `Category` static records (`app/models/category.rb`): label, PoE flag, ordering for reports.
- Asset `before_validation` sets the parsed tag fields from `tag`; parsed fields are read-only in the API.

### Validation warnings (011 rules under `app/models/warnings/`)

| Code | Rule |
|---|---|
| `asset_tag_kind_mismatch` | Asset tag kind differs from its Product's `tag_kind` (`srnp` on a non-PoE switch) |
| `container_retired_not_empty` | A lost or disposed container still holds assets or stock lines |
| `asset_disposed_has_whereabouts` | A disposed asset still sits in a container |
| `stock_line_without_product` | `item_text` set for longer than one Episode (nudge to create a Product) TODO(interview): keep? |

Hard validations: tag parses, at least one of `tag`/`external_id`, `ext` owner implies `ownership = borrowed` unless bought later, `part` requires `parent_id`, `whereabouts` oneof, manifest `product_id` xor `category`.

### Controllers and resources

- `backend/app/controllers/api/<service>/` per service, routed in `config/routes.rb`.
- `backend/app/resources/api/{product,asset,asset_mac,purchase_order,depot,container,container_manifest,stock_line}_resource.rb`.
- `proto/rubykaigi/net_aid/fleet.proto` (messages) and `fleet_service.proto` per service. TODO(interview): one file per entity or one `fleet.proto`? Proposed: follow whatever 004 settles.

### Import (`backend/app/models/imports/`)

- `Imports::AssetSheet` (master, ap-annotate) and `Imports::ContainersTab` (one `containers20xx` tab), on the 012 importer base.
- Cells like `IX2215 * 2 (tun-01,02.rk24)` become a StockLine (`item_text: "IX2215"`, quantity 2, note kept); `はさみ 13本` → quantity 13; `いっぱい` → `quantity_note`. Unparsed cells are reported, never dropped.
- Rake: `rake import:assets[SPREADSHEET_ID]`, `rake import:containers[SPREADSHEET_ID,TAB,SNAPSHOT_NAME]`.

### Frontend

- Routes under `/fleet`, the `/<tag>` resolver route (CloudFront rewrite in 007).
- Shared tag parser in TypeScript mirroring `AssetTag`, with a shared test vector file (`proto/testdata/tags.json`?) TODO(interview).

### Tests

- Model specs: `AssetTag` grammar vectors, validations, whereabouts oneof.
- Request specs for each RPC, including refusal to delete referenced rows.
- Import specs against fixture CSVs exported from the sheets.

## Current Status

Draft: rough content populated, not yet reviewed. Interview not started.

Open questions:
- Tag case normalisation and the unique index form on DSQL.
- Whether direct whereabouts edits record a synthetic scan.
- Hard delete of unreferenced assets created by mistake.
- Price visibility per role.
- Proto file layout (per entity or per dataset), pending 004.
- Shared tag-grammar test vectors between Ruby and TypeScript.
