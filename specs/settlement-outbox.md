# Spec: settlement-outbox (slice 4)

Status: 📝 Reviewed 2026-11-02 (open items 1–3 decided), ready to implement. Builds on `specs/battle-verify.md` (the verdict on `battle_sessions`) and
`specs/server-authority.md` (runs, the action log). Roadmap entry: "4. `settlement-outbox`". Nothing here is built yet.

## 1. Purpose & enterprise mapping

**Purpose.** Three things that slice 3 deliberately left open:

1. **Settlement.** A `Verified` battle that beat a boss grants **completion marks** (character × boss) and the **gems**
   they pay, to the player's account. The grant is **exactly once**, even with redelivery, two workers or a worker killed
   between commit and ack (acceptance scenario 2, settlement half).
2. **The transactional outbox.** The verdict, the settlement and the events that describe them are written in **one
   Postgres transaction**; nothing is published from request or worker code. An **outbox relay** moves rows to their
   destination, at least once.
3. **Events on Redpanda.** The relay publishes domain events (`BattleVerified`, `BattleRejected`, `RewardGranted`) to
   Redpanda, so slice 4b can project analytics from them. Redpanda down never loses an event (acceptance scenario 3).

The same outbox also **carries the verify jobs to RabbitMQ**: the upload transaction writes the `VerifyBattleJob` as an
outbox row, replacing slice 3's publish-after-commit fast path and `BattleVerifyDispatcher` sweeper (battle-verify 2.4
promised exactly this). One mechanism, two destinations.

**Also in this slice (decided 2026-11-01):** the `lock:battle:{id}` dedup lock goes (battle-verify 8, item 2). Correctness
never depended on it; a killed worker's lock only delayed its job by up to ~2 minutes.

**Components used** (from `README.md`):

| Component | Role in this slice | Enterprise analogue |
|---|---|---|
| PostgreSQL | Source of truth: wallet, ledger, completion marks, outbox, all in the verdict transaction | Managed Postgres, transactional outbox |
| RabbitMQ | Still carries `verify.battle`; now fed by the relay, not by request code | BlazingMQ work queue |
| Verifier worker | Writes verdict + settlement + outbox rows in one transaction, then acks | Versioned calculation worker, idempotent consumer |
| Outbox relay (new, in `Rpg.GameServerApi` as a `BackgroundService`) | Drains `outbox` to RabbitMQ or Redpanda, marks rows published | Outbox relay / CDC publisher |
| Redpanda | Append-only event log (`rpg.battle.events`, `rpg.economy.events`) | BMS Kafka |
| Redis | Wallet read cache only (`wallet:{playerId}`); not used for any correctness | Cache-aside, never the source of truth |
| Prometheus / OpenTelemetry | Outbox lag, relay results, settlement counters, trace continued from the job through the event | GUTS metrics, tracing |

**Not used here:** the run-level consequences of a rejection, `FloorVerified`, the run-end verdict and win-based
completion marks (4a); analytics consumers and projections (4b); cards, packs, dust (5, 5b); SignalR push (7).

**Acceptance scenarios covered:** 2 (worker killed after DB commit, before ack → no double reward), 3 (Redpanda down →
outbox drains with no lost event), 1 (a duplicate job → one settlement), 4 (Redis flushed → wallet read from Postgres).
5 stays covered by slice 3 (a rejection settles nothing, tested here too).

## 2. Sequence flow

### 2.1 Upload → job (the outbox replaces the fast path)

```
Godot client ── POST /api/v1/runs/{id}/actions (a `battle` action)                       (Part B, unchanged request)
  API: ONE transaction: run_actions row + battle_sessions row (Submitted)
                        + outbox row  { destination 'rabbit', type 'VerifyBattleJob', key = battleId }       ── commit
  API: DEL run:summary:{id}
  ◀── 200 RunActionAck                                          (the upload never waits for a broker or a worker)

Outbox relay (every Outbox:PollInterval, 250 ms; also woken by Postgres LISTEN/NOTIFY is a later optimisation):
  1. lease:  UPDATE outbox SET leased_until = now() + @lease, attempts = attempts + 1
             WHERE id IN (SELECT id FROM outbox WHERE published_at IS NULL AND (leased_until IS NULL OR leased_until < now())
                          AND dead_lettered_at IS NULL ORDER BY id LIMIT @batch FOR UPDATE SKIP LOCKED)
             RETURNING *                                          (short statement; no lock held while publishing)
  2. publish each leased row to its destination with confirm (RabbitMQ publisher confirm, or Kafka idempotent
     producer ack with acks=all), headers: event id, type, traceparent, x-attempt
  3. success:  UPDATE outbox SET published_at = now(), leased_until = NULL WHERE id = @id      (a failure here only
               means the row is published again later: at-least-once)
     failure:  leave unpublished; leased_until = now() + backoff(attempts) (1 s … 60 s); rpg_outbox_publish_total{result=failed}
```

