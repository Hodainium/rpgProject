# Roadmap: slices and design breaks

Agreed 2026-10-14. This is the build order. Each slice gets its own `specs/<slice>.md` via `/spec` before any code.
Cycle per slice: `/spec` → `/implement` → commit `feat:` → `/sync-spec` → commit `spec:`.

## Where we are
| Slice | Status | Date |
|---|---|---|
| 0. `project-skeleton` | ✅ Done | 2026-10-19 |
| 1. `combat-replay-core` | ✅ Done | 2026-10-19 |
| 1b. `game-skeleton` | 🔨 Implemented, awaiting review | 2026-10-19 |
| 1c. `dev-tools` | ⬜ Not started | |
| 1d. `playable-demo` | ⬜ Not started | |
| 2. `battle-checkout` | ⬜ Not started | |
| 2b. `run-authority` | ⬜ Not started | |
| 3. `battle-verify` | ⬜ Not started | |
| 4. `settlement-outbox` | ⬜ Not started | |
| 5. `gacha` | ⬜ Not started | |
| 6. `observability` | ⬜ Not started | |
| 7. `live-dashboard` | ⬜ Not started | |
| 8. `load-and-chaos` | ⬜ Not started | |
| 9. `ruleset-versioning` | ⬜ Not started | |

Statuses: ⬜ Not started · ⏭️ Next · 📝 Spec written · 🔨 Implementing · ✅ Done (acceptance scenarios pass).
**Claude keeps this table current:** update it whenever `/spec`, `/implement` or `/sync-spec` moves a slice, and
include the change in that slice's commit.

## Changing the roadmap
The roadmap is a living plan. Slices can be reordered, split, merged, added or dropped whenever the user decides.
- Edit the slice list and the table together, so they never disagree.
- Add a line to the change log below saying what changed and why.
- Claude may propose a change (e.g. a slice turns out too big) but only edits the roadmap after the user agrees.
- Commit roadmap changes as `spec:`.

