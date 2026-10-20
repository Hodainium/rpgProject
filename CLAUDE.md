# Project: Turn-Based RPG Distributed System Demo (.NET 10 + Godot 4.7 + GodotGAS)

A data-driven roguelike (Isaac-style floors and items × Honkai: Star Rail turn-based combat, built on GodotGAS) that
plays offline-first and submits battles and runs to a distributed .NET backend for verification, settlement,
player analytics and live monitoring. The game is the frontend and the traffic generator; the backend mirrors enterprise infrastructure.
Game design: `specs/design/game-design.md`. Enterprise mapping: `README.md`.
Pitch: every battle and every run is a versioned distributed workflow with server-issued floor seeds, an ordered idempotent
command log, at-least-once replay verification, exactly-once reward effects, outbox-based event publication, player
analytics, and end-to-end observability.

## Current state (keep this section truthful)
| Path | Status |
|---|---|
| `client-godot/` | Godot 4.7.2 .NET project, GodotGAS v1.1.2 addon and our editor plugin `addons/rpg_dev/` enabled, autoload `Dev` (console), main scene `game/game_main.tscn`. `rpgDemo.csproj` (`net10.0`, references `Rpg.Client`), no C# scripts. `content/` and `presentation/` hold the example set only: `content/demo/` (2 characters with ults and ult charge, 3 enemies, items, rooms, events, a one-floor run; made by `game/tools/build_demo.tscn`), `presentation/demo/` (scene-based screens, sound board, hit cue) and the RTP sound pack in `presentation/audio/rtp/`. `godot_gas/`: real tags (dashboard format, checked by `game/tools/sync_tags.tscn`), the generated `Unit` AttributeSet (snake_case), the hit cue in `cue_registry.tres`. |
| `client-godot/combat/` | Deterministic battle kernel (spec `combat-replay-core`): turn order, `CombatASC` effect timing, execution tables driven by animation `execute` keys, ×100 fixed-point, state hash v1, recorder, headless replay runner (`combat/headless/replay_main.tscn`). Proven on fixtures only. |
| `client-godot/game/` | Run layer (spec `game-skeleton`): content types in `defs/` (characters, enemies, items, equipment, loadouts, rooms, events, chapters, scaling, floor rules, run structure, layouts), seeded Isaac-style floor generator, `RunState`/`RunController` (map, battles with carry-over, events, pickups/shop, field actions, run hash), `GameMain` shell, `ViewGate`. Battle snapshot v2 (inventory capture, enemy loadouts/variants/scaling), triggered passives, death/revive and field mode live in `combat/`. Proven on fixtures. No server sync yet (slice 2b). |
| `client-godot/game/dev/` + `addons/rpg_dev/` | Dev tools (spec `dev-tools`), local mode only: console (backtick; command registry in `game/dev/commands/`, one file per command, throwaway ones in `user://dev_commands/`; play commands and logged cheats through GAS), sandbox (one room or layout), content validator, seed codes, seed runner (`game/dev/seed_runner.tscn`, headless `game/tools/seed_report.tscn`), dev content (`game/dev/content/`: kill/heal/revive effects, dev stat items). Editor plugin: "RPG Content" dock (create from template, validate, Play settings), room grid and Play buttons in the inspector. **Claude drives everything headless** with the script runner `game/tools/dev_run.tscn` (`--script`, JSON out) and `game/tools/validate_content.tscn`. |
| `client-godot/tests/` | In-house GDScript test runner (`run_tests.tscn`, 136 tests incl. the demo smoke test and the content validator over `content/`), frozen fixtures (combat + run world) and goldens in `tests/fixtures/` (`golden/game/` for floors, seeds, seed codes, sandbox, seed report, the scripted run), broken content for the validator in `tests/broken_fixtures/`. |
| `Rpg.slnx` + `global.json` | Root solution (all projects below plus `rpgDemo.csproj`). .NET SDK 10.0.402; tests run on Microsoft.Testing.Platform. Package versions pinned in `Directory.Packages.props`. |
| `src/Rpg.Contracts/` | `ServerInfoResponse`, `RpgJson`, and battle wire shapes in `Battle/` (`BattleSnapshot` v1/v2 with `PartyMemberSnapshot`, `UseSlotSnapshot`, `EnemySnapshot`; `ActionLog`, `ReplayRequest`, `ReplayResult`, `MismatchReason`). No run, inventory or gacha DTOs yet. |
| `src/Rpg.Client/` | `GameServerClient.GetInfoAsync` only. |
| `src/Rpg.GameServerApi/` | Skeleton only: `/api/v1/info`, `/health/live`, `/health/ready`, `/metrics` on port 5000. Connects to Postgres/Redis/RabbitMQ for readiness; **no tables, queues, topics or battle/gacha endpoints yet.** |
| `tests/` | `Rpg.Contracts.Tests` (golden JSON, purity guards, battle contracts cross-checked against the Godot golden files), `Rpg.GameServerApi.Tests` (Testcontainers; **Docker required**). |
| `load-test/`, `web-dashboard/` | **Empty.** |
| `specs/design/` | Design intent (not slice specs). `combat-design.md`: attributes, tags, damage formula. Not yet built in GodotGAS. `run-authority-decisions.md`: why runs work the way `server-authority.md` specifies (options rejected, accepted cheats). |
| `specs/roadmap.md` | **Build order: slices 0–9 and design breaks. Read it to know what's next; mark slices done there.** |
| `.gitattributes` | Root: LF everywhere (CRLF only for `.sln`/`.ps1`/`.cmd`/`.bat`), binaries marked. |
| `infra/docker-compose.yml` | Postgres, Redis, RabbitMQ, Redpanda; Prometheus + Grafana under the `observability` profile. |

