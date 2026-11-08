# 015-labels-and-reports

## Summary

Downloads generated from the model rather than kept as sheet tabs: Tepra label sources for devices, APs and asset QR codes in fixed CSV/XLSX template layouts, LabelExport and LabelBatch for tracking printed ranges, and the `device-sum` style stock report. Label text is derived by parsing natural keys and never stored. Any export can be filtered to a selection. Cable labels and order forms belong to 019.

## Motivation

- Every Network Data sheet carries hand-maintained label tabs (`device-tepra`, `ap-tepra`) and the asset sheet a `tepra` tab. They are copies of the real data with formula columns that split names into parts; they go stale and break when rows are inserted.
- At the venue, staff stick a device label on equipment and need to know which asset ended up behind it. The print order of a roll is the cheapest way to get that link: "the next label on this roll is `ap-lb0-07`", so only the asset tag needs scanning (016).
- `device-sum` answers "do we have enough PoE switches for this Episode": requested per category against available stock. It is recomputed by hand today.

## Explanation

### Label kinds

Each kind has a fixed column layout matching a Tepra SPC10 template. XLSX is offered for every kind and required where a cell holds a line break.

| Kind | Source rows | Columns |
|---|---|---|
| `device` | Devices of the branch (`device-tepra`) | `ID` (`es-tra-01`), `SKU`, `Label` (`tra-01`), `Label2` (`tra`), `Label3` (`01`), `Label4` (`es`), `QR` (`es-tra-01`) |
| `ap` | Devices with role `ap` (`ap-tepra`) | same as device (`ap-lb0-01` → `lb0-01`, `lb0`, `01`, `ap`) |
| `asset_qr` | Assets of Fleet main (asset sheet `tepra`) | `handle` (tag), `url` (`https://nwa.rubykaigi.org/<tag>`), `handle2` |

- Label parts come from parsing the device name `<role>-<location>-<nn>`: role `es`, location `tra`, number `01`. Names that do not parse (`tun-01`, `er`) get `Label = name`, empty parts, and a warning row in the export report.
- `SKU` is the required category's short label while unfilled, or the filled asset's Product SKU. TODO(interview): the sheet shows the planned SKU; is the category label enough before fills? Proposed: Product SKU if a Product is chosen in the plan, else category label.
- The QR on device and AP labels encodes the bare device name, which 016's pair scan recognises. TODO(interview): encode a URL (`https://nwa.rubykaigi.org/d/<episode>/<site>/<name>`) instead, so a phone camera opens the device page? Proposed: URL, the scanner strips it.
- The asset QR always encodes `https://nwa.rubykaigi.org/<tag>`.

### LabelExport and LabelBatch

- Device and AP labels are exported as one bulk file per kind, recorded as a **LabelExport** with fixed row numbers. Row numbers never change once exported, so a range typed later always means the same labels.
- After printing a range in the Tepra app, staff enter it ("rows 12–40") as a **LabelBatch**. Several batches (rolls) can be active at once, each with its own cursor.
- Assigning by batch (016) takes the row at the cursor, fills its Device with the scanned asset, and advances the cursor. Damaged or lost labels are marked skipped; the cursor moves past them and their Devices stay unfilled.
- Overlapping ranges across batches of the same export (a reprint) raise a warning, since a device would have two labels.
- Asset QR labels have no LabelExport; they are printed once at purchase.

```proto
// lble
message LabelExport {
  string id = 1;
  string lineage = 2;
  Kind kind = 3;
  Format format = 4;
  google.protobuf.Timestamp exported_at = 5;
  Actor exported_by = 6;
  int64 seq = 7; // Plan branch seq it read
  repeated Row rows = 8;
  message Row {
    int32 row_number = 1;
    string device_id = 2;
  }
  enum Kind { KIND_UNSPECIFIED = 0; KIND_DEVICE = 1; KIND_AP = 2; }
  enum Format { FORMAT_UNSPECIFIED = 0; FORMAT_CSV = 1; FORMAT_XLSX = 2; }
}

// lblb
message LabelBatch {
  string id = 1;
  string lineage = 2;
  string label_export_id = 3;
  int32 first_row = 4;
  int32 last_row = 5;
  Actor printed_by = 6;
  google.protobuf.Timestamp printed_at = 7;
  int32 cursor = 8; // row of the next unused label; last_row + 1 when used up
  repeated int32 skipped_rows = 9;
  string name = 10; // "roll 2", written on the roll core
}
```

