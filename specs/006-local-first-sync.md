# 006-local-first-sync

## Summary

The client-side sync engine, in the local-first style of Linear's sync engine. It keeps an IndexedDB-backed object pool of one Plan branch plus its Fleet branch, hydrated from the bootstrap and kept current from the change feed. Local mutations apply optimistically, queue in an outbox, and are submitted once an action is complete, retried until acknowledged. The UI reads reactive models from the pool.

It must keep working offline, at the venue and the warehouse, without losing anything a user submitted.

## Motivation

- Venue halls and the warehouse have poor or no connectivity, and the venue network itself is what is being built. Scanning and assignment must not depend on it.
- The data is small (about 460 addresses, a few hundred devices, ~260 assets, ~1,300 cables per branch pair). Loading everything up front makes every screen instant and makes search, filters and validation previews local.
- Several operators edit the same Episode at once. A change feed keeps every client current without polling each screen.
- The domain model requires that no submitted update is ever lost, and inventory scans in particular (domain model, Requirements). The client is half of that guarantee: an outbox persisted in IndexedDB until the server acknowledges.

## Explanation

### Reading

```tsx
import { useEntity, useEntities, useSync } from "@/sync";

function DeviceList({ siteId }: { siteId: string }) {
  const devices = useEntities("Device", (d) => d.siteId === siteId, { sort: (d) => d.name });
  return devices.map((d) => <DeviceRow key={d.id} device={d} />);
}

function DeviceRow({ device }: { device: Device }) {
  // References resolve through the pool; a Plan Device's fill resolves in the Fleet branch.
  return <>{device.name} {device.location?.slug} {device.asset?.tag}</>;
}
```

- Models are MobX observables. Components wrapped with `observer` re-render when a field they read changes, whether locally or from the feed.
- Lookups by natural key: `pool.find("Asset", { tag: "rk-aph26a3" })`, `pool.find("Device", { siteId, name })`. Indexes are maintained in memory.
- `useSync()` exposes status: `bootstrapping | live | offline | error`, queued mutation count, last synced seq per branch.

### Writing

```ts
const tx = sync.mutate(DeviceService.method.updateDevice, {
  device: { id: device.id, locationId: loc.id },
  updateMask: { paths: ["location_id"] },
});
// tx.optimistic is applied to the pool at once; await tx.done for the server outcome.
```

- Every call through `sync.mutate` becomes one Mutation (spec 002): it gets a client-generated `mutation_id` (UUIDv7), the `base_seqs` the client has synced, and `client_time`, filled into the request's `MutationHeader`.
- Creates generate the entity's `id` on the client (UUIDv7, sent as a TypeID), so a new row can be referenced by later mutations before it syncs (an asset registered offline and assigned to a Device at once).
- The optimistic change shows immediately. When the server rejects, the change is rolled back and the screen shows the problem. When it is applied, the server's Change arrives through the feed and replaces the optimistic value.
- Each mutation carries an `optimistic` function describing its local effect. Generic Create/Update/Delete have generic ones; domain commands (pair assignment, scan batch) provide their own.
- Screens send a mutation once an action is complete (both halves of a pair scanned), never per keystroke.

### Offline

- Reads work from IndexedDB with no network after the first bootstrap of that branch pair.
- Mutations queue in the outbox and are sent in order when online. Queued items survive reloads, browser restarts and device sleep.
- Inventory scans (017) are insert-only and conflict-free; they may sit in the outbox for days.
- The header shows "offline, 37 changes waiting". The outbox screen lists queued and rejected mutations; a rejected one can be edited and resubmitted, or discarded.

## Drawbacks

- A sync engine is the most complex client component of the app, and it is bespoke.
- Holding the full branch pair in memory scales to the current data size only. A much larger dataset (all past Episodes at once) would need lazy loading, which this design does not provide.
- Optimistic UI can briefly show values that the server will reject; operators must notice rejections.
- Clients on an old build may receive Change payloads with fields they do not know. Protobuf tolerates unknown fields, but a new entity type needs a client update.

## Considered Alternatives

- SWR per screen with refetch on focus: no offline writes, every screen waits on the network, and multi-user freshness depends on polling.
- An off-the-shelf sync product (Replicache/Zero, ElectricSQL, PowerSync, Automerge/Yjs CRDTs): each wants to own the server side or the database. Our server already owns ordering (`head_seq`) and conflict rules (per-field last writer wins), and runs on DSQL and Lambda, which those products do not target.
- CRDTs for per-field merging: overkill given last-writer-wins in server commit order is the accepted rule.
- TODO(interview): MobX vs. a smaller store (Zustand, Valtio, signals). Proposed: MobX, as in Linear's engine; observable models with computed references fit the reference-heavy domain.
- TODO(interview): `idb` (thin promise wrapper) vs. Dexie. Proposed: `idb`, since the store layout is simple and fixed.

