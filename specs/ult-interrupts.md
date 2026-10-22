# Spec: ult-interrupts (slice 1c4)

Status: 📝 Draft for review · Roadmap: slice 1c4 · Date: 2026-10-21
Design intent: Honkai: Star Rail ultimates (`specs/design/combat-design.md`, "Ult charge"). Turn order, action log,
checkpoints and state hash: `specs/combat-replay-core.md` (whose log schema leaves room for "ultimates that interrupt
the order"). One More, break, follow-ups: `specs/item-pass.md` 3.1–3.2. Console and script runner:
`specs/dev-tools.md`.

## 1. Purpose & enterprise mapping
Any unit with a full ult charge, party member **or enemy**, can cast its ult **between any two actions**, outside the
turn order and without spending a turn, as in HSR: during the enemies' turns (it fires once the current action is
done) and on your own turn before you act (your turn still follows). Today an ult is an ordinary ability that uses up the caster's turn.

The work is making that deterministic. The log records only party decisions and enemy turns are re-simulated, so the
replay has to know exactly **where** an ult went in. The battle offers interrupts at two fixed points, the **ult
windows**: BETWEEN two actions, and DECISION while a party member chooses its action. A party interrupt is logged with the turn number of its window; an enemy interrupt is
decided by its brain from battle state, so the replay re-simulates it like an enemy turn and it is never logged.
Nothing else changes: same RNG, same hash format, same mismatch reasons.

**What makes an ult an ult is data:** a `BattleAbility` with `Ability.Type.Ultimate` in its `asset_tags` (like
`Ability.Type.FollowUp` from item-pass). The cost effect (100 `energy`) still gates it, so "full charge" stays a GAS
rule and no new code checks energy. Enemies charge through the same passives (`ult_charge`, `ult_charge_hit`) the
party uses; the AttributeSet is shared.

| Area | What | Owner |
|---|---|---|
| Ult windows | BETWEEN every two actions (enemies, then the party) and DECISION on a party turn (section 2) | system (`combat/battle.gd`) |
| Interrupt-only ults | An `Ability.Type.Ultimate` ability can't be a turn action, for either side | system |
| Enemy interrupts | `EnemyBrain.choose_interrupt(unit, battle)`; default: cast the first ult that can activate | system (`combat/enemy_brain.gd`) |
| Action log | Party interrupts: entry gains optional `"interrupt": true`; turn = the window's turn | system + `Rpg.Contracts` |
| Replay | `ReplayController` answers party windows from the log; enemy interrupts re-simulated; tampering is 2002 with existing reasons | system (`combat/replay_runner.gd`) |
| Client input | `ActionRecorder.submit_ult(unit, ability, target)` at any time; queued until the next window | system |
| Retargeting | A queued single-target party ult whose target is gone by its window moves to the nearest valid target | system |
| Console | `ult <unit> <ability> [target]` (headless parity) | system (`game/dev/commands/`) |
| Tags and demo ults | `Ability.Type.Ultimate`; the four party ults and one enemy ult of 3.3 | **yours** (`godot_gas/`, `content/demo/`), approved 2026-10-21 |
| Ult buttons, enemy ult display | Per-member ult buttons in the battle panel, lit when the charge is full, pressable during enemy turns; an enemy's charge and "X unleashes Y!" | **yours** (`presentation/demo/`), approved 2026-10-21 |

**Backend components:** none at runtime. The only cross-boundary change is one optional field on the
`Rpg.Contracts.Battle.ActionEntry` record. The server keeps storing and forwarding action logs without reading them;
the slice 3 verifier runs this replay unchanged. This is the "pricing library whose results must reproduce
byte-for-byte" from `combat-replay-core` with out-of-band orders: an order can arrive at any moment, so it is
sequenced at defined points and the sequence is the audit trail.

Out of scope: enemy brains smarter than "ult when full" (content in 1c5), and the rest of section 8.

