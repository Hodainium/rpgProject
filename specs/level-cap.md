# Spec: level-cap (the "level 99" slice; before 5c `card-balance`, after `item-power`)

Status: **spec written 2026-11-22, awaiting the user's review.** The third of four slices the user asked for on
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
  rows more than 10 levels apart).

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

**Open questions:**
- D3. The rhythm is similar, not identical, per class; passives are part of it (at least three per class from 12 to 50).

- D4. New moves continue all the way to 50 (rows at 35-50 kept), though 31-50 are rare in a run.

**Open questions:** none.

**Stays out:** enemy stat scaling (5c), new characters (`second-pack`: they get the same rhythm), new items.

## 8. Measurements

To be filled by the build: XP per floor today, the chosen curve and income, `levelByFloor`, the end-level spread.