## Prior Art

- Linear Sync Engine, as reverse-engineered in `wzhudev/reverse-linear-sync-engine` and the marknotfound post:
  - Models registered with metadata, held in an object pool keyed by UUID, observable via MobX.
  - Full bootstrap into IndexedDB, then delta packets with a monotonically increasing sync id.
  - Transactions queued in memory and persisted in a `__transactions` table, replayed after restart.
  - Local DB is written only with server-confirmed data; in-memory models carry optimistic changes.
  - Incoming deltas rebase pending update transactions (last writer wins), and a transaction completes when the delta with its sync id arrives.
- Differences here:
  - The sync id is per branch (`head_seq`), not global; the client tracks two cursors (Plan, Fleet).
  - Mutations are idempotent by `mutation_id`, so re-sending after a crash is safe, which LSE does not guarantee.
  - No partial or lazy loading, no sync groups: one branch pair is small enough to load whole.
  - Transport is Connect RPC (pull, maybe server-stream) instead of GraphQL plus WebSocket, since Lambda cannot hold WebSockets.

## Security and Privacy Considerations

- IndexedDB data is readable by anyone with access to the unlocked device and browser profile. It contains infrastructure data (addresses, MACs, serials), no secrets. Sign-out and a "clear local data" action delete the databases.
- The outbox may hold mutations from a user whose session later expires. They are sent only with a valid session; on `unauthenticated` the client stops, keeps the outbox, and asks to sign in again. A different user signing in on the same device gets a prompt: submit the previous user's queue under the new user or discard it. TODO(interview): acceptable, or must queued mutations always carry the original actor?
- Bootstrap files for frozen branches on CloudFront must still require authentication (signed URLs or cookie check), since they contain the whole branch (007).

## Mission Scope

### Out of scope

- Server-side Bootstrap and PullChanges implementation (004), and the changelog (002).
- Undo/redo. TODO(interview): wanted later? Proposed: not now; the changelog makes server-side restore possible.
- Loading more than one Plan branch at once (branch diffs and "this device in rk25" use plain RPCs instead).
- Service worker for offline app shell. TODO(interview): needed so the app opens with no network at all? Proposed: yes, a minimal precache of the built assets, in this spec.

### Expected Outcomes

- `frontend/src/sync/` with model registry, object pool, IndexedDB persistence, outbox and feed client.
- A branch pair bootstraps once and reloads from IndexedDB in under a second afterwards.
- Edits from one browser appear in another within a few seconds while online.
- Mutations made offline are submitted after reconnecting, after a reload, and after a browser restart.
- A rejected mutation rolls back and is listed for resubmission.
- Proven end to end with Site, Location and Asn (008).

## Implementation Plan

### Module layout

```
frontend/src/sync/
  index.ts            # public API: SyncClient, hooks
  registry.ts         # entity type -> proto message schema, references, indexes
  model.ts            # observable wrapper over a proto message
  pool.ts             # ObjectPool: Map<id, Model>, natural-key indexes
  store.ts            # IndexedDB access (idb)
  bootstrap.ts        # Bootstrap RPC / cached file -> store + pool
  feed.ts             # PullChanges loop, applies Changes
  outbox.ts           # Mutation queue, persistence, sending, retries
  optimistic.ts       # overlay of pending effects on top of confirmed state
  hooks.ts            # useEntity, useEntities, useSync
```

### Registry

```ts
type EntityDef<T extends Message> = {
  type: string;                     // "Device", matches Change.entity_type
  dataset: "plan" | "fleet";
  schema: GenMessage<T>;            // generated message, e.g. DeviceSchema
  naturalKeys?: (keyof T)[][];      // [["siteId", "name"]]
  references?: Record<string, { field: keyof T; target: string; dataset?: "plan" | "fleet" }>;
};
export function defineEntity<T extends Message>(def: EntityDef<T>): void;
```

Entity specs (008+) register their entities here; the registry is the only per-entity client code needed for sync.

### IndexedDB layout

One database per branch pair: `net-aid:<planBranchId>:<fleetBranchId>`. TODO(interview): one database per branch instead, so switching Episodes that share Fleet main reuses its data? Proposed: per branch (`net-aid:br_...`), plus a small `net-aid:meta` database.

