# Spec: content-pass (slice 1c5)

Status: 📝 Spec written, reviewed (decisions D1–D8 approved as recommended, 2026-10-22) · Roadmap: slice 1c5 · Date: 2026-10-22
Design intent: `specs/design/combat-design.md` ("Not yet designed": buff and debuff magnitudes and durations, break
damage and per-type break effects, resistances), `specs/design/game-design.md` sections 2a and 3. Builds on
`specs/item-pass.md` (hit tags, break, One More, follow-ups), `specs/ult-interrupts.md` (ult windows, enemy brains),
`specs/atomic-battles.md` (v2 log, one final hash, trace). Open gaps it closes: `specs/dev-tools.md` "Remaining work",
`specs/item-pass.md` 6 and 8, `specs/animation-sets.md` 6, `specs/ult-interrupts.md` 6 and 8.

The content lines below were approved as proposed (D8, 2026-10-22). Magnitudes are starting values as a designer types
them; once built they live in the content files, which become the source of truth, and this spec keeps pointers only.

## 1. Purpose & enterprise mapping
The polish and content slice before the demo. Three parts:

1. **Statuses, designed then built:** damage over time, stat ups and downs, control, cleanse and dispel,
   **Persona-style elemental affinities** (weak, resist, drain), effect hit and effect resistance, per-type break effects and break damage. All GAS content on `Status.*` tags and
   GodotGAS's own stacking, with **six small battle hooks** where a status rule needs one (2.1).
2. **Content chosen for mechanic coverage, not volume:** enemies, two bosses (phases and scripted patterns as data),
   items and armor that use the new statuses. Section 3.6 is a **coverage matrix**: each piece names the mechanic, or
   the interaction between mechanics, it exercises (break × One More, follow-ups off statuses, ults between DoT ticks,
   death and revive under debuffs, stacking and expiry, resist vs weakness vs drain, party breaks and enemy One More).
3. **Close the open gaps** left by 1c, 1c2, 1c3 and 1c4 (section 3.8), each with its test.

**Why it matters for the backend:** when slices 3 (battle verify), 4a (run verify), 4b (analytics) and 8 (load) land,
the verifier, replay and analytics must be fed many different mechanic paths, not a few happy paths. Every new path
here is recorded into a golden, so the verifier is proven on it before any server exists.

**Enterprise mapping: none at runtime** (client-only, local mode, no service, queue, broker or cache). Indirect:
- The content hash changes, so `ruleset_version` changes (expected; no server yet).
- The verifier (slice 3) replays the new paths: party turns skipped by control (no log entry), enemy One Mores
  (re-simulated, never logged), status rolls on the battle RNG, boss phases. All deterministic; **no wire change**.
- Analytics (4b) later sees new move and item ids; ids stay namespaced (`demo.item.<id>`) and never become Prometheus
  labels. No new analytics events here.

Out of scope: shields that absorb damage (needs a `shield` attribute in the damage ExecCalc; section 8), summons and
adding units mid-battle, multi-wave encounters, per-ability ult charge amounts, the demo run itself (1d), anything on
the server.

## 2. Sequence flow
No server. Flows inside a battle; system hooks are marked **(hook)**, everything else is content on existing paths.

### 2.1 The six battle hooks (system, `combat/`)
**H1. Control skips a turn** (`Battle.run`, `State.Controlled` rule tag):
```
actor's turn: Broken recovery → asc.turn_start() (DoTs tick) → Event.Turn.Start → drain → deaths → end check
if actor alive and actor.asc has State.Controlled:                 (hook; a rule tag like State.Broken)
    no action: the controller and brain are not asked; nothing logged for a party unit
    signal turn_skipped(actor, reason tags); Event.Turn.Skipped {source: actor} → drain
    asc.turn_end() (buffs and the control itself count down) → Event.Turn.End → drain
    action value reset as for a normal turn
```
Content grants `State.Controlled` through an effect's `granted_tags` beside its own `Status.Debuff.<Name>` tag
(Freeze, Stun, Entangle), so a new control status is a file, not code. A skipped party turn has no log entry, so
replay reaches it by re-simulation; a log entry on a turn the replay skips is a structural 2002 (`TurnMismatch`,
existing reason). Controlled units can't cast ults: **in content** (D3), as an `activation_query` "lacks `State.Controlled`" on
each ult ability, not a battle rule. GodotGAS then refuses the activation, so the battle panel and console don't
offer it, `EnemyBrain.choose_interrupt` skips it, and a logged party ult by a controlled unit fails to activate in
replay (2002 `IllegalAbility`, existing). An ult without the query is a deliberate "breakout" ult; the validator
warns about it (`ult_ignores_control`). Where an ult already has an `activation_query`, the requirement is combined
with it (one AND query), never replacing it.

**H2. Status application chance** (`Battle.resolve_execution`, `ExecutionRow.chance`):
```
row.chance (typed %, stored ×100; default 100) — only rows whose effect is a status set it
if row.chance_x100 < 10000 or the target can resist (effect_res > 0):
    final := chance × (100 + source.effect_hit)% × (100 − min(target.effect_res, 100))%   (Fixed helpers)
    if final < 10000: roll rng.randi_range(0, 9999) < final, one roll per target, in hit order
    miss → the spec is not applied; Event.Status.Resisted to source and target (payload: row tags, effect path)
```
A row with chance 100 against a target with `effect_res` 0 never rolls, so **every existing replay keeps its RNG
sequence** (fixtures and demo have no `chance` and no `effect_res`). Rolls depend on combat state only.

