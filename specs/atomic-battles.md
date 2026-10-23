# Spec: atomic-battles (slice 1c4b)

Status: ✅ Implemented, synced with the code (2026-10-22) · Roadmap: slice 1c4b · Date: 2026-10-22
Builds on: `specs/combat-replay-core.md` (action log, state hash v1, replay runner, mismatch reasons),
`specs/item-pass.md` 3.2 (One More), `specs/ult-interrupts.md` (party and enemy interrupts), `specs/dev-tools.md`
3.6 (dev decisions in the log). Cost figures: `specs/roadmap.md` slice 8, "verifier cost per battle".

## 1. Purpose & enterprise mapping
A battle becomes one atomic unit, end to end. Today the verdict is already atomic (one replay, one `Verified` or
2002, all rewards or none), but the log isn't: every party action carries a `checkpoint` (the state hash after it),
so the client hashes after every party action and the verifier hashes and compares at the same points. That costs
30–50% of a battle's simulation time (measured 2026-10-21: ~5 ms of ~12 ms) and buys one thing, locating a
divergence by turn, which only a developer needs.

After this slice:
- **The log** carries the party's decisions, the claimed outcome and the claimed final hash. Nothing per action.
- **The kernel** computes the state hash **once per battle**, at the end (record and replay alike).
- **Locating a divergence** moves to an opt-in **determinism trace** (tests and dev only): the state hash after
  **every** action (party, enemy, One More, ult interrupt on either side, dev decision), finer than today's
  party-only checkpoints, with the canonical lines on demand. It never enters the wire contract, and when it is off
  it costs one `null` check per action.

| Area | What | Owner |
|---|---|---|
| Wire contract | `ActionEntry` loses `Checkpoint`; `ActionLog.schemaVersion` 1 → 2 (breaking); `MismatchReason.CheckpointMismatch` removed | system (`Rpg.Contracts`, `combat/`) |
| Kernel | No state hash after party actions or interrupts; controller callbacks lose the `checkpoint` argument; final hash unchanged | system (`combat/battle.gd`) |
| Replay | Reads v2 logs only; tampering shows up as a structural reason at its turn or as `OutcomeMismatch` / `FinalHashMismatch` at the end | system (`combat/replay_runner.gd`) |
| Determinism trace | `BattleTrace` attached to a `Battle`; trace file format; diff | system (`combat/battle_trace.gd`) |
| Tools | Headless `combat/headless/trace_main.tscn` (trace a request, diff two traces); console `trace on|off` (records the client side in local play) | system (`combat/headless/`, `game/dev/commands/`) |
| Goldens | Combat goldens and `golden/game/run_scripted.json` re-recorded; golden traces committed beside the combat goldens | system (`tests/fixtures/golden/`) |

Nothing in `content/`, `presentation/` or `godot_gas/` changes. The state hash format stays `hash-v1`, byte for
byte: only *when* it is computed changes.

**Backend components:** none at runtime, and none exist yet that read action logs (no server stores them before
slice 2b), which is why the breaking change costs nothing now. The C# change is two records and one enum.
Enterprise mapping (`README.md`): this is the trade-confirmation pattern. A settlement system confirms a trade on
its final economics (one hash, one verdict), not on every intermediate calculation; when a confirmation breaks,
operations re-runs the trade through a debug pricer with full intermediate output, offline. The trace is that debug
pricer: off the hot path, never part of the message, and able to point at the exact step that diverged.

