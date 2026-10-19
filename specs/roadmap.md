# Roadmap: slices and design breaks

Agreed 2026-10-14. This is the build order. Each slice gets its own `specs/<slice>.md` via `/spec` before any code.
Cycle per slice: `/spec` → `/implement` → commit `feat:` → `/sync-spec` → commit `spec:`.

## Where we are
| Slice | Status | Date |
|---|---|---|
| 0. `project-skeleton` | ✅ Done | 2026-10-19 |
| 1. `combat-replay-core` | ✅ Done | 2026-10-19 |
| 1b. `game-skeleton` | ⏭️ Next | |
| 1c. `dev-tools` | ⬜ Not started | |
| 1d. `items-and-loadouts` | ⬜ Not started | |
| 1e. `playable-demo` | ⬜ Not started | |
| 2. `battle-checkout` | ⬜ Not started | |
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
**Purpose:** a real run you can click through, where every room, floor and encounter comes from data in `content/`,
so making the game becomes filling in data files. GAS-first (`specs/design/game-design.md` section 2a).
Design in `specs/design/game-design.md`. Asset classes (rooms, chapters, scaling, floor-gen rules, run structure,
hand-made floor layouts, characters, enemies, loadouts, encounters, sample events). Seeded Isaac-style floor generator
with separate RNG streams and a run log. Run state. Minimal flow: menu → pick 1–4 characters → floor map → click a room →
battle (existing kernel, isolated) or sample event → boss → next floor. Basic 3D room scene. Generator determinism tests.
The spec says which parts are system code and which land in `content/`/`presentation/`.

### 1c. `dev-tools`
**Purpose:** fast content iteration: build a room and play it in seconds, jump to any state, catch broken content at once.
Isaac-style console, 3D room editor with "Play this room", floor layout editor, seed runner / generation viewer,
content validator (runs as a test).

### 1d. `items-and-loadouts`
**Purpose:** what makes each run different (the Isaac half). Also the slice that extends the battle wire contract.
Items (passive/active, pools, triggered passives), equipment, shops and treasure rooms, HP/MP carry-over into battles,
out-of-battle item and spell use, `BattleSnapshot` schema v2 (touches `combat/`, `Rpg.Contracts` and goldens).

### 1e. `playable-demo`
**Purpose:** a short run playable start to finish, to show people; slices 2–9 then plug into a real game.
Glue and polish so a short multi-floor run can be played start to finish with the user's content.

> 🧭 After 1b, a system-design pass: plan what the run adds that the wire contracts and backend don't support yet
> (run seed and RNG streams, run log, carried-over HP/MP, items, scaling and variants in the battle snapshot), and fold
> it into 1d and slices 2–9.

### 2. `battle-checkout`
Contracts DTOs; Postgres schema (players, `battle_sessions` with seed, snapshot, `ruleset_version`); `POST /battle/start`;
Redis cache (30-min TTL) with Postgres fallback (**scenario 4**); `ruleset_version` hash computation; Godot client HTTP
layer calls start and runs the battle locally.

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