**H3. Stacked DoTs tick per stack** (`CombatASC.turn_start`): GodotGAS adds a periodic stack's spec to
`stack_specs` but its turn tick evaluates only the wrapper spec, so a 3-stack Poison would tick once. The hook ticks
the wrapper and then each stacked spec, in stack order, with one countdown per wrapper (REFRESH_DURATION semantics).
Pinned by a test on the addon internals (`stack_specs`), like the existing `CombatASC` tests. First step of the
slice: confirm the addon behaviour; if it already ticks every stack, H3 becomes a test only.

**H4. Combined events for break effects and ults** (`Battle._send_damage_events`, `Battle._activate`):
- A breaking hit also sends `Event.Damage.Dealt.Break.<DamageType>` / `Event.Damage.Taken.Break.<DamageType>`
  (after the existing events, sorted), so a passive can implement "Fire break → Burn" with an exact trigger tag.
- An activated ability also sends `Event.Ability.Used.<Type>` for each `Ability.Type.<X>` in its `asset_tags`
  (today: `Ultimate`, `FollowUp`), and an out-of-turn ult additionally `Event.Battle.Interrupt` to its caster. Items
  that react to ults (charge refund, "+ATK after an ult") are then plain triggered passives.

**H5. Boss phases as data** (`EnemyDefinition.phases: Array[BossPhase]`, `Battle._check_phases`):
```
BossPhase (combat/boss_phase.gd, Resource): hp_below (typed %, ×100), ability_set: AbilitySet, clear_debuffs: bool
after any HP change settles (where deaths are checked):
    for each living enemy, its next phase whose hp_below > hp% (integer: hp × 10000 < hp_below × max_hp):
        grant the phase's AbilitySet (abilities, effects, tags such as State.Phase.2) through the existing
        AbilitySet path; if clear_debuffs: remove effects with Status.Debuff
        Event.Unit.PhaseChanged {source: unit, phase: n} → drain; signal phase_changed
    phases are entered once each, in order; a hit that crosses two thresholds enters both, in order
```
Phase abilities replace behaviour through tags: phase-1 abilities carry `activation_query` "lacks State.Phase.2",
phase-2 ones "has State.Phase.2"; an enemy brain then picks among whatever can activate. Phase state is tags and
effects, so it is already in the state hash (hash stays v1).