Per-key order: rows for one `key` (battleId for jobs, playerId for events) are published in `id` order by a **single
relay instance per destination partition of the key space** — see 3.4: the relay only leases a row when no
earlier unpublished row has the same key (`NOT EXISTS`), so a retry never overtakes an older event for the same player.

### 2.2 Verdict + settlement in one transaction (the worker)

Slice 3's steps 1–4 and 6–7 are unchanged (read the session, replay in Godot, retry tiers, DLQ). Step 3's **lock is
removed**; step 5 becomes:

```
Verifier worker, a replay finished with exit 0 (Verified) or 2 (Rejected):
  BEGIN
    5a. UPDATE battle_sessions SET status, verdict, verified_at, verifier_version, attempts = attempts + 1
        WHERE battle_id = @id AND status = 'Submitted'                                 (as in slice 3)
        rowcount 0 → ROLLBACK, ack as duplicate. Nothing below runs.                  ← the first idempotency gate
    5b. INSERT outbox  BattleVerified | BattleRejected   (destination 'redpanda', key = playerId)
    5c. if Verified and the verdict's facts say a boss was beaten by a victory (3.1):
          for each party character in the conditions:
            INSERT completion_marks (player_id, character_id, boss_id, battle_id) ON CONFLICT DO NOTHING
              rowcount 1 (a first mark) →
                INSERT wallet_ledger (player_id, currency 'gems', delta, reason 'completion_mark',
                                      idempotency_key = 'mark:{battleId}:{characterId}')   UNIQUE ← the second gate
                UPDATE wallets SET gems = gems + @delta, version = version + 1 WHERE player_id = @p
                INSERT outbox  RewardGranted  (destination 'redpanda', key = playerId)
  COMMIT
  then, best effort (a failure is logged and counted, never changes the decision): verdict cache writes, DEL wallet:{playerId}
  ack
```

Everything that can change money is inside one transaction. A worker killed **before** the commit changes nothing and
the job is redelivered; killed **after** the commit and **before** the ack, the redelivered job finds
`status ≠ Submitted` (5a updates zero rows) and acks: scenario 2. If 5a were somehow skipped, the `completion_marks`
primary key and the `wallet_ledger` unique key still refuse a second grant.

### 2.3 Events out (Redpanda)

```
Outbox relay → Redpanda (idempotent producer, acks=all, key = playerId, so one player's events stay in order)
  Redpanda down: produce times out → the row stays unpublished, backoff, `rpg_outbox_pending` and
  `rpg_outbox_oldest_unpublished_age_seconds` grow. When Redpanda returns, rows drain in id order. Nothing is lost
  because the row was committed with the verdict. Scenario 3.
```

Consumers (slice 4b) must be idempotent by `EventId`; the relay can publish a row twice (a crash between the produce ack
and step 3).

### 2.4 Reading the wallet

```
Godot client / dashboard ── GET /api/v1/wallet   (Bearer)
  Redis GET wallet:{playerId} → hit → 200
  miss / Redis error → Postgres wallets (+ last 20 ledger rows) → 200, fill the cache (60 s)
```

Read-only. Spending is slice 5 (packs). The client shows no UI in this slice; the console gets `server wallet` and
`wait gems <n>` for tests and e2e (tool parity, `client-godot/CLAUDE.md` section 5).

## 3. Data contracts

### 3.1 C# records (`src/Rpg.Contracts/`)

