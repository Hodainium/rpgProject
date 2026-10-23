# Spec: ult-interrupts (slice 1c4)

Status: ✅ Implemented, synced with the code (2026-10-21) · Roadmap: slice 1c4 · Date: 2026-10-21
Design intent: Honkai: Star Rail ultimates (`specs/design/combat-design.md`, "Ult charge"). Turn order, action log,
state hash: `specs/combat-replay-core.md` (whose log schema leaves room for "ultimates that interrupt the order");
per-action checkpoints were removed later by `specs/atomic-battles.md`. One More, break, follow-ups: `specs/item-pass.md` 3.1–3.2. Console and script runner:
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

Ults are battle-only: field mode (map actions) uses `action_abilities()`, so an ult such as Sanctuary is no longer
usable on the map.

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
    │      validate → _interrupt(i) → triggers, deaths, end check → log                           │
    └─────────────────────────────────────────────────────────────────────────────────────────────┘
    if one_more_queue not empty: extra action (its decision is a DECISION window too); continue
    next actor by AV → elapse → turn += 1 → turn start ticks, triggers, deaths, end check
    party actor:  choice = controller.choose(battle, actor)              ◀── DECISION window
                  while choice is an interrupt and actor alive and ongoing:
                      validate → _interrupt(choice) → triggers, deaths, end check → log
                      choice = controller.choose(battle, actor)         (ask again; the turn isn't spent)
                  take the action as today
    enemy actor:  brain (unchanged; presses during an enemy turn wait for the next BETWEEN)
    turn end, deaths, end check, AV reset (unchanged; no state hash since spec atomic-battles)
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
5. Party caster only: `controller.after_interrupt(battle, caster, action)` (no state hash: spec atomic-battles).

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
after_interrupt → entries.append(entry(battle.turn, caster, action, interrupt = true))
battle ends with presses still queued → dropped
```
**Auto** (the battle panel's Auto toggle and the console's auto battles): at a party decision it first presses every
member's ult that can fire (first valid target), so they go in at that DECISION window, then picks the action.

**Retargeting** (HSR: a queued ult never fizzles while a valid target exists). A press names a target, but units act
before the window, so it may be dead (or, for a revive, already revived) by then. `Battle.retarget(caster, ability,
wanted) -> BattleUnit`:
- `wanted` still valid → `wanted`. No `wanted` given → the first candidate by slot.
- Otherwise the valid candidate (`target_candidates`) with the **nearest slot** to `wanted`'s; on a tie the lower
  slot. E2 dies with E1 and E3 alive → E1. For `SINGLE_DEAD_ALLY` the candidates are dead allies, same rule.
- No candidate → `null`: the press is dropped with `action_rejected` (`InvalidTarget`).
- `SELF` / `ALL_*` ults have no target to lose; `BLAST_ENEMY` retargets its primary.

Retargeting is **client-side input resolution**: it decides which target the client submits, and the log holds that
final target. The replay doesn't retarget; it checks the logged target as for any action. So it adds no replay rule
and no tamper surface (a client could always name any valid target). It lives in `Battle` only so the UI, the
console and tests share one rule. `Battle.resolve_press(press)` applies it and then checks the press
(`{"choice"}` or `{"problem"}`). Enemies don't need it: their brain picks at the window.

### B. Replay mode (verify)
- Enemy phase: identical code, re-simulated (brain + battle RNG), as enemy turns are today.
- Party phase: `ReplayController.interrupt(battle)` returns the next entry if it is `interrupt` **and** its
  `turn == battle.turn`; else `{}`. `after_interrupt` advances the cursor (nothing is compared until the end).
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
| `Battle.validate_action` | A turn action that `is_ultimate()` → `IllegalAbility`. New `validate_interrupt(caster, choice, party: bool)`: caster living and on the expected side (`ActorMismatch`), ability granted, `is_ultimate()` and `can_activate_ability` (`IllegalAbility`), target valid (`InvalidTarget`). |
| `Battle` | `interrupt_started(unit_id, ability_tag)` signal; `in_interrupt: bool`; `_ult_window()`; `_party_interrupt()` (checks a party interrupt from either window; an invalid one goes to `controller.on_invalid`); `_interrupt()`; `retarget()`; `resolve_press()`. |
| `EnemyBrain` | `choose_interrupt(unit, battle)` (above). |
| Controllers | New `interrupt(battle) -> Dictionary` and `after_interrupt(battle, unit, action)` on `ActionRecorder`, `ReplayController`, `ScriptedController`. `choose()` may return `{"interrupt": true, "unit", "ability", "target"}` (DECISION). |
| `ActionRecorder` | `submit_ult(unit_id, ability_tag, target_id = &"")`; `pending_interrupts()`; `ActionRecorder.entry(..., extra, interrupt)` writes `"interrupt": true` only when set. |
| Validator | Error `ult_triggered`: `Ability.Type.Ultimate` on a triggered ability. Warning `ult_no_cost`: an ult with no cost effect (castable at every window). Warning `ult_no_charge`: an enemy with an ult among its abilities, default-loadout skills or item grants, but no triggered passive at all there (anything that could charge it). |
| Tools | `game/tools/sync_tags.gd` knows `Ability.Type.Ultimate` as a system tag. `game/dev/commands/ult.gd` (with `ult` tag completion in `dev_console.gd`). |

### 3.2 Wire shape (`Rpg.Contracts.Battle.ActionEntry`)
```csharp
public sealed record ActionEntry(
    int Turn,                                // turn action: as today. Interrupt: battle.turn at its window
    string Actor,                            // for an interrupt: the caster, any living party member
    string Ability,
    string? Target,                          // for an interrupt: the target actually used (after retargeting)
    [property: JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)] bool? Extra = null,
    [property: JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)] bool? Interrupt = null);
    // true for a party ult cast out of turn (spec ult-interrupts); omitted otherwise