**Scope:** battle checkpoints only. Run checkpoints (`RunSnapshot` on checkpoint actions in
`specs/server-authority.md`, the run hash, field mode's `resultHash`) are a different mechanism and stay.
Out of scope: faster canonical text (slice 8 option 2), warm verifier processes (slice 8 option 1).

## 2. Sequence flow
No client → server traffic. In-process, same `Battle` code in both modes.

### A. Client mode (record)
```
presentation / console ── submit_action / submit_ult ──▶ ActionRecorder
Battle.run(recorder)
  party turn, One More, party interrupt, dev decision:
      action resolves → triggers, deaths, end check
      recorder.after_party_turn(battle, unit, action)        (was: …, checkpoint)  ─▶ entry {turn, actor, ability, target[, extra][, interrupt]}
      recorder.after_interrupt(battle, unit, action)         (was: …, checkpoint)
      trace?.point(...)                                       ◀── only when a trace is attached
  enemy turn, enemy interrupt:   trace?.point(...)
  end: final_hash = state_hash()   (the only hash of the battle when no trace is attached)
  battle_ended(outcome, final_hash) ─▶ recorder.action_log(battle) = {schemaVersion: 2, actions, claimedOutcome, claimedFinalHash}
```

### B. Replay mode (verify)
```
godot --headless --path client-godot res://combat/headless/replay_main.tscn -- --in request.json --out result.json
  ReplayRunner: actionLog.schemaVersion != 2 → runner error, exit 1 (as today for unknown versions)
  each party decision: validate turn, actor, extra/interrupt flags, ability, target   (unchanged)
  after_party_turn / after_interrupt: advance the cursor                              (no hash, no compare)
  end: TurnLimitExceeded → TrailingActions → OutcomeMismatch → FinalHashMismatch      (unchanged order)
  exit 0 Verified, 2 Rejected (2002), 1 runner error
```
**What a tamper now looks like.** The replay still stops at the first mismatch. A tamper that breaks the log's
structure is caught at its turn, as today: `TurnMismatch`, `ActorMismatch`, `IllegalAbility`, `InvalidTarget`,
`LogExhausted`. A tamper that is structurally legal (a different valid target, an interrupt moved to another legal
window, one deleted while the rest still fits) plays on and is caught at the end as `OutcomeMismatch` or
`FinalHashMismatch`, with `mismatch.turn` = the battle's last turn. It is still 2002, still deterministic (same
input, same reason, same turn), so acceptance scenario 5 holds. What is lost is only *where* a legal-but-different
log diverged, and that is the trace's job.

