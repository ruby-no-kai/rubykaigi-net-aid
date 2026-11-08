# 005-frontend-foundation

## Summary

Sets up the frontend application: TypeScript, React, Vite, React Router, Kumo UI and tanstack form, managed with pnpm and built into static files served from S3 and CloudFront. It includes Connect clients generated from `proto/`, sign-in through himari, Episode and branch selection carried in URLs, and the layout and navigation shell.

Phones are a first-class target, since scanning and venue assignment happen on them.

## Motivation

- Every later spec ships a screen. Without a shared shell, each one reinvents routing, RPC error handling, forms and the Episode switcher.
- Operators today work in Google Sheets on laptops and phones. The app has to be at least as quick to open on a phone at the venue as a sheet tab is.
- The backend is same-origin only (`ConnectForgeryProtection` rejects cross-site requests and grants no CORS), so the SPA must be served from the API's origin.
- sponsor-app already runs the same stack (`ui/` with Vite, React Router, Kumo, tanstack form, Connect-ES). Following its layout keeps the two apps maintainable by the same people.

## Explanation

### Directory layout

```
frontend/
  package.json            # name: net-aid-frontend, private, type: module
  pnpm-lock.yaml
  pnpm-workspace.yaml     # minimumReleaseAge, allowBuilds
  tsconfig.json           # strict, noUncheckedIndexedAccess, paths: "@/*" -> "src/*"
  vite.config.ts
  vite/rails-proxy.ts     # dev server proxies non-SPA paths to Rails
  index.html
  src/
    main.tsx              # mounts <RouterProvider>, starts the sync client (006)
    router.tsx            # route tree, lazy route modules
    gen/                  # protoc-gen-es output, committed
    lib/                  # rpc.ts, errors.ts, forms.ts, dates.ts, ...
    sync/                 # local-first engine (006)
    routes/
      Root.tsx            # session gate, layout shell
      RouteError.tsx
      paths.ts            # typed path builders, shared with the dev proxy
      episodes/           # Episode list, Episode switcher
      plan/               # per-Episode Plan screens (008+)
      fleet/              # Fleet screens (014+)
      scan/               # phone-first scanning screens (016, 017)
```

TODO(interview): `frontend/` (as the shared naming says) or `ui/` like sponsor-app? Proposed: `frontend/`, matching `backend/`.

### URL scheme

Natural keys in URLs where they are stable (domain model, Row identity):

| Path | Screen |
|---|---|
| `/` | Episode list, redirects to the latest open Episode |
| `/:episode` | Episode dashboard (`/rk26kor`) |
| `/:episode/sites`, `/:episode/locations` | organisation (008) |
| `/:episode/prefixes`, `/:episode/addresses`, `/:episode/vlans` | IPAM (009) |
| `/:episode/devices/:site/:name` | device (`/rk26kor/devices/venue/es-tra-01`) (010) |
| `/:episode/cables/...` | cables (019) |
| `/fleet/assets/:tag` | asset; also the target of `nwa.rubykaigi.org/<tag>` (014) |
| `/fleet/containers/:tag`, `/fleet/depots`, `/fleet/shipments/...` | Fleet (014, 018) |
| `/fleet/inventory/:sessionId` | inventory session (017) |
| `/scan` | phone scanning entry point (016, 017) |
| `/:tag` | redirect for QR labels: resolves an asset or container tag, then navigates |

- The Episode in the URL selects which Plan branch and Fleet branch the sync client loads (006). Fleet paths without an Episode use the last selected Episode's Fleet branch (Fleet main while it is open).
- A row without a natural key falls back to its TypeID (`/:episode/prefixes/pfx_01h...`).
- TODO(interview): `/:tag` at the root collides with Episode slugs (`rk26`) in principle. Proposed: tags always contain `-` (`rk-aph26a3`, `rkc-26F`) and slugs never do, so the router tells them apart by pattern.

### Using the shell from a feature screen

- Screens read synced entities through the sync engine's hooks (006), not RPCs:
  ```tsx
  const devices = useEntities("Device", (d) => d.siteId === site.id);
  ```
- Non-synced calls (sign-in state, exports, imports, downloads) go through `useRpc` / SWR:
  ```ts
  const { data: viewer } = useRpc(ViewerService.method.getViewer, {});
  ```
- Forms use tanstack form through `lib/forms.ts`, which maps a Connect `InvalidRecord` problem's field violations onto form fields.
- Errors: `lib/errors.ts` turns Connect errors carrying problem details into `AppError` (kind, title, field errors). Route-level `ErrorBoundary`s render them.

### Sign-in

- The SPA calls `ViewerService.GetViewer` on boot. When not signed in, it navigates to the backend's sign-in path (`/auth/himari`), which runs the OIDC flow against himari and sets the session cookie, then returns to the original path (001).
- The cookie is the only credential the browser holds. No token is stored in JS-reachable storage.
- Offline at boot: if a session was established before and the sync store holds data, the app opens read-and-queue mode instead of redirecting (006).

### Dev workflow

```sh
cd frontend
pnpm install
pnpm dev          # Vite on :5173, proxying RPC and /auth paths to Rails on :3000
pnpm typecheck
pnpm test         # node --test on *.test.ts
pnpm format       # oxfmt
mise run gen      # also regenerates src/gen via buf.gen.es.yaml
```

## Drawbacks

- An SPA plus a sync engine is far more code than server-rendered Rails views for what is, per screen, a CRUD table.
- Committed generated code (`src/gen/`) doubles proto churn in diffs.
- Kumo is young; components we need (data tables with inline edit, combobox for device references) may be missing and have to be built locally.

