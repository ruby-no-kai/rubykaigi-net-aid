# 016-device-fill-and-venue-assignment

## Summary

Links Plan Devices to the Fleet Assets or StockLines that fill them. At the venue, staff assign by scanning a device label and an asset tag as a pair, in either order, or by sticking on the next label of a LabelBatch and scanning only the asset tag. The assignment is one transaction across the Plan and Fleet branches. Once an AP's MAC is known through its fill, the WLC commands (`ap name`, `ap group-name`) can be downloaded.

## Motivation

- Today the link between a planned device (`ap-lb0-01`) and the physical box (`rk-aph26a3`) is typed into the `devices` and `ap-name-set command` tabs by hand, often hours after mounting, from photos of labels.
- The WLC needs `ap name ap-lb0-01 <mac>` per AP. The MAC comes from the asset sheet, the name from the plan; joining them is a manual XLOOKUP.
- `es-*` CNAMEs (`es-tra-01.venue` → `<asset tag>.venue`) and Kea reservations by asset tag client-id need the same link (exported by 013).
- After the Episode, `rk26kor` must still show which asset filled each device, even after the asset moves on.

## Explanation

### The fill

- A Device (010) has an optional fill: `asset_id` (a tagged Asset) or `stock_line_id` (an untagged item such as `IX2215 ×2`), never both.
- The fill points into the Episode's `fleet_branch`: Fleet main while the Episode is open, the Fleet snapshot after close (003).
- Fill columns on Device: `asset_id`, `stock_line_id`, `mounted_at`, `mounted_by` (Actor), and `status`.
- An Asset may fill at most one Device per Episode. TODO(interview): across open Episodes too (rk26 and rk26kor overlapping)? Proposed: warn, not reject.

### Assignment effects (one transaction, two ChangeSets)

| Branch | Row | Change |
|---|---|---|
| Plan | Device | `asset_id` = asset, `mounted_at` = client time, `mounted_by`, `status` = `deployed` |
| Plan | previous Device filled by this asset (if any) | fill cleared, status back to `planned` |
| Fleet main | Asset | `status` = `deployed`, whereabouts = loose at the venue Depot of the Episode |

- A stock line fill does not change the stock line's quantity or whereabouts.
- Unassigning clears the fill, sets the Device to `planned`, and the Asset to `available` (whereabouts unchanged).
- Collecting at teardown: the Device becomes `collected` and the Asset `available`. This happens in bulk when the return Shipment (018) records the asset, or by an explicit `MarkCollected`.

### Venue flows (phone)

Pair scan:

1. Open "Assign" in the active Episode. The scanner accepts either a device label QR or an asset tag QR first.
2. Scan the device label (`ap-lb0-01`, or its URL). The screen shows the device, its Location and required category, and the current fill if any.
3. Scan the asset tag (`rk-aph26a3` or `https://nwa.rubykaigi.org/rk-aph26a3`). Unknown tags offer quick registration (014).
4. The client checks category compatibility and shows warnings (wrong category, asset already filling another Device, asset `broken`/`disposed`). The person confirms.
5. The client sends one `AssignFill` mutation; offline it is queued (006) and the screen shows it as pending.

Batch scan:

1. Pick an active LabelBatch (015), e.g. "roll 2, next: `ap-lb0-07`".
2. Stick the next label on the AP and scan the asset tag only. The mutation names the batch and expected row, and the cursor advances.
3. "Skip" marks a damaged label; its Device stays unfilled.
4. Two people on two rolls work independently. Two people on one roll conflict: TODO(interview): the server takes the row named in the mutation, so a second phone that read a stale cursor assigns a different device than shown. Proposed: the mutation carries `row_number`; the server rejects if that row was already used, and the client resyncs the cursor.

Typing works everywhere scanning does, for when a label is unreadable.

### WLC commands

Downloads generated from fills (text file, one command per line):

| Kind | Command | Source |
|---|---|---|
| `ap_name` | `ap name <device name> <mac>` | Devices with role `ap` and an asset fill with an Ethernet AssetMac |
| `ap_group` | `ap group-name <group> <device name>` | Device's Location → AP group TODO(interview): where does the group live? Proposed: a `wlc_ap_group` field on Location |
| `ap_reset_name` | `ap name <asset tag> <mac>` | resets APs to their tag after the Episode |

- MAC format follows AireOS (`aa:bb:cc:dd:ee:ff`).
- `ap name` prompts for confirmation on AireOS for each command; the download is meant for pasting with `config paging disable`. TODO(interview): confirm the exact WLC syntax and whether `ap group-name` needs `ap disable` first.
- Selections: all, one Location, or only fills changed since a seq.

### API

| Service | RPC | Notes |
|---|---|---|
| `DeviceService` | `AssignFill` | `device_id` (or `site` + `name`), `asset_id` or `stock_line_id` (or a tag to resolve), optional `label_batch_id` + `row_number`, `mounted_at`; `MutationHeader header` |
| | `ClearFill` | |
| | `MarkCollected` | bulk by device ids |
| | `SkipLabel` | batch id + row number |
| `WlcService` | `DownloadWlcCommands` | kind, selection; returns `DownloadedFile` (015) |

- `AssignFill` accepts natural keys as well as ids, for agents and typed input.
- Responses return the updated Device and Asset messages; clients also receive them through the change feed.