### Change log
- 2026-10-14: Roadmap created (slices 0–9, four suggested design breaks).
- 2026-10-14: Server renamed `Rpg.BasServer` → `Rpg.GameServerApi`; client HTTP layer moved to its own library `src/Rpg.Client`.
- 2026-10-14: Target .NET 10 LTS instead of .NET 8 (support ends 2026-11-10); Godot fallback recorded in the project-skeleton spec.
- 2026-10-19: Design notes moved to `specs/design/` (`combat-design.md`); slice specs stay at the top of `specs/`.
- 2026-10-19: Added slice 1b `game-skeleton` (the Godot game's bare bones) after slice 1 and before slice 2, at the
  user's request: having the game's structure in place first helps the rest of development. To be specced in a
  separate game-design chat.
- 2026-10-19: Split 1b into 1b `game-skeleton`, 1c `dev-tools`, 1d `items-and-loadouts`, 1e `playable-demo`, at the
  user's request, following the game design outline in `specs/design/game-design.md`.
- 2026-10-19: Added slice 2b `run-authority` (authentication; server-owned run state; batched battles plus quick
  authenticated messages for out-of-battle actions) and a system-design pass after 1d, at the user's request.
- 2026-10-19: Merged `items-and-loadouts` into 1b `game-skeleton` (all game mechanics before any tooling; no tools for
  mechanics that don't exist yet). Order is now 1b skeleton → system-design pass → 1c dev tools → 1d playable demo.
  The demo content moved from 1b to 1d. At the user's request.
- 2026-10-19: 1b also creates a small example set in the user's folders (`content/demo/`, `presentation/demo/`, real
  tags and the AttributeSet in `godot_gas/`) so the hand-made structure is visible early; 1d grows it. At the user's request.
- 2026-10-19: Kept `dev-tools` (1c) before `playable-demo` (1d). Building the demo with the tools is expected to expose
  limits and wrong assumptions in them; fixing those is part of 1d's scope. At the user's request.


## Design tuning: any time, not just in breaks
The user may tune `client-godot/content/`, `presentation/` and `godot_gas/` at any point in the project.
The "design breaks" below are only suggestions for when there is something new to feel. They are not gates.
- System tests run only on `tests/fixtures/`, so tuning can never fail them. Only content golden replays change;
  re-record them when the change was intentional (see `client-godot/CLAUDE.md` section 0).
- Tuning changes the content hash, so `ruleset_version` changes. Until slice 9, a battle that is open while you tune
  may be rejected with 2002. That's expected in dev.
- Commit tuning on its own as `design:`, separate from `feat:` commits. Running `/sync-spec` afterwards keeps specs truthful.
- Before Claude runs `/implement`, the tree should be clean (commit or stash design work first) and the Godot editor saved.

## Slices

### 0. `project-skeleton`
`Rpg.slnx`, `Rpg.Contracts`, `Rpg.Client`, `Rpg.GameServerApi` (`/health` only), test projects, Godot `.csproj`. Server connects to the
compose stack (Postgres, Redis, RabbitMQ). Baseline OpenTelemetry and Prometheus `/metrics` wiring.
Done when `dotnet build` and `dotnet test` pass at the root; update the CLAUDE.md status table.

### 1. `combat-replay-core`
Turn order (HSR-style action value / speed), replay log schema (seed, party snapshot, ordered actions), state hash
(fields, order, integers only). Headless runner: `(seed, snapshot, action log) → final state + hash`.
Golden determinism tests on `tests/fixtures/` content only.

> 🎨 Suggested design break 1, combat feel: characters, enemies, abilities and effects in `content/`; damage formula
> and speed tuning; a battle scene in `presentation/` that plays back sim events.

### 1b. `game-skeleton`
**Purpose:** every game mechanic laid out as data before any tooling is built, so making the game becomes filling in
data files. GAS-first (`specs/design/game-design.md` section 2a). Spec: `specs/game-skeleton.md`.
World and run: rooms, chapters, floor-gen rules, run structure, hand-made floor layouts, Isaac-style seeded floor
generator, RNG streams, run state and run log. Units: characters and enemies (subclasses of `UnitDefinition`),
loadouts with encounter and placement overrides, elite variants, floor scaling. Items (passive/active, pools,
character-specific, triggered passives), equipment, shops and treasure rooms, coin drops, events. HP/MP carry-over,
out-of-battle item and spell use, `BattleSnapshot` schema v2 (touches `combat/`, `Rpg.Contracts` and goldens).
Minimal clickable flow on placeholder (graybox) screens, proven on test fixtures.

> 🧭 After 1b, a system-design pass: plan what the run adds that the wire contracts and backend don't support yet
> (run seed and RNG streams, run log, item grants, purchases, out-of-battle actions, snapshot v2 on the server side),
> designed for slice 2b `run-authority` and folded into slices 2–9.

### 1c. `dev-tools`
**Purpose:** fast content iteration, built only for mechanics that exist: build a room and play it in seconds, jump to
any state, catch broken content at once.
Isaac-style console, 3D room editor with "Play this room", floor layout editor, seed runner / generation viewer,
content validator (runs as a test), short seed codes, room sizes and shapes.

### 1d. `playable-demo`
**Purpose:** a short run playable start to finish, to show people, and the first real test of the dev tools.
Grows 1b's example set (`content/demo/`, `presentation/demo/`) into the full demo, built with the 1c tools: coloured-cube units whose ability animations jump, spin or flash;
demo AttributeSet and tags made the GodotGAS way; a short run through battles, an event, a treasure room, a shop and a
boss. **Includes adjusting the dev tools** wherever building the demo exposes limits or wrong assumptions in them.

### 2. `battle-checkout`
Contracts DTOs; Postgres schema (players, `battle_sessions` with seed, snapshot, `ruleset_version`); `POST /battle/start`;
Redis cache (30-min TTL) with Postgres fallback (**scenario 4**); `ruleset_version` hash computation; Godot client HTTP
layer calls start and runs the battle locally.

### 2b. `run-authority`
**Purpose:** the server owns player state. Anything that changes it is an authenticated request; nothing is trusted
from the client alone.
- **Authentication** for every player-state endpoint (including `/battle/start` and `/battle/verify`): player identity
  on each request (bearer token; a dev token issuer until a real identity provider).
- **Server-issued run seed** at run start; the run's state lives in Postgres.
- **Two message styles:** battles stay **batched** (the whole action log is verified asynchronously, slice 3), while
  out-of-battle actions are **quick messages**: small, synchronous, authenticated commands (use an item or skill, take
  an item, buy in a shop, event choice) with an `Idempotency-Key` and a per-run sequence number so retries and
  reordering are safe. The server checks each one against the run's seeded state.
- Contracts come from the system-design pass after 1b. Placed after slice 2 because it needs the players table and
  Postgres from `battle-checkout`.

### 3. `battle-verify`
`POST /verify` + `Idempotency-Key` → RabbitMQ job → `202`. Headless Godot verifier worker container replays the log and
writes a verdict. `GET /battle/{id}/result`. Retries, DLQ, `lock:battle:{id}`.
**Scenario 1** (duplicate verify), **scenario 5** (tampered log → 2002).

### 4. `settlement-outbox`
Reward settlement + outbox row in one Postgres transaction, then ack; unique constraint makes redelivery a no-op.
Outbox relay → Redpanda. **Scenario 2** (killed before ack), **scenario 3** (Redpanda down).

> 🎨 Suggested design break 2, reward loop: payouts, post-battle results screen, progression pacing, more encounters.

### 5. `gacha`
`POST /gacha/pull`; pity counters and currency in Postgres; settlement via RabbitMQ; events through the outbox.
Spec must decide where gacha RNG lives (server-authoritative, separate from combat RNG) and say so explicitly.

> 🎨 Suggested design break 3, gacha feel: banners, rates, pity curve, pull animation, new pullable characters.

### 6. `observability`
End-to-end traces HTTP → RabbitMQ → worker → outbox → Redpanda. Metrics: verify latency, queue age,
`error_code="2002"` rejections, outbox lag. Grafana dashboards provisioned as code.

### 7. `live-dashboard`
SignalR hub pushing verdicts to client and browser. React/TS `web-dashboard` live feed: battles, gacha, anti-cheat alerts.

### 8. `load-and-chaos`
Locust profiles (`/stress`); scripted chaos runs for scenarios 2, 3, 4; **scenario 7** (spike → backpressure →
recovery in Grafana). This is the demo.

### 9. `ruleset-versioning` (later milestone)
Multiple verifier versions; jobs routed by `ruleset_version`. **Scenario 6** (ruleset changes while a battle is open).

> 🎨 Suggested design break 4, polish: UI, audio, balance pass. Safe to rebalance freely once slice 9 lands.