**`mismatch.turn` changes meaning:** it is the turn where the replay **noticed** the mismatch, not where the log
diverged. A legal tamper can surface many turns later as a structural reason: `squad-seed-42-tampered-target` is
tampered at turn 4 and rejected with `InvalidTarget` at turn 11, because a later logged target is already dead.
Nothing (logs, metrics, slice 3's anti-cheat event) may read `mismatch.turn` as the location of the tamper; the trace
gives that (`test_trace_locates_tamper`).

### C. Determinism trace (tests and dev only)
```
var trace := BattleTrace.new(with_lines)     # with_lines: also keep each point's canonical lines
battle.trace = trace                         # before run(); null (default) = no trace, zero hashing
await battle.run(controller)
trace.to_json()                              # trace file (3.3)
BattleTrace.diff(a, b) → {} or the first divergent point
```
**Trace points** (one per action, in the order they happen):

| Kind | Recorded | Where in `Battle` |
|---|---|---|
| `start` | Once, after battle-start events, triggers and deaths, before the first window | `run()` |
| `turn` | Every turn's end, party **and** enemy, also when the actor died at turn start and didn't act (`ability` null) | where the party checkpoint is today, moved out of the `is_party()` branch |
| `extra` | Every One More | `_extra_action` |
| `interrupt` | Every ult interrupt, party **and** enemy | `_interrupt` |
| `dev` | Every dev decision (local mode only) | `_apply_dev` |
| `end` | Once, `hash` = `final_hash` | `run()` after the loop |

Each point: `{i, turn, kind, actor, ability, target, hash}` and, with lines, `lines`. `hash` is
`StateHasher.compute` at that point, identical to what the checkpoint was, so a trace of a v1-era battle's party
points equals its old checkpoints. A hashing error at a trace point (`NonIntegerAttribute`, `AnonymousActiveEffect`)
is a runner error, as it is at the final hash; a trace never hides one that the final hash would miss, and the
battle without a trace still fails at the end.

**Diff** (`BattleTrace.diff(a, b)`): walks both traces point by point and returns the first point where `kind`,
`turn`, `actor`, `ability`, `target` or `hash` differ, or where one trace ends early. When both sides have lines it
adds the canonical lines only in `a` and only in `b` (multiset difference, so duplicate effect lines count), e.g.
`- attr=E1|hp|120000|84000` / `+ attr=E1|hp|120000|83900`. With hashes only it reports the point, the action and both
hashes. The result is printable as plain text (`BattleTrace.describe(divergence)`), which every user of the diff
prints.

**Uses:**
1. **Same request, two fresh processes** (nondeterminism: dictionary order, uninitialised state, a frame await):
   `trace_main` runs the request in process A and process B with lines; the helper diffs them.
2. **Record vs replay** (the client and the verifier disagree): `trace on` in the console attaches a trace to the
   client's battles in local mode and writes `user://traces/<battleId>.record.json` with the request
   (`<battleId>.request.json`) when the battle ends (`DevConsole.trace_battles` / `traces_dir`; the trace is attached
   on `RunController.battle_started`; a `/` in the battle id becomes `_`, e.g. `run-7_f0_c40_dev0`);
   `trace_main --in <request> --lines` writes the replay side;
   `trace_main --diff` prints the first divergent action.
3. **Golden drift** (a code change altered a golden): the committed golden trace is compared with a fresh one (3.3,
   "Golden traces"); the golden test prints the divergence on failure.
4. **A production false 2002 (slice 3+):** the rejected `ReplayRequest` is kept by the worker (slice 3 decides
   where), and a developer reruns it locally with use 2's replay side and use 1 for nondeterminism. Nothing here
   depends on slice 3.

### Headless tool: `combat/headless/trace_main.tscn`
```
godot --headless --path client-godot res://combat/headless/trace_main.tscn -- --in request.json --out trace.json [--lines] [--content-root res://tests/fixtures/]
godot --headless --path client-godot res://combat/headless/trace_main.tscn -- --diff a.trace.json b.trace.json
```
- Trace mode replays the request exactly as `replay_main` does (same `ReplayRunner`, same content-root default), with
  a trace attached, and writes the trace file. It does not stop at a replay mismatch's verdict: the trace covers the
  points up to where the battle stopped, and the file records the verdict and reason alongside (so a 2002 trace ends
  at the rejecting point). Exit codes as `replay_main`.
- Diff mode prints `BattleTrace.describe(...)` and exits 0 when the traces match, 3 when they diverge, 1 on bad input.
- Like every headless entry point here, it always exits (`--quit-after` in callers, script errors → exit 1).

## 3. Data contracts

### 3.1 `Rpg.Contracts.Battle` (breaking: ActionLog v2)
```csharp
namespace Rpg.Contracts.Battle;

/// Produced by the client's ActionRecorder. Only party decisions; enemy turns are re-derived.
/// v2 (spec atomic-battles): a battle is verified as one unit; entries carry no per-action state hash.
public sealed record ActionLog(
    int SchemaVersion,                       // 2
    IReadOnlyList<ActionEntry> Actions,
    BattleOutcome ClaimedOutcome,
    string ClaimedFinalHash);                // lowercase hex SHA-256, state hash v1 at the end of the battle

public sealed record ActionEntry(
    int Turn,                                // global turn index (1-based); for an interrupt, its window's turn
    string Actor,                            // "P1".."P4"
    string Ability,                          // the BattleAbility's ability_tag
    string? Target,                          // primary target unit id, null for SELF/ALL_*
    bool? Extra = null,                      // true for a One More (spec item-pass); omitted otherwise
    bool? Interrupt = null);                 // true for a party ult cast out of turn (spec ult-interrupts); omitted otherwise

public enum MismatchReason
{
    TurnMismatch, ActorMismatch, IllegalAbility, InvalidTarget,
    // CheckpointMismatch removed (spec atomic-battles): no per-action hashes in the log
    LogExhausted, TrailingActions, OutcomeMismatch, FinalHashMismatch, TurnLimitExceeded,
}
```
- `ReplayMismatch.Turn`'s doc comment changes to "the simulated turn at which the replay detected the mismatch (not
  necessarily where the log diverged)" (section 2.B).
- `BattleSnapshot` (v1/v2), `ReplayRequest`, `ReplayResult` and `ReplayMismatch` are otherwise unchanged.
  `ReplayResult.schemaVersion` stays 1: its shape doesn't change and no verifier ever emits the removed reason.