Do not describe or code against components listed as empty as though they exist. Update this table when that changes.

## Planned components
- **`src/Rpg.GameServerApi`**: ASP.NET Core 10 REST API. Runs: `POST /api/v1/runs`,
  `POST /api/v1/runs/{id}/floors/{n}` (floor seed at the stairs), `POST /api/v1/runs/{id}/actions` (batched async
  quick messages; battles travel here), `POST /api/v1/runs/{id}/end`, `GET /api/v1/runs/current`,
  `GET /api/v1/runs/{id}/resume`, `GET /api/v1/runs/{id}/battles/{seq}` (session and, from slice 3, its verdict).
  Auth: `POST /api/v1/auth/dev-token` (development). Gacha: `POST /api/v1/gacha/pull`. Analytics read API for the
  dashboard (player behaviour aggregates). Spec for battles and runs: `specs/server-authority.md`.
- **`src/Rpg.Contracts`**: .NET 10 class library holding only the wire contracts: HTTP request/response `record` DTOs and
  queue/event message schemas. Referenced by the server and `Rpg.Client`.
  **No game logic of any kind:** no combat, no RNG, no stats or formulas.
- **`src/Rpg.Client`**: .NET 10 class library, the client's HTTP layer: a typed wrapper over `HttpClient` using
  `Rpg.Contracts` DTOs. Referenced by the Godot project. No Godot dependency, no game logic.
- **Verifier workers**: headless Godot 4.7.2 .NET containers running the `client-godot` project. They consume
  verification jobs from RabbitMQ.
- **PostgreSQL**: the source of truth for players, runs and their ordered action logs, run inventory, account
  inventory, currency, pity counters, battle sessions (seed + conditions + ruleset version), settlements, the outbox,
  and the analytics projections.
- **Redis**: a cache in front of Postgres battle sessions (30-min TTL) plus `lock:battle:{id}` / `lock:player:{id}`
  to suppress duplicate work; also live presence, per-player rate limiting, the floor read model, verdict cache, live
  analytics counters, leaderboards, the gacha banner cache and the SignalR backplane (slice placement: "Redis plan" in
  `specs/roadmap.md`). **Never the source of correctness:** every entry can be rebuilt from Postgres or the event log.
- **Run authority (2026-10-20):** the client gets one floor at a time (HMAC floor seed at the stairs) and plays it
  offline; every in-floor action is async and verified in parallel by headless Godot; the client stays within one
  floor of the last verified floor. Action policy table: "Run authority model" in `specs/roadmap.md`.
- **RabbitMQ**: work queues with acks, retries and DLQ, for verification jobs and reward/gacha settlement.
- **Redpanda**: append-only event log (runs, run actions such as item offers, pickups and purchases, verified
  battles, gacha outcomes, anti-cheat alerts), fed only by the outbox relay. Analytics consumers project it into
  Postgres tables for the dashboard.
- **Prometheus/Grafana + OpenTelemetry .NET**: operational metrics and traces (latency, queue age, rejections).
  **`web-dashboard`**: React/TS, with SignalR as the browser push gateway: live monitoring (players online, players
  in a battle, service health) **and** player analytics (most played characters and parties, most used moves, items
  picked up, event decisions, what each gacha banner earns). **`load-test`**: Locust.

## Battle workflow decisions (2026-10-14)
- **Single combat implementation:** GodotGAS (GDScript) in `client-godot/` is the only combat logic. Never
  re-implement turn order, effects, tags, activation or RNG in C#. Combat must run headless, with no rendering or
  animation in the simulation path.
- **RNG:** Godot's `RandomNumberGenerator`, seeded with the server-issued seed. The client and the verifier must run the
  identical pinned Godot build (4.7.2 .NET). Known limitation: the client knows the seed, so it can simulate ahead.
  This is accepted for the offline-first model and documented as a tradeoff.
- **No battle handshake (2026-10-20):** battle seeds come from the server-issued floor seed; a battle is uploaded
  in the run's action log (conditions + action log) and stored as a battle session in Postgres, cached in Redis.
  If Redis misses, the server reads Postgres.
- **Verify is asynchronous:** an uploaded battle becomes a job on RabbitMQ; the upload is acknowledged at once. The
  verdict is read from `GET /runs/{id}/battles/{seq}` and is also pushed over SignalR.
- **Exactly-once effects:** the worker commits the settlement and the outbox row in one Postgres transaction, then acks
  RabbitMQ. A unique constraint on the battle/idempotency key turns redelivery into a no-op.
