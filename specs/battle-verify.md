# Spec: battle-verify (slice 3)

Status: ✅ Implemented and synced with the build (2026-11-01); open items in section 8. Builds on `specs/server-authority.md` (Part B stores every battle as a
`battle_sessions` row) and `specs/combat-replay-core.md` / `specs/atomic-battles.md` (the replay runner and its
verdicts). Roadmap entry: "3. `battle-verify`".

## 1. Purpose & enterprise mapping

**Purpose.** Every battle a client uploads in a run's action log becomes a **verify job**. A worker pool of headless
Godot processes replays the battle from its uploaded conditions and action log, and writes a **verdict**:
`Verified`, or `Rejected` with `errorCode` 2002 and the first `MismatchReason`. The verdict is readable from
`GET /api/v1/runs/{runId}/battles/{seq}`. Slice 3 stops at the verdict: it does not settle rewards (slice 4), publish
events (slice 4), or act on a rejection for the run (slice 4a).

**Components used** (from `README.md`):

| Component | Role in this slice | Enterprise analogue |
|---|---|---|
| RabbitMQ | `verify.battle` work queue, retry tiers, DLQ, publisher confirms, manual acks | BlazingMQ work queue with retry and DLQ |
| Verifier worker (new, `src/Rpg.VerifierWorker`, a .NET Worker Service) | Consumes jobs, runs headless Godot per job, writes the verdict | Versioned calculation worker in a managed compute pool |
| Headless Godot 4.7.2 .NET | `combat/headless/replay_main.tscn`, the only combat implementation | The calculation engine the worker hosts |
| PostgreSQL | Source of truth for the verdict; the conditional update is what makes redelivery a no-op | Managed Postgres, idempotent consumer |
| Redis | Verdict cache (`battle:verdict`), work-deduplication lock (`lock:battle`) | Cache and duplicate-work suppression; never the source of correctness |
| Prometheus / OpenTelemetry | Job counters, latency, queue depth, rejection reasons, trace across publish → consume → Godot | GUTS metrics, distributed tracing |

**Not used here:** Redpanda and the outbox (slice 4; see 2.4 for the interim), SignalR push (slice 7; the client
polls), the `1107` stairs gate and run-level consequences of a rejection (slice 4a).

**Acceptance scenarios covered:** 1 (duplicate submission → one verdict), 5 (tampered log → 2002), 4 (Redis flushed
→ the verdict is served from Postgres), and the verdict-commit half of 2 (worker killed after the DB commit, before the
ack → redelivery is a no-op; the settlement half lands in slice 4). Scenario 6 (ruleset changed while a battle is
open) is only prepared (2.5); 3 and 7 are other slices.

## 2. Sequence flow

### 2.1 Upload to verdict

```
Godot client ── POST /api/v1/runs/{id}/actions (a `battle` action)                       (Part B, unchanged)
  API: one transaction: run_actions row + battle_sessions row (status Submitted)  ── commit
  API: DEL run:summary:{id}
  ◀── 200 RunActionAck                                    (the upload never waits for the broker or a worker)
  API (fast path, AFTER the response, best effort): publish VerifyBattleJob  ──▶ RabbitMQ  verify.battle
        one shared confirm channel; the 5 s budget starts at the publish gate; confirm received →
        UPDATE battle_sessions SET enqueued_at = now(); any failure is left to the sweeper (2.4)

Verifier worker (N consumers, prefetch 1 each; N = Verifier:Concurrency):
  receive job (header x-attempt, traceparent)
  1. SELECT status, ruleset_version, conditions, action_log FROM battle_sessions WHERE battle_id = @id
       no such battle               → publish to verify.battle.dlq (reason "poison: unknown battle"), ack
       status ≠ Submitted           → ack (duplicate/redelivery; count result=duplicate)
       ruleset_version not accepted → publish to verify.battle.dlq with reason, ack (2.5)
  2. UPDATE battle_sessions SET enqueued_at = now() WHERE battle_id = @id AND status = 'Submitted'
       (renews the session's lease: a job being replayed never looks lost to the sweeper, 2.4)
  3. SET lock:battle:{battleId} <workerToken> NX PX 120000          (dedup only, 3.4)
       held by another worker       → publish to retry tier 1 without counting an attempt, ack
       Redis error                  → continue without the lock (count result=redis_error)
       lock taken                   → read the status again; no longer Submitted → ack (no Godot run for a duplicate)
  4. write ReplayRequest{conditions, action_log} to a temp dir; start
       godot --headless --path <project> --quit-after <frames> res://combat/headless/replay_main.tscn
             -- --in req.json --out res.json [--content-root <Verifier:ContentRoot>]
       killed (process tree) after Verifier:ProcessTimeout (60 s) → runner error
       exit 0 → Verified · exit 2 → Rejected (2002) · exit 1 / timeout / no result file / a result for another
       battle → runner error
  5. verdict (exit 0 or 2):
       one statement:    UPDATE battle_sessions SET status = 'Verified' | 'Rejected', verdict = @json,
                                verified_at = now(), verifier_version = @v, attempts = attempts + 1
                         WHERE battle_id = @id AND status = 'Submitted'
       rowcount 0 → someone else already wrote the verdict: no-op (ack as duplicate)
       then, best effort (a failure here is logged and can never change the job's decision):
                         metrics; SET battle:verdict:{runId}:{seq} <json> EX 1800; DEL battle:session:{runId}:{seq}
       release lock (compare-and-delete Lua)
       ack
  6. runner error: attempts + 1 in Postgres; below Verifier:MaxAttempts (5) → publish to retry tier
       (attempt 1 → 5 s, attempt 2 → 30 s, attempt 3 and later → 120 s), ack;
       at the limit → dlq, set dead_lettered_at (reason "attempts"), ack
       The delay starts when the worker publishes to the retry queue (the message's TTL runs from its arrival there),
       so a hung replay costs its 60 s timeout first and the wait comes after. When the TTL expires the job returns
       to verify.battle and waits behind any backlog, so the wait is a minimum, not an exact time.
  7. other failures:
       transient Postgres/network error (nothing decided) → retry tier 30 s, no attempt counted
       any other exception (a permanent SQL error, say)    → nack without requeue (the main queue's dead-letter
         exchange puts it in the DLQ) and the session is marked dead_lettered_at, reason "error", so the sweeper
         leaves it alone
       the republish or the ack itself fails (broker trouble) → after 1 s the delivery is nacked WITH requeue; an
         unacked message is never redelivered while its channel stays open, and prefetch 1 would stall the consumer
```

