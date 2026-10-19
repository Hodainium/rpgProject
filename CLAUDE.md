# Project: Turn-Based RPG Distributed System Demo (.NET 10 + Godot 4.7 + GodotGAS)

An HSR-style offline battle / server verification loop, used as a frontend and traffic generator for a
distributed backend. The enterprise-system mapping behind each component is in `README.md`.
Pitch: every battle is a versioned distributed workflow with transactional checkout, at-least-once replay
verification, exactly-once reward effects, outbox-based event publication and end-to-end observability.

## Current state (keep this section truthful)
| Path | Status |
|---|---|
| `client-godot/` | Godot 4.7.2 .NET project, GodotGAS v1.1.2 addon enabled. `rpgDemo.csproj` (`net10.0`, references `Rpg.Client`), no C# scripts. Empty ownership folders (`combat/`, `content/`, `presentation/`, `tests/fixtures/`). No scenes. |
| `Rpg.slnx` + `global.json` | Root solution (all projects below plus `rpgDemo.csproj`). .NET SDK 10.0.402; tests run on Microsoft.Testing.Platform. Package versions pinned in `Directory.Packages.props`. |
| `src/Rpg.Contracts/` | `ServerInfoResponse`, `RpgJson` (shared JSON options). No battle/gacha DTOs yet. |
| `src/Rpg.Client/` | `GameServerClient.GetInfoAsync` only. |
| `src/Rpg.GameServerApi/` | Skeleton only: `/api/v1/info`, `/health/live`, `/health/ready`, `/metrics` on port 5000. Connects to Postgres/Redis/RabbitMQ for readiness; **no tables, queues, topics or battle/gacha endpoints yet.** |
| `tests/` | `Rpg.Contracts.Tests` (golden JSON, purity guards), `Rpg.GameServerApi.Tests` (Testcontainers; **Docker required**). |
| `load-test/`, `web-dashboard/` | **Empty.** |
| `specs/design/` | Design intent (not slice specs). `combat-design.md`: attributes, tags, damage formula. Not yet built in GodotGAS. |
| `specs/roadmap.md` | **Build order: slices 0–9 and design breaks. Read it to know what's next; mark slices done there.** |
| `.gitattributes` | Root: LF everywhere (CRLF only for `.sln`/`.ps1`/`.cmd`/`.bat`), binaries marked. |
| `infra/docker-compose.yml` | Postgres, Redis, RabbitMQ, Redpanda; Prometheus + Grafana under the `observability` profile. |

Do not describe or code against components listed as empty as though they exist. Update this table when that changes.

## Planned components
- **`src/Rpg.GameServerApi`**: ASP.NET Core 10 REST API. `POST /api/v1/battle/start`, `POST /api/v1/battle/verify`,
  `GET /api/v1/battle/{id}/result`, `POST /api/v1/gacha/pull`.
- **`src/Rpg.Contracts`**: .NET 10 class library holding only the wire contracts: HTTP request/response `record` DTOs and
  queue/event message schemas. Referenced by the server and `Rpg.Client`.
  **No game logic of any kind:** no combat, no RNG, no stats or formulas.
- **`src/Rpg.Client`**: .NET 10 class library, the client's HTTP layer: a typed wrapper over `HttpClient` using
  `Rpg.Contracts` DTOs. Referenced by the Godot project. No Godot dependency, no game logic.
- **Verifier workers**: headless Godot 4.7.2 .NET containers running the `client-godot` project. They consume
  verification jobs from RabbitMQ.
- **PostgreSQL**: the source of truth for player state, inventory, currency, pity counters, battle sessions
  (seed + party snapshot + ruleset version), settlements and the outbox.
- **Redis**: a cache in front of Postgres battle sessions (30-min TTL) plus `lock:battle:{id}` / `lock:player:{id}`
  to suppress duplicate work. **Never the source of correctness.**
- **RabbitMQ**: work queues with acks, retries and DLQ, for verification jobs and reward/gacha settlement.
- **Redpanda**: append-only event log (verified battles, gacha outcomes, anti-cheat alerts), fed only by the outbox relay.
- **Prometheus/Grafana + OpenTelemetry .NET**: metrics and traces. **`web-dashboard`**: React/TS, with SignalR as the
  browser push gateway. **`load-test`**: Locust.

## Battle workflow decisions (2026-10-14)
- **Single combat implementation:** GodotGAS (GDScript) in `client-godot/` is the only combat logic. Never
  re-implement turn order, effects, tags, activation or RNG in C#. Combat must run headless, with no rendering or
  animation in the simulation path.
- **RNG:** Godot's `RandomNumberGenerator`, seeded with the server-issued seed. The client and the verifier must run the
  identical pinned Godot build (4.7.2 .NET). Known limitation: the client knows the seed, so it can simulate ahead.
  This is accepted for the offline-first model and documented as a tradeoff.
- **Checkout:** `/battle/start` writes the battle session (seed, party snapshot, `ruleset_version`) to Postgres, then caches it in Redis.
  If Redis misses, the server reads Postgres.
- **Verify is asynchronous:** `/battle/verify` takes an `Idempotency-Key`, publishes a job to RabbitMQ and returns
  `202 Accepted`. The verdict comes from `GET /battle/{id}/result` and is also pushed over SignalR.
- **Exactly-once effects:** the worker commits the settlement and the outbox row in one Postgres transaction, then acks
  RabbitMQ. A unique constraint on the battle/idempotency key turns redelivery into a no-op.
- **Outbox:** events reach Redpanda only through an outbox relay. Never publish directly from request or worker code.
- **Ruleset versioning:** `ruleset_version` (Godot build + content hash) is recorded at checkout and carried on every
  job and event. Only one verifier version runs for now; routing to the matching version is a later milestone.
- Still to be specified before battle code: the replay log schema, the state hash, and turn order and battle content.

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
3. Combat math policy: integers / basis points (`10000 = 100.00%`), seeded RNG only.
4. **GodotGAS resources are the single source of truth** for combat data: the tag registry, AttributeSets, effect `.tres` files and ExecCalcs.
   Tune values there. Specs describe intent and don't duplicate numbers that already live in Godot.

## Commits and design ownership
- Commit prefixes: `spec:` (specs/ADRs), `feat:`/`fix:` (system code), `design:` (the user's work in
  `client-godot/content/`, `presentation/`, `godot_gas/`), `chore:` (tooling/infra).
- The user's design folders are protected; see the ownership section in `client-godot/CLAUDE.md`. Never commit unless asked.
- Slice cycle: `/spec` → `/implement` → commit `feat:` → user tuning → commit `design:` → `/sync-spec` → commit `spec:`.

## Build & test
- Once a solution exists: `dotnet build` and `dotnet test` from the repo root must pass before touching Godot scenes.
- Infra: `cd infra && docker compose up -d` (add `--profile observability` for Prometheus/Grafana). Secrets in `infra/.env` (see `.env.example`).