- **Outbox:** events reach Redpanda only through an outbox relay. Never publish directly from request or worker code.
- **Ruleset versioning:** `ruleset_version` (Godot build + content hash) is recorded at run start and carried on every
  job and event. Only one verifier version runs for now; routing to the matching version is a later milestone.
- **Replay log, state hash and turn order are specified and built** (`specs/combat-replay-core.md`): HSR-style action
  value; party decisions only in the log, enemy turns re-simulated; checkpoint hash per party action; state hash v1;
  every rejection is 2002 with a `MismatchReason`. Real battle **content** is still to be designed (design break 1).

## Game and run decisions (2026-10-19)
- **Data-driven, GAS-first:** every mechanic is data (`content/`: characters, enemies, items, rooms, events,
  chapters, runs) on GodotGAS building blocks (abilities, effects, tags, AttributeSets, cues). New content never needs
  code. Design: `specs/design/game-design.md`; implementation: `specs/game-skeleton.md`.
- **Deterministic runs:** a run is a seed plus an ordered log of the player's choices; floor generation, pools, shops,
  drops and battles all draw from seeded streams, so a run can be replayed and verified like a battle.
- **Authority:** the server issues each floor's seed at the stairs (the client plays the floor offline), orders and
  stores the run's actions as authenticated, idempotent quick messages, and verifies battles and runs by replay in headless
  Godot. Game rules never run in C#. Rewards that leave the run are granted only after verification. The full map of
  what is server-authoritative, server-verified and client-only is section 0 of `specs/server-authority.md`.
- **Local mode:** with no server configured the game plays fully offline (seeds derived on the client, nothing sent,
  nothing rewarded). Dev tools and system tests use it.
- **Player analytics:** every player action is logged (runs and their quick messages, battle sessions and action
  logs). General behaviour metrics (most played characters and parties, most used moves, items picked up, event
  decisions, gacha banner earnings) are aggregated from that log: published through the outbox to Redpanda and
  projected into Postgres tables the dashboard reads, filterable to verified runs. Live counts (players online, in a
  battle) are Prometheus gauges. **Never use item, character, move or encounter ids as Prometheus labels** (unbounded
  cardinality). Design: `specs/design/game-design.md` section 10.

## Error contract
A replay mismatch is a **verdict**, not an HTTP status on `/verify`. `GET /battle/{id}/result` returns
`{ "status": "Rejected", "errorCode": 2002, "error": "ReplayMismatch", ... }`.
HTTP 4xx codes are only for malformed or unauthorized requests. Use code 2002 in specs, code, events and metric labels.

## Acceptance: failure scenarios
Each must have a spec and an automated test before the workflow counts as done:
1. Duplicate `/verify` with the same idempotency key → one settlement.
2. Worker killed after DB commit, before RabbitMQ ack → safe redelivery, no double reward.
3. Redpanda down during settlements → outbox drains with no lost events once it's back.
4. Redis flushed → falls back to the Postgres snapshot.
5. Tampered action log → deterministic rejection with code 2002.
6. Ruleset changed while a battle is open → verified against its original version (later milestone).
7. Load spike → queue age, backpressure and recovery visible in Grafana.

## Spec-Driven Development
1. Write or update a spec in `specs/<feature>.md` (use `/spec`) before implementing a feature.
2. Client↔server contracts are C# `record` DTOs in `src/Rpg.Contracts/`, defined before endpoint code.
3. Combat number policy: **every number a designer types is stored ×100 as a whole number** (up to 2 decimals:
   `500` → `50000`, `150`% → `15000`, `80.5` → `8050`), converted once at edit time. Combat uses only integer
   `+ − × ÷` (no `pow`/`sqrt`/etc.) and the seeded RNG. Details: `specs/combat-replay-core.md`, "Number format".
4. **GodotGAS resources are the single source of truth** for combat data: the tag registry, AttributeSets, effect `.tres` files and ExecCalcs.
   Tune values there. Specs describe intent and don't duplicate numbers that already live in Godot.

## Commits and design ownership
- Commit prefixes: `spec:` (specs/ADRs), `feat:`/`fix:` (system code), `design:` (the user's work in
  `client-godot/content/`, `presentation/`, `godot_gas/`), `chore:` (tooling/infra).
- The user's design folders are protected; see the ownership section in `client-godot/CLAUDE.md`. Never commit unless asked.
- Slice cycle: `/spec` → `/implement` → commit `feat:` → user tuning → commit `design:` → `/sync-spec` → commit `spec:`.

## Build & test
- `dotnet build` and `dotnet test` from the repo root must pass before touching Godot scenes.
- Godot system tests: `H:\Godot\Godot_v4.7.2-stable_mono_win64_console.exe --headless --path client-godot res://tests/run_tests.tscn`
  (details in `client-godot/CLAUDE.md` section 4). Both suites must pass for a slice to count as done.
- Infra: `cd infra && docker compose up -d` (add `--profile observability` for Prometheus/Grafana). Secrets in `infra/.env` (see `.env.example`).