**H6. Action delay and advance** (`Battle.resolve_execution`, set-by-caller `Data.Delay`; D5):
```
after a row's spec is applied to a living target (and not refused by immunity or a missed H2 roll):
    if the spec has a Data.Delay magnitude d (typed %, ×100; negative = advance):
        turn_manager.delay(target, d)      (existing; % of the target's full action value, as BREAK_DELAY)
        an advance never takes the remaining action value below 0
        signal action_delayed(target, d)
```
The value lives on the effect (a set-by-caller modifier the row passes, or the effect's own default), so Entangle
is "SPD down + delay 30" as one file, and "ally acts sooner" buffs or advance items are files too. Action value is
already hashed (`unit=...|av=`), so a wrong delay is caught at the final hash; nothing is logged. Only effects
applied by rows (actions and triggered passives) delay; DoT ticks never do.

### 2.2 Enemy brains (system classes, configured in content)
The default `EnemyBrain` stays. Two subclasses in `combat/`, configured per enemy in its `.tres` (no script in
`content/`):
- **`PatternBrain`**: `pattern: Array[StringName]` of ability tags, cycled by the unit's own action count (a battle
  counter on `BattleUnit`, hashed as `pattern=<n>` only when non-zero, so existing hashes don't change); a step
  whose ability can't activate falls through to the default choice. Targets as the default brain.
- **`TacticalBrain`**: the default choice plus ult timing: `ult_when_ally_hp_below` (typed %; hold the ult until an
  enemy-side ally or itself is below it, or never if 0) and `ult_when_party_broken` (cast when a party member is
  Broken). Single-target choices prefer `State.Taunting` units (H1's sibling rule below); among the rest it skips
  targets that drain the ability's damage type, then those that resist it (Persona enemies learn affinities), as long
  as another candidate is left; then the default draw over what remains. Affinities are read from the ASC's tags, so
  the filter uses no RNG and the draw count is unchanged (one draw per choice).

**Taunt:** a single-target enemy action chosen by any brain must target a `State.Taunting` party unit when one is
alive (`Battle.target_candidates` filters to taunters for enemy single-target abilities). Party targeting is
unchanged. It is a rule tag, granted by content (`Status.Buff.Taunt` + `State.Taunting`).

Both brains close the ult-interrupts gap: the first custom brain gets the test that a brain returning an ult as a
turn action is a runner error, never a verdict.

### 2.3 Status lifecycle (existing rules, written down)
```
applied by a row (H2 roll) or a trigger → GodotGAS stacking (REFRESH_DURATION + max_stacks; overflow effects)
DoT / HoT: tick at the holder's turn start (CombatASC.turn_start), before it acts; per stack (H3)
stat buffs, debuffs, control: count down at the holder's turn end (turn_end); a self-applied one skips its first
    countdown (existing HSR rule); a One More never counts down
cleanse: an effect with remove_effects_with_tags [Status.Debuff]; dispel: [Status.Buff] on an enemy
immunity: an effect's application_query (e.g. lacks Immune.Control) — the application is refused, no roll
death: temporary effects dropped (existing _lay_down); a revived unit comes back with none
end of battle: nothing carries over (game design: buffs, debuffs and DoTs don't)
```
Interaction cases this slice records on purpose: an ult in the BETWEEN window cleanses a DoT before it ticks; a DoT
tick kills the last enemy at turn start (victory before the action; credit via `last_hit_by`); a DoT kill on a
Broken unit; a control applied to a unit owed a One More (the One More still happens: it is not a turn); Freeze
expiring on the frozen unit's skipped turn; a revive under an enemy's AoE debuff.

### 2.4 Elemental affinities (Persona; content + ExecCalc, one small battle change)
Each damage type a unit can be hit by has at most one effective affinity, read from its tags at the moment of the
hit. Tags come from every existing GAS path (definition `tags`, variant or loadout `AbilitySet.tags`, an item's or
armor's infinite effect, a timed effect), so an item that adds an affinity is a file, not code.

| Affinity | Tag | Hit result | Hit tag | Toughness damage |
|---|---|---|---|---|
| Weak | `Weakness.<Type>` (exists) | × target `weakness_dmg` | `Hit.Weakness` | yes |
| Resist | `Resist.<Type>` | × target `resist_dmg` | `Hit.Resisted` | no |
| Drain | `Drain.<Type>` | **no damage; the target heals** the hit's damage after DEF, × target `heal_taken` | `Hit.Drained` | no |
| (none) | – | normal | – | – |

**Priority when a unit has more than one for the same type** (items stack, effects come and go): **Drain > Weak >
Resist** (D9; Weak > Resist is D4). So Analyzer Lens (Exposed: weak to Physical) can't beat an enemy's Physical drain,
and a Resist item doesn't cancel a Weakness implant of the same type.

**A drained hit, step by step** (ExecCalc 3.5, battle `resolve_execution` / `_send_damage_events`):
```
ExecCalc: BaseDmg × DefMultiplier → amount; target has Drain.<X> for the row's Damage.Type.<X>:
    return {"hp": +amount × target.heal_taken%}; inject Hit.Drained; stop
    (no weakness, broken, crit or dmg_mult/dmg_taken step; no crit roll, so no RNG draw for this hit)
battle: HP went up, so no Event.Damage.Dealt / Taken (they need damage > 0): Thorn Mail and other Damage.Taken
    triggers don't fire, last_hit_by is unchanged, no break check
    instead (change): a spec with Hit.Drained sends Event.Damage.Dealt.Drained (source) and
    Event.Damage.Taken.Drained (target), payload {source, target, amount: healed, row, tags, hit_tags},
    and the Battle signal damage_drained(source, target, amount) for the UI
```
Affinities apply to every hit that runs the damage ExecCalc with a damage type: actions, follow-ups, break damage and
**DoT ticks** (a Fire-draining unit with Burn heals each tick). Percent-of-max-HP DoTs (Bleed) and FLAT rows without a
damage type ignore affinities. Healing from a drain is capped at max HP by the AttributeSet's clamp, as any heal.

### 2.5 Authoring loop (unchanged tools)
Builder scene for new files (`game/tools/build_content_pass.tscn`, like `build_item_pass.tscn`; adds missing files
only) → `validate` (0 errors) → `sync_tags --add-missing` → script runner smoke script
`game/dev/scripts/content_pass.txt` → you playtest and tune → `design:`.

## 3. Data contracts
**C# contracts: none change.** `ActionLog` v2, `ActionEntry` (`Extra`, `Interrupt`), `BattleSnapshot` v2,
`ReplayRequest`, `ReplayResult` and `MismatchReason` are unchanged: a skipped turn has no entry, enemy One Mores and
enemy phases are re-simulated, statuses are state. No new mismatch reason. `Rpg.Contracts.Tests` cross-checks the new
goldens (section 6). **RabbitMQ / Redpanda / Redis: N/A** (no server in this slice).

### 3.1 System changes (`combat/`, `game/`)
| Where | Change |
|---|---|
| `combat/battle.gd` | H1 (`CONTROLLED_TAG := &"State.Controlled"`, `EVENT_TURN_SKIPPED`, signal `turn_skipped`), H2 (roll in `resolve_execution`, `EVENT_STATUS_RESISTED`), H4 (`Break.<Type>`, `Ability.Used.<Type>`, `EVENT_BATTLE_INTERRUPT`), H5 (`_check_phases`, `EVENT_PHASE_CHANGED`, signal `phase_changed`), H6 (`DELAY_TAG := &"Data.Delay"`, signal `action_delayed`), taunt filter in `target_candidates` (`TAUNTING_TAG := &"State.Taunting"`) |
| `combat/combat_asc.gd` | H3: per-stack periodic ticks |
| `combat/execution_row.gd` | `chance` (typed %, `chance_x100`, default 10000) |
| `combat/boss_phase.gd` (new) | `BossPhase` resource (H5) |
| `combat/unit_definition.gd` or the enemy subclass | `phases: Array[BossPhase]` (enemies only; empty by default, so existing enemies are unchanged) |
| `combat/pattern_brain.gd`, `combat/tactical_brain.gd` (new) | 2.2 |
| `combat/battle_unit.gd` | `actions_taken` (for `PatternBrain`), `phase_index` |
| `combat/state_hasher.gd` | `pattern=<unit>|<n>` and `phase=<unit>|<n>` lines **only when non-zero**; hash stays `hash-v1`, every existing golden unchanged |
| `game/tools/sync_tags.gd` | Checks the new system tags (3.3) |
| Validator | `phase_order` error (phases not strictly decreasing `hp_below`), `pattern_unknown_ability` error (a pattern step the enemy doesn't have), `chance_on_damage` warning (a `chance` < 100 on a row whose effect is instant damage), `controlled_without_status` warning (an effect granting `State.Controlled` without a `Status.Debuff.*` tag, so the UI can't show it), `ult_ignores_control` warning (an `Ability.Type.Ultimate` ability whose activation query doesn't require lacking `State.Controlled`; D3), `affinity_conflict` warning (a definition whose own tags give two affinities for one type; items and effects combining at run time are fine, 2.4 decides) |
| `combat/battle.gd` (affinities) | `HIT_DRAINED := &"Hit.Drained"`; `_send_damage_events` also runs for a spec with `Hit.Drained` (amount = HP gained, events `Dealt.Drained` / `Taken.Drained` only, not plain Dealt/Taken); signal `damage_drained` |
| `combat/tactical_brain.gd` | affinity-aware target filter (2.2) |
| `RunController.battle_log` / `state json` | `lastBattle` gains drained and resisted hits, skipped turns, resisted applications, phase changes and per-unit statuses (tag, remaining turns, stacks) at the end |
| Console | `status <unit>` (lists active statuses with turns and stacks; Claude parity for the UI tooltip); `effect` (existing) applies a status for tests |

### 3.2 Attributes (your demo AttributeSet and `attributes_draft.cfg`; approved, D1)
| Name | Default | Min | Use |
|---|---|---|---|
| `effect_hit` (%) | 0 | 0 | raises the attacker's status chance (H2) |
| `effect_res` (%) | 0 | 0 (cap 100 in the formula) | lowers the chance a status lands on the holder (H2) |
| `resist_dmg` (%) | 50 | 0 | damage multiplier for a hit of a type the target resists |

Fixtures get these in a **new** fixture attribute set (`fixture_status_attribute_set.gd`) used only by the new
fixture units, so the existing fixture goldens stay byte-identical (adding attributes to a set changes the hash of
every unit using it).

### 3.3 Tags (your `godot_gas/` registry; approved, D1)
Rule tags (read by the battle): `State.Controlled`, `State.Taunting`, `State.Phase.2`, `State.Phase.3`.
Data: `Data.Delay` (H6).
Events: `Event.Turn.Skipped`, `Event.Status.Resisted`, `Event.Unit.PhaseChanged`, `Event.Battle.Interrupt`,
`Event.Ability.Used.Ultimate`, `Event.Ability.Used.FollowUp`, `Event.Damage.Dealt.Break.<Type>` and
`Event.Damage.Taken.Break.<Type>` for Physical, Ice and Fire, `Event.Damage.Dealt.Resisted`,
`Event.Damage.Taken.Resisted`, `Event.Damage.Dealt.Drained`, `Event.Damage.Taken.Drained`. Hit: `Hit.Resisted`,
`Hit.Drained`. Resist: `Resist.Physical`, `Resist.Ice`, `Resist.Fire`. Drain: `Drain.Physical`, `Drain.Ice`,
`Drain.Fire` (one per `Damage.Type.<X>`, like weaknesses; a new damage type adds its own).
Immunity: `Immune.Control`, `Immune.Dot`. Statuses (3.4): one `Status.Buff.<X>` / `Status.Debuff.<X>` each.
Plus one `Ability.*` tag per new ability.

### 3.4 Status catalog (design proposal; content in `content/demo/effects/`, made by the builder)
All `TURN_BASED`. "Turns" count the holder's turns. Stacking: **R** = REFRESH_DURATION, max 1 (reapply refreshes);
**S n** = REFRESH_DURATION, max n stacks (each stack adds, duration refreshes). Chance = the applying row's base chance.

| Status | Tag | Kind | Proposed effect | Turns | Stacking | Chance |
|---|---|---|---|---|---|---|
| Burn (exists) | `Status.Debuff.Burn` | DoT, Fire | runs the damage ExecCalc each turn | 2 | R | 100 |
| Bleed | `Status.Debuff.Bleed` | DoT, Physical | % of the holder's max HP per tick (percent ExecCalc) | 2 | R | 100 |
| Poison | `Status.Debuff.Poison` | DoT, stacking | flat damage per stack per tick (H3) | 3 | S 5 | 100 |
| Regen | `Status.Buff.Regen` | HoT | % max HP per tick | 2 | R | – |
| Attack Up (exists) | `Status.Buff.AttackUp` | stat | + ATK | 2 | R | – |
| Attack Down | `Status.Debuff.AttackDown` | stat | − ATK | 2 | R | 100 |
| Defense Up | `Status.Buff.DefenseUp` | stat | + DEF | 2 | R | – |
| Defense Down | `Status.Debuff.DefenseDown` | stat | − DEF | 2 | R | 100 |
| Haste | `Status.Buff.Haste` | stat | + SPD | 2 | R | – |
| Slow | `Status.Debuff.Slow` | stat | − SPD | 2 | R | 100 |
| Vulnerable | `Status.Debuff.Vulnerable` | stat | + `dmg_taken` | 2 | S 3 | 100 |
| Weaken | `Status.Debuff.Weaken` | stat | − `dmg_mult` | 2 | R | 100 |
| Exposed (exists) | `Status.Debuff.Exposed` | weakness | grants `Weakness.<Type>` | 2 | R | 100 |
| Freeze | `Status.Debuff.Freeze` + `State.Controlled` | control | skips the turn (H1); Ice break effect | 1 | R | 65 |
| Stun | `Status.Debuff.Stun` + `State.Controlled` | control | skips the turn (H1) | 1 | R | 50 |
| Entangle | `Status.Debuff.Entangle` | control (soft) | action delayed on apply (H6, `Data.Delay`) + − SPD | 2 | R | 100 |
| Taunt | `Status.Buff.Taunt` + `State.Taunting` | control (party) | enemies' single-target actions must target the holder | 2 | R | – |
| Cleanse | – | instant | removes `Status.Debuff` effects from allies | – | – | – |
| Dispel | – | instant | removes `Status.Buff` effects from an enemy | – | – | 100 |
| Ward | `Status.Buff.Ward` | immunity | grants `Immune.Control` | 2 | R | – |

**Per-type break effects and break damage** (HSR, D2): a content passive set, `content/demo/ability_sets/
break_effects.tres`, listed in each demo character's abilities, with one passive per `Event.Damage.Dealt.Break.<Type>`:

| Break type | Break damage (FLAT row on the broken target, scaled by the breaker's ATK) | Then |
|---|---|---|
| Physical | 100% ATK, Physical | Bleed |
| Fire | 50% ATK, Fire | Burn |
| Ice | 50% ATK, Ice | Freeze (65%) |

Break damage is a triggered hit: it carries its damage type but no `Hit.Break`, and it can't break again (the target
is already Broken).

**Resistances and drain:** see 2.4 (affinity table and priority). Resisted and drained hits never deal toughness
damage, so a unit can only be broken through a type it is actually weak to.

### 3.5 Your ExecCalc edit (`content/demo/exec_calcs/exec_calc_standard_damage.gd`; approved, D1)
```
  RawDmg = BaseDmg × DefMultiplier%                                    (unchanged)
  weak: … (unchanged)
+ (before the weak step) row has Damage.Type.<X> and target has Drain.<X>:
+       return {"hp": +RawDmg × target.heal_taken%};  inject Hit.Drained   (no crit roll, no toughness, nothing else)
  weak: … (unchanged; skipped when drained)
+ elif row has Damage.Type.<X> and target has Resist.<X>:
+       RawDmg × target.resist_dmg%;  inject Hit.Resisted              (no RNG, no toughness damage)
  broken, crit, dmg_mult × dmg_taken: unchanged
```
The fixture ExecCalc mirrors it (system copy in `tests/fixtures/`).

### 3.6 Content and coverage matrix (proposal; ids `demo.<kind>.<id>`, made by the builder)
**Enemies** (`content/demo/enemies/`):
| Enemy | Kit | Covers |
|---|---|---|
| Fire Imp | Fire bolt (Burn 100%); `Resist.Fire`; weak Ice | Burn on the party, resist vs weakness, Exposed(Fire) on a Fire-resistant enemy (D4) |
| Bog Toad | Spit (Poison, stacks); weak Fire | stacked DoT ticks (H3), cleanse, DoT kill credit |
| Frost Wisp | Chill (Slow), Freeze touch (Freeze 50%); `effect_res` 30; weak Fire, Physical | party turn skipped (H1, no log entry), effect_res vs effect_hit rolls (H2), two weaknesses |
| Knight | Shield bash (Stun 40%), Guard (Defense Up self); **party toughness** target: its hits deal toughness damage; weak Ice; `Immune.Control` (Ward) | Stun, immunity refusing an application, self-buff countdown rule on an enemy |
| Shaman | Hex (Vulnerable, stacks), Mend (Regen on an ally), Dispel the party; `TacticalBrain` | enemy dispel of party buffs, HoT on enemies, stacking stat debuff |
| Elite (existing variant) | unchanged | — |

**Bosses** (`Enemy.Boss`, encounters tagged `Encounter.Boss`):
| Boss | Behaviour | Covers |
|---|---|---|
| Golem (existing) | add `phases`: at 50% HP phase 2 (`State.Phase.2`: Quake every 3rd action via `PatternBrain`, `clear_debuffs`) — **edit to your file, D6** | phase change mid-battle (H5), debuff clear, pattern brain, ult + phase interaction |
| Lich (new) | 3 phases (100 / 60 / 25%): Bleed blast → Hex on the whole party (Vulnerable + Weaken) → Death ray (ult, `TacticalBrain` casts when a party member is Broken); `Resist.Ice`; weak Physical; party toughness hits | multi-threshold crossing in one hit, enemy ult timed by state, party broken → **enemy One More** (re-simulated), resist on a boss |

**Items** (`content/demo/items/`; pools as item-pass):
| Item | Effect | Covers |
|---|---|---|
| Plague Flask (usable) | all enemies: Poison ×2 stacks | stacked application, H2 rolls on several targets |
| Frost Lantern | `Damage.Dealt.Ice` → Freeze 25% | control from a trigger, roll inside a triggered passive |
| Serrated Edge | `Damage.Dealt.Critical` → Bleed | DoT off a hit tag |
| Toxic Echo | `Damage.Dealt.Weakness` on a Poisoned target → follow-up | follow-up off a status (activation query on the target's tag) |
| Purifying Bell (usable, cooldown) | Cleanse the party | cleanse before a tick |
| Hexbreaker Charm | holder `effect_res` + | effect_res on the party |
| Witch's Eye | holder `effect_hit` + | effect_hit |
| Overcharge Coil | `Ability.Used.Ultimate` → refund 20 ult charge (H4) | items reacting to ults |
| Interrupter's Badge | `Battle.Interrupt` → + ATK 1 turn | out-of-turn ult event (H4) |
| Shatterpoint | `Damage.Dealt.Break.Ice` → Vulnerable | combined break event (H4) |
| Mirror Ward | `Status.Resisted` (taken) → heal | resisted-status event (H2) |
| Last Rites | `Unit.Killed` on a target with a DoT → Regen self | kill × DoT |
| Salamander Heart | holder gains `Drain.Fire` **and** `Weakness.Ice` (the implant) · T B · R | drain heals and its events, a party weakness (enemy Ice hits deal weakness damage to the holder), the trade-off item shape |
| Frostguard Charm | holder gains `Resist.Ice` · T S · C | resist on the party; with Salamander Heart the implant still wins (Weak > Resist, D9) |
| Leech Hide | holder gains `Drain.Physical` (no trade-off) · B · R | drain of the most common damage type (Strike, Bite, Crush, Thorn Mail hits); `TacticalBrain` steering Physical attacks away |
| Siphon Sigil | `Damage.Taken.Drained` → + ult charge · T · C | an item reacting to a drain (the new event) |

Salamander Heart, Frostguard Charm and Leech Hide are infinite effects whose `granted_tags` carry the affinity
tags; the Fire Imp (`Resist.Fire`) and the Lich (`Resist.Ice`) keep the enemy side of resist coverage.

**Armor** (`content/demo/equipment/`): Warden Helm (Head: `Immune.Control` while worn — tests immunity from an
infinite effect), Thornbark Mail (Body: `Damage.Taken` → Poison the attacker), Tactician's Ring (Accessory: Taunt self
at battle start).

**Character kits** (your files, D6): Warrior gains Provoke (Taunt self + Defense Up, skill); Cleric gains Purify
(Cleanse + Regen, skill) and both get `break_effects.tres`. So the party can use the new statuses without items;
each line is an `old → new` change shown before it is made.

**Existing ults** (your files, D3 + D6): Cleave, Execute, Sanctuary, Resurrection and the Golem's Quake each get the
"lacks `State.Controlled`" requirement in their `activation_query` (combined with any query already there), shown
as `old → new` before it is made. New ults in 3.6 are built with it.

**Encounters and rooms:** one encounter per new enemy pair, the Lich boss encounter and a boss room; an
`content_pass` sandbox layout with one room per encounter for the smoke script.

### 3.7 UI (your `presentation/demo/`; approved, D1)
`battle_panel`: per unit, a status line `Burn 2 · Poison×3 2 · Freeze 1` read from `Status.*` tags and the active
effects (turns, stacks); messages "X is frozen and skips the turn" (`turn_skipped`), "X resisted Freeze"
(`Event.Status.Resisted` via a read-only signal), "Phase 2!" (`phase_changed`); a taunt mark. Text placeholders,
no icons.

### 3.8 Gaps closed from earlier slices
| From | Gap | Closed by |
|---|---|---|
| `dev-tools` Remaining work | `kill` queued during an enemy turn (untested) | `test_kill_queued_during_enemy_turn`: a scripted controller queues the dev decision while the turn loop is in an enemy action (driven through the battle's signals, not timing) |
| `dev-tools` Remaining work | throwaway commands ignored in a release build; Tab cycling | stay manual; written as a checklist in `specs/dev-tools.md` (no automated test possible headless) |
| `item-pass` 6 | a dead character being equipped | `test_equip_dead_character` (gear applies on revive) |
| `item-pass` 6 | demo Fire beats Physical on a Slime; demo break recovery | `test_demo_slime_fire_vs_physical`, `test_demo_break_recovery` in `test_demo_items.gd` |
| `item-pass` 6 | equip/unequip run-log replay | **stays open** for slice 4a (no run-log replayer) |
| `item-pass` 8 | resists, per-type break effects, break damage, party toughness | 3.4, 3.6 |
| `animation-sets` 6 | `@export_file` stores a `uid://` reference for `view` | `test_view_path_is_uid` |
| `ult-interrupts` 6 | brain picking an ult as a turn action → runner error | `test_brain_ult_as_action_is_runner_error` with `PatternBrain` |
| `ult-interrupts` 8 | items reacting to ults, smarter enemy ult timing, ults × statuses, party toughness | H4, `TacticalBrain`, Lich, 2.3 cases |
| `ult-interrupts` 8 | ult balance (charge gain, costs, Execute vs One More) | **design break 1d**: your tuning, no system work |

## 4. Failure modes
Server failure scenarios (root `CLAUDE.md` 1–7): **none apply** (no server). What this slice protects is **replay
determinism** on many more paths, which scenario 5 (tampered log → 2002) relies on later. A mismatch is a verdict
(`Rejected`, `errorCode` 2002, a `MismatchReason`), never an HTTP status; no new reason.

| Failure | Behaviour | Test |
|---|---|---|
| New rules change existing replays | They can't: no fixture or demo row sets `chance`, no unit has `effect_res`, no `Resist.*` or `Drain.*`, no phases, no `State.Controlled`; hash lines only when non-zero | every existing golden passes un-re-recorded |
| Log entry on a turn the party unit was controlled | 2002 `TurnMismatch` | `status-seed-3-tampered-skip` golden |
| Controlled party unit skipped in the client but not in replay (or the reverse) | Impossible by construction (same rule tag, same order); the trace pinpoints it if it happens | `test_control_skip_record_replay` |
| Status roll count differs between client and verifier | One roll per target in hit order, only when the final chance < 100%; no roll on immunity | `test_status_roll_only_when_needed`, `test_immunity_no_roll` |
| Stacked DoT ticks once instead of per stack | H3 ticks each stack | `test_poison_ticks_per_stack` (pins the addon internals) |
| DoT kills the last enemy at turn start | Victory before the action; no log entry for that turn; killer credited | `test_dot_kills_last_enemy` |
| Ult cleanses a DoT in the BETWEEN window | The DoT never ticks | `test_ult_cleanse_before_tick` |
| Control on a unit owed a One More | The One More still happens (it isn't a turn); control counts down at its next real turn end | `test_one_more_while_controlled` |
| One hit crosses two phase thresholds | Both phases entered once, in order; `PhaseChanged` twice | `test_phase_double_cross` |
| Phase change on the killing blow | No phase (death first) | `test_phase_not_on_kill` |
| Pattern brain step can't activate | Falls back to the default choice, deterministic | `test_pattern_brain_fallback` |
| Brain returns an ult as a turn action | Runner error, never a verdict | `test_brain_ult_as_action_is_runner_error` |
| Taunter dies or is controlled mid-round | Taunt filter only while alive; a controlled taunter still taunts (HSR); filter recomputed per choice | `test_taunt_targeting` |
| Party broken by an enemy | Enemy One More, re-simulated, not logged; party unit delayed and recovers | `test_enemy_one_more` |
| Weak and resistant to the same type | Weakness only (D4) | `test_weakness_beats_resist` |
| Drain together with weak or resist for one type | Drain only (D9) | `test_drain_beats_weakness`, `test_drain_beats_resist` |
| Drained hit | Target heals (capped at max HP), no crit roll, no toughness damage, no break; only `Dealt/Taken.Drained` events, so `Damage.Taken` triggers (Thorn Mail) stay silent; `last_hit_by` unchanged | `test_drain_heals_and_events`, `test_drain_no_rng_draw`, `test_drain_no_thorns` |
| DoT of a drained type | Each tick heals | `test_drain_dot_tick` |
| Affinity from an item gained or lost between battles | Read from tags at hit time; next battle's fresh ASC has only what is held | `test_affinity_from_item` |
| `TacticalBrain` against drainers | Skips drain, then resist targets while another candidate exists; same RNG draws as the default brain | `test_tactical_brain_avoids_drain` |
| Controlled unit's ult | Refused by its activation query: not offered, enemy brain holds it, a logged one is 2002 `IllegalAbility`; an ult without the query still fires (breakout) | `test_controlled_cannot_ult`, `test_breakout_ult` |
| Delay or advance (H6) | Applied once per landed spec; an advance stops at 0; a refused or missed status doesn't delay; a delayed Broken unit keeps the break delay too | `test_action_delay_and_advance`, `test_delay_on_broken_unit`, `test_delay_not_on_miss` |
| Phase lines / pattern lines change existing hashes | Written only when non-zero | existing goldens unchanged |
| Bad content (phase order, unknown pattern step, chance on damage, control without status, ult ignoring control) | Validator error / error / warning / warning / warning | `test_content_validator` broken fixtures |

## 5. Observability
N/A: client-only slice, no service runs. Local signals: validator report, script-runner JSON (`lastBattle` with skips,
resists, phases, statuses), the determinism trace for any divergence.

## 6. Test plan
System tests use `tests/fixtures/` only, on a new fixture attribute set and new fixture units (the builders add
missing files only), so existing fixtures and goldens stay byte-identical.

**Fixtures:** statuses `burn`, `poison_stack` (S 5), `freeze` (control, chance 50), `taunt`, `ward` (immunity),
`cleanse`, `vulnerable` (S 3), `drain_fire_implant` (`Drain.Fire` + `Weakness.Ice`, infinite), `resist_ice`, `drain_physical`, `entangle` (`Data.Delay` 30), `haste_advance` (`Data.Delay` −25); the fixture break-effects passive set; enemies `fixture.enemy.toad` (Poison),
`fixture.enemy.wisp` (Freeze, `effect_res`), `fixture.enemy.knight` (party toughness, Stun), `fixture.enemy.lich`
(three phases, `PatternBrain`, `TacticalBrain` ult); a new fixture character `fixture.character.breaker` with ults `Fixture.Ability.UltLocked` (requires lacking `State.Controlled`) and `UltBreakout` (no requirement); characters `fixture.character.hexer` (status rows with
`effect_hit`), `fixture.character.guard` (Taunt, toughness 0 → party breakable variant `guard_tough`).

**System tests** (`tests/combat/test_statuses.gd`, `test_bosses.gd`, `test_brains.gd`): every row of section 4,
plus `test_status_durations_and_countdown`, `test_refresh_vs_stack`, `test_cleanse_and_dispel`,
`test_break_effect_per_type` (H4 combined events), `test_ability_used_type_events`, `test_interrupt_event`,
`test_resisted_status_event`, the affinity rows of section 4, `test_death_drops_statuses_revive_clean`. Game and tools: `test_status_command`,
`test_equip_dead_character`, `test_kill_queued_during_enemy_turn`, `test_view_path_is_uid`; validator broken fixtures
`enemies/phase_order.tres`, `enemies/pattern_unknown.tres`, `abilities/chance_on_damage.tscn`,
`effects/controlled_without_status.tres`, `abilities/ult_ignores_control.tscn`, `enemies/affinity_conflict.tres`.

**Golden vectors** (`tests/fixtures/golden/`, each with its `.trace.json`):
| File | Proves |
|---|---|
| `status-seed-3.json` / `.result.json` | DoT stacks, a party turn skipped by Freeze (no entry), rolls hit and miss, cleanse ult before a tick, a DoT kill, a drained hit and a resisted hit on a party member holding the implant → Verified |
| `status-seed-3-tampered-skip.json` / `.result.json` | an entry added on the frozen turn → 2002 `TurnMismatch` |
| `boss-seed-5.json` / `.result.json` | three phases (one double cross), pattern brain, party broken → enemy One More, enemy ult on a Broken party member, taunt → Verified |
`Rpg.Contracts.Tests` cross-checks them (deserialize, re-serialize byte-identical), with no record change.

**Demo content tests** (`tests/game/test_demo_content_pass.gd`, reads `content/demo/`, direction only, never tuned
numbers; skipped when the demo AttributeSet lacks the new attributes): one group per table of 3.6 (each enemy's
mechanic happens; each boss changes phase; each item's trigger fires), `test_demo_content_pass_replay` (a recorded
boss fight → Verified), plus the item-pass gap tests (3.8). `test_content_valid`: 0 errors. Smoke script
`game/dev/scripts/content_pass.txt` (manual).

`dotnet build` / `dotnet test` green. Both suites pass before the slice counts as done. Headless Godot always with
`--quit-after` and a timeout.

## 7. Implementation order
One uncommitted change set per step, suites green at each:
A. Confirm GodotGAS stacking on periodic effects (H3 or test only); fixture attribute set.
B. H1 control (+ controlled-ult tests), H2 chance (+ `effect_hit`/`effect_res` on fixtures), H3, H6 delay/advance,
   taunt; status tests; `status-seed-3` goldens.
C. H4 combined events; H5 phases, `BossPhase`, brains; boss tests; `boss-seed-5` golden; C# cross-check.
D. Gap tests from 3.8; validator rules; console `status`; `lastBattle` additions.
E. Your files (after approval): tags, attributes (draft + Generate), ExecCalc resist edit, UI panel, then the builder
   for new content; approved `old → new` edits to existing files (Golem phases, characters, the five existing ults); demo tests.
F. `combat-design.md` (statuses, resistances, break effects now designed), `combat-replay-core` (skip, rolls,
   phases, hash lines), `item-pass` / `ult-interrupts` / `dev-tools` / `animation-sets` gap notes, roadmap ✅, root
   `CLAUDE.md` table, `/sync-spec content-pass`.

## 8. Later
- Shields (`shield` attribute absorbed first in the damage ExecCalc), summons and mid-battle spawns, multi-wave
  encounters.
- Per-ability ult charge amounts; ult balance (1d tuning).
- Status icons and VFX cues per status (presentation).
- A `Event.Status.Applied.<X>` family, only if content needs items that react to a specific status landing.
- The rest of Persona's affinities: Null (`Null.<Type>`, no damage) and Repel (`Repel.<Type>`, the hit goes back to
  the attacker; needs a battle hook to retarget a spec). Same tag pattern and priority list, extended.

## 9. Decisions
All approved as recommended (user, 2026-10-22):
- **D1 approvals:** Claude edits your tag registry, the demo AttributeSet draft (`effect_hit`, `effect_res`,
  `resist_dmg`, then Generate), the damage ExecCalc (resist branch, 3.5) and `battle_panel` (3.7), each shown as a
  diff when made; the rest of `client-godot/CLAUDE.md` section 0 applies.
- **D2 break effects are a content passive set** (`break_effects.tres`) listed on each character, triggered by H4's
  `Event.Damage.Dealt.Break.<Type>` on the breaker. Rejected: a battle-rules table in `combat/` (balance numbers in
  system code, or a content file found by convention that the snapshot doesn't carry).
- **D3 controlled units can't ult, in content:** an `activation_query` on each ult (lacks `State.Controlled`),
  guarded by the `ult_ignores_control` validator warning; an ult without it is a deliberate breakout ult. Rejected:
  a battle rule in the ult window (fixed in code, no breakout ults without another flag).
- **D4 weak and resistant to one type:** weakness wins.
- **D5 action delay and advance as hook H6** (`Data.Delay` on an effect, reusing `TurnManager.delay`; negative
  advances). Rejected: Entangle as SPD down only.
- **D6 edits to your existing files** (Golem phases, Warrior Provoke, Cleric Purify, `break_effects.tres` on both
  characters, the controlled requirement on the five existing ults): approved in principle; each still shown as
  `old → new` before it is made.
- **D7 status chances** roll with `effect_hit` / `effect_res` (H2).
- **D8 the content list (3.4, 3.6)** as proposed; starting values move into the content files when built.

Added and approved 2026-10-22 at the user's request (Persona affinities, 2.4):
- **D9 affinity priority Drain > Weak > Resist.** Consequences, accepted: Analyzer Lens can't turn an enemy's drain
  into a weakness, and Frostguard Charm doesn't cover Salamander Heart's Ice implant (the implant is a real cost).
  Rejected: Drain > Resist > Weak (a resist item would cancel an implant, but it reverses D4, so Exposed on a
  resistant enemy would stop working).
- **Drain rules:** heals the hit's damage after DEF × the target's `heal_taken`, no crit roll, no
  toughness; applies to typed DoT ticks; percent-of-max DoTs ignore affinities.
- **New items** Salamander Heart, Frostguard Charm, Leech Hide, Siphon Sigil (3.6), with the starting pools above.