- JSON field order of an entry: `turn, actor, ability, target[, extra][, interrupt]` (the Godot side writes the same
  order; the contract tests cross-check it against the goldens).
- Enum names serialize as strings (`RpgJson`), so removing a member renumbers nothing on the wire.
- **v1 is not accepted** (decided 2026-10-22): the verifier reads v2 only. A v1 log is an unsupported
  `schemaVersion`, a runner error (exit 1) like any unknown version; slice 3 rejects it with HTTP 400 before it
  reaches a worker. No v1 logs exist outside the goldens, which are re-recorded.

### 3.2 Godot side
- `ActionRecorder.entry(turn, unit_id, action, extra := false, interrupt := false)`; `build_log` writes
  `"schemaVersion"` = `ReplayRunner.ACTION_LOG_SCHEMA_VERSION` (2); the result keeps writing
  `ReplayRunner.RESULT_SCHEMA_VERSION` (1).
- Request check: every action needs `turn`, `actor`, `ability` (no `checkpoint`). A v2 entry with a key outside
  `ReplayRunner.ENTRY_KEYS` (`turn, actor, ability, target, extra, interrupt`) is a runner error (`unknown field "checkpoint" in action 3`),
  so a half-migrated client fails loudly in dev instead of having the key silently ignored.
- Controller interface (`Battle` header comment): `after_party_turn(battle, unit, action)` and
  `after_interrupt(battle, unit, action)`. Implementers: `ActionRecorder`, `ReplayController`,
  `tests/scripted_controller.gd`.
- `Battle.trace: BattleTrace = null`. `StateHasher.compute_count` (static int, incremented per `compute`) lets a test
  prove the one-hash rule; it is never hashed or logged.

### 3.3 Trace file (Godot-only, never on the wire, no C# record)
```json
{
  "traceVersion": 1,
  "hashVersion": "hash-v1",
  "battleId": "ult-seed-7",
  "engineVersion": "4.7.2.stable.mono.official.ed1daf0bf",
  "verdict": "Verified",
  "reason": null,
  "points": [
    {"i": 0, "turn": 0, "kind": "start", "actor": null, "ability": null, "target": null, "hash": "…"},
    {"i": 1, "turn": 0, "kind": "interrupt", "actor": "P1", "ability": "Fixture.Ability.UltNova", "target": null, "hash": "…",
     "lines": ["+attr=E1|hp|…", "-attr=E1|hp|…"]}
  ]
}
```
- `lines` (only with `--lines` / `with_lines`) is **delta-encoded**: point 0 holds its full canonical lines (each
  prefixed `+`), every later point holds `+line` / `-line` against the previous point (multiset difference, sorted:
  removals first, then additions, each in canonical order). `BattleTrace.rebuild` and the diff rebuild the full lines
  at any point as a **sorted** multiset (the deltas can't keep the canonical order, so a rebuilt state can be compared
  but not re-hashed). This keeps a lined trace small: the golden traces are 4–21 KB.
- `verdict` / `reason`: `"Recorded"` and null for a client-side trace; the replay verdict and `mismatch.reason` for a
  replay trace; `"RunnerError"` and the message when the replay hit a runner error (the trace up to there is still
  written).
- Written with `WireJson.stringify` (stable key order), so the same battle always writes the same bytes.
- **Golden traces:** each combat golden `tests/fixtures/golden/<name>.json` gets `<name>.trace.json` (with lines),
  written by `--update-goldens` together with the result. They are test data, re-recorded on purpose with the
  goldens; the golden test compares a fresh trace with them only when a result differs, to explain the failure.

### RabbitMQ / Redpanda / Redis
N/A: no queues, topics or keys. When slice 3 adds `verify.battle`, the job payload is a v2 `ReplayRequest`.

## 4. Failure modes