### Reports

- `device_sum`: per Category, the number of Devices requiring it in the Plan branch, against Fleet assets of that category by status (available, deployed, broken), plus untagged stock line quantities. PoE switches (`CATEGORY_L2_1G_POE_PLUS`, `CATEGORY_L2_100M_POE_PLUS`) are highlighted. Shown on screen and downloadable as CSV.
- TODO(interview): should `device_sum` also count only assets in containers requested by the outbound shipment (018)? Proposed: no, 018's shipment validation covers that.

### API

| Service | RPC | Notes |
|---|---|---|
| `LabelService` | `CreateLabelExport` | kind, format, selection; returns the LabelExport and the file |
| | `DownloadLabelExport` | re-download an existing export, identical bytes |
| | `CreateLabelBatch`, `UpdateLabelBatch` (skip rows, rename), `DeleteLabelBatch` | |
| | `DownloadAssetLabels` | asset QR labels for a selection of tags; no record kept |
| `ReportService` | `GetDeviceSum` | `NO_SIDE_EFFECTS`; message form for the UI |
| | `DownloadDeviceSum` | CSV |

- Selections: explicit ids, or a filter (Location, role, only devices without a LabelBatch row, only assets created after a date). Filters resolve to ids at export time and the export records the rows.
- File delivery: TODO(interview): inline `bytes` in the response, or a pre-signed S3 URL? Files are small (hundreds of rows), proposed inline bytes with `content_type` and `filename`, shared with 016/018/019 downloads as a `File` message.

```proto
message DownloadedFile {
  string filename = 1;     // rk26kor-device-labels-0003.xlsx
  string content_type = 2;
  bytes content = 3;
}
```

### Screens

- `/<episode>/labels`: list of LabelExports per kind, with their batches, cursors and coverage (devices with no label, devices on two batches).
- Export dialog: kind, format, selection filter, preview of rows with derived parts and warnings.
- Batch entry: "rows 12–40 printed as roll 2", then a per-batch view showing the next label and skipped rows.
- `/fleet/labels`: asset QR export by selection.
- `/<episode>/reports/device-sum`.

## Drawbacks

- Fixed column layouts tie the export to the current Tepra templates; changing a template means a code change.
- Row numbers fixed at export mean that devices added later need a new export, and the old export's row numbers stay meaningful only for that export.
- Deriving label text by parsing names fails on irregular names; those need manual handling in the Tepra app.

## Considered Alternatives

- Storing label text on Devices: rejected, it duplicates the name and goes stale exactly like the sheet tabs.
- Generating PDFs or printing directly: rejected, staff print from the Tepra desktop app, which imports CSV/XLSX.
- Per-label records instead of export rows: rejected, the bulk file is the unit staff handle.

## Prior Art

- The `device-tepra`, `ap-tepra` and asset `tepra` tabs (column layouts are copied from them).
- Tepra SPC10 / Label Editor CSV import.

## Security and Privacy Considerations

- Exports contain device names and asset tags only; no addresses or personal data.
- Exports are generated server-side from one branch at one seq, so a re-download is reproducible and auditable through the LabelExport row.

## Mission Scope

### Out of scope

- Cable labels, cable order forms and JJ orders (019).
- WLC commands (016) and the warehouse request form (018).
- The rubykaigi-net protojson export (013).
- Label tape width checks beyond device and AP labels (the cable `charlen` check is 019).

### Expected Outcomes

