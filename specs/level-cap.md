# Spec: level-cap (the "level 99" slice; before 5c `card-balance`, after `item-power`)

Status: **built and measured 2026-11-24 on `feat/level-cap`, awaiting the user's review and playtest** (spec written 2026-11-22; what the
build decided: section 7, D5-D11). The third of four slices the user asked for on
2026-11-22: `bot-play`, `item-power`, `level-cap` (this; first discussed as "level 99"), `second-pack`. **The cap is 50 and
a typical run ends around level 30** (user, 2026-11-22): players are not meant to reach the cap, but their level must
not stop early. Builds on `specs/playable-demo.md` 3.11 (XP, levels, class growth, `level_effect`),
`specs/skill-points.md` (level skills with ranks and `replaces`, enemy levels by depth, secret skills),
`specs/class-pick.md` (the class card's Learns line).

## 1. Purpose & enterprise mapping

**Purpose.** Today The Descent's XP curve (`runs/descent.tres` `xp_to_level`, 14 thresholds) stops at **level 15**, and
every class's level skills end at **level 9** (passives at 3 and 7, rank II of the innate skill at 5, rank III at 9). Late
in a run levels stop or give nothing new. This slice:
1. **Raises the cap to 50** with an XP curve and income tuned so a **typical smart run ends around level 30** and a strong,
   fully explored one in the mid 30s; 50 is out of reach in one Descent (2.1).
2. **Tapers class growth** so 49 levels of growth do not multiply stats out of range (2.2): today a class's growth
   effect applies once per level above 1, so level 50 would be 49 stacks (+392% ATK on the damage growth).
3. **Adds moves at higher levels** for all eleven classes (2.3): new skills, passives and ranks from level 12 to 50.
4. **Moves enemy levels with depth** so enemy levels (shown, and deciding secret skills) track the party's (2.4).

**Enterprise mapping.** Content and a small run-layer and combat-build change, verified by replay like the rest: the
verifier rebuilds each unit's growth from the snapshot's level, so the new bands are part of the ruleset version. No
wire change (levels and XP are already snapshot integers). The new skills are not cards. Postgres, Redis, RabbitMQ,
Redpanda: not touched. Metrics: none (play-report lines).

**Acceptance scenarios covered:** 5 (a tampered level or XP in a checkpoint snapshot fails its hash and is rejected
2002, as today; a test claims a level the XP does not give).

## 2. Sequence flow

### 2.1 XP curve and income

- `xp_to_level` gets 49 thresholds (levels 2..50). Today's shape is cumulative `15 × k × (k + 3)` for level `k + 1`
  (60, 150, 270, ...). The build keeps a closed formula, `cumulative(k) = a × k × (k + b)`, with whole numbers, written
  out as the 49 integers (the validator's `xp_curve_order` already checks they rise).
- **Income** is set by measurement, not guessed: the build first measures XP earned per floor by the smart bot (with
  `bot-play`'s exploration in), then picks `a`, `b`, `xp_per_enemy` and `xp_per_boss` so the median winning run's end
  level is 30 ± 2 and the 90th percentile at most 38. The report gains `levelByFloor` (median and p10 / p90 party level
  when each floor starts) and `xpByFloor`.
- New optional `RunStructure.xp_per_enemy_level` (default 0 = today): XP per enemy = `xp_per_enemy` +
  `xp_per_enemy_level × enemy level`, so deeper floors (higher enemy levels, 2.4) give more XP without a per-floor table.
- Level 50 is a hard cap: XP past the last threshold is kept in the member's `xp` but gives no level (as today at 15).
- Changing `descent.tres` edits an existing design file: shown `old → new` for the user's OK before the build writes it.

### 2.2 Growth that tapers

Today `Battle` appends the class's `level_effect` once per level above 1 (spec `playable-demo` D28); the effect stacks
(validator `level_not_stacking`). New, on `CharacterDefinition`:

```
growth_bands: Array[GrowthBand]     # GrowthBand {from_level: int, effect: GameplayEffect}; sorted by from_level
```

- For each level above 1, the battle applies the effect of the last band whose `from_level` ≤ that level. With no bands,
  `level_effect` as today (fixtures and goldens unchanged). The applications of one band are one stacking active effect
  (stack count = levels in the band), so a level-50 unit carries three active growth effects, not 49 (hash and replay
  time stay flat).
- Proposed bands for the three growth effects (`growth_damage`, `growth_support`, `growth_tank`), as new effect files
  beside them: levels 2-15 today's effect (unchanged early game), 16-30 about half of it, 31-50 about a quarter. At level
  30 the damage growth is then about +172% ATK instead of +232%, at 50 about +212% instead of +392%. Numbers are tuned
  after measurement; the shape is the decision.
- `sp_gain` and `max_mp` (+7% a level today) follow the same bands.
- Validator: `growth_band_order` (bands not rising), `growth_band_not_stacking`, `growth_band_without_effect`.

### 2.3 Moves from 12 to 50

Every class gets about nine new level-skill rows (`UnitDefinition.level_skills`, `LevelSkill {level, ability,
replaces}`). **The rhythm is similar across classes, not identical** (user, 2026-11-22), and **a good share are passives**,
not only actives: each class gets at least three new passives (or passive ranks) and at least three new actives (or
active ranks) between 12 and 50, placed to fit its style (a support may learn more passives, a damage dealer more
actives). The template below is the starting point each class departs from:

| Level | Row | Kind |
|---|---|---|
| 12 | a new skill | an active move of the class's roles (`bot-play` 2.3 role tags) |
| 15 | the ult, rank II | `replaces` the ult |
| 20 | a new passive | a trigger in the class's style (most use `item-power`'s hooks: an ally hit, a DoT tick, a kill) |
| 25 | the level-12 skill, rank II | `replaces` it |
| 30 | a signature move | the class's strongest active move, the one a typical run ends with |
| 35 | the level-20 passive, rank II | `replaces` it |
| 40 | a second passive | a capstone trigger |
| 45 | the signature move, rank II | `replaces` it |
| 50 | the ult, rank III | `replaces` rank II |

- 99 rows, about 55 new ability scenes (a rank is a copy of its skill with larger numbers and the same animation), each
  with `Ability.Role.*`, `Ability.Usage.*`, an SP cost through the cost pass (`effects/sp_cost_<n>.tres`), an animation
  from the default set and a sound from the bank by the audio pass's rules.
- Made by a builder `game/tools/build_level_pass.tscn` (new files only, never overwrites; `--force` rewrites only its
  own files), run with the user's go-ahead. Adding the rows to the eleven character files edits existing design files:
  shown per class `old → new` for the user's OK.
- The class card's Learns line (spec `class-pick`) shows the next three learns; the `Message.Run.SkillLearned` toast is
  unchanged.
- The build prints each class's list (level, active or passive, what it does) for the user's review before the rows
  are added.
- Validator: the existing `level_skill_*` checks; new `level_skill_gap` (a warning: a class with no row between two
  rows more than 10 levels apart) and `level_effect_ignored` (a warning: a class with growth bands keeps a `level_effect`, which
  then does nothing). `test_demo_level_cap::test_the_new_passives_fire` fires each passive from level 12 on with the battle's
  own payload and checks that it changes the battle (35 passives).

### 2.4 Enemy levels

`scaling/descent.tres` `enemy_level_by_depth` [1, 1, 3, 3, 5, 5, 7, 7, 9, 9] → tracks the measured median party level at
each floor's start (proposed starting point [2, 4, 7, 10, 13, 16, 19, 22, 25, 28], elites +2 as today), shown
`old → new` for the user's OK. Enemy *stats* by depth (`enemy_effects_by_depth`) are not changed here; 5c tunes them
against the new party power. Secret skills (`level_skill_every`, enemy `level_skills`) keep their levels; at the new
enemy levels they appear earlier in the run, which the report's `levelSkills` block shows.

## 3. Data contracts

N/A on the wire: `level` and `xp` are already integers in `RunSnapshot` and the battle snapshot (no version change); the
run hash covers them. New Godot fields: `CharacterDefinition.growth_bands` (`GrowthBand`), `RunStructure.xp_per_enemy_level`.

## 4. Failure modes

- **Old content and goldens:** no bands = today's growth; `xp_per_enemy_level` 0 = today's XP. Every fixture and golden
  replays unchanged (a test says so).
- **Determinism:** bands are applied in level order with integer stack counts; no float curves (GAS `scaling_curve` is
  not used, its float sampling could differ by platform).
- **Tampering:** a checkpoint claiming a level its XP does not give fails the run hash and is rejected 2002 (a tampered
  copy in `test_step_runner`).
- **Overflow:** at level 50 with every band the largest attribute stays far below the ×100 integer range (a test builds
  a level-50 unit with the strongest growth and the item-power stat items and checks every attribute).

## 5. Observability

N/A for Prometheus. The play report adds `levelByFloor`, `xpByFloor` and the end-level spread it already has
(`endEntry.level`).

## 6. Test plan

On fixtures (`tests/fixtures/`, a fixture class with two growth bands and level skills past 12):
- Bands: a level-20 unit gets band 1 for levels 2-15 and band 2 for 16-20, as two active effects with stack counts 14
  and 5; no bands = `level_effect` once per level (existing tests unchanged).
- XP: the 49-threshold curve levels up to 50 and stops; `xp_per_enemy_level` adds per enemy level; 0 = today.
- Level skills: rows at 12-50 granted at their level, `replaces` supersedes the rank, the class card's Learns line.
- Overflow at level 50; the tampered-level step.
- Content: the validator passes on the demo with the new rows and bands; `test_content_valid`.
- Measurement (section 8): the median end level 30 ± 2, p90 ≤ 38, on the smart 4-member report with `bot-play` and
  `item-power` in.

## 7. Decisions, open questions, what stays out

**Decisions (user, 2026-11-22):**
- D1. Cap 50; a typical run ends around 30; the cap is not meant to be reached in one Descent.
- D2. More moves at higher levels for every class.

- D3. The rhythm is similar, not identical, per class; passives are part of it (at least three per class from 12 to 50).

- D4. New moves continue all the way to 50 (rows at 35-50 kept), though 31-50 are rare in a run.

**Decisions of the build (the user's OK 2026-11-24 for the content):**
- D5. The curve is `15 × k × (k + 3)` for all 49 thresholds, so the first 14 are unchanged. Free levels (the waystation's training)
  raise XP to the next threshold, so a steeper curve hardly changes the end level; the income (22 XP per enemy + 1 per enemy level) does.
- D6. `xp_per_enemy_level` counts for bosses too (added to `xp_per_boss`).
- D7. Each band is one INFINITE, REFRESH_DURATION effect without a stack limit, so the first band is a new file with today's numbers
  (`growth_<kind>_1`); `growth_damage`, `growth_support` and `growth_tank` are no longer used by anything and are kept, not deleted.
  A band's stacks are applied in one step (`CombatASC.apply_stacks`).
- D8. Ten rows per class (110), not about nine. Signature moves come at 28-29 instead of 30 (the median party starts floor 10 at level
  28), and cost about 15% less SP than first proposed.
- D9. An ult's ranks keep its signature effect and cue; `test_vfx_content` checks a rank against its base.
- D10. Enemy levels [1, 5, 8, 11, 14, 17, 20, 23, 25, 28] (2.4): the measured median party level at each floor's start.
- D11. A level above 99 in a forged snapshot grows nothing more (`CharacterDefinition.MAX_LEVEL`): the step fails its hash instead of looping.

- D12. An ult rank keeps the place of the ult it replaced (`BattleUnit.ultimate_abilities`), so the chooser and Auto see one order at every
  level. Other ranks stay appended in grant order: changing that would change Auto's heals (Q1).
- D13. Undying Faith shares the once-per-battle save with the Undying Ember (`State.DeathSaved`) and fires first; it gives the same 50% HP
  (Regen instead of the Ember's +50% ATK).

**Open questions:**
- Q1 (the user, 2026-11-24: later). Auto takes the first heal in grant order and casts buffs only at full SP, so in 24 logged runs it never used Mass Heal,
  Grand Anthem or Benediction. It was so before this slice; the gate understates the Cleric and the Bard.
- Q2 (for 5c). The Coven route is now easy (206 of 251 runs won), the Collector still decides the other (93 of 235).
- Q3 (for 5c). Enemies rarely use their secret skills (Swarm, Tremor and Hex All never in 600 runs): battles end before their turn comes.

**Stays out:** enemy stat scaling (5c), new characters (`second-pack`: they get the same rhythm), new items.

## 8. Measurements

2026-11-24, The Descent, smart policy, 4 members, `--check` (every battle replayed), 12 shards, `game/dev/balance_seeds.json`. The baseline
is item-power's 128 of 600 and 19 of the first 100 (spec `item-power` section 8). Level-cap's system code alone, with the content unchanged,
reproduced all 100 of those run hashes.

| Run | Won | Winners' end level (p10 / median / p90) |
|---|---|---|
| before, first 100 seeds | 19 | 15 / 15 / 15 (the cap) |
| before, 600 seeds | 128 (21.33%) | 15 |
| first proposal (2 XP per enemy level), first 100 | 50 | 31 / 33 / 36 |
| `17k(k+1)` curve, first 100 | 55 | 29 / 33 / 34 |
| 1 XP per enemy level, 20 per enemy, signatures at 30, first 100 | 41 | 26 / 29 / 31 |
| 22 per enemy, signatures at 28, first 100 | 46 | 27 / 29 / 31 |
| 20 per enemy, signatures at 28, first 100 | 34 | 27 / 29 / 31 |
| **22 per enemy, signatures 15% cheaper, first 100** | 48 | 28 / 30 / 32 |
| **the same, 600 seeds (final)** | **299 (49.83%)** | **28 / 30 / 31, max 34** |

- Final against the 128, seed by seed: +183 −12 (the two-sided sign test is far below 0.001). No stopped run, script error or violation, every
  battle replayed to its hash. 61,710 battles (58,313 before), 634 s. The target (playable-demo D25: 35-55%) and the level target (30 ± 2,
  p90 ≤ 38) are met. The rows on 100 seeds differ by noise too; only the 600 counts.
- After the 600, the second review round gave ult ranks the place of the ult they replace (D12) and Undying Faith 50% HP (D13): **46 of the
  first 100 seeds** (48 before, +0 −2: within noise), no violation. The 600 was not rerun (a small tweak).
- Party level at each floor's start, p10 / median / p90: 1, 5/5/6, 7/8/9, 10/11/12, 13/14/15, 16/17/18, 19/20/21, 21/23/24, 23/25/27, 25/28/29.
- XP won in battles per floor, median: 374, 530, 790, 993, 1230, 1514, 1196, 1411, 1416, 2004 (before: about 420, 630, 720, 690, 810, 860,
  660, 660, 640, 940, counted with free levels).
- Losses by floor (of the runs that entered it): 2: 18/600, 3: 9/582, 4: 2, 5: 40/571, 6: 36/531, 7: 3, 8: 6, 9: 2, 10: 185/484. The Collector
  139 of 232 battles lost, the Nameless 26 of 232.
- Wins by class (before → after): Cleric 77 → 150 of 209, Bard 50 → 124 of 227, Ranger 51 → 121 of 222, Warrior 42 → 111 of 213, Pyromancer
  48 → 113 of 242, Shatterweaver 41 → 111 of 231, Cryomancer 37 → 97 of 230, Bulwark 46 → 94 of 212, Arcanist 45 → 93 of 211, Plaguewright
  30 → 91 of 203, Ember Knight 45 → 91 of 200.
