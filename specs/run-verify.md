# Spec: run-verify (slice 4a)

Status: ✅ Built and synced (2026-11-08): 416 .NET tests, 582 Godot tests, the e2e scenarios and the Linux golden check pass.
Decisions taken while building are folded in below; the main ones: the stairs gate is on the floor just played, the run hash
covers the whole snapshot, completion marks are claimed at release, and the per-battle worker (`verify.battle`) was removed
(legacy runs are never verified). Builds on `specs/server-authority.md` (Part B stores the run's
action log, claimed snapshots and battle sessions), `specs/battle-verify.md` (the verifier worker, `verify.battle`),
`specs/settlement-outbox.md` (the outbox, boss settlement, `wallet_ledger`) and `specs/economy-challenges.md` (marks per
cycle). Roadmap entry: "4a. `run-verify`". Design intent: `specs/roadmap.md` "Run authority model".

## 1. Purpose & enterprise mapping

**Purpose.** Slice 3 verifies each *battle*. Nothing yet verifies the rest of a run: entering rooms, picks, purchases,
events, chests, gear, the stairs, and whether the claimed *conditions* of a battle are what the run state produces at
that point. Slice 4a verifies **whole runs** from the action log:

1. The log is cut into **steps** at the claimed snapshots (the checkpoints of `server-authority` 2.2). Each step starts
   from the snapshot the client claimed, is replayed in headless Godot on its own job, and gets a verdict. All steps of a
   floor run **in parallel**.
2. A C# **fan-in aggregator** (a process manager with its state in Postgres) checks the **links** (a step's verified end
   state is the next step's claimed start state), advances the run's **verified prefix**, and emits `FloorVerified`.
3. The **stairs gate** (`1107`) means the client never enters floor n+1 before floor n is verified.
4. The **run-end verdict** replaces `Run:AutoApproveWins`: a won run becomes `Won` only when every step and link up to
   the end is verified.
5. A rejected step or a broken link **rolls the run back** to the last verified checkpoint and writes an anti-cheat
   event through the outbox. The client resumes from the server.
6. **Pending gems** (decided 2026-11-02): slice 4's grants start `pending`, are released when the battle's step is
   verified and linked, and are voided (with an event) on rollback.
7. **A battle is replayed once.** The battle step's replay produces both the post-battle run state and the battle's
   `ReplayResult` (outcome, final hash, `BattleFacts`). The step worker commits the step verdict, the battle verdict
   and the settlement together. There is no separate per-battle job any more (2.1).
8. **Malformed replay requests are rejected** (decided 2026-11-02, `battle-verify` 8.1): a request the runner refuses
   gets a distinct exit code and a `Rejected` 2002 verdict at once, for battles and steps.

**Components used** (from `README.md`):

| Component | Role in this slice | Enterprise analogue |
|---|---|---|
| RabbitMQ | `verify.segment` work queue (retry tiers, DLQ); the one worker pool (the `verify.battle` queue of slice 3 is no longer used) | Work queue per workload class, pools sized separately |
| Verifier worker (`Rpg.VerifierWorker`) | Replays a step in headless Godot; commits the verdict and runs the aggregator in the same transaction. Its only consumer (the per-battle role was removed) | Versioned calculation worker |
| Headless Godot 4.7.2 .NET | New `game/verify/step_main.tscn` (a `RunController` with no screens, the same `RunWire.apply` the resume tail uses) | The calculation engine the worker hosts |
| PostgreSQL | `run_steps`, `runs.verified_seq` / `epoch`, voided-action archive, `wallet_ledger.status`; the aggregator's state and its transactional guard | Process-manager state, idempotent consumer |
| Outbox → Redpanda | `FloorVerified`, `RunVerified`, `RunRolledBack`, `AntiCheatAlert`, `RewardPending/Voided`; step jobs themselves are outbox rows | Transactional outbox |
| Redis | The **floor read model** (`floor:{runId}:{n}`), the existing caches; never the source of correctness | Read model cache |
| Prometheus / OpenTelemetry | Step, fan-in, gate, rollback and ledger metrics; one trace from upload → step job → verdict → events | GUTS metrics, tracing |

**Not used here:** SignalR push of verdicts (slice 7: the client learns from the upload ack and by polling, 2.6),
analytics projections of the new events (4b), ruleset routing (slice 9: a wrong-ruleset step job is dead-lettered like
a battle job, 4 F9), the unlocked cards (playable characters and the item pool) in the start state (slice 5 adds them to the genesis inputs, 3.3).