```csharp
namespace Rpg.Contracts.Battle;

// ReplayResult / BattleVerdict gain one optional record. Additive: old JSON still reads (Facts = null).
/// <summary>What the replay learned from content that C# must not know: computed by the Godot runner, not the worker.</summary>
public sealed record BattleFacts(
    string EncounterId,
    IReadOnlyList<string> BossIds,          // enemies of the encounter tagged Enemy.Boss; empty for an ordinary battle
    IReadOnlyList<string> PartyCharacterIds);

namespace Rpg.Contracts.Events;

/// <summary>Envelope of every event on Redpanda. Payload types are below; the envelope never changes shape.</summary>
public sealed record DomainEvent<TPayload>(
    Guid EventId,                           // = outbox.id; consumers dedupe on it
    string Type,                            // EventTypes.*
    int SchemaVersion,                      // 1
    Guid PlayerId,
    Guid? RunId,
    DateTimeOffset OccurredAt,              // the commit time, not the publish time
    string RulesetVersion,
    TPayload Payload);

public static class EventTypes
{
    public const string BattleVerified = "BattleVerified";
    public const string BattleRejected = "BattleRejected";
    public const string RewardGranted  = "RewardGranted";
}

public sealed record BattleVerifiedPayload(string BattleId, int RunSeq, BattleOutcome Outcome, int Turns,
    string FinalStateHash, string EncounterId);
public sealed record BattleRejectedPayload(string BattleId, int RunSeq, int ErrorCode /*2002*/, MismatchReason Reason);
public sealed record RewardGrantedPayload(string Source /*"completion_mark"*/, string BattleId, string CharacterId,
    string BossId, string Currency /*"gems"*/, int Amount, int BalanceAfter);

namespace Rpg.Contracts.Economy;

public sealed record WalletResponse(int Gems, long Version, IReadOnlyList<LedgerEntryDto> Recent);
public sealed record LedgerEntryDto(string Currency, int Delta, string Reason, string RefBattleId, DateTimeOffset At);
```

`VerifyBattleJob` is unchanged. **The Godot runner learns to emit `Facts`** (additive field of the `ReplayResult`, schema
version stays 1): the encounter id, which of its enemies carry `Enemy.Boss`, and the party's character ids, all from the
content the replay already loads. The C# side never reads tags or content. This touches the `combat-replay-core`
contract once, additively, and needs a golden update (3.6).

Event JSON uses `RpgJson` (camelCase, string enums). No game logic enters `Rpg.Contracts`.

### 3.2 PostgreSQL: `Migrations/0004_settlement_outbox.sql`

```sql
CREATE TABLE outbox (
  id uuid PRIMARY KEY,                       -- event id; also the Kafka message id / RabbitMQ message-id
  seq bigint GENERATED ALWAYS AS IDENTITY,   -- relay order (uuid is not ordered)
  destination text NOT NULL CHECK (destination IN ('rabbit','redpanda')),
  topic text NOT NULL,                       -- queue/routing key or Redpanda topic
  key text NOT NULL,                         -- battleId (rabbit) or playerId (redpanda): ordering scope
  type text NOT NULL,
  payload jsonb NOT NULL,
  traceparent text,
  created_at timestamptz NOT NULL DEFAULT now(),
  published_at timestamptz,
  leased_until timestamptz,
  attempts int NOT NULL DEFAULT 0,
  dead_lettered_at timestamptz,
  dead_letter_reason text);
CREATE INDEX outbox_unpublished ON outbox (seq) WHERE published_at IS NULL AND dead_lettered_at IS NULL;

CREATE TABLE wallets (
  player_id uuid PRIMARY KEY REFERENCES players,
  gems int NOT NULL DEFAULT 0 CHECK (gems >= 0),
  version bigint NOT NULL DEFAULT 0,
  updated_at timestamptz NOT NULL DEFAULT now());

CREATE TABLE wallet_ledger (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  player_id uuid NOT NULL REFERENCES players,
  currency text NOT NULL CHECK (currency IN ('gems')),
  delta int NOT NULL CHECK (delta <> 0),
  reason text NOT NULL,
  ref_battle_id text,
  idempotency_key text NOT NULL UNIQUE,      -- 'mark:{battleId}:{characterId}': the exactly-once key
  created_at timestamptz NOT NULL DEFAULT now());
CREATE INDEX wallet_ledger_player ON wallet_ledger (player_id, id DESC);

CREATE TABLE completion_marks (
  player_id uuid NOT NULL REFERENCES players,
  character_id text NOT NULL,
  boss_id text NOT NULL,
  battle_id text NOT NULL REFERENCES battle_sessions,
  granted_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (player_id, character_id, boss_id));     -- a character's first win over a boss pays once, ever

-- the sweeper's columns go: enqueued_at has no reader any more
ALTER TABLE battle_sessions DROP COLUMN enqueued_at;
```