### Screens

- Assign screen (phone): scanner view, last five assignments with pending/synced state, undo for the last one.
- `/<episode>/devices` gains fill, mounted at/by columns and a filter for unfilled devices by Location and category.
- Asset page (014) shows current fill per open Episode and past fills from closed Episodes.
- `/<episode>/wlc`: preview and download of WLC commands.

## Drawbacks

- Writing to two branches in one transaction widens the conflict surface: two phones assigning different devices at the same moment both touch the Fleet branch's `head_seq` row and one retries. Acceptable at venue scale (a handful of people).
- Fills stored as plain ids into another branch need remapping whenever the Episode's `fleet_branch` changes (003), so a bug there silently breaks history.
- Requiring a device label means labels must be printed before mounting; when they are not, staff fall back to typing.

## Considered Alternatives

- Storing the Device on the Asset (`deployed_as`): rejected, Fleet never points into a Plan (domain model), and one asset fills devices in many Episodes over time.
- An `Assignment` join table: rejected, per-Episode facts live on Plan rows; a Device has at most one fill, and history comes from the changelog and closed branches.
- Lineage instead of id for the fill: rejected in the domain model; lineage is never a foreign key.

## Prior Art

- The `ap-name-set command` and `ap-group-set` tabs (command formats, 回収済 column).
- NetBox's device ↔ inventory item relation.

## Security and Privacy Considerations

- Assignments are attributed to the Actor (`mounted_by`), so mistakes can be traced and corrected.
- WLC commands contain names and MACs only; no credentials.
- Only roles allowed to edit the Episode's Plan and Fleet main may assign (001). TODO(interview): a venue-staff role that may assign and scan but not edit the plan? Proposed: yes, `venue` role.

## Mission Scope

### Out of scope

- AP RF configuration (WLC is the source of truth; deferred).
- Pushing commands to the WLC automatically.
- Inventory sessions and shipments (017, 018), which record sightings and moves; assignment only sets a loose venue sighting.
- Label generation itself (015).

### Expected Outcomes

- Every deployed device at an Episode shows its asset, who mounted it and when.
- WLC rename commands are a download, not a tab.
- `es-*` CNAMEs and asset-tag Kea reservations in 013 are fed from fills.

## Implementation Plan

### Schema

Fill columns live on `devices` (defined in 010). This spec relies on:

```sql
-- in db/schema/devices.sql (010)
    asset_id uuid,             -- into episodes.fleet_branch_id
    stock_line_id uuid,
    mounted_at timestamp(6) with time zone,
    mounted_by jsonb,          -- Actor
    status smallint not null,
-- index for "which device does this asset fill"
create index idx_devices_branch_asset on devices (branch_id, asset_id);
```

- No foreign keys across branches; integrity is checked in `Fills::Assign` and by the remap job (003).
- LabelBatch cursor update and Device fill commit together (Plan branch).

### Code

- `app/models/fills/assign.rb`: the command. Resolves tag or id in the Episode's Fleet branch (`TagLookup`, 014), checks preconditions, writes Device, previous Device, Asset and optional LabelBatch through `Changelog.write(mutation:, branches: [plan, fleet_main])`.
- `app/models/fills/clear.rb`, `fills/mark_collected.rb`.
- Hard rejections: Episode closed or Plan branch frozen; Fleet branch not main (Episode closed); device or asset not found; asset `disposed`; batch row already used.
- Warnings returned in the response and computed by 011: category mismatch, asset `broken`/`lost`, asset already filling another Device in another open Episode.
- `app/models/wlc/commands.rb`: builds command lines; `app/controllers/api/wlc/`.
- `proto/rubykaigi/net_aid/device_service.proto` gains the RPCs above; `wlc_service.proto`.

### Remapping with 003

- Close: rewrite every Device fill from Fleet main ids to the snapshot ids via lineage, before freezing the Plan branch.
- Fork: rewrite fills from the source's Fleet branch (snapshot) back to Fleet main via lineage; clear fills whose lineage no longer exists in main (disposed rows still exist, so this is rare) and warn.
- Proposed: forks clear all fills by default, since a new Episode re-mounts everything. TODO(interview): keep fills on fork (pre-configured routers) or clear? The domain model says fills are copied then edited.

### Warnings (011)

| Code | Rule |
|---|---|
| `device_fill_category_mismatch` | Fill's Product category differs from `required_category` |
| `asset_fills_multiple_devices` | One asset fills two Devices across open Episodes |
| `device_deployed_without_fill` | Status `deployed` with no fill |
| `ap_fill_without_mac` | AP filled by an asset without an Ethernet MAC (no WLC command) |

### Tests

- `Fills::Assign` specs: both branches change in one transaction, one ChangeSet each, idempotent replay by mutation id, batch cursor race.
- Request specs for natural-key input.
- WLC output fixtures from the current command tabs.

## Current Status

Draft: rough content populated, not yet reviewed. Interview not started.

Open questions:
- One asset filling devices in two overlapping open Episodes: warn or reject.
- Batch cursor races on a shared roll.
- Where the AP group for `ap group-name` lives.
- Exact WLC command syntax.
- Fills on fork: keep and remap, or clear.
- A venue-staff role limited to assignment and scanning.