**Acceptance scenarios covered:** 1 (duplicate step job → one verdict, one release), 2 (worker killed after the commit,
before the ack → no second aggregation, no second release), 3 (Redpanda down → the new events drain from the outbox),
4 (Redis flushed → the floor read model and caches rebuild), 5 (a tampered run log → `Rejected` 2002 and a rollback),
7 (load spike: step queue age and depth visible). Scenario 6 stays groundwork (the step carries the run's ruleset).

## 2. Sequence flow

### 2.0 Run start: the genesis anchor (decided 2026-11-08)

```
Godot client ── POST /api/v1/runs                                                      (Part A, unchanged for the client)
  API, in the run-start transaction (after the runs and run_floors(0) inserts):
    INSERT run_steps (run_id, epoch 0, step_no 0, from_seq 0, to_seq 1, kind 'genesis', status 'Pending')
    INSERT outbox  (rabbit, topic 'segment', key '{runId}/0/0', VerifyStepJob)
  ◀── 201 {runId, floor 0, floorSeed}                 (no Godot on the request path; nothing waits for the worker)

Verifier worker (role segment): the genesis job
  1. run no longer Active/Verifying (abandoned by a new start, ended) → step 'Voided', ack (result=run_gone; no Godot run)
  2. godot … step_main.tscn with a genesis StepRequest (setup + floor 0 seed only; no snapshot, no actions):
       the server's own starting state: start_server_run(structure, characters, runId, floor 0 seed)
       result: Verified, endHash = its run_hash(), endSnapshot = its RunSnapshot
  3. ONE transaction: UPDATE run_steps (guarded, Pending → Verified, end_hash)
                      UPDATE runs SET genesis_hash = endHash, genesis_snapshot = endSnapshot WHERE genesis_hash IS NULL
                      the aggregator (2.3) runs: if the client's seq 1 is already stored, compare it to the anchor
```
The anchor is **the server's, not a claim**: its inputs are `runs` and `run_floors` only, so nothing the client sends can
change it. It exists before the client uploads anything (normally within seconds of the start). The server stores it
as `runs.genesis_hash` and `runs.genesis_snapshot` (opaque JSON, like every snapshot: stored and returned, never read by
C#). Two things depend on that: the claim check at seq 1 (below) and a resume with no uploads (2.6).

### 2.1 Steps are created by the upload (no game rules in C#)

```
Godot client ── POST /runs/{id}/actions [… a checkpoint action with its snapshot …]         (Part B, unchanged shape)
  API, same transaction as the action insert (under the run row lock):
    for each new row with a snapshot (start_run, the client's battle-pending checkpoints, battle, next_floor):
      p = the previous snapshot-bearing seq of this run (index run_actions_checkpoints); 0 for start_run itself
      INSERT run_steps (run_id, epoch, step_no, from_seq = p, to_seq = this seq, kind, status 'Pending')
      INSERT outbox  (rabbit, topic 'segment', key '{runId}/{epoch}/{step_no}', VerifyStepJob)
    a `battle` action still writes its battle_sessions row (status Submitted) but NO VerifyBattleJob: the step that
      contains it produces the battle's verdict (2.2). Nothing publishes or consumes `verify.battle` any more (the per-battle worker was removed
      in this slice). A run that existed when migration 0007 ran is `legacy`: it gets no steps and no gate, and its battles
      stay `Submitted`, never verified.
  ◀── 200 RunActionAck {lastSeq, epoch, verifiedSeq}
```
The first checkpoint (`start_run`, seq 1) opens no new step: the **genesis step** (`step_no` 0, 2.0) already exists and
only waits for this claim. When the upload stores seq 1, the same transaction calls the aggregator's anchor rule (2.3):
`state_hash` at seq 1 must equal `runs.genesis_hash`. If the anchor is already there, the claim is accepted or rejected
**at the upload** (a mismatch is the run's `Rejected` 2002 verdict, `GenesisMismatch`, not an HTTP error); if not, the
comparison happens when the genesis job commits. Once they agree `verified_seq` is 1, and from then on every rollback
has a verified checkpoint to return to. Step 1 then runs from seq 1 to the first checkpoint, starting from `runs.genesis_snapshot` (the server's own copy), not the client's seq-1 snapshot. Every later step starts at
the previous checkpoint and ends at the next. A step ends at every snapshot-bearing action, so a step is either a **segment** (out-of-battle actions up to the next
checkpoint) or a **battle step** (the pending checkpoint and the `battle` action that follows it). The server cannot
tell a pending-battle checkpoint from any other; it only needs "has a snapshot". A client that leaves out the pending
checkpoint just makes a longer step, which still verifies (bounded by `Verifier:MaxStepActions`, 500: a longer one is
a `400` at upload). The client also attaches a snapshot to the last action of a commit once 100 actions
(`RunWire.CHECKPOINT_EVERY`) have passed since its last one, so an honest step stays short. `kind` = `genesis` for step 0 (made at run start), `battle` when the last action is `battle`, `end` for the end action, else `segment`.

### 2.2 Verifying a step (the `segment` worker)

```
Verifier worker (role segment; prefetch 1 per consumer; Verifier:Segment:Concurrency)
  receive VerifyStepJob(runId, epoch, stepNo, rulesetVersion)           (header x-attempt, traceparent)
  1. SELECT the step, the run (epoch, setup, ruleset) FROM run_steps JOIN runs
       step missing / run.epoch ≠ job epoch   → ack (superseded by a rollback; count result=superseded)
       step.status ≠ 'Pending'                → ack (duplicate/redelivery; result=duplicate)
       ruleset not accepted                   → DLQ reason=ruleset, ack (as battle-verify 2.5)
  2. build StepRequest from Postgres only:
       setup        runs.run_structure_id, runs.character_ids
       floorSeeds   run_floors (the server's seeds, never the client's)
       startState   run_actions.snapshot and state_hash at from_seq (genesis step: none; the job rebuilds the start)
       actions      run_actions.action for from_seq+1 … to_seq (battle bodies put back from battle_sessions)
       claimedEnd   the state_hash at to_seq, and for `end` the RunEndRequest hash
  3. godot --headless … res://game/verify/step_main.tscn  --request <file> --result <file>
       exit 0 Verified · 2 Rejected (2002) · 3 Malformed (a Rejected verdict, but only when the runner's own result says
            MalformedRequest; a bare 3 is a runner error) · 1 runner error (retry tiers)
  4. ONE transaction:
       UPDATE run_steps SET status, verdict, start_hash, end_hash, floor_digest WHERE … AND status = 'Pending' AND epoch = @e
         0 rows → ack (lost the race)                                          (the guard is the idempotency key)
       for each battle in the step: the guarded battle_sessions verdict update (WHERE status = 'Submitted'), then the
         slice 4/4c settlement (pending ledger rows, BattleVerified/Rejected/RewardPending outbox rows; the
         completion mark is only looked at, it is claimed at release, 2.5) exactly as the battle worker did, from the ReplayResult the same Godot run returned
       the aggregator (2.3) runs inside this transaction
       outbox rows for what the aggregator decided
  5. COMMIT; DEL run:summary:{runId}; write floor:{runId}:{n} if a floor became verified; ack RabbitMQ
```
What `step_main` does (the only place game rules run): it restores the **start snapshot** into a `RunController` with
no screens and no queue, applies each wire action through `RunWire.apply` (a `battle` action replays the logged battle
through the verifier's `ReplayController`), and checks, in this order (the first failure is the verdict):

| Check | Reject reason |
|---|---|
| Request shape, schema versions, content ids known | `MalformedRequest` (exit 3) |
| Kind `genesis` (2.0): rebuild the start from the setup and floor 0's seed (`start_server_run`) and return its hash and snapshot. There is no claim to check here: comparing it with the client's seq 1 is the aggregator's rule (2.3) | none; a failure is a runner error (retry), not a verdict |
| Any other step: the restored start snapshot's `run_hash()` equals the `stateHash` stored at `from_seq` | `SnapshotHashMismatch` |
| The snapshot's floor seeds equal the server's `floorSeeds` (the request's), and its run id and setup match the run | `ForeignSeed` / `WrongSetup` |
| Each action: the run accepts it (legal, in stock, key present, adjacent …) | `ActionRefused` (seq, the run's reason) |
| A `battle` action: the pending battle's `battle_snapshot()` equals the claimed `conditions` (canonical JSON) **and** the replayed outcome and final hash equal the claim | `ConditionsMismatch` / `BattleMismatch` |
| After each action: `run_hash()` equals the claimed `stateHash` | `StateHashMismatch` (seq) |
| `end` (Won): the run is actually won and `run_hash()` equals the `RunEndRequest.RunHash` | `NotWon` / `StateHashMismatch` |

A step that contains a battle returns, per battle, the `ReplayResult` the replay produced (the same code as
`replay_main`, so a battle's verdict and facts are identical to what slice 3 gave). A battle that mismatches rejects the
step (`BattleMismatch`) and its session is `Rejected` 2002 with the battle's own `MismatchReason`.
A Verified result returns the step's `startHash` (computed from the restored start), `endHash` (computed after the last
action), the battle conditions checks it passed (the battle ids, for pending gems), and, when the step entered a floor,
that floor's **digest** (floor hash, room → role, encounter id, offers: the floor read model, 3.5).

### 2.3 Fan-in aggregator (inside the step verdict transaction)

A C# class `RunAggregator` in `Rpg.Economy` (it releases gems; no game logic; it compares strings and numbers). It is called by the
worker after every step verdict and is a pure function of table state, so running it twice changes nothing.

```
SELECT * FROM runs WHERE run_id = @r FOR UPDATE            (aggregators of one run serialize; different runs don't)
if run.epoch ≠ the step's epoch → return                   (a rollback happened since)
anchor rule (also run by the upload that stores seq 1):
   genesis step Verified (genesis_hash set) and run_actions seq 1 stored:
      state_hash(seq 1) ≠ genesis_hash          → REJECT THE RUN reason=GenesisMismatch (terminal, 2.4)
      equal                                     → verified_seq = 1 (the genesis step is done)
   either side missing                          → wait
loop k = the step after the one containing verified_seq (steps 1, 2, …):
   step k not yet decided                       → stop (wait)
   step k Rejected                              → ROLLBACK (2.4), stop
   step(k-1).end_hash ≠ step(k).start_hash      → ROLLBACK reason=LinkBroken (blames step k), stop
                                                  (for step 1 the left side is the genesis step's end_hash = genesis_hash)
   else UPDATE runs SET verified_seq = step(k).to_seq WHERE verified_seq < step(k).to_seq     (monotone)
        for each floor f with end_seq ≤ verified_seq and verified_at IS NULL:
            UPDATE run_floors SET verified_at = now(), digest; outbox FloorVerified(playerId key)
        release pending ledger rows for battles with run_seq ≤ verified_seq (2.5)
the last floor has no `next_floor` action: it is verified together with the win, when the end step is verified
if run.status = 'Verifying' and verified_seq = run.end_seq:
   UPDATE runs SET status = 'Won', ended_at = now(); outbox RunVerified
```
Links are string comparisons of two hashes that the *worker's Godot* computed (end of step k-1, start of step k): the
claimed hashes only select which snapshot to start from. **Link strength equals `run_hash` coverage.** The
run hash (`run-v2`) covers the whole snapshot through `StateHasher.canonical` (every map cell field, the open event, gifts, the
pending battle, the floor waiting for its seed, the reveal flags). Only the run id, the seeds of floors not entered yet,
`devCommands`, `map.attempts` and the log, tallies and requested floors are left out, and `test_snapshot_fields_are_covered`
changes every leaf of a snapshot to prove it (6, G4). So the next step's check of its restored start against the hash
claimed by the previous step binds the claimed snapshot to the replay; there is no separate snapshot comparison.

### 2.4 Rejection and rollback

One step Rejected (or a link broken, or a step dead-lettered at `MaxAttempts`: that one does not roll back, 4 F8):

```
ONE transaction, run row locked:
  rollback_to = runs.verified_seq                 (always a verified checkpoint seq; never 0, see below)
  INSERT run_actions_voided / battle_sessions_voided  SELECT … WHERE seq > rollback_to    then DELETE them
        (the archive keeps the claimed log for review; deleting frees the deterministic battle ids)
  run_steps with to_seq > rollback_to → status 'Voided' (kept; the epoch makes them history)
  wallet_ledger rows of voided battles → 'voided' (their idempotency key renamed `…#voided:{id}` so a replay can pay again);
    a pending row holds no completion mark, so none is deleted; the wallet is unchanged
  runs: epoch += 1, last_seq = rollback_to, rollbacks += 1, status = 'Active' (a Verifying run goes back to Active)
        if rollbacks > Verify:MaxRollbacks (3) (a GenesisMismatch never reaches this rollback: the anchor rule rejects the run directly, 2.3):
          status = 'Rejected', ended_at set  (terminal: the voided tail never pays; what was verified before it stays paid)
  run_floors with floor beyond the checkpoint's floor: verified_at stays null; the seeds stay (same floor, same seed)
  outbox: RunRolledBack(reason, stepNo, fromSeq, toSeq, rollbackTo) + AntiCheatAlert(kind) on the security topic
  DEL run:summary:{runId}, run:current:{playerId}, floor:{runId}:*, wallet:{playerId}; counted
  DEL battle:verdict:{runId}:{seq} and battle:session:{runId}:{seq} for every voided battle (the aggregator returns their
      seqs; review fix 2026-11-09), and no verdict is cached for a battle the same commit voided, so a voided battle never
      reads as Verified and never hides the next epoch's battle at that seq; a tombstone battle:voided:{runId}:{seq} (2 min)
      is set first, and the API's refill (one Lua step) writes nothing while it exists, so a reader that loaded the voided
      row just before the rollback cannot cache it again
```
**A start that disagrees with the anchor is never rolled back.** `GenesisMismatch` (the client's seq 1 hash ≠ the
server's anchor) ends the run `Rejected`: there is nothing verified to return to, and an honest client never produces
one. Every other rejection happens only after `verified_seq` reached 1 (the aggregator decides in order, 2.3), so
`rollback_to` is always at least 1, and a rollback to seq 1 is served from `runs.genesis_snapshot`, not the client's
copy (2.6).

**The client learns** on its next request: an upload, stairs or end carrying the old `epoch` gets `409 1108
RunRolledBack` with `epoch`, `rollbackSeq` and `reason` (a coarse category: `StateMismatch`, `Illegal`, `Seed`, `Link`).
The client treats it like a `1103`: discard the save, wait out a battle in progress, rebuild from `GET /resume`, show
"The server rolled your run back to <floor>". A run waiting at "Verifying run…" sees `status: Active` and a new
`epoch` in the poll and does the same. The player replays the same floor from the same seed: hindsight on a known seed
is the accepted cheat (`server-authority` 0), and `MaxRollbacks` bounds the retries.

### 2.5 Pending gems

```
step worker (slice 4/4c settlement, same transaction as the step and battle verdicts):
   writes wallet_ledger(status 'pending') + RewardPending outbox row   (wallets and marks unchanged; a mark already held
                                                                        means this cycle is paid: no row is written)
   the aggregator runs right after, in the same transaction: a battle step inside the verified prefix releases at once
release (the aggregator), for each pending row of a battle
  whose run_seq ≤ verified_seq:
   INSERT completion_marks … ON CONFLICT DO NOTHING                  (the mark is claimed now: the first row released for this
                                                                        player, character, challenge and cycle wins it)
     0 rows → UPDATE wallet_ledger SET status = 'voided' (idempotency key renamed), outbox RewardVoided(reason AlreadyPaid), next row
   UPDATE wallet_ledger SET status = 'released', released_at = now() WHERE id = … AND status = 'pending' RETURNING delta
   UPDATE wallets SET gems = gems + delta, version = version + 1   (only rows the UPDATE returned)
   outbox RewardGranted (the existing event, now emitted at release); DEL wallet:{playerId}
void (2.4): UPDATE … SET status = 'voided' WHERE status = 'pending' (a released row is never voided: its battle is ≤ verified_seq)
```
A battle is releasable when its step is inside the verified prefix, which already includes its battle verdict and its
`ConditionsMismatch` check. Because the verdict and the step are one transaction, there is no "second finisher"; a
step that is verified but waits for an earlier step stays `pending` until the prefix reaches it, and the status guard
keeps the release exactly once. `wallets.gems = SUM(delta) WHERE status = 'released'` replaces slice 4's invariant (tested).

### 2.6 Gates, resume, the end

- **Stairs gate (decided 2026-11-08).** `POST /runs/{id}/floors/{n}` keeps `1105`/`1106` and adds: the floor being
  left (n-1) must itself be verified (`run_floors.verified_at` set), else `409 1107` + `Retry-After`
  (`Verify:GateRetryAfter`, 5 s). A client cannot get through a floor, or even receive the next seed, while the floor
  it just played is unverified. A repeat request for the current floor is never gated. Order of checks: `1105`, then
  `1106` (this floor's log fully uploaded), then `1107`.
  *Why this does not stall:* upload and verification are asynchronous and start during play. Every checkpoint (each
  battle, each `next_floor`) is uploaded and becomes a step job while the player is still on the floor, so by the stairs
  only the last step or two remain. The client asks for the next seed at `next_floor`, and the rest stop (spec
  playable-demo 3.11) covers the wait; the "Verifying…" pop-up shows only if the queue is behind or the client is
  offline. A client that reaches the stairs offline waits to sync and for the verdict before it gets the next floor.
  *Floor end:* a floor is verified when `verified_seq` reaches the `next_floor` action that left it
  (`run_floors.end_seq`). Rest-stop choices come after that action and are verified in the following step, with the link
  check; the next floor's generation also happens in that step (its seed is issued only after the gate opens).
- **Resume** (`GET /resume`) now returns the latest **verified** checkpoint (`seq ≤ verified_seq`) and every accepted
  action after it, plus `epoch`, `verifiedSeq`. The client replays the (longer) tail exactly as before.
  *Checkpoint seq 1 is always served from `runs.genesis_snapshot`* (the server's own copy), never the client's, so a
  snapshot field outside `run_hash` coverage cannot be smuggled in through the start (open item 2).
  *Before the client's first upload* (seq 1 not stored, so Part B answered `checkpointSeq 0` and a null snapshot that
  could not be resumed from): the answer is `checkpointSeq 0` with `genesis_snapshot` as the snapshot and an empty tail,
  and the client starts the run again from it, sending `start_run` as seq 1. If the anchor job has not finished (seconds
  after the start) the snapshot is still null and the client retries as it does today.
- **Run end.** `POST /end` for a win stores the `end` action *with its snapshot* (a step of kind `end`) and answers
  `202 Verifying` as today, but `Run:AutoApproveWins` is **removed**; `Won` comes from the aggregator. A win submitted as the very first upload
  (no checkpoint to verify it from) is refused with `409 1106`. A death (`Lost`)
  needs no verification to end, but its steps are still verified (a death gets an ordinary `segment` step, never an `end` step) (an honest death earns nothing; a rejected one rolls
  back the unsettled tail like any other). The client polls `GET /runs/{id}` every 2 s as today.
- **Ack carries progress.** `RunActionAck(LastSeq, Epoch, VerifiedSeq)`; the client shows nothing for it now, but the
  console's `server check` and the e2e scenarios read it. SignalR replaces polling in slice 7.

### 2.7 Floor read model

`GET /api/v1/runs/{runId}/floors/{n}` returns the verified digest of floor n (404 until its entry step is verified).
Source of truth: `run_floors.digest` (jsonb, written by the aggregator from the worker's result); cache-aside in
`floor:{runId}:{n}` (30 min, deleted on rollback, any Redis error falls back to Postgres: scenario 4). It feeds the
dashboard's floor view (slice 7) and is a cheap cross-check for analytics (4b) that "the encounter in this room was X".

## 3. Data contracts

### 3.1 C# records (`src/Rpg.Contracts/`)

```csharp
namespace Rpg.Contracts.Runs;

// Existing records, changed (every new member is last and optional so old JSON still reads):
public sealed record RunActionBatch(IReadOnlyList<RunActionRequest> Actions, int Epoch = 0);
public sealed record FloorSeedRequest(int? AfterSeq = null, int Epoch = 0);
public sealed record RunEndRequest(int Seq, RunEndStatus Status, string RunHash, JsonElement Snapshot, int Epoch = 0);
public sealed record RunActionAck(int LastSeq, int Epoch = 0, int VerifiedSeq = 0);
public sealed record RunSummaryResponse(/* existing */ string RunId, RunStatus Status, int CurrentFloor, int LastSeq,
    string RulesetVersion, DateTimeOffset StartedAt, DateTimeOffset? EndedAt, int Epoch = 0, int VerifiedSeq = 0);
public sealed record RunResumeResponse(/* existing */ string RunId, RunStatus Status,
    IReadOnlyList<FloorSeedResponse> FloorSeeds, int CheckpointSeq, JsonElement Snapshot,
    IReadOnlyList<RunActionRequest> Tail, int Epoch = 0, int VerifiedSeq = 0);

/// <summary>RabbitMQ message on verify.segment. Small: the worker reads everything from Postgres.</summary>
public sealed record VerifyStepJob(Guid RunId, int Epoch, int StepNo, string RulesetVersion, DateTimeOffset CreatedAt);

public enum StepKind { Genesis, Segment, Battle, End }
public enum StepStatus { Pending, Verified, Rejected, Voided }

/// <summary>What step_main.tscn reads (--request). Built by the worker from Postgres; never from the client.</summary>
public sealed record StepRequest(int SchemaVersion, string RunId, string RunStructureId,
    IReadOnlyList<string> CharacterIds, IReadOnlyDictionary<int, string> FloorSeeds, int FromSeq, int ToSeq,
    StepKind Kind, JsonElement? StartSnapshot, string? StartStateHash, IReadOnlyList<RunActionRequest> Actions,
    string? EndRunHash);   // genesis: StartSnapshot/StartStateHash null, Actions empty

public enum StepMismatchReason
{
    MalformedRequest, SnapshotHashMismatch, ForeignSeed, WrongSetup,
    ActionRefused, ConditionsMismatch, BattleMismatch, StateHashMismatch, NotWon,
    GenesisMismatch,    // set by the aggregator (client's seq 1 hash ≠ the anchor), not by Godot
    LinkBroken          // set by the aggregator, not by Godot
}
public sealed record StepMismatch(StepMismatchReason Reason, int Seq, string Detail);

/// <summary>step_main's result and the stored verdict. Same error contract as battles: Rejected is 2002, never an HTTP status.</summary>
public sealed record StepVerdict(ReplayVerdict Status, int? ErrorCode, string? Error, StepMismatch? Mismatch,
    string StartHash, string EndHash, JsonElement? EndSnapshot /* genesis only */,
    IReadOnlyList<ReplayResult> Battles, JsonElement? FloorDigest,
    string VerifierRulesetVersion, string EngineVersion, DateTimeOffset VerifiedAt);

/// <summary>GET /runs/{id}/floors/{n}. Digest is opaque JSON owned by GDScript (floor hash, rooms, encounters, offers).</summary>
public sealed record FloorDigestResponse(string RunId, int Floor, DateTimeOffset? VerifiedAt, JsonElement Digest);

namespace Rpg.Contracts.Battle;
// MismatchReason gains MalformedRequest (appended; ReplayRunner exits 3, the worker commits Rejected 2002 at once).

namespace Rpg.Contracts.Events;   // DomainEvent<T>; topic rpg.run.events (key playerId) unless noted
public sealed record FloorVerifiedPayload(string RunId, int Floor, int EndSeq, int Epoch);
public sealed record RunVerifiedPayload(string RunId, RunStatus Status, int Steps, int Floors);
public sealed record RunRolledBackPayload(string RunId, int Epoch, int RollbackToSeq, int RejectedStepNo,
    StepMismatchReason Reason, int VoidedActions, int VoidedBattles, bool Terminal);
public sealed record AntiCheatAlertPayload(string RunId, string Kind, string Reason, int Seq);  // topic rpg.security.events
public sealed record RewardPendingPayload(string BattleId, string CharacterId, string ChallengeId, string CycleKey,
    int Amount, int RuleVersion);
public sealed record RewardVoidedPayload(string BattleId, string ChallengeId, string CycleKey, int Amount, string Reason);
// RewardGranted: unchanged shape, now emitted when the gems are released.

namespace Rpg.Contracts.Api.V1;
// ApiErrors:  PreviousFloorUnverified = 1107 (409 + Retry-After; reserved by Part A, used now)
//             RunRolledBack = 1108 (409; extensions epoch, rollbackSeq, reason)
```
The server never interprets `StartSnapshot`, `FloorDigest` or the step's action bodies (opaque JSON, like snapshots in
Part B). No game state record enters `Rpg.Contracts`. All new records get golden JSON tests.

### 3.2 PostgreSQL: `Migrations/0007_run_verify.sql`

```sql
ALTER TABLE runs
  ADD COLUMN epoch int NOT NULL DEFAULT 0,          -- bumped by every rollback
  ADD COLUMN verified_seq int NOT NULL DEFAULT 0,   -- the verified prefix: 0 until the client's seq 1 matches the anchor, then always a checkpoint seq
  ADD COLUMN genesis_hash text,                     -- the server's anchor: run_hash() of the state rebuilt at run start (2.0)
  ADD COLUMN genesis_snapshot jsonb,                -- that state, opaque JSON: served by /resume for seq 1 and for a run with no uploads
  ADD COLUMN end_seq int,                           -- the end action's seq once a win is submitted
  ADD COLUMN rollbacks int NOT NULL DEFAULT 0;
ALTER TABLE run_floors
  ADD COLUMN end_seq int,                           -- seq of the next_floor action that left it (set at upload)
  ADD COLUMN verified_at timestamptz,
  ADD COLUMN digest jsonb;                          -- the floor read model's source (2.7)

CREATE TABLE run_steps (
  run_id uuid NOT NULL REFERENCES runs, epoch int NOT NULL, step_no int NOT NULL,
  from_seq int NOT NULL, to_seq int NOT NULL CHECK (to_seq > from_seq),
  kind text NOT NULL CHECK (kind IN ('genesis','segment','battle','end')),
  status text NOT NULL CHECK (status IN ('Pending','Verified','Rejected','Voided')),
  verdict jsonb, start_hash text, end_hash text,
  attempts int NOT NULL DEFAULT 0, dead_lettered_at timestamptz, dead_letter_reason text,
  created_at timestamptz NOT NULL DEFAULT now(), verified_at timestamptz,
  PRIMARY KEY (run_id, epoch, step_no),
  CONSTRAINT run_steps_verdict_set CHECK ((status IN ('Pending','Voided')) = (verdict IS NULL) OR status = 'Voided'));
CREATE INDEX run_steps_pending ON run_steps (created_at) WHERE status = 'Pending' AND dead_lettered_at IS NULL;

CREATE TABLE run_actions_voided (LIKE run_actions, epoch int NOT NULL, voided_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (run_id, epoch, seq));
CREATE TABLE battle_sessions_voided (LIKE battle_sessions, epoch int NOT NULL, voided_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (battle_id, epoch));          -- LIKE copies no foreign key: the live row is deleted

ALTER TABLE wallet_ledger
  ADD COLUMN status text NOT NULL DEFAULT 'released' CHECK (status IN ('pending','released','voided')),
  ADD COLUMN character_id text,             -- the party character a pending row pays (its mark's key)
  ADD COLUMN released_at timestamptz;       -- existing rows: released (they were settled by slice 4)
UPDATE wallet_ledger SET released_at = created_at;
CREATE INDEX wallet_ledger_pending ON wallet_ledger (ref_battle_id) WHERE status = 'pending';
```
**Idempotency keys:** the step verdict is `UPDATE run_steps … WHERE status = 'Pending' AND epoch = @e`; `verified_seq`
only moves forward (`WHERE verified_seq < @n`); a ledger row changes status only `WHERE status = 'pending'`; marks and
ledger keys stay as in slices 4 and 4d. `run_floors.end_seq` is filled at upload when a `next_floor` row is stored
(`floor` = the floor being left; rest-stop choices after it are part of the next step but still belong to that floor's
log, which is why a floor's end is the `next_floor` seq, not the last action tagged with its number).

### 3.3 Inputs a step needs, and where they come from

| Input | Source | Why not the client |
|---|---|---|
| Floor seeds | `run_floors` | The client could claim a seed with a friendlier floor |
| Run structure, characters | `runs` | The party and run rules are fixed at start. Slice 5 adds the account's unlocked cards here (the characters and the item pool, stored at run start) |
| Genesis state | rebuilt by Godot at run start from the two above; stored as `genesis_hash` + `genesis_snapshot` | A claimed start snapshot with extra keys, items or levels is the cheapest cheat; the server's own copy is also what resume and rollback return for seq 1 |
| Ruleset version | `runs.ruleset_version` (worker must accept it) | Scenario 6 groundwork |
| Start snapshot, actions, hashes | `run_actions` (claimed, checked by replay) | These are the claims being verified |

### 3.4 RabbitMQ

Same exchange and DLX as battle-verify 3.3 (`rpg.verify`, `rpg.verify.dlx`). New:

| Object | Kind | Arguments |
|---|---|---|
| `verify.segment` | durable queue, bound `rpg.verify` / `segment` | `x-dead-letter-exchange=rpg.verify.dlx`, `x-dead-letter-routing-key=dead.segment` |
| `verify.segment.retry.5s`, `.30s`, `.120s` | durable queues, TTL 5 / 30 / 120 s | dead-letter back to `verify.segment` |
| `verify.segment.dlq` | durable queue, bound `rpg.verify.dlx` / `dead.segment` | no consumer |

Published only by the outbox relay (rows with `topic = 'segment'`). `VerifyTopology` and `VerifyMessaging` get the
segment names; the consumer, tiers and `x-attempt` handling are the battle consumer's, parameterized by queue. Config:
The worker has one consumer (`Verifier:Role` existed during the build and was removed with the per-battle worker);
`Verifier:Segment:Concurrency` (2), `Verifier:Segment:ProcessTimeout` (90 s), `Verifier:MaxStepActions` (500, API side).
Verify section for the API: `Verify:GateRetryAfter` (5 s), `Verify:MaxRollbacks` (3).

### 3.5 Redis

| Key | Value | TTL | Semantics |
|---|---|---|---|
| `floor:{runId}:{n}` | `{playerId, FloorDigestResponse}` | 30 min | Cache-aside for `GET …/floors/{n}`; the aggregator **deletes** it on rollback and never sets it from the write path (a verified floor is immutable, so a reader's fill is safe). Any Redis error → Postgres. Scenario 4 |
| existing `run:summary`, `run:current`, `wallet`, `battle:*` | | | Deleted by the aggregator when it changes `verified_seq`, status, epoch or the wallet |

No lock is added: row locks and the status guards are the dedup (the `lock:battle` lesson, `settlement-outbox` 7.7).

### 3.6 Godot side

- **`game/verify/step_runner.gd` + `step_main.tscn`** (system code, `res://game/verify/`): reads `StepRequest`, builds the
  `ContentIndex` as `replay_main` does, runs the checks in 2.2 on a headless `RunController` and writes `StepVerdict`.
  Exit codes: `ReplayRunner.EXIT_MALFORMED = 3` is added and `step_main` uses the same constants (0/1/2/3). It shares
  `RunWire.apply` with resume, so what a step accepts is exactly what play accepts.
- **`RunController.floor_digest()`** (floor hash, per room role, encounter id, offers via `RunWire`'s offers helper).
- **Battle runner fix** (`combat/replay_runner.gd`): unknown content id, bad schema version, unknown action field →
  `MismatchReason.MalformedRequest`, exit 3.
- **`ServerLink` (client):** a `409 1107` at the stairs is retried like a 5xx with `Retry-After` (the "Connecting…"
  pop-up now reads "Verifying previous floor…" via the existing waiting hook); `1108` (and a poll showing a new
  `epoch`) takes the 1103 path with the rollback message; `Epoch` is carried on batches, stairs and end and kept in
  the local save; the console's `server check` also asserts `verifiedSeq`. No game logic.
- **Resume with checkpoint seq 0 (client change):** `ServerLink.resume_into` accepts `checkpointSeq 0` with a snapshot (the
  server's `genesis_snapshot`), loads it into a fresh `RunController`, logs and queues `start_run` as seq 1 carrying that
  snapshot, and plays on. A null snapshot (the anchor job is still running) is retried with backoff. A local save for the
  same run still wins when present. Test `test_resume_from_genesis_snapshot`.
- **Dev:** local mode never sends; nothing changes. Console `server steps` lists steps and their status, `wait epoch <n>`
  waits for a rollback; the e2e controls `tamper-battle` and `tamper-genesis` edit a stored battle or the start state in
  Postgres between upload and verification (Development only).

### 3.7 HTTP

| Endpoint | Change |
|---|---|
| `POST /runs/{id}/actions` | Creates steps and their jobs in the upload transaction; `Epoch` checked: stale → `409 1108`; ack carries `epoch`, `verifiedSeq` |
| `POST /runs/{id}/floors/{n}` | `1107` gate; stale `Epoch` → `1108` |
| `POST /runs/{id}/end` | Requires the snapshot (a step); no auto-approve; stale epoch → `1108` |
| `GET /runs/{id}` | `Status` can be `Rejected`; `Epoch`, `VerifiedSeq` |
| `GET /runs/{id}/resume` | Latest verified checkpoint + tail; seq 1 and a run with no uploads served from `genesis_snapshot`; `Epoch`, `VerifiedSeq` |
| `POST /runs` | Also writes the genesis step and its outbox job in the start transaction (2.0); the response is unchanged |
| `GET /runs/{id}/floors/{n}` (new) | Verified digest, 404 until verified (also for another player's run) |
| `GET /runs/{id}/steps` (new, Development) | The steps and verdicts, for tests and e2e |

## 4. Failure modes

| # | Failure | Behaviour | Test |
|---|---|---|---|
| F1 | Same step job delivered twice, or two workers at once | One verdict (guarded update), one aggregation, one release. **Scenario 1** | `TheSameJobTwice_OneVerdict_AndTheSecondIsADuplicate`, `TwoWorkersAtOnce_OneVerdict_OneRelease` |
| F2 | Worker dies after the commit, before the ack | Redelivery finds `status ≠ Pending` → ack. The aggregator already ran in that transaction. **Scenario 2** | `ACrashAfterTheCommit_TheRedeliveredStepIsANoOp`; e2e `verify_worker_kill` |
| F3 | Worker dies during the replay | Unacked → redelivered; replay is deterministic and side-effect free | e2e `verify_worker_kill` |
| F4 | Tampered action, hash, snapshot or conditions | Godot exits 2; `Rejected` 2002 with a `StepMismatchReason`; rollback (2.4). **Scenario 5** | Godot: `test_a_flipped_state_hash_is_named_at_its_action`, `test_a_dropped_action_is_refused_or_hashes_wrong`, `test_a_snapshot_that_is_not_its_claimed_hash`, `test_a_start_that_differs_in_what_the_hash_used_to_miss_is_a_hash_mismatch`, `test_a_foreign_floor_seed_is_named`, `test_another_party_or_run_is_wrong_setup`, `test_a_flipped_battle_outcome_rejects_the_step_and_the_battle`; .NET: `ARejectedStep_VoidsTheGemsOfALaterBattle_FreesItsMark_AndArchivesTheTail`; e2e `verify_tampered` |
| F5 | Two steps individually valid but not linked (a forged snapshot that hashes as its claim yet differs from the replayed end) | `LinkBroken` blames the later step; rollback | `ABrokenLink_RollsTheRunBack_BlamingTheLaterStep`; Godot `test_steps_verify_and_link_on_the_scripted_run`, `test_steps_verify_and_link_on_the_keyed_run` |
| F6 | Step finishes out of order | Aggregator advances only over a contiguous verified prefix | `Steps_VerifyInAnyOrder_ButTheFloorIsVerifiedOnlyOnceThePrefixReachesItsEnd` |
| F7 | Malformed request (unknown content id, bad schema, unknown field) | Exit 3 with a result saying `MalformedRequest` → `Rejected` 2002 at once, **no retries**; a bare exit 3, or a 3 with any other result, is a runner error (retried); closes `battle-verify` 8.1 | `AMalformedStep_IsRejectedAfterOneAttempt_NotRetried`, `ExitThree_WithAMalformedRequestResult_IsARejection_NeverARetry`, `ExitThree_WithoutAMalformedRequestResult_IsARunnerError`, Godot `test_malformed_requests_are_exit_3_never_a_runner_error`, `test_malformed_input` (the battle runner) |
| F8 | Godot runner error / hang / `MaxAttempts` | Retry tiers 5 / 30 / 120 s; at the limit → DLQ, `dead_lettered_at`, the step stays `Pending`, the run is **not** rolled back (an infrastructure fault is not a cheat) and the gate keeps answering `1107`; an operator re-drives it with `POST /api/v1/admin/steps/redrive` (role `ops-admin`; dead letter cleared, attempts 0, a fresh job in the outbox, only Pending steps of the run's current epoch while it is Active or Verifying; review fix 2026-11-09). Dead-lettered outbox rows (e.g. a Redpanda outage longer than `Outbox:MaxAttempts`) go back with `POST /api/v1/admin/outbox/redrive` | `RunnerErrors_RetryOnTheTiers_ThenDeadLetter_AndNeverRollTheRunBack`, `APermanentlyFailingStep_EndsInTheSegmentDeadLetterQueue_WithItsReason`, `StepRedrive_ClearsTheDeadLetter_AndWritesAFreshJob_ButNeverForAnEndedRun`, `OutboxRedrive_MakesDeadLetteredRowsLeasableAgain_OfOneDestination`, `Redrive_NeedsTheOpsAdminRole` |
| F9 | Wrong ruleset | DLQ `reason=ruleset`; the step stays `Pending` (slice 9 routes) | `AWrongRuleset_DeadLettersTheStep_AndLeavesItPending` |
| F10a | A verdict cached before a rollback (review fix) | The rollback deletes the voided battles' `battle:verdict` / `battle:session` keys; `GET /runs/{id}/battles/{seq}` reads Postgres again | `ARollback_DeletesTheCachedVerdictOfEveryVoidedBattle` |
| F10 | Rollback while jobs are in flight | A job with an old epoch finds no step / another epoch → ack as `superseded`. (The draft's `verify.battle` case is moot: that worker was removed) | `AStepOfARolledBackEpoch_IsSuperseded_NotRejected` |
| F11 | Client keeps uploading after a rollback | `409 1108` on batch, stairs and end; nothing stored; client rebuilds from `/resume` | `AStaleEpoch_Is1108_OnUploadStairsAndEnd_AndStoresNothing`, `test_a_rollback_rebuilds_the_run_from_the_server` |
| F12 | Stairs ahead of verification | `409 1107` + `Retry-After` until the floor just played is verified; the client retries and the player sees the pop-up | `Stairs_TheFloorJustPlayedIsNotVerified_Is1107_WithRetryAfter_ThenOpens`; Godot `test_the_stairs_wait_for_the_previous_floor_to_verify`; e2e `stairs` |
| F13 | Win submitted, steps still pending or one rejected | Stays `Verifying`; becomes `Won` only at `verified_seq = end_seq`; a rejection rolls back to `Active` (never a victory) | `AWonRun_BecomesWon_OnlyWhenEveryStepUpToTheEndIsVerified`, `AWinWithARejectedStep_GoesBackToActive_NeverAVictory`; Godot `test_win_waits_for_verdict` (updated) |
| F14 | Pending gems | Pending at the battle verdict; released when the battle is inside the verified prefix; voided with its mark on rollback; the other order (run verified first) releases at once; exactly once either way | `ABattleStep_CommitsTheBattleVerdict_AndItsGemsStayPendingUntilThePrefixReachesIt`, `AReleasedGem_IsNeverVoided`, `ARejectedStep_VoidsTheGemsOfALaterBattle_FreesItsMark_AndArchivesTheTail`, `TwoWorkersAtOnce_OneVerdict_OneRelease`, `TwoRunsOfOnePlayer_BothHoldPendingRows_AndOnlyTheFirstReleasedIsPaid`, `TheWallet_ShowsPendingAndVoidedRows_AsSuch_AndCountsOnlyReleasedGems`; e2e `verify_fabricated_conditions` |
| F15 | Fabricated battle conditions (an easy "boss") | `ConditionsMismatch` rejects the battle step → rollback, gems voided. Closes `settlement-outbox` 8.1 | Godot `test_fabricated_battle_conditions_are_named`; worker `AFabricatedBattle_IsRejectedAsConditionsMismatch_RollsTheRunBack_AndNothingIsPaid`; e2e `verify_fabricated_conditions` |
| F16 | Postgres down at verdict time | Postpone on the 30 s tier without counting an attempt (as battle-verify F12) | `PostgresDown_PostponesTheStep_WithoutCountingAnAttempt` |
| F17 | Redis flushed or down | Floor read model and caches rebuild from Postgres; verification unaffected. **Scenario 4** | `FloorDigest_Is404UntilVerified_ThenServedFromPostgresAndRedis_AndSurvivesAFlush`, `RedisDown_StillVerifiesTheStep`; e2e `verify_redis_flush` |
| F18 | Redpanda down during aggregation | Events are outbox rows written in the aggregator's transaction; they drain when it returns. **Scenario 3** | `TheAggregatorsEvents_AreWrittenInTheStepVerdictsTransaction_AllOrNothing`; e2e `outbox_redpanda_down` (with `redpanda-check`) |
| F19 | A client omits its battle-pending checkpoint | A larger step that includes the battle; still verifies; only a step above `MaxStepActions` is refused (400). The limit holds for every action (review fix 2026-11-09): a plain action is refused once only the closing checkpoint's place is left, the end too is refused past the limit, and seq 1 must be the `start_run` checkpoint (else no step would cover the actions before the first snapshot) | `Upload_AStepAboveTheLimit_Is400_AndStoresNothing`, `Upload_PlainActionsPastTheLimit_Are400_TheCheckpointsPlaceStaysFree`, `End_PastTheLimitFromTheLastCheckpoint_Is400_AndNoStepIsMade`, `Upload_ASeqOneThatIsNotTheStart_Is400`, `Upload_AClientWithoutAPendingBattleCheckpoint_MakesOneLongerBattleStep` |
| F20 | Repeated rollbacks | After `MaxRollbacks` the run is `Rejected` and ended. What the verified prefix held stays paid (it was valid, and so was everything before it); the voided tail never pays (the user, 2026-11-09: "never pay an invalidated part of a run; a part valid before the invalidation pays, but only if everything leading up to it is valid") | `PastTheRollbackLimit_TheRunIsRejected_TheVerifiedPrefixStaysPaid_TheTailNeverPays` |
| F21 | Rollback and new upload at once | Both take the run row lock; whichever is second sees the new epoch (the upload gets 1108) | `Rollback_ConcurrentUpload_Is1108_BecauseTheEpochIsReadUnderTheRunLock` |
| F23 | Forged starting state (the client's seq 1 hash ≠ the anchor) | `GenesisMismatch`: the run ends `Rejected` 2002 at the upload (anchor already there) or when the genesis job commits; no rollback target exists; queued later steps are `Voided` and acked as superseded | `Genesis_AForgedStart_IsRejectedAtTheUpload_WhenTheAnchorIsAlreadyThere`, `Genesis_AForgedStart_EndsTheRun_Rejected_WhenTheAnchorArrivesAfterTheClaim` (both also void the later steps), `Genesis_AClaimThatMatchesTheAnchor_SetsVerifiedSeqToOne_UploadFirstOrAnchorFirst`; e2e `genesis_forged` |
| F24 | Genesis job and upload in either order; runs that never upload | Upload first: the comparison waits for the anchor and happens in the genesis commit. Anchor first: compared at the upload. A run abandoned or ended before the job runs: the job is acked as a no-op, the step `Voided`, no Godot run. A genesis job that dead-letters leaves `verified_seq` 0: uploads are still stored, the stairs gate holds, a human requeues. Step 1 waits for the anchor's snapshot on the 5 s tier **without spending attempts** (its attempts count only Godot runs) while the genesis step is Pending and not dead-lettered; once genesis is dead-lettered (or done without a snapshot) step 1 is dead-lettered `genesis_missing` (review fix 2026-11-09: the waits used to share step 1's attempt counter, so a slow genesis sent step 1's first runner error to the DLQ) | `Genesis_AClaimThatMatchesTheAnchor_SetsVerifiedSeqToOne_UploadFirstOrAnchorFirst`, `Genesis_ARunAbandonedBeforeTheJobRan_IsANoOp_NoGodotRun`, `Genesis_ADeadLetteredJob_LeavesTheUploadsStoredAndTheGateShut`, `StepOne_WaitingForGenesis_SpendsNoAttempts_AndItsFirstRealErrorIsRetried`, `StepOne_IsDeadLettered_OnlyOnceGenesisIs` |
| F25 | Client crashes before its first upload | `/resume` returns `genesis_snapshot` with `checkpointSeq 0`; the client restarts the run from it | `Resume_BeforeAnyUpload_ServesTheServersOwnStartSnapshot`; Godot `test_a_resume_before_the_first_upload_starts_again_from_the_servers_snapshot`; e2e `resume` extended |
| F22 | Genesis inputs differ at the verifier (deploy mismatch) | The ruleset check comes first (F9). Content missing at an accepted ruleset would be a deploy bug; it would reject honest runs, so `MalformedRequest` details log the unknown id and a metric alert fires on `result=malformed` | `rpg_step_jobs_total{result="malformed"}` panel; documented risk |

**Where the tests are.** The Test column names the built tests; they are in `RunVerifyTests` (API),
`StepProcessorTests`, `StepConsumerTests`, `GodotStepRunnerTests`, `GodotProcessTests`, `SettlementTests` and
`ChallengeSettlementTests` (worker), `test_step_runner.gd` and `test_run_authority.gd` (Godot) and the e2e scenarios of
section 6. Added at sync for rows that had none: F10 `VoidedBattleJob_IsAckedAsSuperseded` was written and then removed with the
per-battle worker; F18 `TheAggregatorsEvents_AreWrittenInTheStepVerdictsTransaction_AllOrNothing` (a failing event insert rolls
the whole verdict back); F19 `Upload_AClientWithoutAPendingBattleCheckpoint_MakesOneLongerBattleStep`; F21
`Rollback_ConcurrentUpload_Is1108_BecauseTheEpochIsReadUnderTheRunLock`.

**Idempotency summary:** upload creates steps and jobs once (the unique `(run_id, epoch, step_no)` and the action
idempotency of Part B); the verdict is a guarded update; the aggregator is monotone and idempotent; the ledger status
transitions are guarded; the queue is at-least-once. Dead letters are never retried automatically.

## 5. Observability

Prometheus, existing `RpgMetrics` meter (API) and the worker's meter. Labels are small fixed sets; **never** run,
player, item, character or encounter ids.

| Instrument | Type | Labels |
|---|---|---|
| `rpg_steps_created_total` (API) | counter | `kind` |
| `rpg_step_jobs_total` (worker) | counter | `result` = verified \| rejected \| malformed \| duplicate \| superseded \| runner_error \| retry \| dead_letter \| ruleset \| postponed \| run_gone |
| `rpg_genesis_claims_total` | counter | `result` = match \| mismatch \| anchor_first \| claim_first |
| `rpg_step_duration_seconds` (worker) | histogram | `kind` (Godot wall time incl. startup) |
| `rpg_step_queue_wait_seconds` | histogram | (verdict time − `created_at`: how far behind verification is) |
| `rpg_steps_pending` | gauge | (undecided, not dead-lettered; every `Monitors:Interval`) |
| `rpg_step_oldest_pending_age_seconds` | gauge | |
| `rpg_verify_queue_depth{queue="verify.segment"}` (also `segment_retry`, `segment_dlq`) | gauge | (management API; the existing gauge) |
| `rpg_step_mismatches_total` | counter | `reason` = `StepMismatchReason` (fixed enum) |
| `rpg_fanin_total` (worker) | counter | `result` = advanced \| waiting \| rolled_back \| link_broken \| won |
| `rpg_floor_verified_total` | counter | |
| `rpg_run_verdicts_total` | counter | `result` = won \| rejected |
| `rpg_run_rollbacks_total` | counter | `reason`, `terminal` = true \| false |
| `rpg_stairs_gate_total` | counter | `result` = open \| blocked |
| `rpg_ledger_transitions_total` | counter | `to` = pending \| released \| voided |
| `rpg_gems_pending` | gauge | (sum of pending deltas) |
| `rpg_anticheat_events_total` | counter | `kind` |

Traces: the step job inherits the upload's `traceparent` through the outbox row (slice 4c), so one trace follows an
action upload → outbox relay → RabbitMQ → worker → Godot process → verdict commit → events. The Godot span is the
worker's child. The Grafana dashboard "Run verification" (`infra/grafana/provisioning/dashboards/run_verification.json`) shows
step jobs by result, step queue wait, step duration by kind, undecided steps and their age, step queue depths and the DLQ,
steps created, mismatches by reason, rollbacks, fan-in results, floors and run verdicts, the stairs gate, genesis claims,
pending gems and ledger transitions, anti-cheat alerts. The older dashboard, now "Verification workers and settlement",
lost its battle-job panels. The Prometheus names are the instruments' dotted names with underscores (`rpg.step_jobs` →
`rpg_step_jobs_total`). Floor verification lag was not built as its own metric: the step queue wait and the pending-steps
panels show the same thing.

## 6. Test plan

### Godot (`client-godot/tests/`, fixtures only)
- **Step cut:** not stored as golden files. The tests play the committed scripted and keyed runs and cut them into steps
  the way the server does (`_steps`); the Windows-recorded run files (`run_scripted.json`, `run_keyed.json`) are compared by
  `test_run_scripted` and `test_keyed_run_golden`, which the Linux image check also runs.
- **G1 `test_step_replays_the_goldens`**: every step of both runs verifies; each step's `endHash` equals the next step's
  `startHash` (the links); the last step's hash equals the run hash. Also with all object keys reversed and in jsonb key
  order (the same discipline as the combat goldens: the verifier reads data jsonb has reordered).
- **G2 tampered copies**, one per reason: flipped `stateHash` (`StateHashMismatch`), a dropped action (`ActionRefused` or
  hash), a snapshot with an extra key/item (`SnapshotHashMismatch`), a foreign floor seed (`ForeignSeed`), another
  party (`WrongSetup`), a forged start snapshot (`SnapshotHashMismatch`, then `LinkBroken` against the anchor), fabricated battle conditions
  (`ConditionsMismatch`), a flipped battle outcome (`BattleMismatch`), an unwon `end` (`NotWon`), and malformed requests
  (unknown content id, bad schema version, unknown field → exit 3). The first divergent action is named.
- **G3 `test_floor_digest`**: stable for a floor, differs between floors, matches the generator's rooms.
- **G4 `test_snapshot_fields_are_covered`**: every snapshot field is in `run_hash` or on the allowlist; mutating each
  covered field changes the hash (links are only as strong as this).
- **G5** resume from the verified checkpoint (`test_resume_equivalence` extended); `test_stairs_gate_retries_on_1107`,
  `test_rollback_rebuilds_from_the_server`, `test_epoch_carried_and_saved`, the existing win test updated.
- **G6 `test_battle_malformed_exit_code`**: closes `battle-verify` 8.1 with an unknown encounter id → exit 3, `MalformedRequest`.

### .NET (`tests/`, Testcontainers; Docker required)
- `Rpg.Contracts.Tests`: golden JSON for every new record and the changed ones (old JSON without the new members still
  reads); purity guard unchanged (no logic).
- `Rpg.GameServerApi.Tests` (`RunVerifyTests`): step creation per checkpoint in one transaction with the action insert
  (and none for a rejected batch), the stairs gate (1105 → 1106 → 1107 order), `1108`, the end without auto-approve,
  resume from the verified checkpoint, the floor endpoint and its cache (scenario 4), `Upload_StepTooLong_Is400`,
  and the migration against a database holding slice 4's data (ledger rows become `released`, the invariant holds).
- `Rpg.VerifierWorker.Tests` (`StepProcessorTests`, a fake or stub Godot; a real broker, Postgres, Redis): every row of
  section 4, including the aggregator cases (out of order, link broken, win, rollback with voided actions, battles, marks
  and ledger, epoch supersede, `MaxRollbacks`) and concurrency (two workers, aggregator vs. battle worker releasing the same
  gems). `SettlementTests` updated: grants are `pending` and the wallet moves only on release.
- `SettlementContractTests` updated for `RewardPending` / `RewardVoided`.

### End to end (`tools/e2e.sh`, real Godot, on demand)
Built, under other names: `verify_battle` (a whole run on the fixtures' `titan` party: every step and battle Verified, floors
verified in order, the win `Won` with no auto-approve, `/floors/{n}` answered); `stairs` (worker stopped: the client waits at
the stairs, then `worker-start` lets it through); `verify_tampered` (the `tamper-battle` control step edits a stored battle →
rollback, `1108`, the client rebuilds from the server and the titan party finishes the run to a verified win);
`genesis_forged` (the `tamper-genesis` control step: a forged start ends the run Rejected); `settle_boss` and the reward
scenarios (pending, then released, wallet and events agree); `verify_worker_kill`, `verify_redis_flush`,
`outbox_redpanda_down` (with `redpanda-check`) and `verify_demo_content` (the real demo content). `verify_fabricated_conditions` (the
`tamper-conditions` control step alters the first battle's stored conditions: the step is rejected as `ConditionsMismatch`
without replaying the battle, the run is rolled back, nothing is paid for it and the rebuilt run is played to a verified
win; pending gems of later steps verified first are voided on the rollback). The
scenarios that relied on `Run:AutoApproveWins` start the worker by default (`#! worker` is implied unless the script
controls it with `e2e worker-start`).

### Platform check (open item 5)
`tools/verifier_image_check.sh` runs, inside the Linux image, the Godot golden tests that compare the platform with files
recorded on Windows (floors, seeds, the scripted and keyed runs, the combat goldens) besides the combat replays. Passed
2026-11-08. The `test_step_*` tests are not used for this: they play a run on the machine they run on, so they show only that
the machine agrees with itself. Step goldens as committed files were not added.

## 7. Decisions, and what stays out

**Decisions proposed (change by editing here)**
1. **Steps are cut at the claimed snapshots, created at upload.** The API needs no game rules to cut the log; the cost
   is that a step exists for every snapshot-bearing action (a battle is two steps: pending checkpoint → battle).
2. **The aggregator runs inside the step-verdict transaction** (not a separate consumer): the verdict, the verified
   prefix, the releases and the events cannot disagree, same argument as settlement (`settlement-outbox` 7.3).
3. **Rollback to `verified_seq`, with an `epoch`**, instead of rejecting the run outright: an honest false positive
   costs a floor, not the run; `MaxRollbacks` bounds retries. Voided actions are archived, not deleted.
4. **Dead-lettered steps never roll back**: an infrastructure fault must not punish a player; the gate holds instead.
5. **A battle is replayed once**, inside its step. The step's Godot run yields the post-battle state and the
   `ReplayResult`; the step worker settles. There is no `verify.battle` job any more (the worker was removed at the end of the build; a run that existed before migration 0007 is `legacy` and never verified). The cost is that a battle's
   verdict now waits for its run's earlier steps only for *release*, not for the verdict itself.
6. **`Run:AutoApproveWins` is removed**, and e2e and tests that used it run a segment worker.
7. **Gate on the floor just played** (the user's rule, 2026-11-08; `server-authority` and the roadmap now say so too) and `Retry-After` 5 s; the client retries. Early checkpoint uploads keep the wait short.
8. **No SignalR push**: the ack and the poll carry `epoch` and `verifiedSeq`; slice 7 adds the push.
10. **A genesis anchor is built at run start** (decided 2026-11-08): `POST /runs` queues a genesis job through the
    outbox (no Godot on the request path); a worker rebuilds the starting state from the server's inputs and stores
    `genesis_hash` and `genesis_snapshot` on the run. The client's seq 1 is compared with the anchor in C# (a string
    compare, in the aggregator). It gives every rollback a verified checkpoint, serves seq 1 and zero-upload resume from
    the server's own copy, and costs one cheap Godot start per run (bounded by the run-start rate limit; skipped for
    runs already gone).
11. **Completion marks are claimed at release** (decided 2026-11-08), not when the pending row is written: an unverified or
    rolled-back run never blocks another run's payment. A row whose mark is already held is voided as `AlreadyPaid`.
12. **The run hash covers the whole snapshot** (decided 2026-11-08), so the links bind the claimed snapshots to the replay and
    no separate snapshot comparison exists.
13. **The client sends a snapshot every 100 actions** (decided 2026-11-08) so an honest step stays short.
9. **`RewardGranted` moves to release time**; `RewardPending` is new, so consumers of `RewardGranted` never see gems the
   player does not have.

**Out of scope:** SignalR, analytics projections of the events (4b), ruleset routing (9), card-collection start
state (5), warm Godot processes, load tests (8), a review tool for the voided archive and `rpg.security.events`.

## 8. Open items

1. **Cost:** a run is dozens of Godot process starts (one per step). Slice 8 measures it; mitigations if needed:
   warm workers, merging adjacent segments.
2. **Link strength is `run_hash` coverage** (2.3). The hash now covers the whole snapshot and G4
   (`test_snapshot_fields_are_covered`) fails when a new leaf is neither hashed nor in its `NOT_HASHED` list.
3. **A client with no battle-pending checkpoints** makes a longer step (F19); the honest client now also checkpoints every
   100 actions, and the server refuses a step above `MaxStepActions` rather than requiring pending checkpoints.
4. **Rollback leaves seeds issued** for floors beyond the checkpoint (same seed again). Accepted (hindsight cheat).
5. **Honest false positives** from client/verifier divergence would roll back real players. The ruleset check, the
   Linux/Windows image check (`tools/verifier_image_check.sh`, which now also runs the run and generation goldens on Linux)
   and `rpg_step_mismatches_total` are the defence. A guard that fails when a snapshot holds a float with a fraction
   (`StateHasher.canonical` prints it with `str()`) is not built. Another client platform needs the same golden tests run on it.
6. **Retention**: the outbox, `run_steps`, the voided archives and settled sessions grow without bound. Roadmap slice 7b
   `data-retention` owns it.
7. **Routing by ruleset version** (slice 9): a step job for another ruleset dead-letters and its run waits at the stairs gate.