| Store | Key | Value |
|---|---|---|
| `meta` (in `net-aid:meta`) | branch id | `{ branchId, dataset, frozen, syncedSeq, schemaHash, bootstrappedAt }` |
| `rows` | `[entityType, id]` | serialized entity message (binary protobuf) |
| `outbox` | `mutationId` | `{ mutationId, rpc, payload (binary), branchIds, createdAt, attempts, state: "queued" \| "sending" \| "rejected", error? }` |

- `rows` holds server-confirmed state only, as in LSE. Optimistic effects live in memory and are recomputed from the outbox at load.
- `schemaHash` covers the registry; a mismatch after a deploy discards `rows` and re-bootstraps (the outbox is kept).

### Bootstrap

1. Read `meta`. If the branch has `syncedSeq`, load `rows` into the pool and go to the feed.
2. Otherwise fetch the bootstrap: for a frozen branch, the cached file on CloudFront (007); for a live branch, `SyncService.Bootstrap` (paged, all rows at a `head_seq`).
3. Write rows and `syncedSeq = head_seq` in one IndexedDB transaction per page; `meta` last, so a half-written bootstrap restarts.
4. A branch in `preparing` state (003) shows a waiting screen and polls.

### Feed

- `SyncService.PullChanges(branch_id, after_seq, limit)` returns Changes in seq order plus `head_seq`.
- Loop: while online, pull each branch; when caught up, wait. TODO(interview): long-poll, server-streaming over Connect, or plain polling every few seconds? Lambda function URLs buffer responses (no streaming through `apigatewayv2_rack`), so proposed: short polling (2–5 s while visible, paused when hidden), revisited if Lambda response streaming becomes usable.
- Apply each ChangeSet atomically: write to `rows`, advance `syncedSeq`, then update the pool in one MobX action.
- A gap (first seq received > `syncedSeq + 1`) cannot happen with a correct server; treat it as corruption and re-bootstrap.

### Outbox and optimistic overlay

```ts
type PendingMutation = {
  mutationId: string;
  rpc: string;
  payload: Uint8Array;
  touches: { type: string; id: string; fields?: string[] }[];
  optimistic: (draft: Draft) => void;
};
```

- Effective value of a field = confirmed value from the pool, then every pending mutation's optimistic effect applied in queue order.
- When a Change arrives for a row with pending mutations, the confirmed value updates and the overlay is reapplied on top. This is LSE's rebase: the local pending edit still shows until its own mutation is applied or rejected.
- A mutation is done when its response says applied and the feed has reached the seqs the response names (`ChangeSet.seq` per branch). Then its overlay is dropped.
- Sending: in order, one at a time per dependency chain. TODO(interview): batch several mutations per request? Proposed: no batching at first; one RPC per mutation, sequential.
- Retries: network errors and `unavailable` retry with backoff indefinitely; the same `mutation_id` makes replays safe (002). `invalid_argument`, `failed_precondition`, `permission_denied` mark it rejected and roll back its overlay.
- Dependent mutations: if a rejected mutation created a row that later queued mutations reference, those are rejected locally too. TODO(interview): or held for the user to fix?

### Episode switching

- Switching Episodes swaps the active branch pair: stop the feed, keep the outbox (it is keyed by mutation, not by branch), load the other pair.
- Pending mutations for a non-active branch keep sending in the background.
- Old branch databases are evicted LRU beyond a few. TODO(interview): limit?

### Testing

- Unit tests (`node --test`) for the overlay, rebase and outbox state machine with a fake transport and `fake-indexeddb`.
- An end-to-end spike against the real backend with 008's entities, including kill-and-reload during sending.

## Current Status

Draft: rough content populated, not yet reviewed. Interview not started.

Open questions:
- From 001/002 review: store and echo the opaque cursor without interpreting it; on `RESYNC_REQUIRED` drop the branch copy and bootstrap again, keeping the outbox; on `SESSION_EXPIRED` call `ViewerService.RefreshSession` single-flight and retry; on `SESSION_REVOKED` send the person to sign in, keeping the outbox.
- MobX vs. a smaller store; `idb` vs. Dexie
- IndexedDB database per branch vs. per branch pair
- feed transport: polling, long-poll or streaming on Lambda
- mutation batching
- handling dependent mutations after a rejection
- outbox behaviour when a different user signs in
- service worker for offline app shell
- undo/redo