```
Example (P1 Execute after enemy turn 3; then on P2's own turn 4, P2 Sanctuary before its Strike):
```json
{"turn": 3, "actor": "P1", "ability": "Ability.Ult.Execute",   "target": "E2", "interrupt": true},
{"turn": 4, "actor": "P2", "ability": "Ability.Ult.Sanctuary", "target": null, "interrupt": true},
{"turn": 4, "actor": "P2", "ability": "Ability.Strike",        "target": "E1"}
```
- Optional field, absent from every existing log, so `ActionLog.schemaVersion` stayed 1 and every golden was
  unchanged (the rule `combat-replay-core` set for `extra`). Spec atomic-battles later made it 2 (no `Checkpoint`).
- Enemy interrupts are not in the log (re-simulated); their effects are in the final hash (and in a determinism trace's
  `interrupt` points).
- `interrupt` and `extra` both true is malformed → `TurnMismatch`.
- **No new `MismatchReason`:** an interrupt that can't fire where it is logged (its turn's window has passed, or
  it is met where a turn action is due) is `TurnMismatch`; one moved to another *valid* window fires there and is
  caught later (a later entry no longer fits, or `OutcomeMismatch` / `FinalHashMismatch` at the end: the log alone
  can't tell a later press from a moved one; spec atomic-battles); a
  non-ult or a partial charge is `IllegalAbility`; a dead or enemy caster is `ActorMismatch`; leftover interrupts
  after the end are `TrailingActions`. All are 2002.
- **State hash:** unchanged, `hash-v1`. Queued presses are controller state, never battle state; the hash after an
  interrupt already holds its effects (energy spent, HP, tags, AV). Enemy charge is an attribute, already hashed.

### 3.3 Demo ult examples (yours, approved 2026-10-21)
Each class keeps its AoE ult and gains a single-target one, so the demo shows both shapes and exercises retargeting;
one enemy gets an ult. Both party ults share the one charge bar (cost `effects/ult_cost.tres`); each unit's
`abilities` list grants its ults. New files made by `game/tools/build_ult_pass.tscn` (never overwrites); the tag on
Cleave and Sanctuary and the grants were edited in place with your approval. The numbers live in the files named below.

| Unit | Ult | Tag | Targeting | Does | Why it shows interrupts |
|---|---|---|---|---|---|
| Warrior | Cleave (exists) | `Ability.Ult.Cleave` | ALL_ENEMIES | physical, % ATK (`abilities/cleave.tscn`) | Clear weakened enemies before the next one moves |
| Warrior | **Execute** (new) | `Ability.Ult.Execute` | SINGLE_ENEMY | physical, % ATK, the demo's biggest toughness damage (`abilities/execute.tscn`) | Kill or break the next actor before its turn (break: 25% delay and a One More); retargets if its pick died |
| Cleric | Sanctuary (exists) | `Ability.Ult.Sanctuary` | ALL_ALLIES | party heal (`effects/sanctuary_heal.tres`) | Heal after one enemy's hit, before the next enemy's |
| Cleric | **Resurrection** (new) | `Ability.Ult.Resurrection` | SINGLE_DEAD_ALLY | revive at a % of max HP (`effects/resurrection_revive.tres`, `ExecCalc_PercentOfMax` like Smelling Salts) | Revive an ally killed mid enemy round before the rest of the round; retargets to another dead ally if its pick is already back |
| Golem | **Quake** (new) | `Ability.Ult.Quake` | ALL_ENEMIES (the party) | physical, % ATK to every party member (`abilities/quake.tscn`) | Enemy interrupt: charges from being hit (`ult_charge_hit`), so hitting it hard makes it answer out of turn |

All five get `Ability.Type.Ultimate` in `asset_tags`. New tags `Ability.Ult.Execute`, `Ability.Ult.Resurrection`,
`Ability.Ult.Quake`, `Ability.Type.Ultimate` via `sync_tags --add-missing`. The Warrior gains Execute, the Cleric
Resurrection, the Golem Quake and the `ult_charge_hit` passive (in `characters/*.tres`, `enemies/golem.tres`).
Animations: Execute is a jump and spin, Quake a jump, Resurrection a spin, each with one `execute` key and a sound.

### 3.4 RabbitMQ / Redpanda / Redis
N/A: no queues, topics or keys. The slice 3 battle job carries the log as an opaque payload.

## 4. Failure modes
| Case | Behaviour | Test |
|---|---|---|
| Ult pressed during an enemy's action | Queued; fires at the next window, before the next turn starts | `test_ult_between_turns` |
| Ult on own turn | Fires before the action; the actor still acts; its AV resets once | `test_ult_on_own_turn_keeps_turn` |
| Ally ults during another member's decision | Fires; the deciding member still acts | `test_ult_break_one_more_and_ult_during_it` (P2 ults in P1's One More decision) |
| Actor dies during its DECISION window (the martyr fixture's self-killing ult) | Window ends, no action; BETWEEN of the same turn follows; client and replay agree | `test_actor_dies_in_decision_window` |
| Two party ults back to back | Both fire in one window, in press order, two entries, two trace points | `test_ult_chain` |
| Enemy with a full charge | Ults at the next window, before any party press; not logged; replay re-simulates it | `test_enemy_interrupt`, `test_record_replay_roundtrip_with_interrupts` |
| Two enemies full in one window | Slot order, one each; no loop | `test_enemy_interrupts_slot_order` (`fixture.encounter.rage_pair`) |
| Party ult fills an enemy's charge | The enemy answers at the next window, not the same one | `test_enemy_interrupt` |
| Enemy without a castable ult | No RNG draw; existing goldens unchanged | `test_no_enemy_ult_no_rng` + existing goldens |
| Ult as a turn action (party or enemy brain) | Client: `action_rejected`. Replay: 2002 `IllegalAbility`. Brain: runner error | `test_action_abilities_exclude_ults`, `test_tampered_interrupts` (see 6, known gaps) |
| Interrupt with a partial charge | 2002 `IllegalAbility` (cost check) | `test_tampered_interrupts` |
| Interrupt moved to another turn | 2002 `TurnMismatch` when it can't fire there or a later entry no longer fits (measured in both tests, spec atomic-battles), else `OutcomeMismatch` / `FinalHashMismatch` at the end | `test_tampered_interrupts`, golden `ult-seed-7-tampered-turn` |
| Interrupt deleted from the log | 2002 at the next structural check (`TurnMismatch` in the test) or at the end (`FinalHashMismatch`, `OutcomeMismatch`: spec atomic-battles) | `test_tampered_interrupts`, golden `ult-close-seed-2-tampered-outcome` |
| Interrupt by a dead or enemy unit | 2002 `ActorMismatch` | `test_tampered_interrupts` (enemy), `test_tamper_ult_dead_actor` (dead) |
| Both `extra` and `interrupt` | 2002 `TurnMismatch` | `test_tampered_interrupts` |
| Queued ult whose target died first (incl. to an enemy ult in the same window) | Retargeted to the nearest slot; the log holds the new target; replay `Verified` | `test_ult_kills_next_actor_and_retargets`, `test_queued_ult_retargets_after_enemy_ult`, demo `test_execute_interrupt_and_retarget` |
| Retarget tie (both neighbours alive) | Lower slot | `test_retarget_rules` |
| Queued revive ult whose dead ally is already back | Next dead ally by slot; none → dropped | `test_retarget_rules` |
| Queued ult whose caster died, or no target left | Dropped with `action_rejected`, not logged; replay never sees it | `test_queued_ult_dropped` |
| Ult kills the next actor before its turn | Death check in the window; the dead unit leaves the turn queue | `test_ult_kills_next_actor_and_retargets` |
| Ult breaks a unit | Break delay applies; One More for the caster right after the window | `test_ult_break_one_more_and_ult_during_it` |
| Windows around a One More | BETWEEN opens before it and its decision is a DECISION window; the One More action still follows | `test_ult_break_one_more_and_ult_during_it` |
| Ult kills the last enemy / last party member | Battle ends at once; no more interrupts; queued presses dropped | `test_ult_ends_battle` (Victory), `test_enemy_ult_ends_battle` (Defeat) |
| Self-buff from an own-turn ult | Covers the next two turns (own-turn rule); cast in BETWEEN, counts down normally | `test_ult_on_own_turn_keeps_turn` |
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
- Ults (all `Ability.Type.Ultimate`, cost `effects/ult_cost.tres`): `Fixture.Ability.UltNova` (ALL_ENEMIES, Fire with
  toughness damage, breaks the brittle enemy), `UltSnipe` (SINGLE_ENEMY, retargeting), `UltWard` (SELF, the 2-turn
  guard buff), `UltRaise` (SINGLE_DEAD_ALLY), `UltRage` (the enemy ult), `UltSacrifice` (SELF, kills its caster),
  `UltShield` (SINGLE_ALLY). Passives: `FullCharge` (full bar at battle start), `Recharge` (+charge per action),
  `RageCharge` (+charge per hit taken).
- `fixture.character.ultist`: Strike, Nova, Snipe, Ward, Raise, FullCharge, Recharge. `fixture.character.martyr`:
  Strike, Sacrifice, FullCharge. `fixture.character.warden`: Strike, Shield, FullCharge (its own character, so the
  ultist's kit and `ult-seed-7` stay as recorded).
- `fixture.enemy.sprinter` (fast, acts first), `fixture.enemy.raging` (UltRage + RageCharge);
  `fixture.encounter.ult_trial` (sprinter, brittle, raging), `fixture.encounter.rage_pair` (two raging).
- `ScriptedController` interrupt policy (test-only, deterministic, no RNG): a party unit whose ult can activate casts
  it, units in odd slots at the BETWEEN window and units in even slots at a DECISION window (any member's), so one
  battle covers both windows; it cycles through its ults and picks targets by turn among the candidates. (Splitting
  by turn number never reached DECISION: BETWEEN on the odd turns spent every charge first.)

### Unit tests (`tests/combat/test_ult_interrupts.gd`)
Every row of section 4, plus:
- `test_record_replay_roundtrip_with_interrupts`: ScriptedController run → `Verified`.
- `test_interrupt_entry_shape`: `interrupt` written only when true; field order matches the C# record.
- No change without ults: `test_no_enemy_ult_no_rng` (a break battle logs no `interrupt`) and the existing goldens,
  which rewrote byte-identical with this slice.
- `test_window_order`: BETWEEN (enemies, then party) and DECISION in the documented order (a probe controller logs
  each call).
- `test_action_abilities_exclude_ults` and the validator rules.

### Golden vectors (`tests/fixtures/golden/`)
| File | Proves |
|---|---|
| `ult-seed-7.json` / `.result.json` | Party interrupts in both windows (BETWEEN, and DECISION by an ally during another member's turn and One More), ult breaks followed by One More actions, an enemy interrupt (re-simulated, not in the file), Victory |
| `ult-seed-7-tampered-turn.json` / `.result.json` | The first interrupt moved one turn → 2002 `TurnMismatch` at turn 2 (since spec atomic-battles; until then `CheckpointMismatch` at turn 1) |

Not in the golden, by design: a same-window chain (`test_ult_chain`) and retargeting. Retargeting happens before an
entry is logged, so a retargeted entry looks like any other and a golden can't show it; its tests record a real
press, replay and verify (see 4).

Existing goldens (`duel-seed-1`, `squad-seed-42`, `break-seed-11`, game goldens) must pass **unchanged**.

### C# (`tests/Rpg.Contracts.Tests`)
- `ActionEntry` with `Interrupt` round-trips; `null` is omitted on write.
- The new goldens deserialize into the records and re-serialize byte-identically (existing cross-check, extended).

### Dev tools
- `test_console_ult` (`tests/game/test_dev_console.gd`): outside a battle, a non-ult and an enemy caster are refused,
  ult tags autocomplete, a press fires in the waiting member's DECISION window and is logged as an interrupt, and an
  auto battle casts ready ults out of turn. The script runner uses the same commands headless.

### Demo
- The five ults of 3.3 tagged; `test_demo_items_replay` and the demo smoke test still pass (their scripted policy
  now casts ults as interrupts).
- `tests/game/test_demo_ults.gd` (content test, direction only): the five are ults and never turn actions; Execute
  kills a bat before it moves, replays `Verified`, and an Execute aimed at a dead bat retargets; Resurrection revives
  a fallen ally (set up directly, not inside an enemy round) and then has no target; Sanctuary heals; the Golem
  charges when hit and quakes at the window, unlogged; a scripted boss fight full of ults replays `Verified`.
- `validate` over `content/`: 0 errors.

### Known gaps
- The client's `action_rejected` for an ult taken as a turn action, and the runner error for a brain that picks an
  ult as a turn action, have no direct test (the reason, `IllegalAbility`, and the replay rejection do; a default
  brain can't pick an ult). Neither can cause a wrong verdict: the first is a UI message on a shared path (the panel
  never offers ults as actions), the second is a runner error, never a verdict. **Add a brain test in 1c5** with the
  first custom `EnemyBrain` subclass, when the path first becomes reachable; the client signal needs none.

### Done when
`dotnet build` / `dotnet test` and the Godot suite green; old goldens unchanged; new goldens in; `ult` command works
headless; `combat-replay-core` (windows, `interrupt` field), `combat-design` ("out-of-turn ults" now built) and
`dev-tools` updated; roadmap 1c4 ✅; root `CLAUDE.md` table.

## 7. Files
System (`feat:`): `combat/battle.gd`, `battle_ability.gd`, `battle_unit.gd`, `enemy_brain.gd`,
`action_recorder.gd`, `replay_runner.gd`; `game/dev/commands/ult.gd`, `game/dev/dev_console.gd` (completion,
auto-ult), `game/dev/content_validator.gd`; `game/tools/sync_tags.gd`, `game/tools/build_ult_pass.gd`/`.tscn`;
`tests/scripted_controller.gd`, `tests/combat/test_ult_interrupts.gd`, `tests/combat/test_golden.gd`,
`tests/game/test_demo_ults.gd`, `tests/game/test_dev_console.gd`, `tests/game/test_content_validator.gd`,
`tests/tools/build_fixtures.gd`, `tests/tools/build_broken_fixtures.gd`, fixtures, broken fixtures and goldens;
`src/Rpg.Contracts/Battle/ActionLog.cs`, `BattleContractTests.cs`, `BattleGoldenTests.cs`.
Yours, approved 2026-10-21 (`design:`): `godot_gas/tag_registry.tres` (+ regenerated `gameplay_tags.gd`), the new
demo ult files, `cleave.tscn` and `sanctuary.tscn` (tag), `warrior.tres`, `cleric.tres`, `golem.tres` (grants),
`presentation/demo/battle_panel.gd` (ult row built in code, auto-ult, "X unleashes Y!"; enemy charge shows in the
existing "Ult" stat).

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

Decided in implementation (synced 2026-10-21): a moved interrupt is `CheckpointMismatch`, not `TurnMismatch` (it
lands at a valid window; superseded 2026-10-22 by spec atomic-battles: without checkpoints it is `TurnMismatch` or an
end-of-battle reason); the scripted policy splits windows by slot, not by turn; retargeting stays out of the golden
(it happens before logging); a martyr fixture instead of a thorn enemy, so the death-in-DECISION case replays; ults
are battle-only (not on the map); auto battles press ready ults; the demo ults come from a new builder,
`build_ult_pass`.

None open.