- The `device-tepra`, `ap-tepra` and `tepra` tabs are no longer maintained.
- Every device label printed for an Episode is traceable to a LabelExport row and a LabelBatch.
- `device-sum` is a page, not a tab.

## Implementation Plan

### Schema

```sql
-- db/schema/label_exports.sql
create table label_exports (
    id uuid primary key,
    branch_id uuid not null,
    lineage uuid not null,
    updated_seq bigint not null,
    kind smallint not null,
    format smallint not null,
    exported_at timestamp(6) with time zone not null,
    exported_by jsonb not null,        -- Actor
    seq bigint not null,
    number integer not null,           -- per branch and kind, for the filename; assigned client-side? TODO(interview)
    created_at timestamp(6) with time zone not null default now(),
    updated_at timestamp(6) with time zone not null default now()
);

-- db/schema/label_export_rows.sql
create table label_export_rows (
    id uuid primary key,
    branch_id uuid not null,
    lineage uuid not null,
    updated_seq bigint not null,
    label_export_id uuid not null,
    row_number integer not null,
    device_id uuid not null,
    created_at timestamp(6) with time zone not null default now(),
    updated_at timestamp(6) with time zone not null default now()
);
create unique index idx_label_export_rows_export_row on label_export_rows (branch_id, label_export_id, row_number);
create index idx_label_export_rows_device on label_export_rows (branch_id, device_id);

-- db/schema/label_batches.sql
create table label_batches (
    id uuid primary key,
    branch_id uuid not null,
    lineage uuid not null,
    updated_seq bigint not null,
    label_export_id uuid not null,
    name varchar(64),
    first_row integer not null,
    last_row integer not null,
    cursor integer not null,
    skipped_rows jsonb not null default '[]', -- int array; DSQL has no array columns
    printed_by jsonb not null,
    printed_at timestamp(6) with time zone not null,
    created_at timestamp(6) with time zone not null default now(),
    updated_at timestamp(6) with time zone not null default now()
);
```

- Export rows are a separate table so an export of a few hundred rows stays within DSQL's per-transaction limits and diffable in the changelog. TODO(interview): or `rows` as jsonb on the export? Separate table proposed, since 016 looks up "row N of export X".
- These are Plan tables (per Episode); forking a Plan branch copies them but they are rarely useful in a fork. TODO(interview): exclude label tables from fork copies (003)? Proposed: exclude.

### Code

- `app/models/label_export.rb`, `label_export_row.rb`, `label_batch.rb` (`include Branched`).
- `app/models/labels/device_name_parts.rb`: parses `<role>-<location>-<nn>`; shared with 019's cable ID parser where possible.
- `app/models/labels/layouts/{device,ap,asset_qr}.rb`: column definitions, one class per kind.
- `app/models/labels/writer.rb`: CSV (UTF-8 with BOM for the Tepra app TODO(interview): confirm encoding, the app may want Shift_JIS) and XLSX (`caxlsx` gem).
- `app/models/reports/device_sum.rb`: query over Plan Devices (required_category, fills) and Fleet assets/stock lines in the Episode's `fleet_branch`.
- `proto/rubykaigi/net_aid/label.proto`, `label_service.proto`, `report_service.proto`; controllers under `app/controllers/api/label/` and `api/report/`.

### Warnings (011)

| Code | Rule |
|---|---|
| `label_batch_overlap` | Two batches of the same export cover the same row |
| `device_label_name_unparsed` | Device name does not split into role, location and number |
| `device_without_label` | A Device in a Location has no row in any batch (only once batches exist) |

### Tests

- Layout specs comparing output against fixture files from the current tabs.
- Batch cursor and skip behaviour.
- `device_sum` against a seeded Plan and Fleet.

## Current Status

Draft: rough content populated, not yet reviewed. Interview not started.

Open questions:
- Device label QR payload: bare name or URL.
- SKU column before fills.
- File delivery: inline bytes or pre-signed URL (shared with other downloads).
- CSV encoding expected by the Tepra app.
- Export rows as a table or jsonb; export numbering.
- Whether label tables are copied on fork.