## 2. Sequence flow
No client → server traffic. In-process, same `Battle` code in both modes.

### The ult windows
```
run():
  battle start events, triggers, deaths, end check
  while running:
    ┌─ BETWEEN window (window turn = battle.turn; 0 before the first turn) ───────────────────────┐
    │ 1. Enemies, in slot order, each at most once per window:                                    │
    │      i = brain.choose_interrupt(enemy, battle) → {} skips that enemy                        │
    │      validate → _interrupt(i) → triggers, deaths, end check            (not logged)         │
    │ 2. Party, until the controller has none:                                                    │
    │      i = controller.interrupt(battle) → {} closes the window                                │
    │      validate → _interrupt(i) → triggers, deaths, end check → checkpoint → log              │
    └─────────────────────────────────────────────────────────────────────────────────────────────┘
    if one_more_queue not empty: extra action (its decision is a DECISION window too); continue
    next actor by AV → elapse → turn += 1 → turn start ticks, triggers, deaths, end check
    party actor:  choice = controller.choose(battle, actor)              ◀── DECISION window
                  while choice is an interrupt and actor alive and ongoing:
                      validate → _interrupt(choice) → triggers, deaths, end check → checkpoint → log
                      choice = controller.choose(battle, actor)         (ask again; the turn isn't spent)
                  take the action as today
    enemy actor:  brain (unchanged; presses during an enemy turn wait for the next BETWEEN)
    turn end, deaths, end check, AV reset, checkpoint (unchanged)
```
- **BETWEEN** (HSR's "ult during the enemy's turn"): a press while an enemy acts is queued and fires once that action
  and its turn end are done, **before** the next unit's turn starts. So an ult can kill or break the next actor before it
  moves (a break's 25% delay applies normally), heal before the next enemy hits, or land before a DoT tick. The
  window also opens before a One More and before the first turn.
- **DECISION** (HSR's "ult on your turn"): while a party member chooses its action, after its turn-start ticks, any
  living party member may ult; it fires at once, then the same member chooses again. The turn is not spent. A One More
  decision works the same way. Enemies don't interrupt here (their phase is in BETWEEN), and enemy turns have no
  DECISION window.
- **Enemies first, then the party.** Enemy decisions must not depend on when the player's finger moved, only on
  battle state, or the replay couldn't re-simulate them. So enemies decide at the window's start, and party presses
  queued before or during the enemy ults fire after them. A party ult that provokes an enemy (e.g. fills its charge
  through `ult_charge_hit`) is answered at the next window. Each enemy gets one interrupt per window, so two enemies
  can't loop.
- **Chains:** both windows ask again after each interrupt, so P1 and P2 can ult back to back.
- **An interrupt is not a turn:** no `turn += 1`, no turn start/end ticks, no AV change for anyone (except through
  its own effects: delay from a break, SPD changes). `TURN_LIMIT` is unaffected.

### `_interrupt(caster, ability, target)`
1. `in_interrupt = true`; emit `interrupt_started(caster_id, ability_tag)` (read-only, for UI and the battle log).
2. Activate through `_activate` as today (so `Event.Ability.Used`, cost, cooldown, the presentation gate).
3. Drain triggers; death check; end check. `in_interrupt = false`.
4. A break by the ult queues a **One More** for the caster (item-pass rule, unchanged: any action that breaks). It
   runs before the next turn: right after a BETWEEN window, or after the current turn ends for a DECISION ult (as
   follow-up breaks do). The rule is generic, so an enemy ult that breaks a
   party unit with toughness would do the same (no demo content does).
5. Party caster only: checkpoint (state hash) → `controller.after_interrupt(battle, caster, action, checkpoint)`.

**Self-buffs:** `CombatASC._in_own_turn` already decides it. An ult a unit casts in its own DECISION window (or its
One More's) is "on its own turn", so that turn's end doesn't count it down and a 2-turn self-buff covers its next two
turns. Cast in BETWEEN or during another unit's decision, it counts down at the caster's next two turn ends. No
`CombatASC` change.

### A. Client mode (record)
```
presentation (ult button) ─ submit_ult(unit, ability, target) ─▶ ActionRecorder._interrupts (FIFO)
Battle at BETWEEN, party phase → recorder.interrupt() pops the queue (never waits)
Battle at DECISION → recorder.choose() returns a queued interrupt first, else waits for an action or an ult press
   (a press while choose() waits wakes it: choose() returns {"interrupt": true, "unit", "ability", "target"})
target gone by then → Battle.retarget(caster, ability, target) (below); the log records the target actually used
still invalid (caster dead, charge not full, no target left) → action_rejected, dropped, not logged
after_interrupt → entries.append(entry(battle.turn, caster, action, checkpoint, interrupt = true))
battle ends with presses still queued → dropped
```

**Retargeting** (HSR: a queued ult never fizzles while a valid target exists). A press names a target, but units act
before the window, so it may be dead (or, for a revive, already revived) by then. `Battle.retarget(caster, ability,
wanted) -> BattleUnit`:
- `wanted` still valid → `wanted`.
- Otherwise the valid candidate (`target_candidates`) with the **nearest slot** to `wanted`'s; on a tie the lower
  slot. E2 dies with E1 and E3 alive → E1. For `SINGLE_DEAD_ALLY` the candidates are dead allies, same rule.
- No candidate → `null`: the press is dropped with `action_rejected` (`InvalidTarget`).
- `SELF` / `ALL_*` ults have no target to lose; `BLAST_ENEMY` retargets its primary.

Retargeting is **client-side input resolution**: it decides which target the client submits, and the log holds that
final target. The replay doesn't retarget; it checks the logged target as for any action. So it adds no replay rule
and no tamper surface (a client could always name any valid target). It lives in `Battle` only so the UI, the
console and tests share one rule. Enemies don't need it: their brain picks at the window.

### B. Replay mode (verify)
- Enemy phase: identical code, re-simulated (brain + battle RNG), as enemy turns are today.
- Party phase: `ReplayController.interrupt(battle)` returns the next entry if it is `interrupt` **and** its
  `turn == battle.turn`; else `{}`. `after_interrupt` compares the checkpoint and advances the cursor.
- DECISION: `ReplayController.choose(battle, unit)` returns the next entry as an interrupt if it is `interrupt` with
  `turn == battle.turn`; otherwise the existing checks (turn, actor, `extra`) for the turn action.

**Why the turn number plus log order is enough:** windows are visited in a fixed order. Two windows share a turn
number only as DECISION of turn N and BETWEEN after N, and those are separated by the actor's logged action. If the
actor dies in its DECISION window there is no action entry, but both modes then leave the turn the same way and the
next interrupt fires at BETWEEN N either way. Every other window has a new turn number. So "fire the next entry at
the first window whose turn matches" reproduces the client exactly. The client never picks a window; it only
presses, and the same `Battle` code decides where the press lands.

### Enemy brain
```
EnemyBrain.choose_interrupt(unit, battle) -> {"ability", "target"} or {}
  default: the first ultimate (grant order) that can_activate; a target that needs choosing is drawn with the
           battle RNG over the candidates, as choose() does. No ult can activate → {} and no RNG draw.
```
Because an enemy without a castable ult draws nothing, **existing battles consume the RNG exactly as before** and
every golden stays valid. Content can subclass the brain for smarter timing (1c5). An illegal pick is a runner error,
as for `choose()`.

## 3. Data contracts

### 3.1 Content and system (Godot)
| Item | Change |
|---|---|
| `BattleAbility` | `ULTIMATE_TAG := &"Ability.Type.Ultimate"`, `is_ultimate()` (asset tag present, not triggered). |
| `BattleUnit` | `action_abilities()` excludes ultimates (never turn actions, either side). New `ultimate_abilities()`. |
| `Battle.validate_action` | A turn action that `is_ultimate()` → `IllegalAbility`. New `validate_interrupt(unit, choice)`: caster living (`ActorMismatch`; for the party: a party unit), ability granted, `is_ultimate()` and `can_activate_ability` (`IllegalAbility`), target valid (`InvalidTarget`). |
| `Battle` | `interrupt_started(unit_id, ability_tag)` signal; `in_interrupt: bool`; `_ult_window()`; `_interrupt()`; `retarget()`. |
| `EnemyBrain` | `choose_interrupt(unit, battle)` (above). |
| Controllers | New `interrupt(battle) -> Dictionary` and `after_interrupt(battle, unit, action, checkpoint)` on `ActionRecorder`, `ReplayController`, `ScriptedController`. `choose()` may return `{"interrupt": true, "unit", "ability", "target"}` (DECISION). |
| `ActionRecorder` | `submit_ult(unit_id, ability_tag, target_id = &"")`; `pending_interrupts()`; `ActionRecorder.entry(..., extra, interrupt)` writes `"interrupt": true` only when set. |
| Validator | Warning: an `Ability.Type.Ultimate` ability with no cost effect (castable at every window). Error: `Ability.Type.Ultimate` on a triggered ability. Warning: an enemy loadout with an ult but no charge source. |

### 3.2 Wire shape (`Rpg.Contracts.Battle.ActionEntry`)
```csharp
public sealed record ActionEntry(
    int Turn,                                // turn action: as today. Interrupt: battle.turn at its window
    string Actor,                            // for an interrupt: the caster, any living party member
    string Ability,
    string? Target,                          // for an interrupt: the target actually used (after retargeting)
    string Checkpoint,                       // state hash after this action (or interrupt) resolved
    [property: JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)] bool? Extra = null,
    [property: JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)] bool? Interrupt = null);
    // true for a party ult cast out of turn (spec ult-interrupts); omitted otherwise
```
Example (P1 Execute after enemy turn 3; then on P2's own turn 4, P2 Sanctuary before its Strike):
```json
{"turn": 3, "actor": "P1", "ability": "Ability.Ult.Execute",   "target": "E2", "checkpoint": "…", "interrupt": true},
{"turn": 4, "actor": "P2", "ability": "Ability.Ult.Sanctuary", "target": null, "checkpoint": "…", "interrupt": true},
{"turn": 4, "actor": "P2", "ability": "Ability.Strike",        "target": "E1", "checkpoint": "…"}
```
- Optional field, absent from every existing log, so **`ActionLog.schemaVersion` stays 1** and every golden is
  unchanged (the rule `combat-replay-core` set for `extra`).
- Enemy interrupts are not in the log (re-simulated); their effects are in the next party checkpoint.
- `interrupt` and `extra` both true is malformed → `TurnMismatch`.
- **No new `MismatchReason`:** an interrupt that doesn't fire at its window (wrong turn, or met where a turn action is
  due) is `TurnMismatch`; a non-ult or a partial charge is `IllegalAbility`; a dead or enemy caster is
  `ActorMismatch`; leftover interrupts after the end are `TrailingActions`. All are 2002.
- **State hash:** unchanged, `hash-v1`. Queued presses are controller state, never battle state; the hash after an
  interrupt already holds its effects (energy spent, HP, tags, AV). Enemy charge is an attribute, already hashed.

### 3.3 Demo ult examples (yours, approved 2026-10-21)
Each class keeps its AoE ult and gains a single-target one, so the demo shows both shapes and exercises retargeting;
one enemy gets an ult. Both party ults share the one charge bar (cost `ult_cost`, 100 energy); the loadouts grant
both. Made by `game/tools/build_demo.gd` (new files only; existing files edited in place for the tag). Numbers are
starting values for your tuning; the `.tres`/`.tscn` files become the source of truth.

| Unit | Ult | Tag | Targeting | Does | Why it shows interrupts |
|---|---|---|---|---|---|
| Warrior | Cleave (exists) | `Ability.Ult.Cleave` | ALL_ENEMIES | 200% ATK physical | Clear weakened enemies before the next one moves |
| Warrior | **Execute** (new) | `Ability.Ult.Execute` | SINGLE_ENEMY | 300% ATK physical, high toughness damage | Kill or break the next actor before its turn (break: 25% delay and a One More); retargets if its pick died |
| Cleric | Sanctuary (exists) | `Ability.Ult.Sanctuary` | ALL_ALLIES | party heal | Heal after one enemy's hit, before the next enemy's |
| Cleric | **Resurrection** (new) | `Ability.Ult.Resurrection` | SINGLE_DEAD_ALLY | revive at a % of max HP (`ExecCalc_PercentOfMax`, like Smelling Salts) | Revive an ally killed mid enemy round before the rest of the round; retargets to another dead ally if its pick is already back |
| Golem | **Quake** (new) | `Ability.Ult.Quake` | ALL_ENEMIES (the party) | 150% ATK physical to every party member | Enemy interrupt: charges from being hit (`ult_charge_hit`), so hitting it hard makes it answer out of turn |

All five get `Ability.Type.Ultimate` in `asset_tags`. New tags `Ability.Ult.Execute`, `Ability.Ult.Resurrection`,
`Ability.Ult.Quake`, `Ability.Type.Ultimate` via `sync_tags --add-missing`. The Golem's loadout gains Quake,
`ult_cost` and `ult_charge_hit`. Animations: Execute and Quake reuse the jump shape, Resurrection the spin, each with
one `execute` key, as the builder does for the others.

### 3.4 RabbitMQ / Redpanda / Redis
N/A: no queues, topics or keys. The slice 3 battle job carries the log as an opaque payload.

## 4. Failure modes
| Case | Behaviour | Test |
|---|---|---|
| Ult pressed during an enemy's action | Queued; fires at the next window, before the next turn starts | `test_ult_between_turns` |
| Ult on own turn | Fires before the action; the actor still acts; its AV resets once | `test_ult_on_own_turn_keeps_turn` |
| Ally ults during another member's decision | Fires; the deciding member still acts | `test_ally_ult_during_decision` |
| Actor dies during its DECISION window (e.g. a thorn passive) | Window ends, no action; BETWEEN of the same turn follows; client and replay agree | `test_actor_dies_in_decision_window` |
| Two party ults back to back | Both fire in one window, in press order, two entries, two checkpoints | `test_ult_chain` |
| Enemy with a full charge | Ults at the next window, before any party press; not logged; replay re-simulates it | `test_enemy_interrupt` |
| Two enemies full in one window | Slot order, one each; no loop | `test_enemy_interrupts_slot_order` |
| Party ult fills an enemy's charge | The enemy answers at the next window, not the same one | `test_enemy_answers_next_window` |
| Enemy without a castable ult | No RNG draw; existing goldens unchanged | `test_no_enemy_ult_no_rng` + existing goldens |
| Ult as a turn action (party or enemy brain) | Client: `action_rejected`. Replay: 2002 `IllegalAbility`. Brain: runner error | `test_ult_not_a_turn_action` |
| Interrupt with a partial charge | 2002 `IllegalAbility` (cost check) | `test_tamper_ult_charge` |
| Interrupt moved to another turn | 2002 `TurnMismatch` (or `CheckpointMismatch` if it lands at a valid window with a different result) | `test_tamper_ult_turn` |
| Interrupt deleted from the log | 2002 `CheckpointMismatch` at the next entry | `test_tamper_ult_removed` |
| Interrupt by a dead or enemy unit | 2002 `ActorMismatch` | `test_tamper_ult_actor` |
| Both `extra` and `interrupt` | 2002 `TurnMismatch` | `test_tamper_ult_extra` |
| Queued ult whose target died first (incl. to an enemy ult in the same window) | Retargeted to the nearest slot; the log holds the new target; replay `Verified` | `test_queued_ult_retargets` |
| Retarget tie (both neighbours alive) | Lower slot | `test_retarget_tie_lower_slot` |
| Queued revive ult whose dead ally is already back | Next dead ally by slot; none → dropped | `test_retarget_dead_ally` |
| Queued ult whose caster died, or no target left | Dropped with `action_rejected`, not logged; replay never sees it | `test_queued_ult_dropped` |
| Ult kills the next actor before its turn | Death check in the window; the dead unit leaves the turn queue | `test_ult_kills_next_actor` |
| Ult breaks a unit | Break delay applies; One More for the caster right after the window | `test_ult_break_one_more` |
| Windows around a One More | BETWEEN opens before it and its decision is a DECISION window; the One More action still follows | `test_ult_during_one_more` |
| Ult kills the last enemy / last party member | Battle ends at once; no more interrupts; queued presses dropped | `test_ult_ends_battle` |
| Self-buff from an own-turn ult | Covers the next two turns (own-turn rule); cast in BETWEEN, counts down normally | `test_ult_self_buff_countdown` |
| Old log (no `interrupt`) | Verified exactly as before | existing goldens, unchanged |
| An ability awaits a frame inside an interrupt | Runner error `ContentAwaitedFrame` (unchanged rule) | covered by the zero-frame check |

**Root `CLAUDE.md` acceptance scenarios:** this slice covers **scenario 5** (tampered action log → deterministic 2002)
for the new field, with the tamper tests above and a tampered golden. Scenarios 1–4, 6, 7 are server-side (slices 3,
4, 9, 8) and not touched.

## 5. Observability
N/A: no server process. For slice 3: the `ReplayResult` reason already covers interrupts. If the verifier later
counts interrupts, use a bounded label (`kind="interrupt"|"turn"|"extra"`), **never** the ability or unit id.
Analytics (slice 4b): "most used moves" reads interrupt entries as moves; the flag tells them apart.

## 6. Test plan
### Fixtures (`client-godot/tests/fixtures/`, frozen; builders add missing files only)
- `fixture.ability.ult_nova`: `Ability.Type.Ultimate`, ALL_ENEMIES, cost 100 energy, physical damage that can break
  a brittle enemy; `fixture.ability.ult_ward`: SELF, a 2-turn DEF buff; `fixture.ability.ult_snipe`: SINGLE_ENEMY
  (retargeting).
- `fixture.unit.ultist`: duelist-like, starts with full charge (a battle-start passive), the three ults; the
  energy-charge passive so the bar refills.
- `fixture.unit.raging_dummy`: enemy with an ALL_ENEMIES ult and `ult_charge_hit`.
- `fixture.encounter.ult_trial`: a fast enemy (acts twice before the party), a brittle enemy, the raging dummy.
- `ScriptedController` interrupt policy (deterministic, no RNG): a party unit whose ult can activate casts it,
  at BETWEEN on odd turns and at DECISION on even turns, so a golden covers both windows; it cycles through its ults
  and picks targets by turn among the candidates.

### Unit tests (`tests/combat/test_ult_interrupts.gd`)
Every row of section 4, plus:
- `test_record_replay_roundtrip_with_interrupts`: ScriptedController run → `Verified`, identical checkpoints.
- `test_interrupt_entry_shape`: `interrupt` written only when true; field order matches the C# record.
- `test_no_interrupt_no_change`: a battle with no ults yields the same log and final hash as before this slice.
- `test_window_order`: BETWEEN (enemies, then party) and DECISION in the documented order (a probe controller logs
  each call).
- `test_action_abilities_exclude_ults` and the validator rules.

### Golden vectors (`tests/fixtures/golden/`)
| File | Proves |
|---|---|
| `ult-seed-7.json` / `.result.json` | Party interrupts in both windows and a chain, an enemy interrupt, an ult break with a One More, an ult kill, a retarget |
| `ult-seed-7-tampered-turn.json` / `.result.json` | An interrupt moved one turn → 2002 `TurnMismatch` at that turn |

Existing goldens (`duel-seed-1`, `squad-seed-42`, `break-seed-11`, game goldens) must pass **unchanged**.

### C# (`tests/Rpg.Contracts.Tests`)
- `ActionEntry` with `Interrupt` round-trips; `null` is omitted on write.
- The new goldens deserialize into the records and re-serialize byte-identically (existing cross-check, extended).

### Dev tools
- `ult <unit> <ability> [target]` queues a press; `dev_run` script test: a sandbox battle with an ult during an enemy
  turn and a Golem Quake, logged and replayed `Verified`.

### Demo
- The five ults of 3.3 tagged; `test_demo_items_replay` and the demo smoke test still pass (their scripted policy
  now casts ults as interrupts).
- `test_demo_ults`: each ult cast as an interrupt in a sandbox battle, recorded and replayed `Verified`; Execute
  retargets after its pick dies; Resurrection revives an ally killed earlier in the same enemy round; the Golem
  quakes after being hit enough.
- `validate` over `content/`: 0 errors.

### Done when
`dotnet build` / `dotnet test` and the Godot suite green; old goldens unchanged; new goldens in; `ult` command works
headless; `combat-replay-core` (windows, `interrupt` field), `combat-design` ("out-of-turn ults" now built) and
`dev-tools` updated; roadmap 1c4 ✅; root `CLAUDE.md` table.

## 7. Files
System (`feat:`): `combat/battle.gd`, `battle_ability.gd`, `battle_unit.gd`, `enemy_brain.gd`,
`action_recorder.gd`, `replay_runner.gd`, `game/dev/commands/ult.gd`, the content validator rules,
`tests/scripted_controller.gd`, `tests/combat/test_ult_interrupts.gd`, fixtures and goldens,
`src/Rpg.Contracts/Battle/ActionLog.cs`, contract tests.
Yours, approved 2026-10-21 (`design:`): `godot_gas/tag_registry.tres` (+ `gameplay_tags.gd`), the demo ults, the
Warrior, Cleric and Golem loadouts, `game/tools/build_demo.gd` additions, `presentation/demo/battle_panel` (ult
buttons, enemy charge, interrupt message).

## 8. Later (slice 1c5 `content-pass`, unless noted)
The mechanic and one example of each shape land here; content that leans on it waits for 1c5, where every piece is
chosen for the mechanic it exercises:
- **Items that react to ults:** e.g. charge refund after an ult (HSR's), "after an out-of-turn ult, +ATK", a One
  More that refunds charge. Buildable now on `Event.Ability.Used` + the ability's tags; an `Event.Battle.Interrupt`
  only if content needs to tell an interrupt apart.
- **Smarter enemy ult timing:** brain subclasses (ult only when a party member is low, save it for a phase change),
  and bosses whose ult is a phase or a counter.
- **Ults × statuses:** ults that cleanse, apply DoTs or break effects, and the "ult before a DoT tick" cases, once
  statuses are designed in 1c5.
- **Party toughness:** enemy ults breaking the party and enemy One Mores (the rule already supports it; needs
  content).
- **Balance:** charge gain per action, ult costs, Execute's toughness damage against the One More combo.

## 9. Decisions
Decided 2026-10-21:
1. Ults are interrupt-only, for party and enemies.
2. HSR ult timing: two windows, BETWEEN (during enemy turns, after the current action) and DECISION (on your own
   turn, before you act, without spending it).
3. A break by an ult grants a One More (item-pass rule unchanged).
4. Retargeting is in this slice.
5. All content and presentation edits approved: one new single-target ult per class, one enemy ult (Golem, Quake).
6. Enemies can interrupt (decided by their brain, never logged); enemies act first in a window.

None open.