Invariant (tested): `wallets.gems = SUM(wallet_ledger.delta)` per player. The ledger is append-only (no UPDATE/DELETE in
code; a `REVOKE`-style guard is out of scope for a demo). `battle_sessions.player_id` is read through `runs`.

### 3.3 RabbitMQ

Topology unchanged (battle-verify 3.3). Only the publisher changes: the relay replaces `VerifyJobPublisher`'s upload call
and the dispatcher. The `x-attempt` header keeps its slice-3 meaning (worker attempts); the relay's own publish attempts
live in `outbox.attempts`.

### 3.4 Redpanda topics

| Topic | Key | Partitions | Events | Retention |
|---|---|---|---|---|
| `rpg.battle.events` | `playerId` | 3 | `BattleVerified`, `BattleRejected` | 7 days (dev) |
| `rpg.economy.events` | `playerId` | 3 | `RewardGranted` | 7 days (dev) |

Created on API startup if missing (idempotent). Producer: idempotent, `acks=all`, `linger` 5 ms, message timeout 10 s.
Headers: `event-id`, `type`, `schema-version`, `traceparent`. Message value = the `DomainEvent<T>` JSON. Package:
`Confluent.Kafka` (pinned in `Directory.Packages.props`).

**Relay ordering rule:** a row is leased only if no earlier row with the same `(destination, key)` is still unpublished
and not dead-lettered. This keeps one player's events ordered across retries at the cost of head-of-line blocking per
key (acceptable: keys are per player). `Outbox:BatchSize` (50), `Outbox:Lease` (30 s), backoff 1 s × 2^n capped at 60 s.
A permanent error dead-letters a row at once; after `Outbox:MaxAttempts` (20 for Redpanda, 0 = unlimited for rabbit) a transiently failing row is dead-lettered with a reason and an alert
metric; a human requeues with `UPDATE outbox SET dead_lettered_at = NULL, attempts = 0`.

### 3.5 Redis

| Key | Value | TTL | Semantics |
|---|---|---|---|
| `wallet:{playerId}` | `WalletResponse` JSON | 60 s | Cache-aside for `GET /wallet`; `DEL` after a settlement commit; a miss or error → Postgres (scenario 4) |
| `lock:battle:{id}` | | | **Removed.** The worker no longer takes it; `Verifier:UseLock`, `LockTtl` and `rpg_verify_lock_total` go with it |

### 3.6 HTTP

| Endpoint | Change |
|---|---|
| `GET /api/v1/wallet` | New. Bearer. 200 `WalletResponse`. |
| `GET /api/v1/runs/{id}/battles/{seq}` | Unchanged. |
| `POST /api/v1/runs/{id}/actions` | Unchanged request/response; internally writes the outbox row. |

No new `ApiErrors`. Settlement is invisible to the upload path.

### 3.7 Configuration

API: `Outbox:PollInterval` (250 ms), `BatchSize` (50), `Lease` (30 s), `MaxAttempts` (20), `Enabled` (tests can pause the
relay), `Kafka:BootstrapServers` (`localhost:19092`). `Settlement:GemsPerBossMark` (default 10; an economy number, not a
combat number, so it is a plain whole number and **not** ×100). Worker: `Settlement:Enabled` (default true). Removed:
`Verifier:SweepInterval/SweepGrace/RepublishAfter/SweepBatch`, `Verifier:UseLock`, `Verifier:LockTtl`.

## 4. Failure modes

