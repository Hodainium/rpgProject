# Spec: server-authority (slices 2 and 2b)

Status: Part A ✅ built 2026-10-27 (`2b363c3`), synced 2026-10-27 · Part B 📝 spec, decisions confirmed · Roadmap:
system-design pass after 1b → Part A = slice 2 `run-checkout`, Part B = slice 2b `run-authority` (built in that order)
· Date: 2026-10-19, revised 2026-10-20, synced 2026-10-27 (keys-and-gear, playable-demo 3.8/3.11, gameplay-messages,
export presets; then Part A's implementation)
Design intent: `specs/roadmap.md` "Run authority model" (the client action policy and the Redis plan live there);
`specs/design/game-design.md` sections 5 (seeds and the server) and 10 (player analytics and live monitoring); root
`CLAUDE.md` "Battle workflow decisions" and "Game and run decisions".

## 0. Authority map (read this first)
**The model in one paragraph:** the client gets one floor at a time and plays it offline. The server issues each
floor's seed at the stairs; everything on that floor (layout, rooms, loot, shops, events, battle seeds) comes from it.
Every action on the floor is applied locally at once, logged in order and uploaded when there's a connection. The
server orders and stores the log and (from slice 3 / 4a) has headless Godot verify it. Only a few things block: run
start and resume, the stairs, a won run's ending, and account actions (cards, currency).

| Bucket | Meaning | What's in it |
|---|---|---|
| **Server-authoritative** | The server decides. The client asks and uses the answer; it can't change it. | Player identity (B); the run id; **every floor seed** (HMAC, issued at the stairs: A); which floor the run may be on (A); the **order** of a run's actions and what has been accepted (sequence numbers, B); run status (active, verifying, won, lost, abandoned; B); the **ruleset version** a run started under (A); later: verdicts (3, 4a), rewards and currency (4, 5), cards, packs and market trades (5, 5b) |
| **Server-verified** | The client runs it locally (offline-first, instant); the server stores it and later re-runs it in headless Godot. A mismatch is a `Rejected` verdict with `errorCode` 2002, never an HTTP error. | Every in-floor action: entering rooms (and spending a key on a lock), event choices, giving items, pickups, purchases, opening chests, field use, equipping and swapping armor, moving items, battles (start conditions, turns, result), taking the stairs (floor generation); the claimed state **snapshots** at checkpoints; the run's end. Floor maps, item pools, shop stock, coin drops, HP/MP/ult charge and run inventory are all derived from the floor seeds and the logged actions |
| **Client-only** | Never trusted. | Animations, sounds, cues, camera, screen layout, Auto/Skip, menus, the map view, the content-root switch, dev tools and the console (disabled when connected), the **local save** (a cache of the server's log plus the not-yet-sent tail), the presence heartbeat (a hint for live monitoring, never used for decisions) |

**Why verified and not computed by the server:** the game rules (floor generation, pools, shops, events, combat)
exist only in GDScript, and the root `CLAUDE.md` forbids re-implementing them in C#. The server never runs game rules
on the request path. It issues seeds, orders and stores the log, enforces the gates, and hands replays to headless
Godot workers. Rewards that leave the run are applied only after verification, so a cheated run can't pay out.

**Accepted cheat:** a modded client sees the whole current floor (and every battle seed on it) and can play it
perfectly, or copy its local save to retry a battle before it uploads. Every action it sends is still legal, so
replay can't reject it. Once an action is accepted it can't be redone (409 `1103`). Statistical detection (slice 4b)
may flag it later.

**Local mode stays:** with no server configured, the game plays exactly as in slice 1b (run seed typed or derived on
the client, nothing sent, nothing rewarded). Dev tools and tests use it. The scripted-run golden must not change.

## 1. Purpose & enterprise mapping
- **Part A (slice 2, `run-checkout`): first hookup to the server.** The server starts runs and issues **floor seeds**:
  floor 0 at run start, each next floor at the stairs. Runs live in Postgres, with a Redis cache-aside read model in
  front (**scenario 4**). Also: the SQL migration runner, the `ruleset_version`, the dev player header, and the
  client's server adapter (the first C# in the Godot project) plus the client's **seed source** (local vs server).
  The client doesn't upload actions yet.
- **Part B (slice 2b, `run-authority`): auth, the action log, saves.** Bearer-token identity; every in-floor action
  is an **async quick message**: ordered, idempotent, uploaded in batches (queued while offline), with a claimed
  **state snapshot** at each checkpoint. Battles arrive as actions and become **battle sessions**. The stairs gate
  checks the log is fully uploaded; a won run ends **blocking**. **Local saves**, and resume **without** a save
  (rebuild from the server's log). **Live presence** and **per-player rate limiting** in Redis. The log is also the
  record of every player action that the analytics dashboard (4b) aggregates later.

| Component | Part A | Part B | How |
|---|---|---|---|
| `Rpg.Contracts` | ✅ | ✅ | Run, floor, action, battle session, resume, presence and auth records; API error codes |
| `Rpg.GameServerApi` | ✅ | ✅ | Endpoints, migration runner, run store, floor seeds (HMAC), action log, gates, JWT auth |
| PostgreSQL | ✅ | ✅ | Source of truth: `players`, `runs`, `run_floors` (A); `run_actions`, `battle_sessions` (B) |
| Redis | ✅ | ✅ | A: run summary cache (**scenario 4**). B: battle session cache, presence sorted sets, rate-limit buckets. Never the source of correctness |
| RabbitMQ, Redpanda, outbox | ❌ | ❌ | N/A: verification (3, 4a), settlement and events (4) |
| `Rpg.Client` | ✅ | ✅ | Typed calls for every endpoint |
| `client-godot` | ✅ | ✅ | C# `ServerBridge` (the one adapter), GDScript `ServerLink`, `SeedSource`; B: `RunSnapshot`, action queue, local save, resume |

**Enterprise mapping:** an *offline-first edge with server reconciliation*. Like a mobile banking app or a field-sales
app: the device works offline against data it was issued (the floor), records every operation in an ordered,
idempotent journal, syncs in batches when it can, and the back office reconciles the journal and only then books
anything of value. Postgres is the system of record (an event-sourced log per run); Redis holds read models and
counters that can be flushed at any time. The gates are a *bounded-staleness* contract: the edge may only drift so
far from what the server has confirmed.

## 2. Sequence flow

### 2.1 Run start and the stairs (Part A)
```
Godot client                                   Rpg.GameServerApi                          Postgres / Redis
menu → ServerLink.start_run(structure, characters) ─▶ POST /api/v1/runs
                                                 check ruleset_version (409 1001)
                                                 one transaction: upsert players row, SELECT … FOR UPDATE on it
                                                   (two starts by one player serialize; the index never decides)
                                                   the player's run Verifying → 409 1101, nothing written
                                                   the player's run Active → UPDATE status Abandoned, ended_at
                                                   runId = uuid v7; floorSeed(0) = HMAC(secret, runId, 0)
                                                   INSERT runs, run_floors(0)  ────────────────────▶ Postgres (commit)
                                                 DEL run:current:{playerId}, run:summary:{abandoned} (best effort) ▶ Redis
  ◀── 201 {runId, floor 0, floorSeed}
RunController.start_server_run(…, runId, floorSeed)   the client builds floor 0 from its seed and plays it offline
… floor played offline …
next_floor → floor_seed_needed(1) → ServerLink (retried while offline) ─▶ POST /api/v1/runs/{runId}/floors/1
                                                 one transaction: SELECT runs … FOR UPDATE
                                                   floor == current_floor     → 200, same seed (a retry)
                                                   floor == current_floor + 1 → (B: afterSeq == last_seq, else 409 1106)
                                                                                 (4a: floor − 2 verified, else 409 1107)
                                                                                 INSERT run_floors; UPDATE current_floor
                                                   otherwise                  → 409 1105
                                                 issued: DEL run:summary:{runId} (best effort) ───▶ Redis
  ◀── 200 {floor 1, floorSeed}                   (hidden behind the floor transition; "Connecting…" while offline)
RunController.provide_floor_seed(1, seed)        the client generates floor 1 and plays it offline
```
**The rest stop (spec playable-demo 3.11):** `next_floor` opens the run's rest event first. The next floor starts
when the rest event ends. The client asks for the seed at `next_floor`, so the rest stop hides the latency.
`AfterSeq` is the `next_floor` action's own seq. Choices made at the rest stop are logged with the floor being left.
`GET /api/v1/runs/{runId}` and `GET /api/v1/runs/current` read `run:summary:{runId}` from Redis, then Postgres on a
miss (and re-cache).

### 2.2 The action log (Part B)
```
any in-floor action (enter_room, choose, give_to, take, buy, open_chest, field, equip, unequip, swap_gear,
                     move_item, battle, next_floor):
  RunController applies it locally, appends to run_log and the local save, queues it
  ServerLink, whenever online: POST /api/v1/runs/{runId}/actions {actions: [seq a … seq b]}   (Bearer)
                                                 one transaction: SELECT runs … FOR UPDATE
                                                   not owner → 404 · not Active → 409 1101
                                                   for each action in order:
                                                     seq ≤ last_seq: same body → skip (a retry), else 409 1103
                                                     seq > last_seq + 1 → 409 1102 {expectedSeq}
                                                     checkpoint action without a snapshot → 400
                                                     INSERT run_actions (+ battle_sessions for a battle)
                                                   UPDATE runs.last_seq
                                                 DEL run:summary:{runId}; ZADD presence:online
  ◀── 200 RunActionAck {lastSeq}                 the queue drops everything ≤ lastSeq
```
**Batches:** the client sends everything queued, up to 50 actions per request, in seq order, one request at a time.
A player coming back online after a floor uploads it in a few requests, not 60 round trips. A batch is all-or-nothing;
a retried batch is a no-op for the seqs already stored.

**Checkpoints:** the client attaches a `RunSnapshot` (3.5, the full run state *after* the action) to: `start_run`
(seq 1), every action that leaves a battle pending, every `battle`, and every `next_floor`. Those cut the log into
**steps**: segments of out-of-battle actions, and single battles. Each step starts from a claimed snapshot, so
slice 4a can verify all of a floor's steps in parallel and then check the links (each step's start hash = the
previous step's verified end hash). Part B only stores them.

**Battles:** a `battle` action carries the conditions it was played under (the v2 `BattleSnapshot`, seed included,
which the client derived from the floor seed), the action log, the outcome and the final hash. The server writes a
`battle_sessions` row in the same transaction. Slice 3 verifies the battle against those conditions; slice 4a checks
the conditions are what the run state at that point produces.

### 2.3 Ending a run (Part B)
```
death: the defeat screen shows at once; `end {Lost}` is queued like any action → status Lost
win:   RunController reaches the end → "Verifying run…" (blocking)
       ServerLink waits for the queue to drain, then POST /api/v1/runs/{runId}/end {seq, Won, runHash, snapshot}
                                                 seq must be last_seq + 1 (else 409 1106 {lastSeq})
                                                 status → Verifying; 202 {status Verifying}
       client polls GET /api/v1/runs/{runId} every 2 s (SignalR replaces polling in slice 7)
         Won      → victory screen (rewards settle in slice 4/4a, in the same step)
         Rejected → rollback to the last valid checkpoint (4a); never a victory
```
**Until slice 4a exists** nothing verifies runs, so a Development-only setting `Run:AutoApproveWins` turns
`Verifying` into `Won` at once. With it off, a won run waits at "Verifying run…". 4a removes the setting.

### 2.4 Saves and resume (Part B)
```
local save: user://saves/run.json, rewritten after every action: {runId, floorSeeds, snapshot (after the latest
            action), unsent queue, lastAckedSeq}. A convenience copy; the server's accepted log always wins.
app start, signed in → GET /api/v1/runs/current → none: menu · Active: resume
  with a matching save (same runId, save's seq ≥ server lastSeq): load the snapshot, keep playing, upload the queue.
    If the upload hits 409 1103 (the server accepted different actions: another device, an old save restored),
    the save is discarded and the client resumes without it.
  without a save (or a discarded one): GET /api/v1/runs/{runId}/resume
            ◀── {floorSeeds, the latest checkpoint snapshot ≤ lastSeq, the accepted actions after it}
            the client loads the snapshot and replays the tail locally (same code as play; deterministic),
            then continues. Anything never uploaded from the lost device is gone.
offline at app start with a save: play continues from the save; everything syncs later.
```
The server never needs game rules to restore a run: the run is a seed set plus an ordered log, and the client
rebuilds the state by replaying it. In 2b the checkpoint is the latest *claimed* snapshot; 4a switches to the latest
*verified* one.

## 3. Data contracts

### 3.1 C# records (`src/Rpg.Contracts/`, JSON camelCase via `RpgJson`)
```csharp
namespace Rpg.Contracts.Runs;

// Part A
public sealed record RunStartRequest(string RulesetVersion, string RunStructureId, IReadOnlyList<string> CharacterIds);
/// 201. Floor is 0; FloorSeed is a decimal string (int64 isn't safe as a JSON number in browsers).
public sealed record RunStartResponse(string RunId, int Floor, string FloorSeed, DateTimeOffset StartedAt);

/// POST /api/v1/runs/{runId}/floors/{floor}. AfterSeq (Part B): the client's last seq on the floor it's leaving.
public sealed record FloorSeedRequest(int? AfterSeq = null);
public sealed record FloorSeedResponse(string RunId, int Floor, string FloorSeed);

public sealed record RunSummaryResponse(string RunId, RunStatus Status, int CurrentFloor, int LastSeq,
    string RulesetVersion, DateTimeOffset StartedAt, DateTimeOffset? EndedAt);
public enum RunStatus { Active, Verifying, Won, Lost, Abandoned, Rejected }   // Rejected: slice 4a

// Part B
/// POST /api/v1/runs/{runId}/actions. 1–50 actions with consecutive seqs.
public sealed record RunActionBatch(IReadOnlyList<RunActionRequest> Actions);

/// One run_log entry. StateHash = RunState.run_hash() after the action. Snapshot: the RunSnapshot JSON after the
/// action, required on checkpoint actions (2.2). PlayedAt: the client's clock, for analytics and upload lag only.
public sealed record RunActionRequest(int Seq, RunAction Action, string StateHash, DateTimeOffset PlayedAt,
    JsonElement? Snapshot = null);

public sealed record RunAction(string Type, int Floor, int? Cell = null, int? Page = null, int? Choice = null,
    int? Placement = null, int? Slot = null, string? Ability = null, int? Target = null,
    string? ItemId = null,                        // take / buy / field / give_to / move_item: the item involved (take / buy: or the armor piece)
    ItemKind? Kind = null,                        // take / buy: Equipment for armor (armor inventory), Keys for keys
    string? CharacterId = null,                   // take / buy: who received it (never for armor or keys); field: who acted
    string? EquipmentId = null,                   // equip / swap_gear: the piece put on
    string? EquipmentSlot = null,                 // unequip: the slot tag emptied (Equipment.Slot.<X>)
    int? FromSlot = null, int? ToSlot = null,     // swap_gear: the member who wore it (FromSlot); move_item: giver Slot → ToSlot
    string? SwapItemId = null,                    // move_item: the item sent back the other way, if any
    string? ChestId = null, int? Serial = null,   // open_chest: the chest and its serial (spec keys-and-gear)
    string? Unlock = null,                        // enter_room: "key" or "golden" when a lock opened
    string? Chapter = null,                       // next_floor: the chapter picked on a CHOICE slot (playable-demo 3.8)
    int? Price = null,                            // buy: coins paid
    string? PriceItemId = null,                   // buy: the curse item paid with, if any (RoomPlacement.price_item)
    int? CoinsAfter = null,                       // every action: the run's coins afterwards
    IReadOnlyList<ItemOffer>? Offers = null,      // enter_room: every pickup on offer in that room
    BattleSubmission? Battle = null);             // battle: what was played

public sealed record BattleSubmission(string BattleId, BattleSnapshot Conditions, ActionLog ActionLog);

/// One pickup on offer when a room is entered (analytics: what players are shown and what they pick up).
public sealed record ItemOffer(int Placement, string ItemId, int Price, OfferSource Source,
    ItemKind Kind = ItemKind.Item);
public enum OfferSource { Treasure, Shop, BossReward, Other }
public enum ItemKind { Item, Equipment, Keys }    // item-pass: pedestals and shelves offer armor; keys-and-gear: shops sell keys

public sealed record RunActionAck(int LastSeq);

/// POST /api/v1/runs/{runId}/end. Seq is the end's own seq (last_seq + 1). Lost also travels as a queued action.
public sealed record RunEndRequest(int Seq, RunEndStatus Status, string RunHash, JsonElement Snapshot);
public enum RunEndStatus { Won, Lost }
public sealed record RunEndResponse(string RunId, RunStatus Status);

/// GET /api/v1/runs/{runId}/resume.
public sealed record RunResumeResponse(string RunId, RunStatus Status, IReadOnlyList<FloorSeedResponse> FloorSeeds,
    int CheckpointSeq, JsonElement Snapshot, IReadOnlyList<RunActionRequest> Tail);

namespace Rpg.Contracts.Battle;   // Part B

/// GET /api/v1/runs/{runId}/battles/{seq}.
public sealed record BattleSessionResponse(string BattleId, string RunId, int RunSeq, BattleSnapshot Conditions,
    ActionLog ActionLog, string RulesetVersion, BattleSessionStatus Status, DateTimeOffset SubmittedAt);
public enum BattleSessionStatus { Submitted }   // slice 3 adds Verified, Rejected

namespace Rpg.Contracts.Presence;   // Part B

public sealed record PresenceRequest(PresenceActivity Activity);
public enum PresenceActivity { Menu, Map, Battle }

namespace Rpg.Contracts.Auth;   // Part B

public sealed record DevTokenRequest(string PlayerName);
public sealed record DevTokenResponse(string AccessToken, DateTimeOffset ExpiresAt, string PlayerId);

namespace Rpg.Contracts.Api.V1;

/// Error codes carried as `errorCode` in ProblemDetails (HTTP 4xx). 2002 stays the replay verdict only.
public static class ApiErrors
{
    public const int RulesetMismatch = 1001;          // 409: the client's ruleset_version isn't accepted
    public const int RunNotActive = 1101;             // 409
    public const int SequenceGap = 1102;              // 409, extension `expectedSeq`
    public const int SequenceConflict = 1103;         // 409: same seq, different body
    public const int FloorNotReachable = 1105;        // 409: not the current floor or the next one
    public const int UploadIncomplete = 1106;         // 409, extension `lastSeq`: stairs or end before the log is in
    public const int PreviousFloorUnverified = 1107;  // 409 + Retry-After (slice 4a)
    public const int RateLimited = 1201;              // 429 + Retry-After
}

/// Part A's development identity header (built 2026-10-27; Part B removes it).
public static class ApiHeaders { public const string DevPlayer = "X-Dev-Player"; }
```
**Snapshots are opaque to the server.** `RunSnapshot` (3.5) is owned by GDScript and changes with the game; the
server stores it as `jsonb`, checks only that it's a JSON object with `schemaVersion` 1, and hands it back on resume
and to the verifier. No game-state record in `Rpg.Contracts` (it would duplicate `RunState` in C#).

**Analytics capture:** the item, character, price, coin, offer and `PlayedAt` fields exist so slice 4b can count
general behaviour from the stored log without re-running the game. They are claims like the rest of the action:
stored as sent, checked by replay, flagged unverified until then. `run_actions.action` keeps them in `jsonb`.

`Type` values: `start_run` (seq 1, client-sent, carries the first snapshot), `enter_room`, `choose`, `take`, `buy`,
`field`, `equip`, `unequip` (armor, spec item-pass: map only, `Slot` = the party member; async and server-verified
like `field`), `give_to` (spec event-items: who gets an item from an event or a chest; `Item`, `Slot`; refused
unless that item is the next one waiting), `open_chest`, `swap_gear`, `move_item` (spec keys-and-gear: map only,
async and server-verified), `battle`, `next_floor`, `end` (Lost only; Won uses the end endpoint). The local log's
`dev` (console cheats) and `sandbox` entries are local mode only and never sent: server mode has no dev tools. A
`field` entry's `resultHash` is not sent; `StateHash` covers it. All new records get golden JSON tests.

### 3.2 Endpoints
| Endpoint | Part | Auth | Success | Errors |
|---|---|---|---|---|
| `POST /api/v1/runs` | A | A: `X-Dev-Player` · B: Bearer | 201 | 400, 401, 409 1001/1101 (a run is Verifying), 429 (B), 503 |
| `POST /api/v1/runs/{runId}/floors/{floor}` | A | as above | 200 | 400, 401, 404, 409 1101/1105, (B) 1106, (4a) 1107, 503 |
| `GET /api/v1/runs/current` | A | as above | 200 / 204 none | 400, 401, 503 |
| `GET /api/v1/runs/{runId}` | A | as above | 200 | 400, 401, 404 (also for another player's run), 503 |
| `POST /api/v1/auth/dev-token` | B | none; **only when `Auth:DevTokens` is enabled** | 200 | 400, 404 when disabled |
| `POST /api/v1/runs/{runId}/actions` | B | Bearer | 200 | 400, 401, 404, 409 1101/1102/1103, 429 |
| `POST /api/v1/runs/{runId}/end` | B | Bearer | 202 Won (Verifying) / 200 Lost | 400, 401, 404, 409 1101/1102/1106 |
| `GET /api/v1/runs/{runId}/resume` | B | Bearer | 200 | 401, 404, 409 1101 |
| `GET /api/v1/runs/{runId}/battles/{seq}` | B | Bearer | 200 | 401, 404 |
| `POST /api/v1/presence` | B | Bearer | 204 | 400, 401 |

Part A identifies the player with an `X-Dev-Player` header (development only; `ApiHeaders.DevPlayer`). It carries a
player **name** (1–64 letters, digits, `-`, `_`, `.`); the player id is derived from it (the first 16 bytes of
SHA-256 over `"rpg-dev-player|" + name`, as a version-8 uuid), so the same name is always the same player, and the
`players` row (display name = the name) is created on the first run start. A missing header is 401, a bad name 400;
outside Development the header is ignored and every run endpoint is 401. A run id in the path that isn't a uuid is a
routing 404. The floor request's body is optional in Part A (`AfterSeq` is read from Part B on). Postgres unreachable
is 503 ProblemDetails on any endpoint. Part B replaces the header with the token's `sub` everywhere and removes it. Idempotency: run start is not idempotent (a
second start abandons the first, by design); floor seeds are idempotent by `(runId, floor)`; actions by
`(runId, seq)` with body comparison. No `Idempotency-Key` header is needed on these; slice 3's `/battle/verify`-style
job submission and slices 5 and 5b (cards, market) keep it.

### 3.3 Floor seeds
`floorSeed = int63(HMAC-SHA256(key = Seeds:Secret, message = "floor-seed-v1|{runId}|{floor}"))`: the first 8 bytes
big-endian with the top bit cleared. The same `(runId, floor)` always gives the same seed, so a retried stairs
request needs no extra state. The seed is also stored in `run_floors`, so verifier jobs get it from Postgres and
workers never hold the secret; rotating the secret never changes an issued seed. Generated in C# (it's an id, like a
uuid, not a game rule). The key is the secret's UTF-8 bytes; `{runId}` is the lowercase `D` format (run ids are uuid
v7). `Seeds:Secret` is required at startup (at least 32 characters, else the server refuses to start): in development
from `dotnet user-secrets`, elsewhere from the environment (`Seeds__Secret`); the server never reads `infra/.env`.

### 3.4 PostgreSQL (plain SQL migrations, applied at startup)
A small runner (`Migrations/MigrationRunner.cs`) applies the `Migrations/NNNN_name.sql` files (embedded resources, in
name order): every pending file in **one** transaction under `pg_advisory_xact_lock`, recorded in `schema_migrations`,
so two instances never migrate at once (the second waits, then finds nothing to do). The server must start while
Postgres is down, so it migrates in the background at startup (retried every 5 s) and again, once per process, before
the first query. No ORM (Npgsql only).
```sql
-- Part A (0001)
CREATE TABLE players (player_id uuid PRIMARY KEY, display_name text NOT NULL, created_at timestamptz NOT NULL);
CREATE TABLE runs (
  run_id uuid PRIMARY KEY, player_id uuid NOT NULL REFERENCES players,
  ruleset_version text NOT NULL, run_structure_id text NOT NULL, character_ids text[] NOT NULL,
  status text NOT NULL, current_floor int NOT NULL DEFAULT 0, last_seq int NOT NULL DEFAULT 0,
  claimed_run_hash text, started_at timestamptz NOT NULL, ended_at timestamptz);
CREATE UNIQUE INDEX one_active_run ON runs (player_id) WHERE status IN ('Active', 'Verifying');
CREATE TABLE run_floors (
  run_id uuid NOT NULL REFERENCES runs, floor int NOT NULL, floor_seed bigint NOT NULL CHECK (floor_seed >= 0),
  issued_at timestamptz NOT NULL, PRIMARY KEY (run_id, floor));
-- Part B (0002)
CREATE TABLE run_actions (
  run_id uuid NOT NULL REFERENCES runs, seq int NOT NULL, floor int NOT NULL, type text NOT NULL,
  action jsonb NOT NULL, state_hash text NOT NULL, snapshot jsonb,        -- snapshot: checkpoint actions only
  played_at timestamptz NOT NULL, received_at timestamptz NOT NULL, PRIMARY KEY (run_id, seq));
CREATE INDEX run_actions_checkpoints ON run_actions (run_id, seq) WHERE snapshot IS NOT NULL;
CREATE TABLE battle_sessions (
  battle_id text PRIMARY KEY, run_id uuid NOT NULL, run_seq int NOT NULL,
  seed bigint NOT NULL CHECK (seed >= 0), ruleset_version text NOT NULL,
  conditions jsonb NOT NULL, action_log jsonb NOT NULL,   -- as played; verified in slice 3
  status text NOT NULL, submitted_at timestamptz NOT NULL,
  UNIQUE (run_id, run_seq), FOREIGN KEY (run_id, run_seq) REFERENCES run_actions);
```
Battle ids are the client's deterministic ids (`{runId}/f{floor}/c{cell}{label}`), so a re-uploaded battle maps to
the same row. The seed column is parsed from the conditions for indexing and the verifier.

### 3.5 Client: seed source, run snapshot, ruleset version
- **Seed source (Part A).** Every per-floor stream already uses the label `floor/{N}/…` under the run seed. A small
  `SeedSource` replaces direct `RunSeeds.rng(state.run_seed, "floor/%d/x" % n)` calls with
  `seeds.floor_rng(n, "x")` (and `floor_derive` for battle and field seeds). Local mode:
  `RunSeeds.rng(run_seed, "floor/%d/x" % n)`, exactly today's labels, so every golden stays byte-identical. Server
  mode: `RunSeeds.rng(floor_seed[n], "x")`. Built as `game/seed_source.gd` (`floor_rng`, `floor_derive`, `run_rng`,
  `has_floor`, `server_mode`); `RunState.floor_seeds` (floor → issued seed, empty in local mode) and
  `RunState.seeds()` give the run's source. `FloorGenerator` and `FloorSlot.pick_chapter` take it as an optional last
  argument (null: local mode from the `run_seed` they still take, so tools and tests that generate floors are
  unchanged). `RunState.canonical_lines()` adds `floor_seed=<current floor's seed>` right after `seed=` in server mode
  only; local mode is unchanged (every golden still matches). In server mode `run_seed` is 0 and `run_id` is the
  server's. The dev-only streams (`dev/<k>`, the sandbox) stay on `run_seed`.
  **Run-wide streams.** Two streams aren't per floor: `chapter/<id>/bosses` (boss rotation, playable-demo 3.8) and
  `chest/<serial>` (a chest gives the same contents on any floor, keys-and-gear). They go through
  `seeds.run_rng(label)`: local mode uses `RunSeeds.rng(run_seed, label)` (today's labels), server mode uses
  `RunSeeds.rng(floor_seed[0], "run/" + label)`. A modded client therefore knows every chapter's boss order and
  every chest's contents from run start. That falls under the accepted cheat (section 0).
- **RunSnapshot v1 (Part B).** `RunState.to_snapshot()` / `RunState.from_snapshot()` plus the controller's pending
  battle and event directive: everything needed to continue a run, as a JSON dictionary with `schemaVersion: 1`.
  That includes the armor inventory (`RunState.armor`), keys, the golden key, held chests and the chest serial,
  opened rooms, XP and levels, pending gifts with the event's `after` step (event-items), and a pending rest stop
  (`rest_to`).
  Requirements: (1) round trip: `from_snapshot(to_snapshot(s)).run_hash() == s.run_hash()`; (2) **resume
  equivalence**: a scripted run stopped at any checkpoint, saved, loaded and finished reaches the same final run hash
  as the uninterrupted run. That second property is what makes local saves, resume without a save, and 4a's parallel
  step verification correct; it's a golden test. No RNG positions are needed: every stream is derived fresh from a
  seed and a label.
- **Ruleset version (Part A).** `<godot version>+<first 16 hex of SHA-256>` over the sorted paths and **source**
  bytes of `res://combat/`, `res://game/`, `res://content/`, `res://godot_gas/` and the GodotGAS addon, minus the
  dev-only and tool paths the player preset excludes (`export_presets.cfg`). Those paths never affect rules. An
  exported pack can't recompute it: scripts ship as binary tokens, text resources ship converted to binary, and
  presets exclude different files. So it is **computed at export time**: `tools/export.sh` writes it into the pack,
  and `game/ruleset_version.gd` reads it there. The editor and headless runs from the project compute it live with the
  same rules, and `game/tools/print_ruleset_version.tscn` prints it for deployment. Every preset of one source tree,
  and the verifier, get the same version. Built details: each file is hashed as its path, a NUL, its length (8 bytes)
  and its bytes; `.uid`/`.import` side files and the stamp itself are skipped; the exclusions are the
  `exclude_filter` of the preset named "Windows Desktop"; the version reads `4.7.2.stable.mono+…` (`.mono` when the
  `CSharpScript` class exists). The stamp is `res://game/ruleset_stamp.tres` (a `RulesetStamp` resource, gitignored,
  removed by `export.sh` after the export); `RulesetVersion.current()` reads it when `OS.has_feature("template")`,
  else computes. `print_ruleset_version.tscn -- --stamp` writes it, `-- --files` lists the hashed files. The server accepts
  `Ruleset:Accepted`; `Ruleset:AcceptAny = true` (Development only) accepts and records anything. Every run stores
  the version it started under (groundwork for **scenario 6**).

### 3.6 Redis
| Key | Part | Value | TTL | Semantics |
|---|---|---|---|---|
| `run:summary:{runId}` | A | `{playerId, summary}`: the `RunSummaryResponse` and its owner (decided 2026-10-27), so another player gets a 404 straight from Redis | 30 min | Cache-aside for `GET /runs/{id}` and `/runs/current` (via `run:current:{playerId}` → runId, same rules; a cached current id is used only while that run is still Active or Verifying, and "no current run" is never cached). Every write commits to Postgres first, then **deletes** the keys (never sets them from the write path, so a slow writer can't leave a stale copy); reads re-fill them. Any Redis error (incl. not connected yet) → counted, then Postgres. **Scenario 4.** |
| `battle:session:{runId}:{seq}` | B | `BattleSessionResponse` JSON | 30 min | Same cache-aside rules; the verifier (slice 3) reads it first. |
| `presence:online`, `presence:battle` | B | sorted sets, member playerId, score = last seen (unix s) | none (trimmed) | `ZADD` on every authenticated request and heartbeat; the heartbeat also adds/removes `presence:battle`. Gauges: `ZCOUNT` over the last 5 min (online) / 2 min (in battle); a 30 s job trims with `ZREMRANGEBYSCORE`. |
| `ratelimit:{playerId}:{bucket}` | B | hash {tokens, updatedAt} | 10 min idle | Token bucket in one Lua script (atomic refill + take). Buckets: `actions` (requests, not actions per batch), `runs` (run starts), `floors`. Limits in `RateLimit:*`. Over the limit → 429 `1201` + `Retry-After`. |
**Redis down:** reads fall back to Postgres; presence gauges stop updating (marked stale, not zero); the rate limiter
**fails open** (requests pass, `rpg_cache_errors_total{operation="ratelimit"}` counts it). Correctness never depends
on Redis: ordering and idempotency come from the run row lock and primary keys.

### 3.7 Godot side
- **`client-godot/net/ServerBridge.cs`** (C#, the one adapter): wraps `Rpg.Client`. `Configure(baseUrl, devPlayer,
  timeoutSeconds)`, then methods that take and return whole records as JSON strings (A: `StartRun(requestJson)`,
  `GetFloorSeed(runId, floor, requestJson)`, `GetRun(runId)`, `GetCurrentRun()`; B adds `SendActions`, `EndRun`,
  `Resume`, `GetBattle`, `Heartbeat`, `GetDevToken`), each returning a request id at once and completing through one
  signal, `Completed(requestId, ok, json)` (C# keeps PascalCase names), on the main thread. ok: the response record
  (`null` for a 204); not ok: `{status (0 = no answer), errorCode, title, detail, retryAfterSeconds}`. No game logic,
  no retries. Loaded only in server mode, so local mode and the tests never need the assembly.
- **`game/server_link.gd`** (GDScript): `await`-able wrappers resolving to `{ok, data, error}`. Server mode is
  `GameMain.server != null` (no `connected` flag): `ServerLink.from_settings()` links when the Settings section
  `server` names a `url` (with `player`), never on its own in a headless run; `ServerLink.create(url, player)` writes
  no Settings (the e2e harness links that way); `GameMain.use_server(link)`. A: `link(run, runId)` answers the run's
  `floor_seed_needed` with `floor_seed_until_issued`: backoff from 1 s doubling to 30 s with ±25% jitter (a
  `Retry-After` wins) on no answer, 5xx and 429; any 4xx calls `RunController.stop_on_server_error` (a stop through
  `stopped(error)`, not a loss). `GameMain.start_run` in server mode returns "" at once, asks the server
  (`RulesetVersion.current()`), and starts the run when it answers ("Connecting…" meanwhile, a refusal as a
  Notification). The console's `server [<url> [player] | off | ruleset | check]` drives it (spec dev-tools); cheats
  are refused on server runs. B: the action queue (persisted in the local save; batches of
  up to 50; one request in flight; exponential backoff with jitter on network errors and 5xx; honours
  `Retry-After` on 429; a 409 `1103` discards the save and triggers resume without it; any other 409 stops the run
  through `RunController.stopped(error)`, like a runner error, not a loss), the heartbeat (every 30 s and on Menu/Map/Battle changes),
  and `user://saves/run.json`.
- **`game/seed_source.gd`** (A) and **`game/run_snapshot.gd`** (B) as in 3.5.
- **`RunController`** stays synchronous (A, built): `start_server_run(content, characters, runId, floorSeed,
  structure)` opens the run the server started (`allow_dev = false`; the start log entry carries `runId` and
  `floorSeed` instead of `seed`). `next_floor` emits `floor_seed_needed(n)` once per floor (the rest stop hides the
  wait, 2.1); `enter_floor` of a floor without its seed waits (`waiting_for_floor()`, every action refused meanwhile,
  "Connecting…" as a `Message.Notification` on the `GameplayMessages` bus) until `provide_floor_seed(n, seed)`, which
  ignores a repeat. `stop_on_server_error(text)` stops the run like a runner error. B: every `run_log` append also
  goes to the queue (B), with the snapshot on checkpoint actions and the battle conditions on `battle` entries (the
  conditions travel only in the queued message, not in `run_log`, so the local golden doesn't change). A won run
  emits a new `run_verifying` signal and only emits `run_ended("won")` after the server says Won.
- **Presentation:** no change is required (the message line already shows `Message.Notification`, which carries
  "Connecting…" and "Verifying run…"). A dedicated verifying screen or a "Server: on/off" menu line only if you ask; those are your folders.

## 4. Failure modes
| Case | Behaviour | Test |
|---|---|---|
| **Scenario 4:** Redis flushed or down | Reads fall back to Postgres and re-cache; writes still succeed (the key delete failing is logged, counted, ignored) | `RedisFlushed_ReadFallsBackToPostgres`, `RedisDown_WritesStillSucceed`; end to end: `tools/e2e.sh` `redis_flush` (spec dev-tools E3) |
| Stale cache race | Writers delete, never set; a reader that re-fills after a delete reads the committed row | `Cache_WriteDeletesKey_NextReadIsFresh` |
| Stairs retried (lost response) | Same floor → same seed, no second row | `FloorSeed_Retry_ReturnsSameSeed` |
| Stairs skipping a floor, or going back | 409 `1105` | `FloorSeed_NotNextFloor_Rejected` |
| Floor seeds are stable and secret-derived | Same run and floor → same seed across instances; different runs differ; non-negative | `FloorSeed_Hmac_StableAndDistinct`, `FloorSeed_MatchesTheSpecFormula` |
| Postgres down | 503 ProblemDetails; readiness already reports unhealthy | `StartRun_PostgresDown_Returns503` |
| Unaccepted ruleset version | 409 `1001` | `StartRun_UnknownRuleset_Rejected`; end to end: `tools/e2e.sh` `ruleset_refused` |
| Two migrating instances | Advisory lock: one migrates, the other waits | `Migrations_ConcurrentStart_RunOnce`, `Migrations_CreateSchema_ThenAreANoOp` |
| Development conveniences outside Development | `X-Dev-Player` ignored (401/400), `/auth/dev-token` 404, `Ruleset:AcceptAny` and `Run:AutoApproveWins` have no effect even if set in configuration | `DevConveniences_OffOutsideDevelopment` |
| (A) No or bad `X-Dev-Player` | 401 / 400 on every run endpoint | `Endpoints_WithoutPlayer_Return401`, `DevPlayer_IdIsStablePerName` |
| (A) Malformed or incomplete run start | 400 | `StartRun_InvalidBody_Returns400` |
| (A) Stairs on an ended run | 409 `1101` | `FloorSeed_EndedRun_Rejected` |
| (A) The next floor | Issued, becomes current, the seed is the HMAC's | `FloorSeed_NextFloor_IssuedAndBecomesCurrent` |
| (A, Godot) Stairs before the seed arrives | The run waits (every action refused), asks once, enters the floor when the seed comes; the same seed builds the same floor whenever it arrives | `test_stairs_wait_for_the_floor_seed` |
| (A, Godot) No answer or a 5xx at the stairs | Retried with backoff until the seed arrives; a 4xx stops the run (not a loss) | `test_server_link_starts_and_retries_the_stairs`, `test_server_refusal_stops_the_run`; end to end with the server stopped and restarted: `tools/e2e.sh` `offline_stairs` |
| (B) No or bad token | 401 on every player-state endpoint | `Endpoints_RequireAuth` |
| (A, built) Another player's run | 404 (no existence leak), also from a cached copy | `Runs_OtherPlayer_NotFound` |
| (B) Batch retried | Seqs already stored with the same body are skipped; same ack; no new rows | `Actions_BatchRetry_IsIdempotent` |
| (B) Same seq, different body (old save, second device, tampering) | 409 `1103`; nothing in the batch is stored | `Actions_SameSeqDifferentBody_Conflicts` |
| (B) Gap | 409 `1102` with `expectedSeq`; the client resends from there | `Actions_Gap_ReportsExpectedSeq` |
| (B) Checkpoint action without a snapshot | 400 | `Actions_CheckpointWithoutSnapshot_Rejected` |
| (B) Two devices uploading at once | Serialized by `FOR UPDATE`; the first wins each seq, the other gets `1103` and resumes from the server | `Actions_Concurrent_SerializeBySeq` |
| (B) Stairs before the floor's log is uploaded | 409 `1106` with `lastSeq`; the client drains the queue and retries | `FloorSeed_UploadIncomplete_Rejected` |
| (B) Win before the log is uploaded | 409 `1106` | `EndRun_UploadIncomplete_Rejected` |
| (B) Win, verifier not built yet | `Verifying`; with `Run:AutoApproveWins` → `Won` | `EndRun_Won_VerifyingThenAutoApproved` |
| (A, built) New run while one is active or verifying | The old run becomes `Abandoned` (a verifying run can't be abandoned: 409 `1101`) | `StartRun_AbandonsPrevious`; **untested:** the Verifying case (Part A can't produce a Verifying run; test it in 2b) |
| (B) Battle action | One `battle_sessions` row in the same transaction; re-upload maps to the same row | `Actions_Battle_CreatesSession` |
| (B) Rate limit exceeded | 429 `1201` + `Retry-After`; Redis down → fails open, counted | `RateLimit_Exceeded_Returns429`, `RateLimit_RedisDown_FailsOpen` |
| (Godot) Offline for a whole floor | Play continues; the queue and save grow; at the stairs "Connecting…" until online, then the queue drains and the seed arrives | `test_offline_floor_then_sync` |
| (Godot) Network error mid-batch | Retried in order with backoff; the map keeps working | `test_action_queue_retries_in_order` |
| (Godot) 409 `1103` on upload | The save is discarded; resume without a save | `test_conflict_discards_save` |
| (Godot) Resume without a save | Snapshot + tail replay reaches the server's `stateHash` at `lastSeq` | `test_resume_from_server_log` |

Root `CLAUDE.md` acceptance scenarios: **4** is covered here (Part A). **1**, **2** reuse this spec's key pattern in
slices 3–4. **5** (tamper → 2002) is slice 3 for battles and 4a for runs; this spec makes it meaningful by fixing
floor seeds server-side and storing every action and checkpoint. **6** is groundwork only. **3**, **7**: later.

## 5. Observability
Prometheus via the existing `RpgMetrics` meter:
| Instrument | Type | Labels |
|---|---|---|
| `rpg_run_starts_total` | counter | `result` = created \| abandoned_previous \| rejected |
| `rpg_floor_seeds_total` | counter | `result` = issued \| repeated \| not_reachable \| upload_incomplete |
| `rpg_cache_reads_total` | counter | `entity` = run \| battle, `source` = redis \| postgres \| missing |
| `rpg_cache_errors_total` | counter | `operation` = get \| set \| delete \| zadd \| ratelimit (`set`: a failed cache fill on the read path, decided 2026-10-27) |
| `rpg_run_actions_total` (B) | counter | `type`, `result` = accepted \| duplicate \| gap \| conflict \| inactive |
| `rpg_run_action_batch_size` (B) | histogram | |
| `rpg_run_action_upload_lag_seconds` (B) | histogram | (received − played: how long players played offline before syncing) |
| `rpg_run_action_duration_seconds` (B) | histogram | |
| `rpg_battles_submitted_total` (B) | counter | |
| `rpg_run_ends_total` (B) | counter | `status` = won \| lost \| auto_approved |
| `rpg_rate_limited_total` (B) | counter | `bucket` |
| `rpg_dev_tokens_issued_total` (B) | counter | |
| `rpg_runs_in_progress` | gauge | (status Active; recomputed every 30 s from Postgres; not exported until the first count. Its presence is tested; its value comes with `Gauges_PresenceAndRuns` in 2b) |
| `rpg_players_online` (B) | gauge | (`ZCOUNT presence:online`, last 5 min) |
| `rpg_players_in_battle` (B) | gauge | (`ZCOUNT presence:battle`, last 2 min; a client hint, not a verified fact) |
`type` and `bucket` are small fixed sets. Never item, character, room or encounter ids as labels. Traces: ASP.NET
Core, Npgsql (its built-in `Npgsql` source) and Redis spans (`OpenTelemetry.Instrumentation.StackExchangeRedis`,
prerelease, attached once the multiplexer's background connect succeeds; decided 2026-10-27), tested by
`Traces_IncludeRedisAndNpgsqlSpans`; `rpg.run_id` and `rpg.floor` as span attributes. **Battles over time vs server load:**
`rate(rpg_battles_submitted_total[1m])` beside CPU, memory, latency and errors (Grafana, slice 6). Note it counts
battles when they're *uploaded*, which trails play by the upload lag; `played_at` in Postgres gives the play-time view.

## 6. Test plan
**C# contract tests (`tests/Rpg.Contracts.Tests`):** golden JSON for every new record (exact camelCase shape and
round-trip); `ApiErrors` codes never collide with 2002; `BattleSubmission.Conditions` binds the existing v2 golden.
**Server tests (`tests/Rpg.GameServerApi.Tests`, Testcontainers Postgres + Redis):** every server row of section 4,
plus: migrations create the schema on an empty database and are a no-op the second time; resume returns the latest
checkpoint ≤ `lastSeq` and exactly the actions after it; `Gauges_PresenceAndRuns` (two players heartbeating, one idle
for 6 minutes → `rpg_players_online` 2).
**Client tests:** `Rpg.Client` calls against `WebApplicationFactory` (status codes → `GameServerApiException` with
`errorCode`, `Retry-After` exposed). Part A: every run test goes through `Rpg.Client` (`ErrorCode` checked);
**untested:** `RetryAfter`, since no Part A endpoint sends it (test it in 2b with the 429 rate limiter). Also built:
`Metrics_CountRunStartsAndFloorSeeds`, `Traces_IncludeRedisAndNpgsqlSpans`, `Scripts_AreEmbedded_InNameOrder`.
**Godot system tests (fixtures only, a fake bridge; no network):** A: `test_local_mode_unchanged` (every golden
still matches); `test_server_seed_source` (floor content follows the issued floor seed, not the run seed; two runs
with the same floor seeds generate the same floor; boss rotation and chest contents follow floor 0's seed);
`test_ruleset_version_stable` (and the version written by `export.sh` equals the live one, for every preset; built as
the stamp round trip). Also built in A: `test_seed_source_local_keeps_todays_labels`, `test_seed_source_server_streams`,
`test_stairs_wait_for_the_floor_seed`, `test_server_link_starts_and_retries_the_stairs`,
`test_server_refusal_stops_the_run`, `test_server_link_errors` (`tests/game/test_server_mode.gd`); the real client
against the real server: `tools/e2e.sh` (spec dev-tools E1–E7). B: `test_snapshot_round_trip`;
`test_resume_equivalence` (golden: stop at every checkpoint of the scripted run, save, load, finish → same final
hash); `test_checkpoints_attached` (snapshots exactly on `start_run`, battle-pending actions, `battle`,
`next_floor`); `test_actions_sent_in_order` (batches, seq 1…n); `test_offline_floor_then_sync`;
`test_action_queue_retries_in_order`; `test_conflict_discards_save`; `test_resume_from_server_log`;
`test_win_waits_for_verdict` (no `run_ended("won")` before the fake server says Won).
**Part A done (2026-10-27):** both suites pass; every floor seed of a run comes from the server, a floor crossed with
the server stopped syncs at the stairs once it is back, and flushing Redis mid-run changes nothing for the player
(`tools/e2e.sh`); the player export carries the stamped ruleset version. **Done when (B):** `dotnet build` /
`dotnet test` and the Godot suite pass; with the stack up and a dev token, the demo
plays a run where every floor seed comes from the server, every action lands in `run_actions` in order with
snapshots at checkpoints and battles in `battle_sessions`; a floor played with the network cut syncs at the stairs;
deleting the local save mid-run and restarting resumes at the same state hash; flushing Redis mid-run changes nothing
for the player; `/metrics` shows runs in progress, players online and in battle, and upload lag.

## 7. What later slices pick up
- **Slice 3 `battle-verify`:** a submitted battle (conditions + log) becomes a verify job on RabbitMQ; verdict cache
  and duplicate-work locks in Redis; `BattleSessionStatus` gains Verified/Rejected.
- **Slice 4a `run-verify`:** step jobs on `verify.segment` and `verify.battle` from the stored checkpoints, the
  fan-in link check, the floor verdict, the `1107` stairs gate (at most one unverified floor), the real run-end
  verdict (removes `Run:AutoApproveWins`), `Rejected` + rollback, resume from the latest *verified* checkpoint, and
  the floor read model in Redis (written when a floor's entry step is verified). Floor N+1 can't be generated ahead
  of time: its item pools depend on what was seen and held on floor N, so its generation is verified as part of the
  step that ends with `next_floor`.
- **Slice 4b:** analytics from `run_actions`; leaderboards and anomaly flags (including the accepted cheats above).

## Files this spec creates or changes
```
Part A
src/Rpg.Contracts/Runs/          RunStart, FloorSeed, RunSummary, RunStatus
src/Rpg.Contracts/Api/V1/        ApiErrors.cs, ApiHeaders.cs
src/Rpg.GameServerApi/           Runs/ (endpoints, run store, floor seeds, ruleset policy, summary cache, runs-in-progress
                                 monitor), Migrations/ (runner, 0001_runs.sql), Players/DevPlayer.cs,
                                 Infrastructure/PostgresUnavailableHandler.cs (503), RedisConnection.WhenConnected,
                                 Observability/RpgMetrics.cs (instruments), Program.cs, appsettings.Development.json
Directory.Packages.props         OpenTelemetry.Instrumentation.StackExchangeRedis 1.20.0-beta.1 (prerelease, Redis spans)
src/Rpg.Client/                  GameServerClient.cs (run calls)
client-godot/net/                ServerBridge.cs        (first C# script; rpgDemo.csproj already references Rpg.Client)
client-godot/game/               seed_source.gd, server_link.gd, ruleset_version.gd, ruleset_stamp.gd,
                                 tools/print_ruleset_version.tscn, run_controller.gd, floor_generator.gd,
                                 defs/floor_slot.gd, run_state.gd, game_main.gd, dev/commands/server.gd, dev/dev_console.gd
tools/export.sh                  writes the ruleset version into the pack; .gitignore ignores the stamp
tests/                           contract goldens, server tests, Godot tests (fake bridge)
Part B
src/Rpg.Contracts/Runs/, Battle/, Presence/, Auth/   action, end, resume, battle session, presence, auth records
src/Rpg.GameServerApi/           Auth/ (JWT bearer, dev issuer), Runs/ (actions, end, resume), Battle/ (session read + cache),
                                 Presence/, RateLimiting/ (Lua token bucket), Migrations/0002_*.sql
Directory.Packages.props         Microsoft.AspNetCore.Authentication.JwtBearer (pinned)
client-godot/game/               run_snapshot.gd, server_link.gd (queue, save, resume, heartbeat), run_controller.gd, run_state.gd
infra/.env.example               a note: server secrets (Seeds:Secret, the JWT key) go to user-secrets in development
```

## Decisions to review (please confirm or change before `/implement`)
All confirmed 2026-10-20 (1, 6 and 10 were decided in the design discussion).
1. **Whole floor, offline.** The client gets one floor's seed at a time and plays it offline; every in-floor action,
   battles included, is async. Battles no longer have a blocking handshake (this replaces the earlier
   `/battle/start` design; slice 2 is renamed `run-checkout`).
2. **Floor seeds are HMAC-derived** from a server secret, the run id and the floor, and stored. Retries are free;
   workers never hold the secret.
3. **Gates:** the stairs need the floor's log fully uploaded (B) and, from 4a, at most one unverified floor; a won
   run blocks on "Verifying run…" until the server says Won (`Run:AutoApproveWins` stands in until 4a). A death ends
   at once.
4. **Checkpoints with claimed snapshots** on `start_run`, battle-pending actions, `battle` and `next_floor`. Stored
   now so 4a can verify a floor's steps in parallel. Snapshots are opaque `jsonb` to the server (owned by GDScript).
5. **Batched uploads:** up to 50 actions per request, all-or-nothing, idempotent by `(runId, seq)`.
6. **Saves:** local save after every action; the server's accepted log always wins (`1103` discards the save);
   resume without a save = latest checkpoint + replay of the tail on the client.
7. **Redis:** run summary and battle session caches (delete-on-write cache-aside), presence sorted sets, a Lua token
   bucket that fails open. Never needed for correctness.
8. **Presence is a client hint.** "Players in a battle" comes from the heartbeat, since the server only learns about
   a battle when it's uploaded.
9. **Development conveniences:** `X-Dev-Player` (Part A only), `POST /auth/dev-token`, `Ruleset:AcceptAny`,
   `Run:AutoApproveWins`. Read only when the environment is Development; a test starts the server as Production with
   all four set in configuration and checks none of them takes effect.
10. **Accepted cheats:** perfect play on a known floor, and retrying a battle by restoring a save before it uploads.
    Detected statistically later (4b), not prevented.
11. **Run-wide streams from floor 0's seed** (2026-10-27): boss rotation and chest contents use
    `SeedSource.run_rng`, which is derived from floor 0's seed in server mode. Their early visibility is accepted.
12. **Ruleset version computed at export time** (2026-10-27): it covers source files and leaves out dev and tool
    paths, so every preset and the verifier share one version.
13. **The dev player is a name** (2026-10-27, made while building Part A): `X-Dev-Player` carries a readable name and
    the server derives a stable player id from it (3.2), so tests and the console use names (`alice`, `e2e-stairs`).
14. **The cached run summary carries its owner** (2026-10-27): `run:summary:{runId}` holds the summary and the player
    id, so ownership is checked without a Postgres read (3.6).
15. **`rpg_cache_errors_total` also counts `set`** (2026-10-27): a Redis that accepts reads but not writes stays visible.
16. **Redis spans now, through a prerelease package** (2026-10-27): `OpenTelemetry.Instrumentation.StackExchangeRedis`
    `1.20.0-beta.1`, pinned like the Prometheus exporter, rather than waiting for slice 6.
