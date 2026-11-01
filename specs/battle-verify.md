# Spec: battle-verify (slice 3)

Status: 📝 Spec written, awaiting review. Builds on `specs/server-authority.md` (Part B stores every battle as a
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
  API (fast path, best effort, after commit): publish VerifyBattleJob  ──▶ RabbitMQ  verify.battle
        publisher confirm received → UPDATE battle_sessions SET enqueued_at = now()
  ◀── 200 RunActionAck                                    (the upload never waits for a worker)

Verifier worker (N consumers, prefetch 1 each; N = Verifier:Concurrency):
  receive job (header x-attempt, traceparent)
  1. SELECT status, ruleset_version, conditions, action_log FROM battle_sessions WHERE battle_id = @id
       status ≠ Submitted           → ack (duplicate/redelivery; count result=duplicate)
       ruleset_version not accepted → publish to verify.battle.dlq with reason, ack (2.5)
  2. SET lock:battle:{battleId} <workerToken> NX PX 120000          (dedup only, 3.4)
       held by another worker       → publish to retry tier 1 without counting an attempt, ack
       Redis error                  → continue without the lock (count result=redis_error)
  3. write ReplayRequest{conditions, action_log} to a temp dir; start
       godot --headless --path <project> --quit-after <frames> res://combat/headless/replay_main.tscn
             -- --in req.json --out res.json
       killed (process tree) after Verifier:ProcessTimeout (60 s) → runner error
       exit 0 → Verified · exit 2 → Rejected (2002) · exit 1 / timeout / no result file → runner error
  4. verdict (exit 0 or 2):
       one transaction:  UPDATE battle_sessions SET status = 'Verified' | 'Rejected', verdict = @json,
                                verified_at = now(), verifier_version = @v, attempts = attempts + 1
                         WHERE battle_id = @id AND status = 'Submitted'
       rowcount 0 → someone else already wrote the verdict: no-op
       commit
       then (fail-open): DEL battle:session:{runId}:{seq}; SET battle:verdict:{runId}:{seq} <json> EX 1800;
                         DEL run:summary:{runId} is NOT needed (the summary holds no battle verdicts)
       release lock (compare-and-delete Lua)
       ack
  5. runner error: attempts + 1 in Postgres; below Verifier:MaxAttempts (5) → publish to retry tier
       (attempt 1 → 5 s, attempt 2 → 30 s, attempt 3 and later → 120 s), ack;
       at the limit → dlq, set dead_lettered_at, ack
       The delay starts when the worker publishes to the retry queue (the message's TTL runs from its arrival there),
       so a hung replay costs its 60 s timeout first and the wait comes after. When the TTL expires the job returns
       to verify.battle and waits behind any backlog, so the wait is a minimum, not an exact time.
```

The ack always comes **after** the commit (or after the republish to a retry/DLQ queue). If the worker dies between
commit and ack, RabbitMQ redelivers; step 1 finds `status ≠ Submitted` and acks. That is scenario 2's verdict half.

### 2.2 Reading the verdict

```
Godot client / tools ── GET /api/v1/runs/{id}/battles/{seq}   (Bearer)
  Redis battle:verdict:{runId}:{seq} → hit: return it with the cached session
  miss → Redis battle:session:{runId}:{seq} → miss → Postgres (re-cache; a Submitted session is cached with a short
         TTL, 10 s, so polling sees the verdict soon after it lands; a verdict is cached 30 min)
  200 BattleSessionResponse { …, Status, Verdict }       Status Submitted → Verdict null (still pending)
```

Not the owner or no such battle: 404, as today. A **rejected battle is a 200** whose `Verdict` is
`{ status: "Rejected", errorCode: 2002, error: "ReplayMismatch", mismatch: {...} }`; never an HTTP 4xx (root
`CLAUDE.md` error contract). The client polls with backoff (1 s, 2 s, 5 s, capped); slice 3 adds no client UI. A
console command `server verdict [seq]` (and `wait verdict <seq>` for `dev_run`) exists for tests and e2e (tool parity,
`client-godot/CLAUDE.md` section 5).

### 2.3 Worker lifecycle

- Startup: read the project's ruleset version once (`print_ruleset_version.tscn`, 2.5) and keep it; wait until the
  migration history lists `0003_battle_verdicts`; declare the topology (3.3); connect Redis (optional).
- `Verifier:Concurrency` consumers, each prefetch 1, so one process runs at most one Godot at a time per consumer.
- Shutdown: stop consuming, let running jobs finish up to a grace period, nack the rest with requeue.
- A Godot process is started **per job** (a few seconds of engine startup per battle). A warm, long-lived Godot per
  worker is a later optimisation (listed in 7), not needed for correctness.

### 2.4 Interim for the outbox: publish-after-commit plus a sweeper

Publishing to RabbitMQ in the upload's transaction is a dual write. The outbox that fixes this properly is slice 4, so
slice 3 uses a **reconciler** that makes the same guarantee (no battle stays unverified because a publish was lost):

- The upload path publishes after the commit (fast path above). A crash or broker outage between commit and publish
  loses only the fast path.
- `BattleVerifyDispatcher` (a `BackgroundService` in the API, every `Verifier:SweepInterval`, 10 s) selects up to 100
  rows `WHERE status = 'Submitted' AND dead_lettered_at IS NULL AND (enqueued_at IS NULL OR enqueued_at < now() -
  Verifier:RepublishAfter)` (default 120 s) `FOR UPDATE SKIP LOCKED`, publishes each with confirm, sets `enqueued_at`.
  Several API instances therefore never publish the same row twice at once (and a duplicate job is harmless anyway).
- Slice 4 replaces both paths with an outbox row written in the upload transaction and relayed to RabbitMQ.

### 2.5 Ruleset version (groundwork for scenario 6)

Each job and each session carries `ruleset_version`. The worker holds exactly one version (its own project's). A job
whose version is not in `Verifier:AcceptedRulesets` (default: the worker's own) goes to `verify.battle.dlq` with
`reason = ruleset`, is counted as `result=wrong_ruleset`, and the session stays `Submitted`. Routing to a worker
pool of the matching version is slice 9; slice 3 only makes the mismatch visible and loses nothing.

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
| `battle:verdict:{runId}:{seq}` | `{playerId, session}`: the `BattleSessionResponse` including its verdict, and the run's owner | 30 min | Written by the worker **after** the Postgres commit; read by the endpoint first. Never the source of truth: a miss or Redis error falls back to Postgres (scenario 4). |
| `battle:session:{runId}:{seq}` | as in Part B | 30 min (10 s while Submitted) | The worker deletes it after the commit so a stale `Submitted` copy cannot outlive the verdict. |
| `lock:battle:{battleId}` | worker token | 120 s (> `Verifier:ProcessTimeout`) | `SET NX PX`, released with a compare-and-delete Lua script. **Deduplication only**: it saves a second worker from wasting a Godot run. Correctness never depends on it: if the lock is lost or Redis is down, both workers may replay and the conditional update still lets exactly one verdict win. |

### 3.5 HTTP

| Endpoint | Change |
|---|---|
| `GET /api/v1/runs/{runId}/battles/{seq}` | Response gains `Verdict`; `Status` can be `Verified` / `Rejected`. 200 even for Rejected. |
| `POST /api/v1/runs/{runId}/actions` | Unchanged request/response. A re-uploaded identical battle changes nothing and enqueues nothing new (the row exists; the sweeper covers a missed publish). |

No new ApiErrors codes. 2002 appears only in `BattleVerdict`.

### 3.6 Configuration

`RabbitMq:Uri` (exists). New: `Verifier:Concurrency` (default 2), `Verifier:ProcessTimeout` (60 s),
`Verifier:MaxAttempts` (5), `Verifier:GodotPath`, `Verifier:ProjectPath`, `Verifier:AcceptedRulesets`
(default: own), `Verifier:SweepInterval` (10 s), `Verifier:RepublishAfter` (120 s). The worker gets `ConnectionStrings`
for Postgres and the Redis connection like the API.

### 3.7 Packaging

- `src/Rpg.VerifierWorker/`: Worker Service, references `Rpg.Contracts` only (no game logic; it shells out to Godot).
  Added to `Rpg.slnx`.
- `infra/verifier/Dockerfile`: the .NET 10 runtime plus pinned Godot 4.7.2 .NET (linux headless) plus the
  `client-godot/` project, imported at build time. `docker-compose.yml` gains a `verifier` service under a
  `workers` profile.
- `infra/prometheus/prometheus.yml` scrapes the worker's `/metrics`.

## 4. Failure modes

| # | Failure | Behaviour | Test |
|---|---|---|---|
| F1 | Same battle uploaded twice | One `battle_sessions` row (Part B); at most one extra job; one verdict | `Upload_DuplicateBattle_OneSession`, `Verify_SameJobTwice_OneVerdict` |
| F2 | Two workers get the same job at once (lock lost, Redis down) | Both may replay; the guarded update lets one win, the other updates zero rows and acks. **Scenario 1** | `Verify_ConcurrentWorkers_OneVerdict` (lock disabled), `Verify_LockBusy_RetriesWithoutAttempt` |
| F3 | Worker dies after the commit, before the ack | Redelivery finds `status ≠ Submitted`, acks. No second verdict, no second cache write needed. **Scenario 2, verdict half** | `Verify_CrashAfterCommit_RedeliveryIsNoOp` (fake runner, kill between commit and ack) |
| F4 | Worker dies during the replay | Unacked → redelivered by RabbitMQ; replay is deterministic and side-effect free, so it just runs again | `Verify_CrashDuringReplay_Redelivered` |
| F5 | Tampered log or conditions | Godot exits 2; verdict `Rejected`, `errorCode` 2002, `ReplayMismatch`, the `MismatchReason`. Not retried (a rejection is a verdict, not an error). **Scenario 5** | `Verify_Tampered_Rejected2002` over the committed tampered goldens (target, turn, final hash, outcome, skipped turn, dropped Auto entry); the GET returns 200 |
| F6 | Godot runner error (exit 1, crash, timeout, no result file) | `attempts + 1`, retry on tier 5 s / 30 s / 120 s; at `MaxAttempts` → DLQ with `dead_lettered_at` and reason, session stays `Submitted`, the sweeper skips it | `Verify_RunnerError_RetriesThenDeadLetters` |
| F7 | Godot hangs | The process tree is killed at `ProcessTimeout`, counted as F6 | `Verify_Timeout_KillsProcessTree` |
| F8 | Poison message (undeserialisable job, unknown battle id) | Straight to the DLQ with a reason; acked | `Verify_PoisonMessage_DeadLettered` |
| F9 | Wrong ruleset | DLQ with `reason=ruleset`, session stays `Submitted`, counted (2.5) | `Verify_WrongRuleset_DeadLettered` |
| F10 | Redis flushed or down | No lock (verification still correct), no cache writes (counted), the endpoint reads Postgres. **Scenario 4** | `GetBattle_RedisFlushed_ServedFromPostgres`, `Verify_RedisDown_StillVerifies`; e2e `verify_redis_flush` |
| F11 | RabbitMQ down at upload | The upload still succeeds (200, committed); the fast path logs and counts `result=failed`; the sweeper publishes once the broker is back | `Upload_BrokerDown_SweeperPublishesLater` |
| F12 | Postgres down at verdict time | Commit fails → nack to retry tier without counting; the verdict is recomputed later | `Verify_PostgresDown_RetriesLater` |
| F13 | Publish lost between commit and fast path (API crash) | `enqueued_at IS NULL` → the sweeper republishes after `RepublishAfter` | `Sweeper_PublishesUnenqueued`, `Sweeper_SkipsDeadLettered` |
| F14 | Stale cached `Submitted` after the verdict | The worker deletes `battle:session` after the commit; Submitted copies live 10 s at most | `GetBattle_AfterVerdict_NeverReturnsStaleSubmitted` |

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
| `rpg_verify_latency_seconds` | histogram | none (submitted → verdict committed; buckets 1 s … 15 min) | worker |
| `rpg_verify_lock_total` | counter | `result` = `acquired`\|`busy`\|`redis_error` | worker |
| `rpg_verify_queue_depth` | gauge | `queue` = `verify.battle`\|`retry`\|`dlq` (passive declare, every `Monitors:Interval`) | API |
| `rpg_battles_unverified` | gauge | none (Postgres count of pending rows) | API monitor |
| `rpg_battle_oldest_unverified_age_seconds` | gauge | none (queue age proxy for scenario 7) | API monitor |
| `rpg_cache_reads_total` | counter | existing, new `cache="battle_verdict"` | API |
| `rpg_cache_errors_total` | counter | existing, `operation` unchanged | API, worker |

Traces: the upload span's context travels in `traceparent`; the worker continues it as `verify.battle`, with child
spans for the Postgres read, the Godot process (attributes: exit code, turns, verdict), and the commit. Structured
logs carry `battleId` and `runId` as log fields (not metric labels). The worker exposes `/metrics`, `/health/live`
and `/health/ready` (ready = RabbitMQ and Postgres reachable, Godot path exists).
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
- Migration 0003 applies on a database that already has Part B rows; the `verdict_set` constraint rejects a
  Verified row with no verdict.
- Upload publishes one job with the right headers; broker down → upload still 200 → sweeper publishes later (F11, F13).
- `GET` of a Submitted, Verified and Rejected battle; a Rejected one is 200 with `errorCode` 2002 (F5); other
  player's battle is 404 from Redis and Postgres.
- Cache: verdict served from Redis; Redis flushed → from Postgres (F10); no stale Submitted (F14).
- Sweeper skips dead-lettered and recently enqueued rows; uses `SKIP LOCKED` with two instances.

**Worker (`tests/Rpg.VerifierWorker.Tests`, Testcontainers; the Godot runner behind `IReplayRunner`, a fake returns
canned `ReplayResult`s and exit codes).**
- Every row of section 4 with the fake runner: duplicate job, concurrent workers, crash after commit (kill the
  consumer between commit and ack), runner error → retry tiers → DLQ with the right attempt counts, timeout kills the
  tree, poison message, wrong ruleset, Postgres down, Redis down, lock busy.
- Retry tiers actually delay (queue TTLs set as in 3.3) and return to `verify.battle`.
- Metrics emitted per result; a rejection increments `rpg_battle_rejections_total{reason}`.
- Real-runner adapter: command line, temp files cleaned up, exit-code mapping (0, 2, 1), with a stub executable.

**Real Godot, golden vectors.**
- `tools/e2e.sh` scenarios (on demand, Docker infra, worker started on the host with the Windows Godot):
  - `verify_battle`: a real client run (`dev_run --server`) wins a battle; the session becomes Verified; verdict in the
    endpoint and the `.sql` check; metrics file lists the job result.
  - `verify_tampered`: a battle whose log was altered after upload (the e2e control folder gets a
    `tamper-battle` step that edits the stored log in Postgres) → Rejected 2002 with a `MismatchReason`.
  - `verify_worker_kill`: the worker is stopped mid-queue and restarted; every battle ends with exactly one verdict.
  - `verify_redis_flush`: scenario 4 on the verdict path.
- `tools/verifier_image_check.sh` (on demand): builds `infra/verifier/Dockerfile` and verifies every committed
  combat golden and all six tampered copies in the Linux container, **expecting Verified for the goldens and
  Rejected 2002 for the tampered ones**. This is the cross-platform determinism test: the goldens were recorded on
  Windows, and the fixed-point rules (`client-godot/CLAUDE.md` section 3) exist so they pass on Linux too. The worker's
  ruleset version must equal the Windows build's version for the same source.
- Godot suite: no change expected; the runner and `replay_main` are already covered. If the worker needs a flag or
  output field the runner lacks, it gets a Godot test first.

**Done when:** `dotnet build` and `dotnet test` pass, `tools/godot_tests.sh` passes, the four e2e scenarios and the
image check pass, and acceptance scenarios 1, 5, 4 (verdict path) and the verdict half of 2 each have their named test.

## 7. Decisions to confirm, and what stays out

**Decisions I made that you may want to change**
1. **Separate C# worker project** (`Rpg.VerifierWorker`) that shells out to Godot per job, instead of a Godot-hosted
   consumer. Keeps RabbitMQ, retries and metrics in C# and Godot to pure replay.
2. **Per-job Godot process.** Simple and isolated; costs a few seconds of startup per battle. A warm Godot per worker
   (a small stdin protocol) is a later optimisation if the load test (slice 8) shows it matters.
3. **Publish-after-commit plus a sweeper** instead of an outbox, because the outbox is slice 4 and will replace it.
4. **Verdict columns on `battle_sessions`** rather than a separate verdicts table; one row, one guard.
5. **Rejection has no run-level effect in this slice.** Rolling back to a checkpoint, the stairs gate and the run-end
   verdict are slice 4a. Rewards are not touched (slice 4).
6. **No SignalR push.** The roadmap's "also pushed over SignalR" waits for slice 7; the client polls.
7. **Wrong-ruleset jobs dead-letter** rather than waiting for a matching worker (slice 9 adds routing).

**Out of scope:** settlement and the outbox (4), verifying the *conditions* against the run state and out-of-battle
steps (4a), analytics events (4b), Grafana beyond the verification panels (6), load tests (8), ruleset routing (9).

**Deferred follow-ups:** warm Godot workers; a tool to requeue dead letters; a client results screen for verdicts.