The ack always comes **after** the commit (or after the republish to a retry/DLQ queue). If the worker dies between
commit and ack, RabbitMQ redelivers; step 1 finds `status ≠ Submitted` and acks. That is scenario 2's verdict half.

### 2.2 Reading the verdict

```
Godot client / tools ── GET /api/v1/runs/{id}/battles/{seq}   (Bearer)
  Redis MGET battle:verdict:{runId}:{seq}, battle:session:{runId}:{seq}  (one round trip; the verdict wins)
  miss, a Redis error or an entry that cannot be read → Postgres (re-cache: a Submitted session under battle:session
         with a 10 s TTL, so polling sees the verdict soon after it lands; a verdict under battle:verdict for
         30 min; a Submitted copy is not written once the verdict key exists)
  200 BattleSessionResponse { …, Status, Verdict }       Status Submitted → Verdict null (still pending)
```

Not the owner or no such battle: 404, as today. A **rejected battle is a 200** whose `Verdict` is
`{ status: "Rejected", errorCode: 2002, error: "ReplayMismatch", mismatch: {...} }`; never an HTTP 4xx (root
`CLAUDE.md` error contract). The client polls with backoff (1 s, 2 s, 5 s, capped); slice 3 adds no client UI. Console
commands for tests and e2e (tool parity, `client-godot/CLAUDE.md` section 5): `server verdict [seq]` (what the verifier
decided about each battle of the run, or one) and `wait verdict all|<seq> [seconds]` (waits for the upload queue to
drain, then polls until every wanted battle is Verified or Rejected, asking again only about the pending ones).
`ServerLink.battle_verdicts` is the system code behind both.

### 2.3 Worker lifecycle

- Startup: read the project's ruleset version once (`print_ruleset_version.tscn`, 2.5; retried every 2 s if Godot cannot
  print it, never fatal) and keep it; wait until the migration history lists `0003_battle_verdicts`; connect to
  RabbitMQ (retried); declare the topology (3.3); attach the consumers; connect Redis lazily (optional).
- `Verifier:Concurrency` consumers, each prefetch 1, so one process runs at most one Godot at a time per consumer.
- Readiness (`/health/ready`) follows the work: true once the consumers are attached; false when the broker connection
  is lost or a consumer channel is closed by the broker; after a recovery it is true again only if every consumer
  channel is open.
- Shutdown: cancel the consumers first (nothing new arrives), let running jobs finish for `Verifier:ShutdownGrace` (70 s,
  longer than `ProcessTimeout`), then close the channels, which returns anything unacked to the broker. The host waits
  90 s and compose gives the container 100 s (`stop_grace_period`).
- A Godot process is started **per job** (a few seconds of engine startup per battle). A warm, long-lived Godot per
  worker is a later optimisation (listed in 7), not needed for correctness.

### 2.4 Interim for the outbox: publish-after-commit plus a sweeper

Publishing to RabbitMQ in the upload's transaction is a dual write. The outbox that fixes this properly is slice 4, so
slice 3 uses a **reconciler** that makes the same guarantee (no battle stays unverified because a publish was lost):

- The upload path publishes after the commit and the response (fast path above). A crash or broker outage between
  commit and publish loses only the fast path.