| # | Failure | Behaviour | Test |
|---|---|---|---|
| F1 | The same job twice (redelivery, duplicate publish) | 5a updates zero rows; one verdict, one settlement, one event. **Scenario 1** | `SameJobTwice_OneVerdict_OneSettlement` |
| F2 | Worker killed after the commit, before the ack | Redelivery finds `status ≠ Submitted` and acks; the ledger has one row per mark. **Scenario 2** | `CrashAfterTheCommit_RedeliveryGrantsNothingTwice`, `ADeliveryTheFirstWorkerNeverAcked_IsRedeliveredAndFoundDone` (real broker) |
| F3 | Worker killed before the commit | Nothing changed (one transaction), job redelivered, settlement happens once | `CrashBeforeTheCommit_LeavesNoVerdictNoLedgerNoOutbox` |
| F4 | Two workers, same battle, same moment | The guarded update lets one transaction win; the loser rolls back with zero side effects | `ConcurrentWorkers_OneSettlement` |
| F5 | The 5a guard is bypassed (a bug, a manual SQL) | `completion_marks` PK and `wallet_ledger.idempotency_key` UNIQUE refuse the second grant | `LedgerKey_AndMarkKey_RefuseADoubleGrant_EvenWithoutTheStatusGuard` |
| F6 | A Rejected verdict | Outbox `BattleRejected` only; no mark, no ledger, no wallet change | `Rejected_SettlesNothing_PublishesBattleRejected` |
| F7 | A verified battle with no boss or a defeat | `BattleVerified` event, no settlement | `VerifiedWithoutABossVictory_GrantsNothing` |
| F8 | A character already holds the mark for that boss | `ON CONFLICT DO NOTHING`: no gems, no `RewardGranted` | `SecondWinOverTheSameBoss_PaysNothing` |
| F9 | **Redpanda down** | Rows stay unpublished with backoff; gauges grow; on recovery all drain in per-key order, none lost, none reordered for a player. **Scenario 3** | `RedpandaDown_RowsDrainInOrderWhenItReturns` (Testcontainers, stop/start), e2e `outbox_redpanda_down` |
| F10 | RabbitMQ down at upload | The upload succeeds (the row is committed); the relay publishes the job when the broker returns; no sweeper needed | `Upload_BrokerDown_StillStores_AndTheRelayPublishesLater` |
| F11 | The API crashes between publish-ack and `published_at` | The row is published again: duplicate job (F1 handles it) or duplicate event (consumers dedupe on `EventId`) | `RelayCrashAfterPublish_PublishesAgain_WithTheSameEventId` |
| F12 | Two relay instances | `FOR UPDATE SKIP LOCKED` plus the lease: never the same row at once; the per-key rule keeps order | `TwoRelays_NeverPublishTheSameRowAtOnce_AndKeepKeyOrder` |
| F13 | Poison row | A permanent error (cannot serialise, unknown topic) is dead-lettered on the first attempt; a transient one retries to `MaxAttempts` first (8.3). Counted; rows of other keys flow throughout | `APoisonRow_IsDeadLettered_AndOtherKeysKeepFlowing` |
| F14 | Postgres down at verdict time | Nothing decided; retry tier 30 s without an attempt (as slice 3) | slice 3's `PostgresDown_PostponesWithoutCountingAnAttempt`, still green |
| F15 | Redis flushed or down | Settlement unaffected (Postgres only); the wallet is read from Postgres. **Scenario 4** | `GetWallet_RedisFlushed_IsServedFromPostgres`, `RedisDown_StillSettles` |
| F16 | Cache write or `DEL wallet` fails after the commit | Best effort; the 60 s TTL bounds staleness; never changes the decision | `AFailureAfterTheCommit_NeverChangesTheDecision` (extended) |
| F17 | Tampered log | Slice 3 behaviour plus F6: **Scenario 5** | slice 3's tests, e2e `verify_tampered` extended to assert an empty ledger |
| F18 | Lost upload job (old sweeper case) | Cannot happen: the job row commits with the upload | `UploadAndOutboxRow_AreOneTransaction` (a forced failure rolls both back) |

**Idempotency summary:** the unit of exactly-once is the **Postgres transaction** guarded by
`WHERE status = 'Submitted'`; two database constraints back it; the queue and the relay are at-least-once. Money never
moves outside that transaction, and events are published only from the outbox.

## 5. Observability

Names follow the `rpg_*` convention. Labels are bounded enums only; **never** battle, run, player, character or boss ids.

