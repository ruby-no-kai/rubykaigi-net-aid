# Specs

Design specs for rubykaigi-net-aid, derived from the [README](../README.md) and the [domain model](../docs/domain-model.md). Each spec follows the same template and ends with its Current Status.

## Roadmap

Specs are numbered in the order they are expected to be implemented. Milestones group them into shippable steps.

### A. Backend core

Prove the data model's hardest parts on the server before any UI exists.

| Spec | Depends on |
|---|---|
| [021 Request logging](021-request-logging.md) | |
| [001 Authentication and roles](001-authentication-and-roles.md) | 021 |
| [002 Branches and changelog](002-branches-and-changelog.md) | 001 (Actor) |
| [003 Episodes and branch lifecycle](003-episodes-and-branch-lifecycle.md) | 002 |
| [004 Entity RPC pattern](004-entity-rpc-pattern.md) | 001, 002 |

021 is numbered after the rest but implemented first, since 001 and 002 log through it.

### B. Client core

A usable app shell with offline-capable sync, exercised against the first entities.

| Spec | Depends on |
|---|---|
| [005 Frontend foundation](005-frontend-foundation.md) | 001 |
| [006 Local-first sync](006-local-first-sync.md) | 004, 005 |
| [008 Plan organisation](008-plan-organisation.md) | 003, 004, 006 |

008 is the first vertical slice: Site, Location and Asn from table to UI.

### C. Plan data (replaces the Network Data sheet)

| Spec | Depends on |
|---|---|
| [009 IPAM](009-ipam.md) | 008 |
| [010 Devices](010-devices.md) | 009 |
| [011 Validation warnings](011-validation-warnings.md) | 009, 010 |
| [012 Network sheet import](012-network-sheet-import.md) | 003, 010 |

### D. Go live

Usable by the team for the next Episode's planning, and feeding rubykaigi-net.

| Spec | Depends on |
|---|---|
| [007 Deployment](007-deployment.md) | 001, 005 |
| [013 rubykaigi-net export](013-rubykaigi-net-export.md) | 010 |

007 can start any time after A and B; it is numbered early because every later milestone ships through it.

### E. Fleet (replaces the asset sheet and inventory tabs)

| Spec | Depends on |
|---|---|
| [014 Fleet catalogue](014-fleet-catalogue.md) | 003, 004 |
| [015 Labels and reports](015-labels-and-reports.md) | 010, 014 |
| [016 Device fill and venue assignment](016-device-fill-and-venue-assignment.md) | 010, 014, 015 |
| [017 Inventory scanning](017-inventory-scanning.md) | 006, 014 |
| [018 Shipments](018-shipments.md) | 016, 017 |

### F. Cables

| Spec | Depends on |
|---|---|
| [019 Cables](019-cables.md) | 010, 012, 015 |

### G. History

| Spec | Depends on |
|---|---|
| [020 History and restore](020-history-and-restore.md) | 002, 004, 011 |

## Interview order

Detail the specs that constrain the most others first: 002, 004 and 006 fix the row, write and sync contracts every entity spec relies on. 002 and 006 cover the spikes the domain model leaves open (lineage in Rails, the client sync protocol). The cable ID parser spike belongs to 019.