- `BattleVerifyDispatcher` (a `BackgroundService` in the API, every `Verifier:SweepInterval`, 10 s) **leases** up to 100
  sessions in one short statement, `UPDATE battle_sessions SET enqueued_at = now() WHERE battle_id IN (SELECT … FOR UPDATE
  SKIP LOCKED) RETURNING …`, for rows with `status = 'Submitted' AND dead_lettered_at IS NULL`, older than
  `Verifier:SweepGrace` (30 s, so the upload's own fast path is left alone), and either never enqueued
  (`enqueued_at IS NULL`) or enqueued before `Verifier:RepublishAfter` (10 min) **but only while the verify queues are
  empty**. It then publishes each leased job with confirm, holding no lock or transaction. A job it could not publish,
  by failure, exception or shutdown, gets its lease cleared, so the next sweep takes it again.
- **A backlog is never doubled.** While anything waits in `verify.battle` or the retry queues (the broker is asked at each
  sweep; an unreachable broker counts as waiting) the stale branch is off, because a job with an old `enqueued_at` may be
  one of those waiting. A job a worker is replaying has left the queue, so workers renew `enqueued_at` when they take a
  job (2.1 step 2); it can only look stale after `RepublishAfter` without a worker touching it.
- Several API instances never lease the same row (`SKIP LOCKED`), and a duplicate job is harmless anyway (2.1 steps 1
  and 3).
- Slice 4 replaces both paths with an outbox row written in the upload transaction and relayed to RabbitMQ.

### 2.5 Ruleset version (groundwork for scenario 6)

Each job and each session carries `ruleset_version`. The worker holds exactly one version (its own project's). A job
whose version is not in `Verifier:AcceptedRulesets` (default: the worker's own) goes to `verify.battle.dlq` with
`reason = ruleset`, is counted as `result=wrong_ruleset`, and the session stays `Submitted`. Routing to a worker
pool of the matching version is slice 9; slice 3 only makes the mismatch visible and loses nothing. The replay always
runs the worker's own project, so `AcceptedRulesets` may list another version only as an operator's promise that this
project replays it identically; otherwise an honest battle is rejected, and the verdict records only the worker's
version. The ruleset version is the same on Linux and Windows for one source tree: dot-files such as `.gitkeep` are not
hashed (Godot lists them on Windows but hides them on Linux; found by `tools/verifier_image_check.sh`).

## 3. Data contracts

### 3.1 C# records (`src/Rpg.Contracts/Battle/`)

```csharp
namespace Rpg.Contracts.Battle;

/// <summary>RabbitMQ message on verify.battle. Small on purpose: the worker reads conditions and the log from Postgres.</summary>
public sealed record VerifyBattleJob(string BattleId, Guid RunId, int RunSeq, string RulesetVersion,
    DateTimeOffset SubmittedAt);

/// <summary>Slice 3: the verdict of the replay. Verified or Rejected only; nothing else is a verdict.</summary>
public sealed record BattleVerdict(
    ReplayVerdict Status,                 // Verified | Rejected  (existing enum)
    int? ErrorCode,                       // 2002 when Rejected
    string? Error,                        // "ReplayMismatch" when Rejected
    ReplayMismatch? Mismatch,             // existing record; null when Verified
    BattleOutcome Outcome,                // what the verifier's simulation reached
    int Turns,
    string FinalStateHash,
    string VerifierRulesetVersion,
    string EngineVersion,
    DateTimeOffset VerifiedAt);

// BattleSession.cs, changed:
public enum BattleSessionStatus { Submitted, Verified, Rejected }
public sealed record BattleSessionResponse(string BattleId, string RunId, int RunSeq, BattleSnapshot Conditions,
    ActionLog ActionLog, string RulesetVersion, BattleSessionStatus Status, DateTimeOffset SubmittedAt,
    BattleVerdict? Verdict = null);   // new, last, optional: old JSON still reads
```

`ReplayResult`, `ReplayVerdict`, `ReplayMismatch`, `MismatchReason` and `ReplayErrors` are reused unchanged. A
`BattleVerdict` is built from the runner's `ReplayResult` plus the worker's ruleset version and the commit time. No
game logic enters `Rpg.Contracts`.

Also in `Rpg.Contracts`, as data only: `VerifyTopology` (exchange, queue and header names, and the three `RetryTier`
records with their delays). Behaviour is in the new shared project `src/Rpg.Verification/` (referenced by the API and the
worker): `VerifyMessaging` (declares the topology, builds and parses jobs, publishes with confirm, attempt and trace
headers), `VerifyPolicy` (`TierForAttempt`, the Redis key formats) and `StoredBattle` (the cached session with its owner).

### 3.2 PostgreSQL: `Migrations/0003_battle_verdicts.sql`

```sql
ALTER TABLE battle_sessions
  ADD COLUMN verdict jsonb,                       -- BattleVerdict; set with status Verified/Rejected
  ADD COLUMN verified_at timestamptz,
  ADD COLUMN verifier_version text,               -- the worker's ruleset version
  ADD COLUMN attempts int NOT NULL DEFAULT 0,     -- runner errors + verdicts
  ADD COLUMN enqueued_at timestamptz,             -- last confirmed publish
  ADD COLUMN dead_lettered_at timestamptz,
  ADD COLUMN dead_letter_reason text;
ALTER TABLE battle_sessions ADD CONSTRAINT battle_sessions_status
  CHECK (status IN ('Submitted','Verified','Rejected'));
ALTER TABLE battle_sessions ADD CONSTRAINT battle_sessions_verdict_set
  CHECK ((status = 'Submitted') = (verdict IS NULL));
CREATE INDEX battle_sessions_pending ON battle_sessions (submitted_at)
  WHERE status = 'Submitted' AND dead_lettered_at IS NULL;
```

The `verdict_set` constraint makes "a verdict exists exactly when the status says so" a database fact. **The
idempotency key is the primary key `battle_id` plus the guard `AND status = 'Submitted'`** on the verdict update.
Redelivery or a second worker updates zero rows.

### 3.3 RabbitMQ topology (declared by both API and worker, idempotently)

| Object | Kind | Arguments |
|---|---|---|
| `rpg.verify` | direct exchange, durable | |
| `verify.battle` | durable queue, bound `rpg.verify` / `battle` | `x-dead-letter-exchange=rpg.verify.dlx`, `x-dead-letter-routing-key=dead` (a message nacked without requeue lands in the DLQ) |
| `verify.battle.retry.5s`, `.30s`, `.120s` | durable queues, bound `rpg.verify` / `retry.5s` etc. | `x-message-ttl` = 5000 / 30000 / 120000; `x-dead-letter-exchange=rpg.verify`, `x-dead-letter-routing-key=battle` (expiry returns the job to the main queue) |
| `rpg.verify.dlx` | direct exchange, durable | |
| `verify.battle.dlq` | durable queue, bound `rpg.verify.dlx` / `dead` | no consumer; inspected by hand or by `tools/` |

One TTL per retry queue (not per-message TTL) so a long delay never blocks a short one at the head. Messages are
persistent (`delivery_mode 2`); the publisher uses confirms. Headers: `x-attempt` (int, default 0), `x-reason` (on
the DLQ), `traceparent`. The consumer uses manual acks; QoS prefetch 1.

### 3.4 Redis

| Key | Value | TTL | Semantics |
|---|---|---|---|
| `battle:verdict:{runId}:{seq}` | `{playerId, session}`: the `BattleSessionResponse` including its verdict, and the run's owner | 30 min | Written by the worker **after** the Postgres commit; read by the endpoint first (in one `MGET` with the session key). Never the source of truth: a miss, a Redis error or an entry that cannot be read (another build wrote it) falls back to Postgres and the fill replaces it (scenario 4). |
| `battle:session:{runId}:{seq}` | as in Part B | 30 min (10 s while Submitted) | The worker deletes it after the commit so a stale `Submitted` copy cannot outlive the verdict; a reader that loaded Submitted from Postgres does not write it back once the verdict key exists. |
| `lock:battle:{battleId}` | worker token | 120 s (> `Verifier:ProcessTimeout`) | `SET NX PX`, released with a compare-and-delete Lua script. **Deduplication only**: it saves a second worker from wasting a Godot run. Correctness never depends on it: if the lock is lost or Redis is down, both workers may replay and the conditional update still lets exactly one verdict win. The worker's Redis calls time out after 1 s so a Redis outage cannot stall a consumer. **Open:** a killed worker's lock lasts its full TTL (section 8). |

### 3.5 HTTP

| Endpoint | Change |
|---|---|
| `GET /api/v1/runs/{runId}/battles/{seq}` | Response gains `Verdict`; `Status` can be `Verified` / `Rejected`. 200 even for Rejected. |
| `POST /api/v1/runs/{runId}/actions` | Unchanged request/response. A re-uploaded identical battle changes nothing and enqueues nothing new (the row exists; the sweeper covers a missed publish). |

No new ApiErrors codes. 2002 appears only in `BattleVerdict`.

### 3.6 Configuration

`RabbitMq:Uri` (exists). Section `Verifier`, worker: `Concurrency` (2), `ProcessTimeout` (60 s), `MaxAttempts` (5),
`GodotPath`, `ProjectPath`, `ContentRoot` (empty = the runner's `res://content/`; e2e on fixtures sets
`res://tests/fixtures/`), `QuitAfterFrames` (200000, the headless safeguard), `AcceptedRulesets` (default: own),
`RulesetVersion` (empty = ask Godot at startup; tests and e2e set it), `LockTtl` (120 s), `ShutdownGrace` (70 s),
`UseLock` (tests only: false skips the lock). API: `SweepInterval` (10 s), `SweepGrace` (30 s), `RepublishAfter`
(10 min), `SweepBatch` (100). Both get `ConnectionStrings` for Postgres and Redis like the API; the worker's
`Urls` default is `http://127.0.0.1:5100`.

### 3.7 Packaging

- `src/Rpg.VerifierWorker/`: Worker Service (web SDK for `/metrics` and the health endpoints), references `Rpg.Contracts` and
  `Rpg.Verification` (no game logic; it shells out to Godot). Added to `Rpg.slnx`, with `Rpg.Verification` and
  `tests/Rpg.VerifierWorker.Tests`.
- `infra/verifier/Dockerfile`: the .NET 10 runtime plus pinned Godot 4.7.2 .NET (linux headless) plus the
  `client-godot/` project, imported at build time (`--import`, bounded, and the build fails unless the class cache
  exists). Proven by `tools/verifier_image_check.sh`. A root `.dockerignore` keeps `.git`, `bin`, `obj` and `build` out of
  the context. `docker-compose.yml` gains a `verifier` service under a `workers` profile (`stop_grace_period` 100 s).
- `infra/prometheus/prometheus.yml` scrapes the worker's `/metrics` (port 5100); `infra/grafana/provisioning/dashboards/`
  provisions the "Battle verification" dashboard.

## 4. Failure modes

| # | Failure | Behaviour | Test |
|---|---|---|---|
| F1 | Same battle uploaded twice | One `battle_sessions` row (Part B); at most one extra job; one verdict | `Upload_SameBattleAgain_PublishesNothingNew`, `SameJobTwice_OneVerdict_TheSecondIsADuplicate` |
| F2 | Two workers get the same job at once (lock lost, Redis down) | Both may replay; the guarded update lets one win, the other updates zero rows and acks. **Scenario 1** | `ConcurrentWorkers_WithoutTheLock_StillOneVerdict`, `LockHeldByAnotherWorker_RetriesSoonWithoutCountingAnAttempt` |
| F3 | Worker dies after the commit, before the ack | Redelivery finds `status ≠ Submitted`, acks. No second verdict, no second cache write needed. **Scenario 2, verdict half** | `CrashAfterTheCommit_TheRedeliveredJobIsANoOp`, `ADeliveryTheFirstWorkerNeverAcked_IsRedeliveredAndFoundDone` (a real unacked delivery returned by the broker) |
| F4 | Worker dies during the replay | Unacked → redelivered by RabbitMQ; replay is deterministic and side-effect free, so it just runs again. The dead worker's `lock:battle` outlives it (section 8) | e2e `verify_worker_kill` (the worker is killed only once a job is unacked); no automated .NET test |
| F5 | Tampered log or conditions | Godot exits 2; verdict `Rejected`, `errorCode` 2002, `ReplayMismatch`, the `MismatchReason`. Not retried (a rejection is a verdict, not an error). **Scenario 5** | `Rejected_IsAVerdict2002_NotRetried` (four reasons, fake runner); `GetBattle_SubmittedVerifiedRejected_ShowTheVerdict_AndARejectionIs200`; real Godot: e2e `verify_tampered` and the image check over the committed tampered goldens |
| F6 | Godot runner error (exit 1, crash, timeout, no result file) | `attempts + 1`, retry on tier 5 s / 30 s / 120 s; at `MaxAttempts` → DLQ with `dead_lettered_at` and reason, session stays `Submitted`, the sweeper skips it. **A malformed request also lands here (section 8)** | `RunnerErrors_RetryOnTheTiers_ThenDeadLetterAtTheLimit`, `ARunnerError_GoesToTheShortestRetryQueue_AndComesBackAfterItsDelay`, `APermanentlyFailingJob_EndsInTheDeadLetterQueueWithItsReason`, `EverythingElse_IsARunnerError_NeverAVerdict` |
| F7 | Godot hangs | The process tree is killed at `ProcessTimeout`, counted as F6 | `AHangingReplay_IsKilledWithItsProcessTree_AtTheTimeout`, `ARunnerThatTimesOutOrThrows_IsARunnerError` |
| F8 | Poison message (undeserialisable job, unknown battle id) | Straight to the DLQ with a reason; acked | `UnknownBattle_IsPoison`, `APoisonMessage_GoesToTheDeadLetterQueue_AndIsAcked` |
| F9 | Wrong ruleset | DLQ with `reason=ruleset`, session marked `dead_lettered_at` and stays `Submitted`, counted (2.5) | `WrongRuleset_DeadLettersAndLeavesTheSessionSubmitted`, `AJobForAnotherRuleset_GoesToTheDeadLetterQueue`, `AcceptedRulesets_WidenWhatTheWorkerVerifies` |
| F10 | Redis flushed or down | No lock (verification still correct), no cache writes (counted), the endpoint reads Postgres. **Scenario 4** | `GetBattle_RedisFlushed_IsServedFromPostgres`, `RedisDown_StillVerifies_AndCountsTheErrors`, `AFlushedRedis_ChangesNothingForTheVerdict`; e2e `verify_redis_flush` |
| F11 | RabbitMQ down at upload | The upload still succeeds (200, committed); the fast path logs and counts `result=failed`; the sweeper publishes once the broker is back | `Upload_BrokerDown_StillStores_AndTheSweeperFailsQuietly`, `Sweeper_PublishesAJobWhoseFastPathWasLost` |
| F12 | Postgres down at verdict time | Nothing decided → retry on the 30 s tier without counting an attempt; the verdict is recomputed later | `PostgresDown_PostponesWithoutCountingAnAttempt` |
| F13 | Publish lost between commit and fast path (API crash) | `enqueued_at IS NULL` past `SweepGrace` → the sweeper republishes | `Sweeper_PublishesAJobWhoseFastPathWasLost`, `Sweeper_RepublishesAfterTheWindow_AndSkipsVerifiedAndDeadLettered`, `Sweeper_LeavesAYoungSessionToTheUploadsOwnPublish`, `Sweeper_TwoInstancesAtOnce_NeverPublishTheSameRowTwice` |
| F14 | Stale cached `Submitted` after the verdict | The worker deletes `battle:session` after the commit; a Submitted reader cannot write its copy back over the verdict; Submitted copies live 10 s at most | `GetBattle_AfterTheVerdict_NeverReturnsAStaleSubmittedCopy`, `GetBattle_ASubmittedReaderCannotWriteItsCopyBackOverAVerdict`, `GetBattle_Verdict_IsCachedForThirtyMinutes_AndSubmittedForTenSeconds` |
| F15 | A backlog older than `RepublishAfter` | The sweeper does not republish jobs that may still be queued; it recovers a lost one once the queues are empty; a job being replayed carries a renewed lease; an unreachable broker counts as waiting | `Sweeper_DuringABacklog_NeverDoublesAJobThatIsStillQueued_ButRecoversALostOneOnceTheQueuesAreEmpty`, `Sweeper_AJobWithAFreshLease_IsLeftAloneEvenWhenTheQueuesAreEmpty`, `Sweeper_WhenTheBrokerCannotBeAsked_RepublishesNothingStale`, `ATakenJob_RenewsItsLease_SoTheSweeperNeverSeesItAsLost` |
| F16 | Sweep publish fails, throws or is cancelled | The leases of everything unpublished are given back at once | `Sweeper_AFailedPublish_GivesTheLeaseBack`, `Sweeper_APublishThatThrows_GivesTheLeasesBack`, `Sweeper_DoesNotHoldRowLocksWhilePublishing` |
| F17 | Unexpected exception, or a permanent SQL error | Not "Postgres is down": nack to the DLQ and mark the session `dead_lettered_at`, reason `error` (the sweeper would otherwise republish it for ever) | `AnUnexpectedFailure_DeadLettersTheJob_AndMarksTheSessionSoTheSweeperLeavesItAlone`, `APermanentSqlError_IsNotTreatedAsPostgresBeingDown` |
| F18 | Failure after the commit (cache, metrics, building the cached session) | Best effort only; the decision stays `verified`/`rejected`, never a dead letter | `AFailureAfterTheCommit_NeverChangesTheDecision` |
| F19 | The republish or the ack fails (broker trouble) | The delivery is nacked with requeue after 1 s, so the consumer is never left stuck | `AFailedSettle_RequeuesTheDelivery_SoTheConsumerIsNotLeftStuck` |
| F20 | The broker connection or a consumer channel is lost | `/health/ready` goes false; after recovery true only if every consumer channel is open; the consumers come back | `Readiness_FollowsTheBrokerConnection_AndTheConsumersComeBack` |
| F21 | A cache entry that cannot be read (another build wrote it) | A miss: Postgres answers (not a 500) and the fill replaces the entry | `GetBattle_ACacheEntryThatCannotBeRead_IsAMiss_NotA500` |

**Idempotency summary:** the verdict write is `UPDATE … WHERE status = 'Submitted'`; the queue is at-least-once; the
lock is an optimisation. **Dead letters** are never retried automatically (the sweeper skips them); a human or a
future tool requeues with `UPDATE … SET dead_lettered_at = NULL, attempts = 0` and the sweeper picks them up.

## 5. Observability

Prometheus names follow the existing convention (`rpg_*` from OpenTelemetry meters; counters gain `_total`). Labels are
bounded enums only; **never** battle, run, player, character, ability or encounter ids as labels.

| Metric | Type | Labels | Where |
|---|---|---|---|
| `rpg_verify_jobs_published_total` | counter | `source` = `upload`\|`sweeper`, `result` = `ok`\|`failed` | API |
| `rpg_verify_jobs_total` | counter | `result` = `verified`\|`rejected`\|`duplicate`\|`retry`\|`dead_lettered`\|`wrong_ruleset`\|`lock_busy` | worker |
| `rpg_battle_rejections_total` | counter | `reason` = a `MismatchReason` (9 values) | worker |
| `rpg_verify_replay_duration_seconds` | histogram | `result` = `verified`\|`rejected`\|`error` (Godot process time) | worker |
| `rpg_verify_godot_cpu_time_seconds` | histogram | `result` (CPU time of one Godot process, polled every 200 ms while it runs, so a run can be under-counted by its last 200 ms) | worker |
| `rpg_verify_godot_peak_memory_bytes` | histogram | `result` (peak working set of one Godot process) | worker |
| `rpg_verify_latency_seconds` | histogram | none (submitted → verdict committed; buckets 1 s … 15 min) | worker |
| `rpg_verify_lock_total` | counter | `result` = `acquired`\|`busy`\|`redis_error` | worker |
| `rpg_verify_queue_depth` | gauge | `queue` = `verify.battle`\|`retry`\|`dlq` (passive declare, every `Monitors:Interval`) | API |
| `rpg_battles_unverified` | gauge | none (Postgres count of pending rows) | API monitor |
| `rpg_battle_oldest_unverified_age_seconds` | gauge | none (queue age proxy for scenario 7) | API monitor |
| `rpg_cache_reads_total` | counter | existing labels `entity` (new value `battle_verdict`, next to `battle`) and `source` | API |
| `rpg_cache_errors_total` | counter | existing, `operation` unchanged | API, worker |

Traces: the upload span's context travels in `traceparent`; the worker continues it as `verify.battle`, with child
spans for the Postgres read, the Godot process (attributes: exit code, turns, verdict), and the commit. Structured
logs carry `battleId` and `runId` as log fields (not metric labels). The worker exposes `/metrics`, `/health/live`
and `/health/ready` (ready = the ruleset version is known, the schema is there and the consumers are attached; it
follows connection and channel loss, 2.3). `rpg_verify_queue_depth` is read from RabbitMQ at each `Monitors:Interval`;
the sweeper asks the broker itself at each sweep (2.4).
A Grafana panel set ("Verification": jobs by result, latency, queue depth, DLQ size, rejections by reason) is added to
`infra/grafana/` as part of this slice; the full dashboard work stays in slices 6 and 7.

## 6. Test plan

**Contracts (`tests/Rpg.Contracts.Tests`).**
- Golden JSON for `VerifyBattleJob` and `BattleVerdict` (Verified and Rejected).
- `BattleSessionResponse` still reads old JSON without `Verdict`.
- Purity guard still holds (no new references, no logic).
- The existing cross-check of battle contracts against the Godot golden files also parses a Godot-produced
  `ReplayResult` into `BattleVerdict`.

**API (`tests/Rpg.GameServerApi.Tests`, Testcontainers Postgres, Redis, RabbitMQ; Docker required).**
- Migration 0003 and its constraints: the `verdict_set` and `status` constraints reject a Verified row with no verdict, an
  unknown status and a Submitted row with a verdict. (Not tested: applying 0003 to a database that already holds Part B
  rows; the test migrates a fresh database.)
- Upload publishes one job with the right headers; broker down → upload still 200 → sweeper publishes later (F11, F13).
- `GET` of a Submitted, Verified and Rejected battle; a Rejected one is 200 with `errorCode` 2002 (F5); other
  player's battle is 404 from Redis and Postgres.
- Cache: verdict served from Redis; Redis flushed → from Postgres (F10); no stale Submitted (F14).
- Sweeper skips dead-lettered, young and recently enqueued rows; two instances never publish the same row; a backlog is
  never doubled and a lost job is recovered once the queues are empty; leases come back on a failed, thrown or cancelled
  publish; no row lock is held while publishing.

**Worker (`tests/Rpg.VerifierWorker.Tests`, Testcontainers; the Godot runner behind `IReplayRunner`, a fake returns
canned `ReplayResult`s and exit codes).**
- Every row of section 4 with the fake runner: duplicate job, concurrent workers, crash after commit (kill the
  consumer between commit and ack), runner error → retry tiers → DLQ with the right attempt counts, timeout kills the
  tree, poison message, wrong ruleset, Postgres down, Redis down, lock busy.
- Retry tiers actually delay (queue TTLs set as in 3.3) and return to `verify.battle`.
- Metrics emitted per result; a rejection increments `rpg_battle_rejections_total{reason}`.
- Real-runner adapter: command line, temp files cleaned up, exit-code mapping (0, 2, 1), the process tree killed at the
  timeout and the ruleset version read from stdout only, with a stub script standing in for godot (Windows only).
- Real broker: a delivery the first worker never acked is redelivered; a failed settle is requeued; readiness drops and
  recovers when the broker closes the connections; the queue arguments are the ones in 3.3 (read from the management API).

**Real Godot, golden vectors.**
- `tools/e2e.sh` scenarios (on demand, Docker infra; each scenario has its own RabbitMQ vhost; the worker runs on the host
  with the Windows Godot; `#! worker` starts it with the server, otherwise `e2e worker-start`):
  - `verify_battle`: a real client run (`dev_run --server`) wins; every session becomes Verified with the client's own
    final hash and outcome; the `.sql`, `.metrics` and `.worker-metrics` checks pass.
  - `verify_tampered`: the first battle's stored log is altered after upload (the `tamper-battle` step) while the worker is
    not yet running → Rejected 2002 `FinalHashMismatch`, the others Verified.
  - `verify_worker_kill`: the worker is killed once a job is unacked (`worker-stop`) and restarted; every battle ends with
    exactly one verdict and `attempts = 1`.
  - `verify_redis_flush`: scenario 4 on the verdict path.
  - `verify_demo_content` (`#! content real`): the demo's one-floor run on the real `res://content/`, every battle replayed
    by the worker on the same folders, through `jsonb`, to the client's own hash. (One short run, not all demo content.)
- `tools/verifier_image_check.sh` (on demand): builds `infra/verifier/Dockerfile` and, inside the Linux container, checks
  that the ruleset version equals the Windows build's and that every committed combat golden (18: ten valid and eight
  tampered copies) replays with the Windows-recorded final hash, exit 0 for the valid ones and exit 2 (Rejected 2002)
  for the tampered. This is the cross-platform determinism test; it found the dot-file difference in the ruleset version.
- Godot suite (all against fixtures): `server verdict` / `wait verdict` and the e2e worker steps (`test_e2e_tools`, with
  the fake bridge); the scenario lint knows `#! worker` and `#! content real`; the ruleset version hashes no dot-files
  (`test_server_mode`); and **every golden also replays with all object keys reversed and in Postgres `jsonb`'s key order**
  (`test_golden`), because the worker replays data `jsonb` has reordered: a replay must not depend on key order.

**Done when:** `dotnet build` and `dotnet test` pass, `tools/godot_tests.sh` passes, the five e2e scenarios and the
image check pass, and acceptance scenarios 1, 5, 4 (verdict path) and the verdict half of 2 each have their named test.
(Met on 2026-11-01: 215 .NET tests, 532 Godot tests, 12 of 12 e2e scenarios, the image check.)

**Not covered by an automated test:** F4 (a worker killed during the replay) beyond the on-demand e2e scenario; applying
migration 0003 to a database that already holds Part B rows; the `traceparent` from the upload to the worker's span.

## 7. Decisions, and what stays out

**Decisions taken (change by editing here)**
1. **Separate C# worker project** (`Rpg.VerifierWorker`) that shells out to Godot per job, instead of a Godot-hosted
   consumer. Keeps RabbitMQ, retries and metrics in C# and Godot to pure replay.
2. **Per-job Godot process.** Simple and isolated; costs a few seconds of startup per battle. A warm Godot per worker
   (a small stdin protocol) is a later optimisation if the load test (slice 8) shows it matters.
3. **Publish-after-commit plus a sweeper** instead of an outbox, because the outbox is slice 4 and will replace it. The
   sweeper never doubles a backlog (2.4).
4. **Verdict columns on `battle_sessions`** rather than a separate verdicts table; one row, one guard.
5. **Rejection has no run-level effect in this slice.** Rolling back to a checkpoint, the stairs gate and the run-end
   verdict are slice 4a. Rewards are not touched (slice 4).
6. **No SignalR push.** The roadmap's "also pushed over SignalR" waits for slice 7; the client polls.
7. **Wrong-ruleset jobs dead-letter** rather than waiting for a matching worker (slice 9 adds routing).

**Out of scope:** settlement and the outbox (4), verifying the *conditions* against the run state and out-of-battle
steps (4a), analytics events (4b), Grafana beyond the verification panels (6), load tests (8), ruleset routing (9).

**Deferred follow-ups:** warm Godot workers; a tool to requeue dead letters; a client results screen for verdicts.

## 8. Open items

1. **A malformed replay request is retried, never rejected. Decided 2026-11-02: fixed in slice 4a (`run-verify`), together
   with what a rejection means for the run; it changes the combat-replay-core contract once, not twice. Not a reward
   risk meanwhile: only `Verified` settles.** If the replay runner refuses the request
   itself (an unknown content id, a bad schema version, an unknown field in an action) it exits 1, which is a runner
   error: the worker retries it five times and dead-letters it, and the session stays `Submitted`, so a tampered request
   of that shape never gets a 2002 verdict (acceptance scenario 5 is met for tampering that the replay can simulate). The
   fix is a distinct exit code or result kind from `ReplayRunner` that the worker turns into a `Rejected` verdict. It
   changes `combat/` and the combat-replay-core contract (a runner error is today "never a verdict").
2. **A killed worker's `lock:battle:{id}` delays its job by up to about 2 minutes (`LockTtl`, 120 s).** The replacement worker
   finds the lock held and retries on the 5 s tier until it expires (seen: `verify_worker_kill` takes about 135 s against
   about 15 s for the other scenarios; the lock wait is not logged, so this is the likely cause, not a confirmed one).
   **Planned for slice 4 (`settlement-outbox`): remove this lock or cut its TTL heavily** (decided 2026-11-01). Until then it
   stays as is; correctness never depends on it (3.4).
3. **Wrong-ruleset jobs have no recovery path** until slice 9 routes by version: they are dead-lettered and the session is
   marked, so neither the sweeper nor a later worker sees them (2.5). A human clears `dead_lettered_at` to requeue.
4. **A message the broker loses while other jobs are still queued** is recovered only once the queues are empty (2.4).
5. **Cost:** every uploaded battle can cost up to 60 s of worker CPU. The upload rate limit and `MaxAttempts` bound it;
   slice 8 measures it.
6. A rejected verdict's `mismatch.detail` shows the claimed and the simulated final hash. A rejected battle cannot be
   resubmitted (battle ids are unique per run), so this teaches a cheating client nothing it cannot simulate itself (the
   known limitation in the root `CLAUDE.md`).
