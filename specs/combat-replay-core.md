# Spec: combat-replay-core (slice 1)

Status: 📝 Reviewed, ready to implement · Roadmap: slice 1 · Date: 2026-10-19

## 1. Purpose & enterprise mapping
Build the deterministic battle kernel that both the player's client and the server's verifier run, and pin down the
three things the root `CLAUDE.md` lists as still unspecified: **turn order**, the **replay log schema** and the
**state hash**.

After this slice:
- A battle runs headless from `(snapshot, seed)` plus the player's choices, using GodotGAS for all combat math.
- The client mode **records** the player's choices into an action log as the battle is played.
- The replay mode **re-runs** a battle from `(snapshot, actionLog)` and returns a verdict: `Verified`, or `Rejected` with
  `errorCode` 2002 and the first point of divergence.
- Same inputs → same final state hash, in the same process, in a fresh process, and (later) in the verifier container.

Everything is proven on **frozen test-only fixture content** in `client-godot/tests/fixtures/`. Your real content in
`content/` comes in design break 1 and never affects the system tests.

| Component | Used in this slice | How |
|---|---|---|
| GodotGAS combat (GDScript) | ✅ | The only combat implementation. Abilities, effects, ExecCalcs, turn-based durations (driven by `CombatASC`). |
| `client-godot/combat/` | ✅ new | Turn manager, battle node, replay runner, state hasher, log recorder, headless entry point |
| `client-godot/tests/` | ✅ new | GDScript system tests and fixture content |
| `Rpg.Contracts` | ✅ | C# records for the snapshot, action log and replay result (wire shapes the server stores and forwards later) |
| Server, Postgres, Redis, RabbitMQ, Redpanda | ❌ | N/A: no network or storage in this slice. Checkout is slice 2, verification workflow is slice 3. |

**Enterprise mapping:** this is the *versioned calculation library* that runs identically on the desk and in the
managed compute pool, like a pricing library whose results must reproduce byte-for-byte for audit. Golden vectors
play the role of the library's regression suite.

## 2. Sequence flow
No client → server traffic in this slice. Two in-process flows share one code path (`Battle`), so recording and
replaying cannot drift apart.

**A. Client mode (record)**
```
presentation/ ──start(snapshot)──▶ Battle ──resolve content──▶ UnitDefinitions, EncounterDefinition
                                     │
                                     ├─ turn loop (TurnManager picks actor by action value)
                                     │    turn_start: DoTs/HoTs tick
                                     │    Party turn: wait for submit_action(ability, target) from presentation
                                     │    Enemy turn: EnemyBrain decides (may draw from the battle RNG)
                                     │    → GodotGAS: try_activate → for each baked execution: await gate ◀── execute key / skip
                                     │                                   → row's effect → ExecCalcs (battle RNG)
                                     │    → wait for animation end (or skip)
                                     │    → turn_end: buffs/debuffs count down → death/end checks → AV reset → checkpoint
                                     ├─ ActionRecorder appends {turn, actor, ability, target, checkpoint}
                                     └─ battle_ended(outcome, finalHash) ──▶ presentation (and, in slice 3, /verify)
```
Presentation **listens** to signals (`turn_started`, `execution_resolved`, `unit_died`, `battle_ended`), calls
`submit_action`, and opens the presentation gate from animation events (see "Execution table and animation events").
It never changes combat state directly.

**B. Replay mode (verify)**
```
godot --headless --path client-godot res://combat/headless/replay_main.tscn -- --in request.json --out result.json
  └─ ReplayRunner: parse ReplayRequest → Battle in replay mode
       Party turn: take next log entry; validate turn, actor, ability, target; activate
       after each party turn: compare checkpoint hash
       end: compare outcome and final hash → ReplayResult
  exit code 0 = Verified, 2 = Rejected (2002), 1 = runner error (malformed input, content error)
```
In slice 3 the verifier worker wraps this command; nothing here knows about RabbitMQ.

### Turn order: action value (HSR-style), integers only
- `AV_SCALE = 100_000_000`: HSR's 10 000 gauge, × 100 for two decimals of action value, × 100 because SPD is stored ×100.
- A unit's full action value: `full_av = AV_SCALE / SPD` (integer division, truncating). SPD 100 (stored `10000`) →
  `10000` (= 100.00 AV); SPD 134.5 (stored `13450`) → `7434`.
