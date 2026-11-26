# Spec: auto-support (before 5j `second-pack`, after `level-cap`)

Status: **spec written and reviewed 2026-11-25 (the user took the recommendations for Q1 and Q2: D6, D7), ready for `/implement`.** Closes `level-cap` Q1 (the user deferred it 2026-11-24 and
asked for this spec 2026-11-25). Builds on `specs/auto-battle.md` (the smart policy, `AutoPolicy`), `specs/skill-points.md` 3.4
(the SP rhythm and the danger reserve), `specs/bot-play.md` (`Unit.Role.*`) and `specs/level-cap.md` (the moves learned to 50).

## 1. Purpose & enterprise mapping

**Purpose.** Auto (the player's Auto and the smart bot, one policy) plays healers and buffers badly:
1. **Heals: the first one in grant order.** `_support` returns the first `Ability.Role.Heal` move it can cast, so a Cleric with
   Heal, Greater Heal, Mass Heal, Benediction and Miracle always casts **Heal** on one ally, even with the whole party hurt.
   In 24 logged runs it never cast Mass Heal or Benediction.
2. **Buffs: only at full SP, or when nothing else scores.** A buff goes before a basic only when one more basic would overflow
   SP (skill-points 3.4), so a Bard almost never opens with Anthem, and in 24 logged runs it never cast Grand Anthem.

So the gate understates the Cleric and the Bard (and, next slice, the Lifebinder, a healer). The fix: Auto **picks the heal that
restores the most HP that is actually missing**, with an SP-efficiency rule so it never pays extra for nothing, also heals early when
**several** allies are hurt, and **casts a party buff the party lacks** when it can afford it, instead of only at the SP cap.

To know how much a heal restores without casting it, heal ExecCalcs answer `restore_of(source, target)`, read by a new
`RestoreReader`, the same way cost ExecCalcs answer `cost_of` for `CostReader` (skill-points 3.2). GAS first: the numbers stay in
the effects and ExecCalcs; Auto reads them.

**Enterprise mapping.** Client only. Auto's picks are player inputs: they go into the action log like a pressed button, and the
verifier replays the log, never Auto. No component of the backend changes. It moves the balance gate, which is how every later
slice is judged (the smart 4-member gate on `game/dev/balance_seeds.json`).

| Component | Used? |
|---|---|
| Godot client (`game/auto/`, `combat/restore_reader.gd`, two ExecCalcs in `content/`) | Yes |
| ASP.NET Core API, Postgres, Redis, RabbitMQ, Redpanda, verifier worker | No (no wire, log or hash change) |
| Ruleset version | Changes (shipped code and two ExecCalcs change), as with any client build |

## 2. Sequence flow

No server flow. Inside one party decision (spec auto-battle 2.2), `AutoPolicy.choose(battle, unit)` keeps its order and changes
two steps:

1. A ready ult worth casting (unchanged).
2. Revive a dead ally (unchanged).
3. **Heal (changed, 3.2):** when the party is hurt (an ally under `HEAL_BELOW`, today's trigger) **or spread hurt** (`SPREAD_HURT`
   allies or more under `SPREAD_BELOW`, new), Auto scores every heal it can cast (affordable, the danger reserve does not apply to the
   heal itself) by **effective healing** (3.2) and picks the best by the efficiency rule; `{}` when none heals anything.
4. Cleanse (unchanged).
5. Damage and the SP rhythm (unchanged), **except** that before the rhythm compares the best costed move with the basic, a
   **party buff** the party lacks (3.3) is cast when it is affordable above the danger reserve.
6. The cap buff, the basic, the best move, the fallback buff and the last resort (unchanged; the fallback buff uses the 3.3 order).

`last_reason` gains `"party buff"`; the heal keeps `"heal"`. BattleLog prints the picked heal's effective healing.

The ult step (`_ult_worth_casting`, `_best_ult_target`) is unchanged: Sanctuary and Finale keep today's rules (stays out, 7).

## 3. Data contracts

### 3.1 C#
N/A: no wire change. `RunAction`, the battle log and `BattleSnapshot` are unchanged; Auto's picks are logged as today.

### 3.2 Heals

**`RestoreReader`** (`combat/restore_reader.gd`, new, system code; like `CostReader`, never activates anything, never draws from
the RNG):

```gdscript
## What `ability` would restore on `target` if `source` cast it now: {attribute: amount ×100}, before the target's cap.
## Reads every execution row's effect: each ExecCalc offering restore_of(source_asc, target_asc) adds its part; an
## instant effect counts once, a periodic one (a HoT) once per tick over its duration_turns. Rows with chance count fully.
static func restore_of(ability: BattleAbility, source: BattleUnit, target: BattleUnit) -> Dictionary
## HP only (×100; 0 when the ability restores no HP).
static func hp_restore(ability: BattleAbility, source: BattleUnit, target: BattleUnit) -> int
```

**ExecCalcs** (your folder, `content/demo/exec_calcs/`; additive edits, each method beside `execute`, shown `old → new` before the
build):
- `exec_calc_restore.gd` gains `restore_of(source_asc, target_asc) -> Dictionary`: the same formula `execute` uses
  (`amount × source.<source_bonus> × target.<target_bonus>`, or `amount_attribute`), no change to `execute`.
- `exec_calc_percent_of_max.gd` gains the same (`percent × target.<max_attribute> × bonuses`).
- `execute` is refactored to call the shared formula only if that changes no result; otherwise the formula is copied and a test
  pins both against each other (3.5).
- Fixture copy: `tests/fixtures/exec_calcs/fixture_restore.gd` (new) with `restore_of`.

**Effective healing** of a heal move aimed at `target`: over every living ally it reaches (SINGLE_ALLY: the target; ALL_ALLIES: the
party; SELF: the caster), `Σ min(hp_restore, max_hp − hp)`. Overhealing counts for nothing.

**Choice** (`AutoPolicy._heal`, replaces the heal use of `_support`; revives keep `_support`):
1. Candidates: every activatable `Ability.Role.Heal` move that does not target enemies, each single-target one on every living ally,
   each with its effective healing `E` and SP cost `C`. A candidate with `E == 0` is dropped.
2. The best is the highest `E`, except that a move costing more SP than a cheaper candidate must reach `HEAL_STEP`% of the cheaper
   one's `E`, else the cheaper one wins (compared pairwise from the cheapest up, so the result does not depend on grant order).
3. **Cleanse exception (D6):** while an ally the move reaches is afflicted (`_afflicted`: controlled, or `CLEANSE_AT` or more debuffs),
   a heal that also cleanses (`Ability.Role.Cleanse`: Miracle, Purify, Holy Water) skips the `HEAL_STEP` step: it wins when its `E`
   is at least that of the best cheaper heal. No other extra (a buff, a HoT beyond its counted ticks) earns anything.
4. Ties: the lower SP cost, then the most hurt target (lowest HP %), then grant order, then slot. Ints only; no StringName order.

New constants (`AutoPolicy`, system numbers like `HEAL_BELOW`; changed only by measurement, recorded in section 8):

| Constant | Proposed | Meaning |
|---|---|---|
| `HEAL_STEP` | 125 | % of a cheaper heal's effective healing a costlier one must reach |
| `SPREAD_BELOW` | 70 | % of max HP: an ally under it counts as hurt for the spread rule |
| `SPREAD_HURT` | 2 | allies under `SPREAD_BELOW` that make the party spread hurt |

With today's numbers: two allies down 300 HP each → Mass Heal (`E` 600 for 113 SP) beats Heal (`E` 300 for 69 SP); one ally down
500 → Greater Heal (`E` 450) beats Heal (`E` 300, 150% ≥ 125%); one ally down 320 → Heal (Greater Heal's `E` 320 is 107%).

### 3.3 Party buffs

A **party buff** is an activatable `Ability.Role.Buff` move targeting ALL_ALLIES (not an ult) whose `Status.Buff.*` tags
(`_buff_tags`, today's reading) at least `BUFF_LACKING` living allies lack.

`AutoPolicy._party_buff(battle, unit, actions, reserve)`, called in step 5 for a unit with a basic (the rhythm), before the
spend-or-build comparison:
1. Skipped when the party is in danger (`party_in_danger`, today's rule: heals and revives come first and keep their reserve).
2. Skipped when the fight is nearly won: every living enemy is under `BUFF_SKIP_BELOW`% of its max HP.
3. Candidates must be affordable above the danger reserve (`affordable_above`).
4. Order: the most allies lacking one of its tags, then the higher SP cost (a rank or a bigger anthem), then grant order.

A unit without a basic keeps today's buff rule (after damage, `_saving_mp`). Single-target and SELF buffs (War Cry, Iron Hide,
Provoke) keep today's rules: the cap buff and the fallback buff (their order becomes 3.3's step 4 too).

| Constant | Proposed | Meaning |
|---|---|---|
| `BUFF_LACKING` | 2 | living allies that must lack a party buff's status |
| `BUFF_SKIP_BELOW` | 25 | % of max HP: no party buff when every enemy is under it |

### 3.4 Report (dev)

The play report gains an `autoPicks` block (only for runs that Auto played): per class, Auto's picks by `last_reason` and the
abilities picked under `heal`, `party buff`, `cap buff` and `buff` (counts, merged across shards like `procs`). It is how the
build shows Mass Heal, Benediction, Grand Anthem and the other moves are now used. Ability ids appear only in this dev report, never
in a metric label.

### 3.5 RabbitMQ / Redpanda / Redis
N/A: client only.

## 4. Failure modes

- **Determinism.** Auto stays RNG-free and orders only by ints (SP, HP %, counts, slots) and grant order; no `StringName` sort
  (`test_determinism_guard`). The same battle state gives the same pick on a window client and headless.
- **Replays and verification.** Unchanged: the verifier replays logged inputs and never runs Auto. Every golden replays as
  committed; `auto-seed-4` is only re-recorded with `--update-goldens` (not part of this slice; its fixture party has no second heal).
- **A heal or buff that can't be cast.** The candidate lists use `_activatable` (`can_activate_ability`) as today; a refused pick
  hands the decision back (auto-battle 2.4), then the fallback.
- **An ExecCalc without `restore_of`.** `RestoreReader` counts it as 0, so a heal built on an unknown ExecCalc is never picked
  by the heal rule. The validator warns `heal_unreadable` on an `Ability.Role.Heal` move whose effects restore no HP that the
  reader can see (in `content/` only when it uses the role tags).
- **Overflow of numbers.** `restore_of` uses `Fixed` helpers on ×100 ints, like the damage estimate.
- **Root acceptance scenarios:** none (no server path). Covered instead: the balance gate (not a test, 6).

## 5. Observability

N/A for Prometheus: no server code. Dev: BattleLog lines (`heal <ability> -> <target> E=<n>`, `party buff <ability>`) and the
play report's `autoPicks` block (3.4).

## 6. Test plan

**Unit tests** (`tests/game/test_auto_policy.gd`, on fixtures; new fixture heals in `tests/tools/build_fixtures.gd`: a small single
heal, a big single heal, a party heal, a HoT, a party buff and a costlier ranked party buff, on a fixture healer and buffer):
- `RestoreReader` equals what the effect really restores (cast it on a hurt unit, compare HP), for both ExecCalcs and a HoT over its
  ticks; `restore_of` and `execute` agree for bonuses (`heal_mult`, `heal_taken`).
- An afflicted ally → Miracle over Mass Heal at equal or more healing, Mass Heal when Miracle heals less; no afflicted ally →
  the 125% step applies to Miracle like any heal.
- Two allies hurt → the party heal; one ally hurt a little → the small heal; one ally hurt a lot → the big heal (the 125% step both
  ways); a heal that would only overheal is never picked; ties by SP, then HP %, then slot.
- The spread rule: two allies under 70% and none under 45% → a heal; one ally under 70% → no heal.
- Party buff: cast when two allies lack it and SP allows it above the danger reserve; not when the party is in danger, not when every
  enemy is under 25%, not when only one ally lacks it; the costlier rank wins over the lower one; a unit without a basic keeps
  today's rule.
- `test_auto_draws_no_rng` and the determinism guard stay green; the same state gives the same pick twice.

**Content test** (`tests/game/test_demo_auto_support.gd`, real `content/`): a level-30 Cleric with three hurt allies casts Mass Heal
or Benediction (whichever the rule picks), not Heal; a level-30 Bard at the start of a boss fight with SP casts its party anthem.

**Validator** (`test_content_validator`): `heal_unreadable` on a broken fixture.

**Balance (not a test; a step).** The smart 4-member gate, `--check`, on the first 100 seeds for each tweak and the 600 seeds
once at the end (spec level-cap section 8: 299 of 600, 49.83%; 46 of the first 100 with the final code). Expected: the Cleric and
the Bard win more, the others about the same; report per-class wins and `autoPicks` before → after.

**Done when:** both suites pass, the validator is clean, the 600 run is recorded in section 8, and the Cleric's and Bard's kits
show their big moves in `autoPicks`.

## 7. Decisions, open questions, what stays out

**Proposed decisions (for review):**
- D1. Heals by effective healing with an SP-efficiency step (`HEAL_STEP` 125%), not by grant order.
- D2. A spread trigger (two allies under 70%) beside today's 45% trigger, so a party heal can go out before anyone is critical.
- D3. Party buffs cast when affordable above the reserve and lacked by two allies; not in danger, not when the fight is nearly won.
- D4. `restore_of` on the two heal ExecCalcs and a `RestoreReader`, like `cost_of` and `CostReader`; two additive edits to your
  ExecCalcs.
- D5. The player's Auto and the bot stay one policy: the player gets the better Auto too.

**Decided by the user (2026-11-25):**
- D6 (was Q1). A heal that also cleanses skips the `HEAL_STEP` step while an ally it reaches is afflicted (3.2 step 3): one turn
  instead of a heal and then Purify. Benediction's Regen needs no rule: `RestoreReader` already counts a HoT's ticks (capped by the
  HP missing now, so it is slightly undervalued). No other extra earns anything.
- D7 (was Q2). Start from the proposed constants. Measure one 100-seed pass with all five, read `autoPicks`, the average effective
  healing per heal, battle turns and overtime losses (the risk: `SPREAD_BELOW` too high makes healers heal instead of attack and
  fights longer), then change at most one or two constants per 100-seed pass; 600 seeds once at the end. Each change and its
  result goes into section 8.

**Open questions:** none.

**Stays out:** support ults (Sanctuary, Finale: today's ult rules), debuff choice, enemy brains, the bots' out-of-battle decisions,
Auto for consumables (A4), any content tuning of heal or buff numbers (5c).

## 8. Measurements

2026-11-25/26, The Descent, smart policy, 4 members, `--check`, `game/dev/balance_seeds.json`. "Before" is `main`'s code (the spec
commit) run in a temporary worktree beside the build, so both sides are the same content and seeds. All five constants as proposed;
no constant was changed (D7: nothing measured called for one, see below).

| Run | Won | Cleric | Bard | Mean turns (boss) | Boss fights 50+ turns (lost) |
|---|---|---|---|---|---|
| before, first 100 | 46 | 26/36 | 16/34 | 3.06 | 1 |
| after, first 100 | 48 | 24/36 | 17/34 | 3.13 | 0 |
| before, 600 | 291 (48.50%) | 154/209 | 119/227 | 3.14 (5.48) | 4 (3) |
| **after, 600 (final)** | **296 (49.33%)** | **147/209** | **121/227** | **3.19 (5.45)** | **3 (2)** |

- Seed by seed, after against before: +63 −58, within noise; every other class within a few wins. No stopped run, no script error;
  every battle replayed to its hash. Two code-review rounds changed the code after the first 600 (a refreshed HoT counts only its new
  ticks, the 125% step against every cheaper heal, untargeted rows as Battle applies them, a single-target buff reaches one ally, only
  rows that reach the whole party count for a party buff): 591 of 600 run hashes unchanged, the same 296; the third round's nits left
  all of the first 100 hashes unchanged.
- **One violation in the after runs, none before:** seed 137548, floor 10, the Reflection (`demo.encounter.event_reflection`) hits the
  500-turn cap. Not a heal or buff: the party (Bulwark, Ranger; two dead) has nothing that doesn't feed the mirror's drains, so the
  Ranger Blocks 240 times (the last resort of spec skill-points) and the Bulwark casts Bastion. The run reaches that fight only because
  earlier picks changed. A pre-existing gap in the last resort, outside this spec.
- `autoPicks`, 600 seeds: the **Cleric** heals 602 times (Mass Heal 101, Purify 138, Greater Heal 46, Benediction 34, Heal 18, Miracle 5,
  Potion 248, Holy Water 12; 932 HP of effective healing per heal) and casts Blessed Aegis as a party buff 4,623 times (a 2-turn party
  ward, recast as it lapses), basics 12,113, damage moves 33. The **Bard** heals 2,136 times (Ballad 1,657, Ballad II 443; 1,160 HP per
  heal) and casts party buffs 2,386 times (Grand Anthem 1,783, War Symphony 156, Rousing Anthem 131, Anthem 233). Before, neither Mass
  Heal, Benediction nor Grand Anthem was ever cast (section 1).
- The kits are used as intended; the win rate did not move. The Cleric's free Potion is its most picked heal (it is the cheapest, and a
  costlier heal must reach 125% of it).