## Considered Alternatives

- Rails views with Hotwire: no offline story, which the scanning flows require (006, 017).
- Next.js: needs a server runtime for SSR; the app is behind sign-in, so SSR buys nothing and SSG of a plain Vite build suffices.
- A native mobile app for scanning: two codebases. Browser camera APIs (`BarcodeDetector`, or a JS decoder fallback) and USB/Bluetooth HID scanners acting as keyboards cover the need.
- TODO(interview): Kumo vs. another component library (shadcn/ui, Mantine). Proposed: Kumo, as in sponsor-app.

## Prior Art

- sponsor-app `ui/`: same stack; copy `vite/rails-proxy.ts`, `lib/rpc.ts`, `lib/errors.ts`, `lib/fieldErrors.ts`, `routes/paths.ts` patterns.
- NetBox UI for IPAM screen structure (list, filter, detail, related objects).

## Security and Privacy Considerations

- Same-origin only: SPA and API share one CloudFront distribution (007), so `ConnectForgeryProtection` stays strict and no CORS is opened.
- Session cookie: `HttpOnly`, `Secure`, `SameSite=Lax` (001).
- Content Security Policy from CloudFront response headers: `default-src 'self'`, no inline scripts. Camera access only on scanning screens.
- IndexedDB holds a copy of Plan and Fleet data on each device (006). That includes MAC addresses and asset serials, not personal data beyond Actor display names. Sign-out clears it.
- Third-party dependencies: `minimumReleaseAge` in `pnpm-workspace.yaml`, as in sponsor-app.

## Mission Scope

### Out of scope

- Feature screens themselves (each entity spec owns its screens).
- The sync engine internals (006).
- Infrastructure for hosting (007).
- i18n beyond English labels with Japanese domain terms as they appear in the sheets. TODO(interview): is a Japanese UI needed? Proposed: no, English only.

### Expected Outcomes

- `frontend/` builds to static files with `pnpm build`.
- Signing in through himari works locally against Rails.
- Root layout with navigation, an Episode switcher, and route error handling.
- Generated Connect-ES clients for every service in `proto/`.
- Phone-width layout usable for the `/scan` entry screen.

## Implementation Plan

### Packages

| Package | Purpose |
|---|---|
| `react`, `react-dom` 19 | UI |
| `react-router` | routing, lazy route modules |
| `@cloudflare/kumo`, `@phosphor-icons/react`, `tailwindcss` | components, icons, styles |
| `@tanstack/react-form` | forms |
| `@bufbuild/protobuf`, `@connectrpc/connect`, `@connectrpc/connect-web` | RPC |
| `swr` | non-synced RPC caching |
| `mobx`, `mobx-react-lite`, `idb` | sync engine (006) |
| dev: `vite`, `@vitejs/plugin-react`, `@bufbuild/protoc-gen-es`, `typescript`, `oxfmt` | build, codegen, format |

### Codegen

- `buf.gen.es.yaml` at the repo root, separate from `buf.gen.yaml` (Ruby), with `protoc-gen-es` from `frontend/node_modules/.bin`, `target=ts`, `import_extension=ts`, `erasable_syntax=true`, output `frontend/src/gen`.
- `mise run gen:proto` runs both templates. CI fails on drift (`git diff --exit-code`).

### Core modules

```ts
// lib/rpc.ts
export const transport: Transport; // createConnectTransport({ baseUrl: "/", useBinaryFormat: false })
export function client<T extends DescService>(service: T): Client<T>;
export function useRpc<I, O>(method: DescMethodUnary<I, O>, input: MessageInitShape<I> | null): SWRResponse<O, AppError>;

// lib/errors.ts
export type AppError =
  | { kind: "problem"; type: string; title: string; detail?: string; fieldErrors: FieldError[] }
  | { kind: "unauthenticated" }
  | { kind: "network"; cause: unknown };
export function toAppError(e: unknown): AppError;

// routes/paths.ts
export const paths: {
  episode(slug: string): string;
  device(episode: string, site: string, name: string): string;
  asset(tag: string): string;
  // ...
};
export const SPA_PATTERNS: RegExp[]; // shared with vite/rails-proxy.ts and the CloudFront function (007)
```

### Routing and served paths

- RPC paths (`/rubykaigi.net_aid.*/*`), `/auth/*` and `/up` go to Rails. Everything else is the SPA's `index.html`.
- In development, `vite/rails-proxy.ts` applies that split. In production, CloudFront behaviours do (007).
- Vite assets under `/_ui/` (hashed, long cache). TODO(interview): keep sponsor-app's `/_ui/` base or use `/assets/`? Proposed: `/_ui/`.

### Layout shell

- `Root.tsx`: loads the Viewer, starts the sync client for the Episode in the URL, shows sync status (online, offline with N queued mutations, bootstrapping) in the header.
- Desktop: sidebar navigation (Plan, Fleet, Exports). Phone: bottom tab bar (Scan, Search, Episode).
- Global search box resolving natural keys (tag, FQDN, address, cable ID) from the local object pool.

### Tests

- `node --test` for `lib/` and `routes/paths.ts`, as in sponsor-app.
- TODO(interview): browser tests (Playwright) for the scan flows? Proposed: later, with 016/017.

## Current Status

Draft: rough content populated, not yet reviewed. Interview not started.

Open questions:
- `frontend/` vs `ui/` directory name
- root `/:tag` redirect vs Episode slugs
- Kumo as the component library
- Vite asset base path
- Japanese UI needed or not
- browser test tooling