- **Battle start:** every unit's `av = full_av`.
- **Each turn:**
  1. Actor = living unit with the lowest `av`. **Ties:** Party before Enemy, then lower slot first.
  2. `elapsed = actor.av`; every living unit's `av -= elapsed`.
  3. `turn += 1`; emit `turn_started(actor, turn)`.
  4. **Turn start:** `actor.asc.turn_start()` ticks the actor's periodic turn-based effects (DoTs/HoTs) and counts down
     their duration. Then death and end checks; if the actor died from a tick, it doesn't act (go to 7).
  5. Action: Party → next player choice (client) or next log entry (replay). Enemy → `EnemyBrain`.
     The ability is activated with `await` and runs its baked execution list in order (see "Execution table").
  6. **Turn end:** `actor.asc.turn_end()` counts down the actor's non-periodic turn-based effects (buffs/debuffs) and
     removes the expired ones.
  7. Death check: any unit with `HP` current value `<= 0` is dead, leaves the turn queue, and its ASC is `cleanup()`ed.
  8. End check: all enemies dead → `Victory`; all party dead → `Defeat`.
  9. `actor.av = full_av` using the actor's **current** SPD.
  10. Party turn in replay mode: compute the state hash and compare it to the entry's `checkpoint`.
  11. `turn >= TURN_LIMIT` (1000) without an end → `TurnLimit`. A safety stop for the verifier, not a balance value.
- **SPD changes mid-cycle** (a buff or debuff on `SPD`): the turn manager listens to `attribute_changed` and rescales the
  remaining distance: `av = av * old_spd / new_spd` (integer division). SPD below 1 is a content error.
- Out of scope, but the log schema leaves room for them: action advance/delay, extra turns, ultimates that interrupt
  the order, multiple enemy waves. Adding any of them bumps `schemaVersion`.

### Effect timing: `CombatASC`
GodotGAS's `advance_turn()` ticks DoTs and counts down every turn-based effect in one call. To get "DoTs at turn start,
buffs at turn end", every unit uses `CombatASC` (system, `combat/combat_asc.gd`), a subclass of GodotGAS's
`AbilitySystemComponent`. The addon itself is not edited.

| Method | Affects | Does |
|---|---|---|
| `turn_start()` | `TURN_BASED` effects with `period > 0` (DoTs/HoTs) | Tick (cues, events, math, as `advance_turn` does), then `remaining_turns -= 1`, remove at 0 |
| `turn_end()` | `TURN_BASED` effects with `period == 0` (buffs/debuffs) | `remaining_turns -= 1`, remove at 0 |

- **Whose turn:** an effect counts down on the turns of the unit it is **on**, not the unit that applied it.
- **Applied during the owner's own turn** (e.g. a self-buff): that turn's `turn_end()` does **not** count it down, so
  "2 turns" means your next two turns, as in HSR. `CombatASC` records the turn each effect was applied on to do this.
- `CombatASC` calls the addon's internal tick helpers (`_evaluate_spec`, `_commit_spec_math`, `_trigger_effect_events`).
  Tests pin this behaviour so a GodotGAS upgrade that changes them fails loudly (allowed by the Lyra-style extension
  rule in `client-godot/CLAUDE.md` section 2).
- `advance_turn()` is never called in combat.

**What `duration_turns` means when you author effects** (`policy = TURN_BASED`):

| You make | Set | Result |
|---|---|---|
| Self-buff cast on your turn | `period = 0`, `duration_turns = 2` | Active through the end of your next 2 turns |
| Buff on an ally | `period = 0`, `duration_turns = 2` | Ends at the end of the **ally's** 2nd turn |
| Debuff on an enemy | `period = 0`, `duration_turns = 2` | Ends at the end of the **enemy's** 2nd turn |
| DoT / HoT | `period = 1`, `duration_turns = 3` | Ticks at the start of the target's next 3 turns, then ends |

### Number format: fixed-point ×100
**Every number a designer types is stored ×100 as a whole number.** Designers write values as they mean them, with up to
two decimals; combat only ever sees whole numbers in hundredths.