| Metric | Type | Labels | Where |
|---|---|---|---|
| `rpg_outbox_published_total` | counter | `destination` = `rabbit`\|`redpanda`, `type` (event type enum), `result` = `ok`\|`failed` | API relay |
| `rpg_outbox_publish_duration_seconds` | histogram | `destination` | API relay |
| `rpg_outbox_pending` | gauge | `destination` (Postgres count, every `Monitors:Interval`) | API monitor |
| `rpg_outbox_oldest_unpublished_age_seconds` | gauge | `destination` (the outbox lag; scenario 3 and 7) | API monitor |
| `rpg_outbox_dead_lettered` | gauge | `destination` | API monitor |
| `rpg_settlements_total` | counter | `result` = `granted`\|`no_reward`\|`already_marked`\|`rejected` | worker |
| `rpg_gems_granted_total` | counter | `reason` = `completion_mark` | worker |
| `rpg_wallet_reads_total` | counter | `source` = `redis`\|`postgres` | API |
| `rpg_cache_reads_total` / `rpg_cache_errors_total` | counters | existing; new `entity` value `wallet` | API |

Removed with the sweeper and the lock: `rpg_verify_jobs_published_total` (replaced by `rpg_outbox_published_total{type=VerifyBattleJob}`),
`rpg_verify_lock_total`, and the `lock_busy` value of `rpg_verify_jobs_total`. The "Battle verification" Grafana
dashboard is updated, and an **"Outbox & settlement"** row is added (lag, pending, publish results, settlements, gems
granted). Traces: the upload span's `traceparent` is stored on the outbox row, continues through the relay's publish span
and the worker's `verify.battle` span, and the settlement transaction span; the event row stores the worker's
`traceparent`, so an event links back to the replay that caused it. Logs carry `eventId`, `battleId`, `runId` as fields.

## 6. Test plan

**Contracts (`tests/Rpg.Contracts.Tests`).**
- Golden JSON for `DomainEvent<T>` with each of the three payloads, `BattleFacts`, `WalletResponse`.
- `ReplayResult` / `BattleVerdict` still read old JSON without `Facts`; the Godot-produced result golden parses into
  `BattleFacts`.
- Purity guard: no new references, no logic.

**API (`tests/Rpg.GameServerApi.Tests`, Testcontainers Postgres, Redis, RabbitMQ, **Redpanda**; Docker required).**
- Migration 0004 and its constraints (`gems >= 0`, ledger unique key, mark primary key, outbox destination check).
- Upload writes the session and the outbox row in one transaction (F18); the relay publishes the job with headers (F10).
- Relay: lease, backoff, per-key order, two relays, crash after publish, poison row, pause and resume (F9, F11–F13).
- Redpanda down and back: all events present exactly in per-player order, with their event ids (F9, **scenario 3**).
- `GET /wallet` from Redis, Redis flushed → Postgres, cache cleared after a settlement (F15).
- The sweeper's tests are deleted with the sweeper; each guarantee they covered maps to F10/F18 above.

**Worker (`tests/Rpg.VerifierWorker.Tests`, fake runner returning canned `ReplayResult`s with `Facts`).**
- Every row F1–F8 and F14–F16, including the real-broker redelivery after an unacked commit (**scenario 2**).
- Property-style test: N random interleavings of duplicate and concurrent jobs always end with
  `wallets.gems = SUM(ledger.delta) = marks × GemsPerBossMark` and exactly one outbox row per fact.
- The lock is gone: no Redis call on the happy path; a worker with Redis down is unaffected.

**Real Godot, golden vectors.**
- Godot suite: the replay runner emits `Facts` for the committed boss and non-boss goldens (encounter id, boss ids,
  party ids); a tampered golden has none; every existing golden hash is unchanged (Facts are not hashed); `test_golden`
  key-order replays still pass. `server wallet` and `wait gems` (`test_e2e_tools`, fake bridge).
- `tools/e2e.sh` scenarios (on demand): `settle_boss` (a run that beats a boss on the fixtures content: the worker
  settles; `.sql` asserts one mark per party character, ledger sum equals the wallet, one `RewardGranted` outbox row per mark,
  all published; Redpanda topic read back); `outbox_redpanda_down` (`redpanda-stop`/`redpanda-start` fault steps added to
  the control folder: events written while it is down drain after); `verify_worker_kill` extended (a killed worker →
  exactly one settlement, and the job no longer waits two minutes: runtime drops to ~15 s); existing `verify_*` scenarios
  still pass with the relay carrying the jobs.
- `tools/verifier_image_check.sh` (on demand): the Linux image emits the same `Facts` for the goldens.

**Done when:** `dotnet build` and `dotnet test` pass, `tools/godot_tests.sh` passes, the e2e scenarios (old and new) and the
image check pass, and acceptance scenarios 2, 3, 1, 4 and 5 each have their named test.