| Situation | Behaviour | Test |
|---|---|---|
| Honest battle, record then replay | `Verified`; the replay never hashes before the end | `test_record_then_replay_verifies` (migrated), `test_one_hash_per_battle` |
| One hash per battle, both modes | `StateHasher.compute_count` rises by exactly 1 per battle with no trace attached, for record and replay, on a battle with One Mores and interrupts | `test_one_hash_per_battle` |
| Trace attached | Final hash and log identical to the same battle without a trace (the trace only observes) | `test_trace_does_not_change_battle` |
| Tampered target (still a valid target) | `Rejected` 2002, `InvalidTarget` at that turn, or `OutcomeMismatch` / `FinalHashMismatch` at the end; the same reason and turn on a second run | `test_tamper_target` (migrated) |
| Tampered ability / actor / turn | `IllegalAbility` / `ActorMismatch` / `TurnMismatch` at that turn (unchanged) | `test_tamper_ability`, `test_tamper_actor`, `test_tamper_turn` |
| Interrupt moved to another legal window | `TurnMismatch` if its window is gone or a later entry no longer fits, else `OutcomeMismatch` / `FinalHashMismatch`. Measured on the ult trial recording: `TurnMismatch` | `test_tampered_interrupts` (migrated) |
| Interrupt deleted | Caught at the next structural check or at the end. Measured: `TurnMismatch` on the ult trial recording (the next entry's turn no longer fits); `FinalHashMismatch` for 5 of `ult-seed-7`'s entries; `OutcomeMismatch` in `ult-close-seed-2-tampered-outcome`. Deterministic | `test_tampered_interrupts` (migrated), `test_golden_replays` |
| Edited claimed hash / outcome | `FinalHashMismatch` / `OutcomeMismatch` (unchanged) | `test_claim_mismatch` |
| Truncated log / extra entries | `LogExhausted` / `TrailingActions` (unchanged) | `test_log_exhausted`, `test_trailing_actions` |
| v1 log (`schemaVersion` 1) | Runner error, exit 1, message names the version | `test_malformed_input` (new case) |
| v2 entry with a `checkpoint` (or any unknown) key | Runner error, exit 1 | `test_malformed_input` (new case) |
| Hashing error mid-battle with no trace (fractional attribute, anonymous effect) | Still a runner error, now at the final hash instead of at the next party action | `test_non_integer_attribute` (migrated) |
| Same request, two fresh processes, trace on | Identical trace files byte for byte | `test_trace_two_processes` |
| Legal tamper surfacing late | The trace diff of an honest golden against its tampered copy puts the first divergence at the tampered turn (`squad-seed-42`: turn 4), although the verdict reports turn 11 | `test_trace_locates_tamper` |
| Legal tamper reaching the end | `FinalHashMismatch` / `OutcomeMismatch` from the simulation, in a fresh process | `test_golden_replays` (`-tampered-final`, `-tampered-outcome` goldens) |
| Diverging traces | `diff` returns the first divergent point with its action and the differing lines; `describe` prints them | `test_trace_diff` (synthetic traces: hash-only, lined, one ends early, duplicate effect lines) |
| Record vs replay with trace on | Identical points (a client-recorded trace equals the replay trace of its own request, except `verdict`) | `test_trace_record_vs_replay` |
| Golden result changed | Golden test fails and prints the first divergent point against the committed `.trace.json` | `test_golden_replays` (also: every golden has its `.trace.json`); self-check `test_golden_trace_explains_a_change` (an altered golden trace gives a printed divergence) |

**Acceptance scenario 5 (tampered action log → deterministic rejection with 2002):** still covered at the runner
level by the tamper tests above, each run twice (same reason, same turn), and by the tampered goldens in fresh
processes. End-to-end through the API is slice 3.

**Idempotency, retries, dead-lettering:** N/A, no queues. A replay is still a pure function of its input, so slice
3's at-least-once redelivery stays safe; the trace is never attached in the worker path.

**Rejected request triage (slice 3 note, not built here):** the worker keeps the request of every 2002 so it can be
traced locally (2.C use 4). That is the replacement for reading the turn off a `CheckpointMismatch`.

## 5. Observability
N/A: no server process. Effect on slice 3's planned metrics: `rpg_replay_verdicts_total{verdict, error_code,
reason}` loses the `CheckpointMismatch` reason value (bounded label set, now nine values) and
`rpg_replay_duration_seconds` should drop by the checkpoint share (30–50% of simulation time on the fixture
battles). Slice 8's verifier-cost note gets the measured number after implementation (`test_one_hash_per_battle`
proves the count; a one-off timing of the ult goldens before and after is recorded in the roadmap, not in a test).
**Measured 2026-10-22** (`ult-seed-7`, median of 20 in-process runs): turn loop 10.6 → 5.2 ms, whole in-process job
~19 → ~13 ms; details and what remains (the per-request `ContentIndex`, process startup) in `specs/roadmap.md` slice 8.

## 6. Test plan

### Unit and system tests (GDScript, `client-godot/tests/`)
- **New `tests/combat/test_atomic_battles.gd`:** `test_one_hash_per_battle`, `test_trace_does_not_change_battle`,
  `test_trace_points` (on the ult trial: a `start` point, one `turn` point per turn for both sides including a unit
  that died at turn start, `extra` for each One More, `interrupt` for party and enemy ults, `end` with
  `hash == final_hash`; party `turn`/`extra`/`interrupt` points line up 1:1 with the log's entries),
  `test_trace_lines_delta` (a test subclass keeps each point's full `StateHasher.canonical_lines`: the sorted rebuild
  from the deltas equals them sorted, hashing them in canonical order gives the point's `hash`, and later points hold
  fewer lines than point 0), `test_trace_diff`, `test_trace_record_vs_replay`,
  `test_trace_two_processes` (two `trace_main` processes via `OS.execute`, with `--quit-after`),
  `test_trace_locates_tamper` (traces of `squad-seed-42` and `squad-seed-42-tampered-target`: first divergent point
  is the turn-4 `turn` point with target E2 vs E3, while the replay verdict is `InvalidTarget` at turn 11).
- **Migrated:** `test_replay.gd` (remove `test_tamper_checkpoint`; `test_tamper_target` accepts
  `InvalidTarget`/`OutcomeMismatch`/`FinalHashMismatch`; `test_malformed_input` gains the v1 and unknown-key cases;
  determinism test compares logs and final hashes), `test_ult_interrupts.gd` (field-order test without `checkpoint`;
  "each interrupt has its own checkpoint" becomes "each interrupt has its own trace point"; moved/deleted interrupt
  tamper reasons as in section 4), `test_dev_battle.gd` (dev entry without `checkpoint`), `scripted_controller.gd`.
- **Dev tools:** `test_console_trace` (`tests/game/test_dev_console.gd`): `trace on`, one auto battle on the ult
  trial, the saved request verifies and its replay trace equals the saved record trace, `trace off`. The same path
  through `dev_run.tscn` and `trace_main --diff` was checked by hand on 2026-10-22 ("traces match", exit 0; the honest
  vs tampered squad goldens exit 3 with the turn-4 divergence). Headless parity per `specs/dev-tools.md`.

### Golden vectors (re-recorded on purpose)
- Combat goldens: `duel-seed-1`, `squad-seed-42`, `break-seed-11`, `run-v2-seed-7`, `ult-seed-7` (requests lose
  `checkpoint`, `schemaVersion` 2; results unchanged except where the run is tampered). **Final hashes must not
  change:** the hash format and the simulation are untouched, so every `finalStateHash` in a re-recorded result
  equals the old one; a changed final hash is a bug in this slice, not a re-record.
- Tampered goldens, reasons measured 2026-10-22 by replaying them with the checkpoint compare switched off:

  | Golden | Tamper | Before | After |
  |---|---|---|---|
  | `squad-seed-42-tampered-target` | turn 4 target E2 → E3 | `CheckpointMismatch` @ 4 | `InvalidTarget` @ 11 (a later logged target is dead because of the tamper) |
  | `ult-seed-7-tampered-turn` | interrupt moved turn 0 → 1 | `CheckpointMismatch` @ 1 | `TurnMismatch` @ 2 |

  The other five goldens stay `Verified` with the same outcome and turn count.
- **New tampered goldens for the end-of-battle reasons.** After this slice `OutcomeMismatch` and
  `FinalHashMismatch` are the only defence against a legal tamper, and neither tampered golden above reaches them.
  Two more, found at implement time by searching single-entry tampers (another target, an interrupt one turn later,
  an entry deleted), chosen so the simulation itself diverges (editing the claim fields is `test_claim_mismatch`):
  - `<name>-tampered-final`: a legal tamper that plays to the same outcome with a different state →
    `FinalHashMismatch` at the battle's last turn.
  - `<name>-tampered-outcome`: a legal tamper that changes how the battle ends (e.g. Victory becomes Defeat) →
    `OutcomeMismatch`. A tamper that leaves the battle still going when the log runs out is `LogExhausted` and
    doesn't count.
  If no single-entry tamper of the existing goldens gives one of them, the search widens to fixture battles recorded
  for it (new seed or encounter), and the spec sync records which golden it came from.

  Built 2026-10-22 (written by `test_golden.gd` with `--update-goldens`):

  | Golden | Tamper | Verdict |
  |---|---|---|
  | `squad-seed-42-tampered-final` | entry 3 (turn 5, P4 Poison) target E3 → E2 | `FinalHashMismatch` @ 27, still Victory |
  | `ult-close-seed-2-tampered-outcome` | entry 11 deleted | `OutcomeMismatch` @ 15: claimed Victory, simulated Defeat |

  No single-entry tamper flipped the outcome of the existing goldens, nor of 120 other fixture battles (5 scenarios ×
  24 seeds): the scripted party wins too comfortably. So the outcome golden comes from a **close** battle,
  `ult-close-seed-2` (`test_golden._close_ult_snapshot()`: the ult trial, seed 2, both ultists carried in at 60000 of
  120000 HP). It is recorded during the update but is not a golden itself.
- New `<name>.trace.json` beside each combat golden (3.3).
- `golden/game/run_scripted.json`: battle entries in the run log lose `checkpoint`; the run's own hashes and
  checkpoints are untouched, so only the battle entries' text changes.
- `hash-v1-sample` is unchanged (the hash format doesn't change), which the test asserts as today.

### .NET (`tests/Rpg.Contracts.Tests`)
- `BattleContractTests`: `ActionEntry` round-trip without `checkpoint` (plain, `extra`, `interrupt`); `ActionLog`
  with `schemaVersion` 2; a `ReplayResult` golden using a remaining reason (e.g. `FinalHashMismatch`); the
  cross-check against the Godot golden files reads the re-recorded v2 requests.
- `MismatchReason` member list pinned (nine names, in order), so a reason added or dropped on one side fails here.

### Specs to update in the same slice (`/sync-spec`)
`combat-replay-core` (flow diagrams, step 10 of the turn, 3.2 contracts and reasons, the meaning of
`mismatch.turn` and "the replay stops at the first mismatch; `mismatch.turn` is where it happened", section 4
table, the "Same inputs twice" row), `item-pass` (One More "checked like any party action", the `extra=` "at a checkpoint" wording),
`ult-interrupts` (window diagram's "checkpoint → log", `_interrupt` step 5, replay B), `dev-tools` 3.6 (dev entry
shape) and the trace command, root `CLAUDE.md` (combat row: "state hash v1, recorder" text and the `ActionLog`
description), `specs/roadmap.md` (1c4b status, slice 8 note). `server-authority` has no battle-checkpoint text
(its checkpoints are run checkpoints), so it only needs its `ActionLog` references read for "v1".

### Remaining work
- **`test_trace_points`** asserts every turn number has a point, but the ult trial may not contain a unit that dies
  at turn start; a fixture battle that does (1c5) makes that case explicit.
- **`trace_main --diff` exit 3** is checked by hand only; `test_trace_two_processes` covers exit 0.

### Suggested implementation order (tests green at each)
1. Trace first, checkpoints still in place: `BattleTrace`, trace points, `trace_main`, diff, golden traces. Proves
   the trace's party points equal today's checkpoints.
2. Drop checkpoints: contract v2 (C# and Godot together), controllers, replay runner, mismatch reason, tests and
   goldens re-recorded (final hashes unchanged).
3. Console `trace` command, the dev_run check, spec sync, roadmap.