| You type | Meaning | Stored / used in combat |
|---|---|---|
| `500` | ATK 500 | `50000` |
| `80.5` | 80.5 flat damage | `8050` |
| `150` | 150% multiplier | `15000` |
| `5.25` | 5.25% crit rate | `525` |
| `62.537` | (3rd decimal dropped) | `6253` |

- **Converted once, at edit time.** Our authoring fields (`ExecutionRow`, `UnitDefinition` stats, `CombatModifier`)
  show and accept decimals in the inspector but save the whole number in the `.tres`. Nothing is converted during a battle.
  The conversion is exact: `int(roundi(typed * 1000) / 10)`, so `0.29` becomes `29`, never `28`, and digits after the
  2nd decimal are dropped (with an editor warning).
- **Combat math** uses only `+ − × ÷` on whole numbers, through helpers in `combat/fixed.gd`:
  `mul(a, b) = a * b / 100` (two ×100 values), `pct(value, percent) = value * percent / 10000` (value × percentage),
  integer division truncating toward zero. No `pow()`, `sqrt()`, `exp()` or other math-library functions in combat:
  their last digit can differ between Windows and Linux, which would reject honest players.
- **RNG rolls** for percentages: `rng.randi_range(0, 9999) < chance` where `chance` is the stored value (5.25% → `525`).
- **Display:** presentation divides by 100 and decides how many decimals to show.
- **GodotGAS's own float fields:** `CombatModifier` (Lyra-style subclass of `GameplayEffectModifier`) gives modifiers the
  same decimal authoring: `ADD`/`OVERRIDE` values are stored ×100; `PERCENT_ADD` takes a percentage (`20` = +20%).
  Unit stats are set from `UnitDefinition` through `initialize_attribute_overrides`, so AttributeSet defaults from the
  GodotGAS dashboard are not used for balance.
- **Whole-number snap:** after GodotGAS combines an attribute's modifiers (float math, e.g. +20% of 33333), `CombatASC`
  snaps the current value: within `1e-6` of a whole number → that number; otherwise truncate toward zero. Same result on
  every machine, so percentage buffs stay safe to use.

### Core attribute contract
Combat core reads exactly two attributes by name: **`HP`** (death) and **`SPD`** (turn order). Every unit's
AttributeSet must have both. All other attributes are content. Every attribute value is a whole number in hundredths
(see Number format and State hash).

### RNG
- One `RandomNumberGenerator` per battle, owned by the `Battle` node, `seed` set from the snapshot. Nothing else in
  combat creates an RNG or uses the global `randf()`/`randi()`/`randomize()`.
- ExecCalcs and the enemy brain reach it with `BattleContext.rng_for(node)`, which walks up from the unit to its
  `Battle` ancestor. No autoload or static state, so several battles can run one after another in one process.
- Percentage rolls: `rng.randi_range(0, 9999) < chance` (see Number format). The RNG's final `state` is part of the state hash, so any extra or
  missing draw shows up as a mismatch.

### Execution table and animation events (Dark Souls-style)
An ability's **execution table** says *what* each hit does; its **animation** says *when* each hit lands and *which*
row it uses. Hitboxes are out of scope; targets come from the ability's targeting.

**Execution table.** `BattleAbility.executions: Array[ExecutionRow]`. Each `ExecutionRow` (Resource):