## 7. Decisions, and what stays out

**Decisions (reviewed 2026-11-02; change by editing here)**
1. **One outbox table, two destinations** (RabbitMQ jobs and Redpanda events), instead of a separate mechanism for the
   verify jobs. Retires the slice 3 sweeper and fast path.
2. **Relay inside the API process** as a `BackgroundService`, polling Postgres (`SKIP LOCKED`), not a separate service,
   Debezium or `LISTEN/NOTIFY`. Simplest to run and test; `LISTEN/NOTIFY` wake-up is a later optimisation.
3. **Settlement inside the worker's verdict transaction** (not a second queue and consumer), so the verdict and the money
   cannot disagree. The roadmap's "settlement + outbox row in one transaction, then ack" is exactly this.
4. **What a battle pays is decided in Godot** (`BattleFacts`), never in C#; C# only multiplies by a configured gem amount.
5. **Only completion marks for boss victories** settle in this slice: a character's first verified boss win pays once,
   ever. Run-win marks, item/card rewards and spending come with 4a, 5 and 5b.
6. **Gems only**, one wallet row and an append-only ledger: enough to prove exactly-once effects without inventing a
   currency system early.
7. **`lock:battle` is removed**, not shortened (the roadmap allowed either).
8. **Per-key ordering by a `NOT EXISTS` rule** rather than one global in-order relay, so one stuck player cannot block everyone.

**Out of scope:** consumers/projections/dashboards of the events (4b); `FloorVerified`, run-end verdict, win marks,
rollback (4a); cards/dust/market (5, 5b); SignalR push (7); schema registry or Avro (JSON with `SchemaVersion` is enough
for the demo); Debezium CDC; DB-level append-only enforcement of the ledger.

## 8. Open items

1. **Conditions are not yet checked against the run state (4a). Decided 2026-11-02: accepted for slice 4, and the
   approach for slice 4a is option (b): gems are granted as `pending` and released by the run-level verification.**
   A client could submit a battle with fabricated conditions (an easy "boss") that replays cleanly, and be paid. Until 4a,
   settlement trusts `conditions`; this is a documented, demo-only gap (gems cannot be spent before slice 5). **4a must:**
   add a `status` (`pending` | `released` | `voided`) to `wallet_ledger` and make `wallets` hold only released gems;
   have slice 4's settlement write ledger rows as `pending`; release them when the fan-in aggregator verifies that the
   battle's conditions match the run state at its checkpoint (voiding them, with an event, if the floor is rejected or
   rolled back). The `idempotency_key` and `completion_marks` guards stay as they are. The roadmap's 4a entry carries the
   same note.
2. **`BattleFacts` changes the replay runner's output (additive). Decided 2026-11-02: yes, `combat/headless/` is touched.**
   The tamper-resistance of that field relies on the verifier computing it, not the client.
3. **Head-of-line blocking per player key. Decided 2026-11-02: permanent failures dead-letter at once, transient ones
   retry.** The ordering rule (3.4) holds back a player's later events while an earlier one is unpublished, so a row that
   can never succeed would block that player (only that player) until `MaxAttempts`, about 15 minutes of backoff
   (1 s, 2 s, 4 s … capped at 60 s, 20 attempts). To make that wait apply only to failures that can heal, the relay
   classifies errors: a **permanent** one (payload cannot be serialised, unknown topic or queue, message too large) is
   dead-lettered on its first attempt, with a reason, and the player's next events flow; a **transient** one (timeout,
   broker down, not-leader) is retried with backoff and blocks the key, which is correct because everything for that
   destination is failing anyway. A dead-lettered event leaves a gap in the player's stream; requeuing it later publishes
   it out of order, so consumers dedupe on `EventId` and order by `OccurredAt`, not arrival (4b's rule). Test:
   `APermanentlyBadRow_IsDeadLetteredAtOnce_AndTheKeysNextRowFlows`, next to F13.
4. **Migration drops `enqueued_at`** (the sweeper's lease). A deployment with in-flight sessions needs the upload outbox
   row backfilled for `Submitted` sessions that were never enqueued; the migration does that backfill in SQL.
5. **Gem amount is flat** (`GemsPerBossMark`); a per-boss table is design work (`design:` territory) and not needed to prove
   the mechanism.