| Field | Meaning |
|---|---|
| `id: StringName` | Name the animation refers to, e.g. `&"slash_heavy"`. Unique within the ability. |
| `effect: GameplayEffect` | The effect to apply (a damage effect, a buff, a DoT...). |
| `damage_mode` | `USE_EFFECT` (no override), `FLAT`, or `SCALED`. |
| `flat_damage` | Used when `FLAT`. Typed as a decimal (`80.5`), stored ×100. |
| `multiplier` | Used when `SCALED`: percentage of the attacker's ATK, typed as `150` for 150%, stored ×100. |
| `targets` | `ALL` (the ability's full target list), `PRIMARY`, or `ADJACENT` (for blast: neighbours of the primary). |

The override travels through GodotGAS's own **SetByCaller** mechanism: the row sets
`spec.set_set_by_caller_magnitude(&"Data.Damage.Flat", ...)` or `(&"Data.Damage.Multiplier", ...)` on the effect spec,
and the damage ExecCalc uses it when present, otherwise its default. (These two `Data.Damage.*` tags are constants in
`combat/`; adding them to your tag registry is optional and only gives you editor dropdowns.)

**Animation events.** On any method track of the ability's `animation` (an `Animation` resource), a key that calls
`execute(&"<row id>")` fires that row. Keys may reuse a row (multi-hit). Other method keys (sound, VFX) are ignored by
combat. To change damage, edit the row; to change the frame, move the key.

**The animation is the source of truth for what executes.** Every `BattleAbility` must have an `animation` with at least
one `execute` key; placeholder enemies and fixtures use a minimal animation resource that holds only `execute` keys and
no art. The execution table only describes what each row does: a row the animation never calls never runs, and a row
called three times runs three times.

**Execution sequence (read at runtime, cached).** The first time an ability activates in a process, combat reads its
animation's `execute` keys and sorts them by `(time, track index, key index)` into a fixed list of row ids, cached per
`Animation` resource. That list alone decides which rows run and in what order. Client and headless use the same reader,
so they can't disagree, and it can't go stale after you edit an animation (no separate bake step).
- **Headless (replay and tests):** loads the `Animation` resource (no rendering) and runs the list instantly.
- **Client:** runs the same list, but before each entry awaits `battle.gate.next_execution()`. When the animation reaches
  an `execute` key, presentation calls `gate.release_execution()`, so damage lands on that frame. Damage numbers appear
  on `execution_resolved`. After the last entry the ability awaits `gate.finished()` (animation end) before the turn ends.
- **Skip** or an animation that ends early releases every remaining entry, in list order, then finishes.
- **Determinism:** playback speed, skipping, dropped frames or a slow machine change *when* executions happen, never
  *which* rows run or in what order. RNG draws happen only inside executions. Animation keys only release the gate; they
  never apply effects, change attributes or draw from the RNG.
- **Animations are combat data:** editing an `execute` key changes the result, so animations are part of the content
  hash behind `ruleset_version` (slice 2). Imported animations (e.g. from `.glb`) must be saved as separate `.res`/`.tres`
  files before adding keys, which Godot requires for editing imported animations anyway.

**Example: a 3-hit sword combo**
```
executions:  slash_light  SCALED   60   (60% ATK)   PRIMARY
             slash_heavy  SCALED  120   (120% ATK)  PRIMARY
             shockwave    FLAT     80.5             ADJACENT
animation:   0.35s execute(slash_light)   0.60s execute(slash_light)
             1.10s execute(slash_heavy)   1.15s execute(shockwave)
baked list:  [slash_light, slash_light, slash_heavy, shockwave]
```

### Zero-frame rule (replay mode)
With the headless gate, a whole battle must finish without yielding a frame (`Engine.get_process_frames()` unchanged
from start to end). An ability that awaits anything other than the gate (a timer, `task_play_animation`, a signal)
breaks this and is reported as a **runner error** (`ContentAwaitedFrame`), not a verdict: it's a content bug, and it
would otherwise make results depend on timing.

### Targeting
`BattleAbility` (system, extends `GameplayAbility`) adds one export, `targeting`:
`SINGLE_ENEMY`, `ALL_ENEMIES`, `BLAST_ENEMY` (target plus neighbours by slot), `SINGLE_ALLY`, `ALL_ALLIES`, `SELF`.
The log records only the **primary target** (or none). The battle expands it to the full target list in canonical
order (slot ascending), so a client can't reorder targets to change the result.

## 3. Data contracts

### 3.1 Content resource classes (system, in `combat/`)
These are the shapes your content will fill in during design break 1. They contain no numbers.

| Class | Fields |
|---|---|
| `UnitDefinition` (Resource) | `id: StringName`, `attribute_set: AttributeSet`, `abilities: Array[PackedScene]` (each a `BattleAbility`), `brain: EnemyBrain` (enemies only) |
| `EncounterDefinition` (Resource) | `id: StringName`, `enemies: Array[UnitDefinition]` (slot order) |
| `BattleAbility` (extends `GameplayAbility`) | `targeting` (above), `executions: Array[ExecutionRow]`, `animation: Animation` (optional). `ability_tag` must be unique per unit. |
| `ExecutionRow` (Resource) | `id`, `effect`, `damage_mode`, `flat_damage`, `multiplier`, `targets` (see "Execution table"). Decimal authoring, stored ×100. |
| `CombatModifier` (extends `GameplayEffectModifier`) | Same decimal authoring for modifier magnitudes (see "Number format"). |
| `UnitDefinition` stats | `stats: Dictionary[String, float]` authored as decimals, saved ×100, applied with `initialize_attribute_overrides`. |
| `CombatASC` (extends `AbilitySystemComponent`) | `turn_start()`, `turn_end()` (see "Effect timing"). Every battle unit uses it. |
| `PresentationGate` | `next_execution()`, `finished()`, `release_execution()`, `release_finished()`, `skip()`. `HeadlessGate` returns immediately. |
| `EnemyBrain` (Resource) | `choose(unit, battle) -> {ability, target}`. Default: first activatable ability; target drawn with `rng.randi_range` over living party by slot. |

Content is found by id under a **content root**: `res://tests/fixtures/` for system tests, `res://content/` for real
play. The runner scans `<root>/units/` and `<root>/encounters/` and indexes by `id`, sorted for stable order.
`level` is carried in the snapshot and passed to abilities as `ability_level`; what level means is content.

### 3.2 Wire shapes (JSON, camelCase per `RpgJson`; C# records in `Rpg.Contracts.Battle`)
The server never interprets these beyond storing and forwarding them. No stats or formulas in C#: the snapshot holds
identities (`unitDefId`, `level`) and Godot derives everything else from content.

```csharp
namespace Rpg.Contracts.Battle;

/// Frozen at checkout (slice 2). Seed is a decimal string: int64 is not safe as a JSON number in browsers.
public sealed record BattleSnapshot(
    int SchemaVersion,                       // 1
    string BattleId,
    string Seed,                             // "0".."9223372036854775807"
    string EncounterId,                      // e.g. "fixture.encounter.duel"
    IReadOnlyList<PartyMemberSnapshot> Party);

public sealed record PartyMemberSnapshot(int Slot, string UnitDefId, int Level);   // slot 1..4

/// Produced by the client's ActionRecorder. Only party decisions; enemy turns are re-derived.
public sealed record ActionLog(
    int SchemaVersion,                       // 1
    IReadOnlyList<ActionEntry> Actions,
    BattleOutcome ClaimedOutcome,
    string ClaimedFinalHash);                // lowercase hex SHA-256

public sealed record ActionEntry(
    int Turn,                                // global turn index (1-based) when this party unit acted
    string Actor,                            // "P1".."P4"
    string Ability,                          // the BattleAbility's ability_tag
    string? Target,                          // primary target unit id ("E1", "P2"), null for SELF/ALL_*
    string Checkpoint);                      // state hash at the end of this turn

public sealed record ReplayRequest(BattleSnapshot Snapshot, ActionLog ActionLog);

public sealed record ReplayResult(
    int SchemaVersion,                       // 1
    string BattleId,
    ReplayVerdict Verdict,
    int? ErrorCode,                          // 2002 when Rejected, else null
    string? Error,                           // "ReplayMismatch" when Rejected, else null
    ReplayMismatch? Mismatch,
    BattleOutcome Outcome,                   // what the verifier's own simulation reached
    int Turns,
    string FinalStateHash,
    string EngineVersion);                   // Engine.get_version_info()["string"], e.g. "4.7.2.stable.mono.official"

public sealed record ReplayMismatch(MismatchReason Reason, int Turn, string Detail);

public enum ReplayVerdict { Verified, Rejected }
public enum BattleOutcome { Victory, Defeat, TurnLimit }
public enum MismatchReason
{
    TurnMismatch,        // next entry's turn != the simulated turn of the next party action
    ActorMismatch,       // entry's actor isn't the unit whose turn it is
    IllegalAbility,      // not granted to that unit, or can_activate_ability is false (cost, cooldown, tags)
    InvalidTarget,       // missing, dead, wrong side, or not allowed for the ability's targeting
    CheckpointMismatch,  // state hash after the turn differs from the entry's checkpoint
    LogExhausted,        // a party unit needs to act but the log has no entries left
    TrailingActions,     // battle ended with entries left in the log
    OutcomeMismatch,     // claimedOutcome differs from the simulated outcome
    FinalHashMismatch,   // claimedFinalHash differs
    TurnLimitExceeded,   // the simulation hit TURN_LIMIT (1000)
}
```
- Unit ids are assigned by the battle, never by the client: party `P<slot>`, enemies `E<slot>` in encounter order.
- **Error contract:** every `Rejected` result carries `errorCode` 2002 and `error` `"ReplayMismatch"`, with the reason
  in `mismatch.reason`. Use code 2002 everywhere (logs, metrics, events); `reason` is the detail, not a new code.
- The replay stops at the **first** mismatch; `mismatch.turn` is where it happened.

### 3.3 State hash (v1)
SHA-256 (Godot `HashingContext`) over a canonical UTF-8 text, lowercase hex. One line per fact, joined with `\n`:
```
hash-v1
turn=<int>
rng=<int>                                  # RandomNumberGenerator.state
outcome=<Ongoing|Victory|Defeat|TurnLimit>
unit=<id>|alive=<0|1>|av=<int>             # units sorted by id
attr=<id>|<name>|<base>|<current>          # per unit, attributes sorted by name
tag=<id>|<tag>|<count>                     # per unit, active tags sorted
effect=<id>|<resource_path>|<remaining_turns>|<stack_count>|<suppressed 0|1>   # per unit, sorted
```
- **Whole numbers only.** Values are hashed as stored (hundredths). Each attribute value must be integral (after the
  `CombatASC` snap) and within ±2^53; otherwise it's a runner error (`NonIntegerAttribute`), because a fraction means
  some math escaped the fixed-point rules.
- **Excluded on purpose:** `GameplayEffectSpec.application_time` (wall clock), cue state, node names and paths,
  anything in `presentation/`.
- Active effects must come from saved `.tres` resources, so `resource_path` is stable. An active effect without a path is
  a runner error (`AnonymousActiveEffect`).
- `hash-v1` is versioned so a later change to the hash format is explicit.

### RabbitMQ / Redpanda / Redis
N/A: no queues, topics or keys in this slice.

## 4. Failure modes

| Situation | Behaviour | Test |
|---|---|---|
| Same inputs twice, same process | Identical final hash and identical checkpoint sequence | `test_determinism_same_process` |
| Same inputs, fresh Godot process | Identical to the committed golden hash | `test_golden_replays` (each golden runs in its own `godot --headless` process) |
| Tampered target | `Rejected` 2002, `InvalidTarget` or `CheckpointMismatch` at that turn | `test_tamper_target` |
| Tampered ability (not granted / on cooldown) | `Rejected` 2002, `IllegalAbility` | `test_tamper_ability` |
| Wrong actor or turn | `ActorMismatch` / `TurnMismatch` | `test_tamper_actor`, `test_tamper_turn` |
| Edited checkpoint | `CheckpointMismatch` at that turn | `test_tamper_checkpoint` |
| Truncated log | `LogExhausted` | `test_log_exhausted` |
| Extra entries | `TrailingActions` | `test_trailing_actions` |
| Wrong claimed outcome or final hash | `OutcomeMismatch` / `FinalHashMismatch` | `test_claim_mismatch` |
| Endless battle | `TurnLimitExceeded` after 1000 turns | `test_turn_limit` |
| Ability awaits anything but the gate | Runner error `ContentAwaitedFrame`, exit code 1 | `test_zero_frame_rule` |
| Ability without an animation, animation without `execute` keys, a key naming a missing row, or duplicate row ids | Content test fails (caught before shipping, never at verify time) | `test_execution_table_valid` |
| Fractional attribute | Runner error `NonIntegerAttribute`, exit code 1 | `test_non_integer_attribute` |
| Malformed JSON / unknown schemaVersion | Runner error, exit code 1 (slice 3 rejects these with HTTP 400 before they reach a worker) | `test_malformed_input` |

**Acceptance scenario 5 (tampered action log → deterministic rejection with 2002):** covered at the runner level here,
by the tamper tests, each run twice to prove the rejection itself is deterministic (same reason, same turn).
End-to-end through `/verify` is completed in slice 3.

Idempotency, retries, dead-lettering: N/A, no queues. A replay is a pure function of its input, which is what makes
slice 3's at-least-once redelivery safe.

## 5. Observability
N/A: no server process in this slice. For slice 3, `ReplayResult` already carries what the worker will turn into metrics:
verdict and `mismatch.reason` (labels on a `rpg_replay_verdicts_total{verdict, error_code, reason}` counter), `turns`,
and the runner's wall time (a `rpg_replay_duration_seconds` histogram, measured by the worker, never hashed).

## 6. Test plan

### Test runner (GDScript)
A small in-house runner, `client-godot/tests/run_tests.gd` (system), run with
`godot --headless --path client-godot --script res://tests/run_tests.gd`. It discovers `res://tests/**/test_*.gd`,
runs every `test_*` method, prints results and exits non-zero on any failure. No new addon.

### Fixture content (`client-godot/tests/fixtures/`, frozen, never references `content/`)
- `FixtureAttributeSet` with `HP`, `MaxHP`, `ATK`, `DEF`, `SPD`, `CritRate`, `CritDmg` (all stored ×100), with clamps.
- Units: `fixture.unit.striker` (single-target hit), `fixture.unit.sweeper` (ALL_ENEMIES), `fixture.unit.support`
  (SPD buff on an ally), `fixture.unit.dummy` (enemy with default brain), `fixture.unit.poisoner` (turn-based DoT).
- ExecCalc `FixtureDamage`: the integer formula from `specs/design/combat-design.md` including the RNG crit roll, so
  every replay exercises the RNG, with `BaseDmg` taken from the `Data.Damage.Flat` / `Data.Damage.Multiplier`
  SetByCaller values when a row sets them.
- `fixture.ability.combo`: the 3-hit example above, with a saved fixture `Animation` resource carrying the `execute` keys.
- Encounters: `fixture.encounter.duel` (1v1), `fixture.encounter.squad` (3v3), `fixture.encounter.stalemate`
  (nobody can deal damage, for the turn limit).
- Tags use the `Fixture.*` namespace and are **not** added to your tag registry (GodotGAS only uses the registry in
  the editor).

### Unit tests
- **Turn order:** SPD 100 vs 160 produces the precomputed sequence for 20 turns; ties resolve Party-then-slot; a SPD buff
  mid-cycle rescales remaining AV; a dead unit leaves the queue.
- **Effect timing:** a 2-turn DoT ticks at the start of the victim's next two turns, then is gone; a 2-turn debuff on an
  enemy lasts through the end of that enemy's second turn; a self-buff applied on your own turn covers your next two
  turns; a DoT that kills at turn start stops the unit acting.
- **Execution table:** the baked list for a fixture animation matches its keys sorted by time (ties by track, then key);
  `FLAT`, `SCALED` and `USE_EFFECT` rows produce the expected integer damage through the fixture ExecCalc's SetByCaller
  path; `PRIMARY`/`ADJACENT`/`ALL` hit the right units; a row called twice by the animation runs twice; a row never
  called never runs; the cached list is reused on the second activation.
- **Number format:** typed `0.29`, `80.5`, `150`, `62.537` save as `29`, `8050`, `15000`, `6253`; `fixed.mul`/`fixed.pct`
  truncate toward zero for positive and negative values; the `CombatASC` snap turns `9999.9999999` into `10000` and
  `6666.6` into `6666`; a purity guard finds no `pow(`, `sqrt(`, `exp(`, `log(`, `sin(`, `cos(` in `combat/` or fixture ExecCalcs.
- **Gate:** the 3-hit fixture ability gives the same state hash played with the client gate released key by key,
  skipped after the first hit, skipped immediately, and with the headless gate. A content test rejects an `execute` key
  naming a missing row.
- **RNG:** same seed → same draw sequence; two battles in one process don't share RNG state.
- **State hash:** a hand-built state hashes to a committed expected value (tests the hasher alone); the hash ignores
  `application_time`; attribute or tag insertion order doesn't change it; a fractional attribute raises `NonIntegerAttribute`.
- **Recorder ↔ replay:** a scripted client plays a battle in record mode; replaying its log returns `Verified` with the
  same final hash.
- **Purity guards:** no `randf(`, `randi(`, `randomize(` or `RandomNumberGenerator.new(` in `combat/` or
  `tests/fixtures/` except in `Battle`; nothing under `tests/fixtures/` references `res://content/`; no `DURATION`
  policy or real-time `period` on fixture effects.

### Golden vectors (`client-godot/tests/fixtures/golden/`)

| File | Proves |
|---|---|
| `duel-seed-1.json` / `duel-seed-1.result.json` | Smallest full battle: request in, expected `ReplayResult` out |
| `squad-seed-42.json` / `.result.json` | AoE, buffs, DoT ticks, SPD change, deaths mid-battle |
| `squad-seed-42-tampered-target.json` / `.result.json` | Expected rejection, reason and turn |
| `hash-v1-sample.txt` / `.sha256` | Canonical text and hash for the hasher-only test |

Each golden request is replayed in a **fresh** headless process by the test runner and must produce its `.result.json`
byte for byte (except `engineVersion`, which is checked separately against the pinned build).

### C# (`tests/Rpg.Contracts.Tests`)
- The golden request and result files above deserialize into the `Rpg.Contracts.Battle` records and re-serialize with
  `RpgJson.Options` byte for byte, so the C# and GDScript sides agree on every field name and enum spelling.
- `Seed` round-trips as a string; `ErrorCode` is 2002 on every rejected golden.

### Done when
- [ ] `godot --headless ... --script res://tests/run_tests.gd` passes, and the project loads headless with no errors.
- [ ] Every golden replays identically in a fresh process, run twice.
- [ ] `dotnet build` and `dotnet test` pass at the root (C# golden cross-checks).
- [ ] No files changed in `content/`, `presentation/` or `godot_gas/`.
- [ ] CLAUDE.md "Current state" and "Battle workflow decisions" updated (replay log, state hash and turn order are now specified).
- [ ] `client-godot/CLAUDE.md` section 3 updated: abilities may await **only** the presentation gate (executions), never timers
  or animation tasks directly; `advance_turn()` is replaced by `CombatASC.turn_start()`/`turn_end()`.

## Files this slice creates (all system-owned)
```
client-godot/combat/battle.gd, battle_context.gd, fixed.gd, combat_modifier.gd, execution_reader.gd, turn_manager.gd, combat_asc.gd, presentation_gate.gd,
                    headless_gate.gd, battle_ability.gd, execution_row.gd, enemy_brain.gd,
                    unit_definition.gd, encounter_definition.gd, content_index.gd, action_recorder.gd,
                    state_hasher.gd, replay_runner.gd, headless/replay_main.gd(.tscn)
client-godot/tests/run_tests.gd, tests/combat/test_*.gd
client-godot/tests/fixtures/{attributes,abilities,effects,exec_calcs,units,encounters,golden}/...
src/Rpg.Contracts/Battle/*.cs
tests/Rpg.Contracts.Tests/BattleContractTests.cs
```

## Decisions (review, 2026-10-19)
- **Effect timing:** DoTs/HoTs tick at turn start; buffs/debuffs count down at turn end; an effect applied during its
  owner's own turn skips that turn's countdown (HSR). Implemented by `CombatASC`.
- **Animation-timed hits (Dark Souls-style):** each ability has an execution table (effect + flat/scaled damage override
  + targets per row); animation `execute(row)` keys decide when and which row; headless reads them and runs them instantly.
- **Animation is the source of truth for executions:** every ability needs an animation; its `execute` keys are read at
  runtime and cached (no separate bake step); a key may call the same row many times.
- **Number format:** every typed number (flat or percentage) has up to 2 decimals and is stored ×100 as a whole number,
  converted once at edit time; combat uses only integer `+ − × ÷`; `CombatASC` snaps combined modifier results.
- **Turn limit:** 1000 turns.
- **GodotGAS extension:** minimal Lyra-style subclasses in `combat/` are allowed; the addon is never edited.
- **C# battle records now:** `Rpg.Contracts.Battle` is added in this slice, so the golden files lock the GDScript and C#
  shapes together from day one.
- **Test runner:** in-house (`tests/run_tests.gd`, no new addon). Tests are plain GDScript, so moving to gdUnit4 later is cheap.
