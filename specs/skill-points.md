# Spec: skill-points (slice 1f3)

Status: ✅ Done 2026-10-27 (synced to the build; every decision answered, section 7; the balance rounds in 4.5:
the smart 4-member gate on the 600 balance seeds wins 31.8%, sound parties 38.9%, about 3 basics per costed ability,
0 turn limits) · Date: 2026-10-27 ·
Roadmap: slice 1f3, after 1f2 `keys-and-gear` (done) and before 2 `run-checkout`.
Builds on `specs/playable-demo.md` (classes 3.10, class growth 3.11, the play report and its smart 4-member gate, the
H9/H10 mirror), `specs/content-pass.md` H4 (`Event.Ability.Used.<Type>`), `specs/auto-battle.md` (`AutoPolicy`, the
role pass this slice copies for costs), `specs/keys-and-gear.md` (bots wearing gear, the last balance numbers).

## 1. Purpose & enterprise mapping
A game design pass on systems that already exist. MP becomes **Skill Points**, as in Honkai: Star Rail, but on
today's per-character numeric scale, with Persona as the reference for the numbers.

**Today (measured in `content/demo/`):**
- **Pools:** per character, 60 (Warrior, Bulwark) to 140 (Arcanist). They carry over between battles
  (`carry.mp` in the battle snapshot), so MP is a run-long budget, Persona-style.
- **Refills:** in battle, only Spellweave (+6 on a kill, Arcanist) and Scholar's Tome (+5 on a weakness hit). Between
  battles: Ether (+60, reusable after 3 won battles), Honey Cake (40% of max), Waystation (50%) and the rest event.
- **Costs:** five shared cost effects (`mp_cost_10/15/20/heal/ice`, 10 to 25 MP). A basic attack is free and gives
  nothing back. Provoke and Fyrefly Strike are free non-basic moves.
- **Bots:** `AutoPolicy` holds costed moves while MP is under 30% (`MP_RESERVE`); heals and cleanses are excepted.

**After this slice:**
- **Basic attacks give SP back:** every `Ability.Type.Basic` use restores SP. The gain grows with level, through the
  class growth that already exists (`CharacterDefinition.level_effect`).
- **The rhythm is "attack, attack, ability":** a normal ability costs about 2–3 basics' worth of SP, and a few cheap
  ones cost about one basic's worth. Costs and the SP items are retuned to that economy.
- **New items:** a few items raise SP gain (strongest early, before levels carry it), and a few lower ability costs
  (proposals in D8).
- **Bots learn the rhythm:** they build SP with basic attacks, spend it when an ability is worth it, and keep enough
  for a heal or revive when the party is in danger. Chaos keeps trying moves it can't afford.
- **The turn limit drops from 1000 to 500, and hitting it is a loss** (D15).
- **Where runs end is mapped before any balance decision** (D16): by floor, chapter, route and encounter, to see
  whether the losses pile up at one point.
- **The Collector is measured, then tuned:** win rate by items held on the light route, the crossing point, and a fix
  for the two turn-limit battles (section 4.4, D13 and D14).
- **Skills learned by level** (D17–D20): a unit definition maps levels to abilities, and reaching a level grants its
  ability.
  - **Characters:** this is where learnable skills live from now on. Today `learnable_skills` is only a list a
    loadout may draw from at run start; nothing teaches a skill during a run.
  - **Enemies:** an enemy gets a level from the floor's depth and its variant. Some enemies have secret skills that
    exist only when they spawn at a higher level.
  - **Cost:** learned skills are the "unlocked" tier of D5, so they cost the most SP.

**Approach (GAS-first, data-driven):**
- **New attributes:** the `Unit` AttributeSet gains three:
  - `sp_basic`: flat SP per basic attack, a per-class stat in `stats_x100` (odd numbers, D4).
  - `sp_gain`: a multiplier at 100% by default, raised by levels and items.
  - `sp_cost`: a multiplier at 100% by default, lowered by items.
- **SP gain:** a triggered passive like `ult_charge`. Each class gets `sp_gain.tscn`, which fires on
  `Event.Ability.Used.Basic` (the event already exists, content-pass H4). It restores `mp` through `ExecCalcRestore`,
  which gains one option, `amount_attribute`: the amount is read from the unit's `sp_basic` instead of being fixed.
  The result is `sp_basic × sp_gain`, truncated to a whole SP, so the player never sees a fraction.
- **Costs:** the cost effects become one small ExecCalc, `ExecCalcCost`: `mp −= amount × source.sp_cost`, truncated
  to a whole SP. GodotGAS' `can_afford_cost` already evaluates ExecCalcs, so an unaffordable move is still refused by
  GAS, with no new rule.
- **Level scaling:** `sp_gain` and `max_mp` +7% per level (PERCENT_ADD), added to the three shared growth effects.
- **Items:** plain effects on these attributes, plus one passive pattern that is already used (a triggered restore).
- **No code per item or ability.** System code changes only in the places listed in 3.2.

**What the name means:** the attribute stays `mp`. Renaming it would touch every fixture, snapshot and hash for no
gain. Only the label the player sees changes (D10).

**Enterprise mapping:** none yet. This is client-only: battle rules and content in `client-godot/`. No service, queue,
broker, cache or wire contract is touched. What it changes for the distributed system later:
- **`ruleset_version` (slice 2):** the content hash changes. That is expected for any design pass.
- **Battle verifier (slice 3):** SP gain and costs are ordinary GAS effects inside the deterministic kernel, so the
  verifier replays them with no new rule. The battle snapshot already carries `mp`.
- **Analytics (later):** "most used moves" will show the basic/ability split. The play report's new `sp` block
  (section 5) is the dev preview of that.

Out of scope:
- **A shared party pool** (HSR's real model), unless D1 picks it.
- **Enemy SP:** enemy kits have no costed moves, so they never get the passive.
- **New classes:** none.
- **New abilities:** only those for the level-skill tables (D20), proposed and approved before any is written.
- **Skill slots or forgetting skills:** a learned skill is simply kept; the kit has no size limit today.
- **Teaching skills from events:** an outcome like `LearnSkill` could reuse `learnable_skills` later.
- **Server work.**

## 2. Sequence flow
Client only. No ASP.NET Core endpoint, store or broker is involved.

**A basic attack in battle (fixed-point, deterministic):**
1. `Battle._activate` calls `try_activate`. A basic has no cost effect, so GAS lets it through.
2. On success, `Battle` already sends `Event.Ability.Used` and `Event.Ability.Used.Basic` (H4) to the actor.
3. The actor's `sp_gain` passive fires on `Event.Ability.Used.Basic` and applies `sp_gain.tres`: `ExecCalcRestore`
   with `attribute "mp"`, `amount_attribute "sp_basic"`, `target_bonus "sp_gain"`, `whole true`. For example, a
   level-8 Warrior gains 17 × 149% = 25.33, shown as 25. The `mp` clamp to `max_mp` already exists.
4. Its `ult_charge` passive fires as today (on `Event.Ability.Used`).
5. The state hash sees `mp` and the new `sp_basic`/`sp_gain`/`sp_cost` attributes like every other attribute.

**The turn limit (D15):** when `turn` reaches 500 with no outcome, the battle ends as `TurnLimit`, which counts as a
defeat. The run ends as on a lost battle, and the battle screen shows it as a defeat ("Out of time").

**A costed ability:**
1. `CombatASC.can_activate_ability` → GodotGAS `can_afford_cost`, which evaluates `ExecCalcCost` on a mock spec:
   `mp − amount × sp_cost ≥ 0`, or the move is refused (`INSUFFICIENT_RESOURCES`, as today).
2. On activation, the same ExecCalc subtracts the scaled cost.
3. `AbilityHint.cost_text` shows the scaled cost for that unit ("SP 20").

**Between battles:** `mp` carries over exactly as today (D2), and level-ups rebuild growth from the snapshot's level
(playable-demo 3.11), which now also raises `sp_gain` (and `max_mp`, per D4).

**Learning a skill by level (D17–D19):**
1. **Characters:** `RunController` awards XP after a won battle and raises the level as today (`GainLevel`). For each
   `LevelSkill` whose `level` the member just reached, it broadcasts `Message.Run.SkillLearned` (unit, ability) for
   the toast and the battle feed. Nothing is logged: the skill follows from the level, which is already in the run
   state and the hash.
2. **Battle build, party:** `Battle._party_kit` grants every `level_skills` ability with `level ≤ member.level`, from
   the snapshot's `level`, the same way 3.11 rebuilds growth. The battle snapshot needs no new field.
3. **Battle build, enemies:**
   - **The enemy's level** is `ScalingRules.level_for_depth(depth)` (from the snapshot's `scalingId` and `depth`)
     plus `EnemyVariant.level_bonus` (for example Elite +2) plus `EncounterSlot.level_bonus`. It becomes the
     enemy's real `BattleUnit.level` (D21).
   - **Its skills:** every `level_skills` ability with `level ≤` that enemy level is granted, rebuilt from content by
     encounter id like the encounter grants (playable-demo 3.7). The snapshot needs no new field.
   - **Same value on replay:** the level follows from the snapshot and content, so the verifier derives it too. It is
     hashed through the read-only `level` attribute (D22) on units whose AttributeSet has one.
   - **No effect-level change:** an enemy's GAS level (`effect_level`) stays 1 (D21), so the levels of its abilities
     and effects, and every number they scale, are unchanged.
   - **Stats:** an enemy's level only unlocks skills. Its stats still come from the depth scaling effect, so floors
     don't get stronger twice.
4. **The `level` attribute (D22):** `BattleUnit.create` writes `BattleUnit.level` × 100 into the unit's `level`
   attribute, as base and current value, before any effect is applied. From then on the AttributeSet refuses every
   change.
5. **Brains:** `PatternBrain` already falls back to the default choice when a step names an ability the unit lacks.
   A pattern can therefore name a secret skill: below its level the step just becomes a normal action.
   `TacticalBrain` picks from whatever abilities the unit has.

**Bots (3.4):** `AutoPolicy.choose` asks "is this ability worth its SP, given the reserve?" before it compares
abilities against the basic. The play report's smart policy is the same code.

## 3. Data contracts
**C# DTOs: none.** `BattleSnapshot` v2 already carries `mp` per member, and the `ActionLog` v2 entry shape does not
change. No RabbitMQ queue, Redpanda topic or Redis key. The C# golden cross-check (`Rpg.Contracts.Tests`) must still
pass; it reads the committed Godot goldens, which keep their shape.

The client-side contracts this slice adds:

### 3.1 GAS resources (the user's folders; each with approval, D-numbers)
| What | Where | Content |
|---|---|---|
| Attributes `sp_basic`, `sp_gain`, `sp_cost` | `godot_gas/attributes_draft.cfg` → regenerated `UnitAttributeSet` (dashboard Generate) | `sp_basic` default 0; `sp_gain`, `sp_cost` default 10000 (100%); clamps ≥ 0 in `DemoUnitAttributes.pre_attribute_change` |
| `sp_basic` per class | `content/demo/characters/*.tres` `stats_x100` | the D4 values (×100: 17 → 1700) |
| Tag `Event.Ability.Used.Basic` | `godot_gas/tag_registry.tres` (checked by `sync_tags.tscn`) | sent already; registered so a trigger can match it |
| `sp_gain.tscn` (passive) | `content/demo/abilities/` | `trigger_event_tag = Event.Ability.Used.Basic`, `targeting` self, one row: `sp_gain.tres` |
| `sp_gain.tres` | `content/demo/effects/` | `ExecCalcRestore`: `mp`, `amount_attribute "sp_basic"`, `target_bonus "sp_gain"`, `whole true` |
| `exec_calc_restore.gd` | `content/demo/exec_calcs/` | two new options: `amount_attribute` (read the amount from the target's attribute; "" = `amount` as today) and `whole` (truncate the result to a whole number, a multiple of 100 ×100). Defaults keep every existing effect identical. |
| `exec_calc_cost.gd` | `content/demo/exec_calcs/` | `ExecCalcCost`: `attribute`, `amount_x100`, `source_bonus "sp_cost"`; returns `{attribute: −whole(Fixed.pct(amount, sp_cost))}`, truncated, never below 0 |
| Cost effects `sp_cost_<n>.tres`, one per distinct D5 amount (shared when equal) | `content/demo/effects/` | `ExecCalcCost` at the D5 amounts; they replace `mp_cost_10/15/20/heal/ice` |
| Growth | `effects/growth_damage/support/tank.tres` | + `sp_gain` PERCENT_ADD 7% per level, + `max_mp` PERCENT_ADD 7% per level (D4) |
| Items | `content/demo/items/`, `equipment/`, `effects/` | D8 (new) and D9 (retuned) |

### 3.1b Level skills (system types; content filled with approval)
| Type or field | Where | Content |
|---|---|---|
| `LevelSkill` (new Resource) | `combat/level_skill.gd` | `level: int` (2 or more), `ability: PackedScene` |
| `UnitDefinition.level_skills: Array[LevelSkill]` | `combat/unit_definition.gd` | on the base type, so characters and enemies share it; empty by default |
| `ScalingRules.enemy_level_by_depth: Array[int]` | `game/defs/scaling_rules.gd` | index = floor depth; past the end, the last value; empty = level 1 everywhere |
| `EnemyVariant.level_bonus: int` | `combat/enemy_variant.gd` | default 0 |
| `EncounterSlot.level_bonus: int` | `combat/encounter_slot.gd` | default 0 |
| `CharacterDefinition.learnable_skills` | unchanged | still the list a loadout may give at run start; a level skill counts as learnable for the loadout check |
| `BattleUnit.level`, `BattleUnit.effect_level` | `combat/battle_unit.gd` | `level`: the unit's real level (party: the snapshot's; enemies: D19). `effect_level`: the GAS ability and effect level (party: = `level`, as today; enemies: 1, as today) |
| Attribute `level` (read-only) | `godot_gas/attributes_draft.cfg` → regenerated `UnitAttributeSet` (approval) | default 100 (level 1, ×100); written once by `BattleUnit.create`; `DemoUnitAttributes.pre_attribute_change("level", …)` returns the current value once the unit is built, so no effect can change it |
| `Message.Run.SkillLearned` | `godot_gas/tag_registry.tres` (approval) | payload: slot, character, ability tag, level |

The defaults (empty tables, level 1, bonus 0) leave every existing unit, fixture and golden exactly as today. The
fixtures' frozen AttributeSets have no `level` attribute, so their hashes don't change. The new
`FixtureSpAttributeSet` has one, so `sp-seed-<n>` covers it.

### 3.2 System code (`combat/`, `game/`; no per-item code)
- **`Battle`:**
  - `_party_kit` grants the level skills reached, from the snapshot's level.
  - The enemy kit grants the skills reached at the enemy's derived level.
  - **One level concept (D21):** `BattleUnit.level` is the real level for both sides. `effect_level` keeps
    today's GAS levels (party = level, enemies 1), so no existing number moves. `Battle._add_unit` takes both.
    Every place that uses `BattleUnit.level` as a GAS level switches to `effect_level`: the grant at build, later
    grants (`battle_unit.gd:157`) and later effect applications (`:170`). A test pins that enemy ability and effect
    levels stay 1.
  - **The `level` attribute (D22):** written at build and read-only afterwards. ExecCalcs and activation queries
    may read it, like any attribute.
- **`RunController`:** on a level-up, broadcasts `Message.Run.SkillLearned` for each newly reached skill. No log
  entry; the run hash already has the level.
- **UI (as built, the user's call):**
  - **Status screen:** no separate list. `RunController.member_kit` also lists level skills not reached yet, with
    `unlock_level`, and the abilities list shows them dimmed with "Unlocked at level X." after the description.
    Class details add "(Lv X)" next to those skills.
  - **Toast:** a "NEW SKILL" rule for `Message.Run.SkillLearned` in `run_toasts.tres` (`UIToastRule.KNOWN_FIELDS`
    gains `skillName`, `skillTag`, `replacesTag`). No battle-feed line: skills are learned between battles.
  - **SP bar preview:** the battle hint carries `unit` and `spCost`; the party window shows what a hovered ability
    would leave on that member's SP bar, with the spent part highlighted (`member_row` `mp_preview`).
- **Console:** `status <unit>` shows each unit's level and, for party units, SP, SP per basic, SP gain and cost %.
  `skills [slot]` lists learned and upcoming level skills. `battlelog on|off` (below). The `xp` cheat reaches a level.
  `dev_run`'s JSON party `stats` carry `sp_basic`, `sp_gain`, `sp_cost` and `level` (`RunController.unit_stats`).
- **`CostReader`** (`combat/cost_reader.gd`): an ability's cost for a unit, from negative modifiers and every cost
  ExecCalc that offers `cost_of(caster)` (`ExecCalcCost` and its fixture copy). The hint, the bots and the report read
  costs through it.
- **`AbilityHint.cost_text(ability, unit = null)`:** through `CostReader`; with a unit, the cost scaled by its
  `sp_cost`. The label text follows D10.
- **`BattleLog`** (`combat/battle_log.gd`, added while hunting a hang): an optional, read-only log, one line per action
  and target (refused marked), triggered passive and its event, skipped turn, overtime, Auto pick with its reason
  (`AutoPolicy.last_reason`) and outcome. Off by default; on with `RPG_BATTLE_LOG=1` (every tool), `seed_report
  --battle-log` or `battlelog on`. A headless Auto with no move always warns (it once hung a play report).
- **Soft enrage** (added after the stall traces): `EnemyDefinition.overtime_turn`, `overtime_effect` (on the enemy)
  and `overtime_party_effect` (on every living party unit), applied at each of the enemy's turn starts from that
  battle turn; all off by default. Validator `overtime_not_stacking`.
- **`EnemyBrain.level_skill_every`** (0 = off): on those battle turns a brain uses a level skill the unit has reached.
- **Options built off by default:** `RunStructure.sp_start_min` (D2's fallback: a carried SP below that share of max SP
  starts the battle at it, applied to the battle snapshot) and `EnemyDefinition.mirror_limit` (D13 (b): copy only the
  first N pieces held, party slot order, and count no more for `per_item_effect`).
- **Tools:** `seed_report --set` reaches nested values (`executions/0/amount_x100`); the role, usage and cost passes
  also scan level skills (`RolePass.party_scenes`).
- **`ContentValidator`:**
  - **Level skills:**
    - `level_skill_bad_level` (error): a level under 2, or above the run's max level for a character (silently
      unreachable).
    - `level_skill_duplicate` (error): a level skill that is also in `abilities`, or listed twice.
    - `level_skill_triggered_ult` (error): the existing ult rules, applied to these scenes too.
    - `level_skill_tags`: the usual role and usage checks on these scenes.
    - `secret_skill_unreachable` (warning): an enemy skill whose level no depth, variant or slot can reach on any run
      that uses the enemy.
  - `level_attribute_modified` (error): an effect modifier or ExecCalc output targets the `level` attribute. The
    AttributeSet would refuse the change in battle anyway; the validator catches it at edit time.
  - `sp_gain_missing` (warning): a character with a Basic ability and a costed ability but no `sp_gain` passive.
  - `cost_unscaled` (warning): a party ability costs `mp` through a plain modifier, so `sp_cost` items skip it.
  - `basic_costed` (error): an `Ability.Type.Basic` ability has an `mp` cost.
- **`AutoPolicy`:** the rhythm rules (3.4).
- **`ScriptedController` ("auto" policy) and `ChaosController`:** 3.4.
- **Play report:** the `sp` block, the `held` counts and the death map (section 5, D16).
- **Turn limit (D15):**
  - **`Battle`:** `TURN_LIMIT` goes from 1000 to 500. The outcome string stays `"TurnLimit"`, which the wire enum
    `BattleOutcome.TurnLimit` already has, so no contract changes.
  - **Run:** `RunController` and `GameMain` treat `TurnLimit` exactly like `Defeat`: the run is lost.
  - **Replay:** `ReplayRunner` verifies a `TurnLimit` battle (`Verified`, outcome `TurnLimit`) instead of rejecting
    it. `MismatchReason.TurnLimitExceeded` stays on the wire, now for a log that still has party entries after the
    battle ended at the cap (tampering).
  - **Dev checks:** the `InvariantChecker` still reports a turn-limit battle as the `turn_limit` violation (user,
    2026-10-27): a stall usually means a broken item or interaction. The player just loses; the report also counts
    these battles under `turnLimits`.
  - **Analytics (later):** a `TurnLimit` outcome reaches the player analytics as its own outcome (the battle event's
    `outcome`), so production stalls can be found too.
  - **Spec sync:** `combat-replay-core.md` is synced at `/sync-spec`.
- **Tool:** `game/tools/build_cost_pass.tscn`, the same shape as `build_role_pass`. It proposes each party ability's
  tier from the D5 table (by role, targeting and current cost) and prints the table. `--apply` writes only the
  abilities the user has approved, and never touches a file that already has a tier effect.
- **If needed (risk):** if `can_afford_cost`'s mock spec doesn't resolve the source unit for `ExecCalcCost`, then
  `CombatASC` overrides `can_afford_cost` to pass itself as the source. That is a marked subclass override, not an
  addon patch (GodotGAS extension policy).

### 3.3 Test fixtures (frozen; builders only add missing files)
- **`FixtureSpAttributeSet`:** `FixtureStatusAttributeSet` plus `sp_gain` and `sp_cost`.
- **A "drummer" unit:** a Basic-tagged jab, a costed burst through `ExecCalcCost`, and the `sp_gain` passive, with
  fixture effects at round numbers.
- **The "sp trial" encounter.**
- **Untouched:** older fixture units keep their sets, so their goldens never change (the project's fixture rule).

### 3.4 Bot rules
Each rule is deterministic and RNG-free, and reads only `Ability.Type.*`, `Ability.Role.*` and costs (no ids).

**`AutoPolicy` (the player's Auto, and the smart policy).** Today's order stays: ult, revive, heal, cleanse, best
score, buff, first legal. Inside it:
- **Danger reserve:** a unit that has a Revive- or Heal-role ability keeps SP for its cheapest one while the party is
  in danger: any ally dead, under `HEAL_BELOW` (45%), or under `DANGER_BELOW` (60%) during a boss fight. Such a unit
  never spends SP on another move if that would leave it under the reserve.
- **Value per SP:** a costed damage, debuff or buff move is picked over the unit's basic only when its score is at
  least `SPEND_RATIO` (150%) of the basic's best score on any target, and SP stays at or above the reserve.
- **No waste at the cap:** when one more basic would overflow `max_mp`, the best costed move is picked with no
  `SPEND_RATIO` (its score must still be above 0).
- **Gating, so fixtures don't move:** these rules apply only to a unit that has an `Ability.Type.Basic` ability. A unit
  without one keeps today's `MP_RESERVE` rule. No fixture ability is Basic-tagged today, so `auto-seed-4` and the
  smart/chaos runs on fixtures are unchanged (D12).

**Also built in `AutoPolicy`:**
- **No waste at the cap:** a buff an ally lacks (within the reserve) goes before a basic that would overflow SP.
- **Never feed a drain:** when nothing scores, the last resort skips a move every target of which drains it, then
  Blocks, then takes the first legal move. It always returns a move (an empty pick waits for a player that a
  headless run never has).

**"auto" (`ScriptedController`, first legal):** it stays the dumb baseline, with one change: a costed move is skipped
when it would take SP under the danger reserve and the unit has a Basic ability. Without that, "auto" spends a
healer's SP on its first costed move and the report measures nothing useful (D11).

**Chaos (`ChaosController`):**
- **Unaffordable moves stay on its illegal list.** Its existing `unaffordable` case (any move that can't activate)
  already covers SP costs; no new code, pinned by a test.
- **Counted:** refusals are counted as `refused.insufficient_resources` in the report, as today.
- **Legal decisions** are uniform as today, so chaos still wastes SP freely.

## 4. Failure modes
### 4.1 Game rules
- **SP at the cap:** a basic at full SP restores nothing; the existing clamp holds. Bots avoid it (3.4).
- **Basic used while controlled:** `State.Controlled` skips the turn (nothing logged), so no SP is gained.
- **One More / extra turn:** an extra action that is a basic gains SP like any other basic.
  Follow-ups (`Ability.Type.FollowUp`) and ults never gain SP.
- **A basic that misses or is drained:** SP is gained on use, not on hit (HSR rule).
- **Item-granted basics:** none exist. If one did, it would gain SP, because the passive reads the type tag.
- **Whole numbers:** gains and scaled costs truncate to a whole SP, so the player never sees a fraction. Gains round
  down; costs round down in the player's favour, so 37 × 79% = 29.23 costs 29.
- **Cost reductions:** `sp_cost` never goes below 0%. A 0% `sp_cost` makes every ability free; no item goes below
  50% (D7).
- **Pools at higher levels:** `max_mp` grows +7% per level and the shown pool is whole (60 × 149% = 89.4, shown 89).
  A level-up during a run raises the pool, not the current SP; carry-over clamps to the new max as today.
- **Field mode:** `Battle.field_mode` sends no `Event.Ability.Used`, so using Heal on the map gains nothing, and its
  cost is scaled by `sp_cost` the same way.
- **Mirror:** the Collector mirrors SP items like any other passive, but it has no costed moves and no Basic-tagged
  ability, so they do nothing for it. That asymmetry is on purpose (D13 a).
- **Level skills:**
  - **Learned between battles:** a level-up happens after a won battle, so a skill is first usable in the next
    battle. A battle never changes its kit midway.
  - **Several levels at once:** a level jump (the `xp` cheat, a big boss reward) grants every skill reached, with one
    message each.
  - **A skill already given by a loadout:** if a loadout also gives a level skill, it is granted once. The validator
    warns about it (`level_skill_duplicate`).
  - **Enemy below the level:** the secret skill doesn't exist on that enemy. A pattern step naming it falls back to
    the default choice; the step still counts, as built.
  - **Replay:** the verifier derives the same skills from the snapshot's party levels and from content plus depth for
    enemies. A log that uses a skill the unit hasn't reached is rejected with 2002 `IllegalAbility`, through the
    existing check that a battle only accepts abilities the unit has.

### 4.2 Goldens: what changes, on purpose, and why
Expected, to be confirmed with the real diff at `/implement` (the implementation report lists every changed file):

| Golden | Expected | Why |
|---|---|---|
| Combat goldens (`duel`, `squad`, `run-v2`, `break`, `ult`, `status`, `boss`, `mirror`, `auto-seed-4`) with their `.trace.json` and the six tampered copies | **unchanged** | fixtures use frozen AttributeSets and fixture abilities; no fixture ability is Basic-tagged, so neither the passive nor the `AutoPolicy` rhythm reaches them (D12). If D12 is declined, `auto-seed-4`, its trace and `auto-seed-4-tampered-drop` are regenerated. |
| `hash-v1-sample` | unchanged | the hash format doesn't change |
| Level skills | no system golden changes | the new tables default to empty, so every fixture is unchanged. The drummer fixture gets one level-3 skill and the sp trial one enemy with a secret skill at level 2 with a slot `level_bonus`, so `sp-seed-<n>` covers both. A new tampered copy, `sp-seed-<n>-tampered-unlearned`, uses the skill at level 2 and must be rejected with 2002 `IllegalAbility`. |
| Demo runs | change | Warrior's Ice Blast moves from his loadout to his level table (D20), so demo run states and run hashes change. No golden pins a demo run. |
| Turn limit (D15) | no golden changes | no golden battle reaches 500 turns. `test_replay`'s "nobody can deal damage" case changes on purpose: it stops at 500 and is now `Verified` with outcome `TurnLimit`. A new test rejects a log that continues past the cap with `TurnLimitExceeded`. |
| **New:** `sp-seed-<n>` (+ `.trace.json`, `.result.json`) and `sp-seed-<n>-tampered-cost` (a cost the unit can't afford, so 2002 `IllegalAbility`) | added | proves SP gain, scaled costs and the refusal on replay |
| `golden/game/run_scripted.json`, `run_keyed.json`, `seed_report.json`, floors, seed codes, sandbox | **unchanged** | all run on the fixture world, which has no SP content; bots are gated by D12 |
| `golden/game/seed_report_play.json` | **regenerated on purpose** | the report gained keys (`seedSet`, `analysis`, `sp`, `levelSkills`, `secretSkills`, `bossEntrySpPercent`); its runs and hashes are unchanged |
| Demo-content tests (smoke, item, ult, content-pass tests, content validator over `content/`) | assertions on MP numbers updated | the demo is the only content that changes |
| C# cross-check | passes; `GoldenSet_IsComplete` counts 18 goldens (was 15) | the three `sp-seed-13` files |

**Why so few:** the project freezes fixtures on purpose, so a content pass never moves system goldens. If you want the
scripted runs to show SP too, the alternative is a new fixture run with SP, not a rebuilt old one (D12).

### 4.3 The death map first (D16; nothing is tuned before you see it)
Before any balance decision, a smart 4-member gate run (seeds 1–300) on today's content plus the D15 turn limit
answers one question: do runs end at one specific point?
- **Losses by floor and chapter**, including the floor-8 route split (light: Silent Cathedral → Vault; dark: Black
  Coven → Void).
- **Losses by encounter**, ranked, with each encounter's share of all losses, separately for bosses and regular
  fights.
- **Losses per attempt at that point:** losses / battles fought there. A boss that kills 75 of the 200 losing runs
  may still be beaten most of the times it is reached.
- **Concentration:** the top encounter's share of all losses and the top three's, plus the floor with the biggest
  drop in survivors.
- **How the party arrived:** median HP% and SP% entering the battle that ended the run, and levels.
- **Turn-limit losses**, by encounter.

The same map is printed again after the SP change, side by side. Balance changes are proposed only from these two
maps.

### 4.4 The Collector (measure first; nothing changes before D13 and D14)
**Measure** (dev tool only):
- Each battle in the play report records `held`: the items held plus armor pieces worn by the party when the battle
  starts. That is the same count the mirror's per-item effect uses (`mirror["count"]`).
- The report gains `winByHeld`, filtered by encounter: battles and wins per `held` bucket, for example
  `--by-held demo.encounter.collector`.
- **Crossing point:** the smallest `held` from which the win rate stays at or above 50%.
- **Two runs of the smart 4-member gate:** before the SP change (a baseline on today's content) and after it. The
  numbers come to you before any tuning.

**The two stalled battles (1000 turns in 1f2):** trace the two stalled seeds (`trace on`, `trace_main.tscn` to the first repeating state).
Hypotheses, in order of likelihood:
1. **Drain on a weak boss.** The party holds Leech Hide ("You drain Physical"), so the Collector, who is weak to
   Physical, mirrors a Physical drain. `AutoPolicy` scores drained hits 0, finds nothing better, and falls back to the
   first legal move, often a Physical basic that heals the boss.
2. **Sustain over damage.** Mirrored sustain (Vampire Fang, Heart Regen, Mimic Tooth) outheals a party that has run
   out of MP and can only use basics. The SP change itself shifts this one.
3. **A dispel loop.** The Collector's pattern (Appraise, Gilded Ray, Dispel) strips buffs as fast as Bards and
   Bulwarks put them back.

The fix depends on the trace (D14). With D15, these battles end at 500 turns as a loss. A loss at the cap is
still a symptom to fix, not a design.

**Found (2026-10-27):** hypothesis 1. All six stalls held Leech Hide; the Collector, weak to Physical, sat at full HP
for 400+ turns. Fixed by `mirror_skip_tags` on `enemies/collector.tres` (the six `Drain.*`/`Resist.*` tags).

### 4.5 Balance rounds (2026-10-27, smart 4-member gate, 600 balance seeds)
| Round | Change | Win | Sound parties | Basics per ability | Turn limits |
|---|---|---|---|---|---|
| Baseline | today's content, 500-turn cap | 31.0% | 35.6% | – | 6 |
| SP content | SP economy and level content | 47.8% | 47.5% | 0.57 | 5 |
| Harder | costs ×2.5 (odd, capped at the smallest unlocking pool), the rest restores HP only, Collector skip tags | 33.7% | 39.4% | 2.99 | 7 |
| Traces | drain-safe Auto, secret skills in brains, Fire and anti-control items | 34.0% | 40.4% | 2.96 | 2 |
| Overtime | soft enrage and stacking exhaustion on every boss from turn 50 | **31.8%** | **38.9%** | 2.97 | **0** |

- **Where runs end:** floor 10 (the route bosses) holds most losses. The Nameless is the hard boss on purpose
  (75% lost per attempt: 9000 HP, resists Physical and Ice, weak to Fire, Silence stuns); the user accepts it and
  wants more items over a nerf.
- **The turn-limit traces:** 6 of 7 were Auto feeding a drain (Bound Demon drains Fire, Void Wraith and Vault Sentry
  drain Ice) with no affordable skill, fixed in `AutoPolicy`. The fix exposed a hang (a "safe" revive with no target
  returned no move; the battle waited for a player). The last ones were a lone Bulwark against Mother Heart, ended by
  the overtime exhaustion (a flat loss couldn't beat Shield Wall's 5% a turn).
- **Why costs alone weren't enough:** fights are short and SP carried, so casters opened every fight with a stored
  ability; the 50% SP at the Waystation refilled them each floor. Removing it is what made the rhythm.

**Root acceptance scenarios:** none apply, because this slice has no server. Scenario 5 (tampered log → 2002) is
extended on the client by the new `sp-seed-<n>-tampered-cost` golden. Replay mismatches stay verdicts with
`errorCode` 2002, never an HTTP status.

## 5. Observability
N/A for Prometheus: client-only, no service. Never use ability or item ids as metric labels later; the analytics
projections own those.

**Dev visibility:**
- **Play report `sp`** (per class): `basics`, `abilities`, `spGained`, `spSpent`, `capWaste` and
  `basicsPerAbilityX100` (the measured rhythm). `bossEntrySpPercent` (per boss floor) sits beside
  `bossEntryHpPercent`.
- **`analysis`:** `deathMap` (`lostRuns`, `byFloor` with losses, entered and loss rate, `byChapter`, `byEncounter`
  with losses, battles, share and losses per attempt, `turnLimits`, `concentration`, `endEntry` HP%, SP% and level),
  `byRoute` (the floor-9 chapter), `byPair` (with lift), `byFeature`, `sound` and `heldByBoss` (every boss's wins by
  pieces held, with the crossing point). Each battle record has `held`, `chapter`, `level`, `hpPercent`,
  `mpPercent`. `--compare <old report>` prints what changed.
- **`levelSkills`:** per class, the runs that reached each level skill; **`secretSkills`:** per enemy skill, battles at
  or above its level and uses.
- **Balance tools:** `game/dev/balance_seeds.json` (600 committed seeds), `--seeds`, `--count`, nested `--set` what-ifs.
- **Console and `dev_run`:** `status`, `skills`, `battlelog` and the JSON stats (3.2).
- **Battle HUD:** the cost hint shows the scaled cost (3.2). No new screen.

## 6. Test plan
Godot (`tools/godot_tests.sh`, all through `watch.sh`):
- **Turn limit:**
  - A battle stops at 500 turns with `TurnLimit`.
  - The run is lost.
  - Replay verifies it.
  - A log with entries past the cap is rejected with 2002 `TurnLimitExceeded`.
  - The invariant checker doesn't flag it; the report counts it.
- **Death map:** losses by floor, route and encounter, shares and concentration on a fixture report with known
  losses.
- **`ExecCalcRestore` defaults:** an existing effect without the new options gives the identical result
  (ult charge, heals).
- **SP gain:**
  - A fixture basic with `sp_basic` 17 restores 17 SP.
  - At 149% it restores 25 (truncated from 25.33).
  - Nothing at the cap.
  - Nothing for a follow-up, an ult or a controlled skip.
  - A One More basic gains.
- **Costs:**
  - `ExecCalcCost` at 100%, 80% and 50%, with truncation.
  - `can_afford_cost` refuses at 1 SP short and accepts at exactly the cost.
  - Field mode scales the cost too.
- **Growth:** a level-8 drummer gains 149% of its level-1 SP per basic (truncated), and its pool grows by the same
  149%. The level comes from the snapshot, as 3.11 rebuilds growth.
- **Goldens:**
  - `sp-seed-<n>` replays to its hash.
  - The tampered-cost copy is rejected with 2002 `IllegalAbility`.
  - `BattleTrace` matches the committed `.trace.json`.
- **AutoPolicy:**
  - It basics while under the threshold, then casts.
  - It keeps a heal's worth of SP when an ally is under 45%, and doesn't spend the healer's SP on damage.
  - It spends at the cap.
  - A unit with no Basic ability behaves exactly as before (the D12 gate).
  - Its picks are always legal.
- **Content:** the validator run over `content/` checks every class's `sp_basic` and the D5 costs; a demo test
  checks that each class can afford its most expensive ability from a full level-1 pool.
- **Level skills:**
  - **Party:** a member has a level skill from its level on, and not before (from the snapshot's level).
  - **Message:** a level-up broadcasts `SkillLearned` once per skill, including on a level jump.
  - **Enemy level:** depth table + variant bonus + slot bonus, with the clamp past the table's end.
  - **Secret skill:** present only at its level.
  - **PatternBrain:** a step naming a missing secret skill falls back to the default choice.
  - **Replay:** the sp-seed golden replays, and the tampered-unlearned copy is rejected with 2002 `IllegalAbility`.
  - **Defaults:** empty tables leave every fixture battle's hash unchanged.
  - **One level concept:** an enemy at depth level 5 has `BattleUnit.level` 5, but its abilities and effects are
    applied at level 1. A party member's level and `effect_level` are equal.
  - **The `level` attribute:**
    - It equals level × 100 after build.
    - An effect that targets it leaves it unchanged, and the validator flags that effect.
    - An ExecCalc reading it sees the unit's level.
    - It appears in the state hash for the SP fixture.
  - **Validator:** the `level_skill_*` and `secret_skill_unreachable` checks, against broken fixtures.
- **Chaos:** the unaffordable case is reached and refused, and the run ends with 0 violations on fixtures.
- **Validator:** `sp_gain_missing`, `cost_unscaled`, `basic_costed` against new broken fixtures in
  `tests/broken_fixtures/`. The validator run over `content/` stays clean.
- **Hint:** `cost_text` shows the ExecCalc cost, scaled by a unit's `sp_cost`.
- **Report:**
  - `held` equals the mirror count on a fixture battle.
  - `winByHeld` buckets.
  - The `sp` block sums.
  - Seed order and merge (2.3d) stay deterministic.
- **Demo:** the smoke test plays one battle on the demo content in which a basic restores SP. The content tests for
  each new item (D8) assert their effect on a demo unit.

.NET (`tools/dotnet_test.sh`): unchanged suite. The golden cross-check passes over the committed goldens, including
the new `sp-seed-<n>` files if the cross-check enumerates the folder.

**Balance gate** (informs tuning; no test asserts a rate): smart, 4 members, seeds 1–300, sharded
(`game/tools/play_sharded.sh`). The target is the existing D25 band, **35–55%** (today 33.33%, under the band). The
other policies run only once the gate is in the band.

## 7. Decisions (answered 2026-10-27)
**D1. Pool model.** ✅ Per character, as today (Persona). The `mp` attribute, the carry and every UI stay.

**D2. SP between battles.** ✅ Carry over as today; the Waystation rest no longer refills SP (4.5), so SP comes from
basic attacks and items. The fallback `RunStructure.sp_start_min` is built and off.

**D3. Where SP gain lives.** ✅ The `sp_gain.tscn` passive on `Event.Ability.Used.Basic`, listed on each class like
`ult_charge`. Its amount is the class's `sp_basic` × `sp_gain`.

**D4. Numbers and growth.** ✅ Starting pools as before; SP per basic is a per-class odd number, higher for
fighters and lower for casters (11–19): `sp_basic` in each `content/demo/characters/*.tres` `stats_x100`. `sp_gain` and
`max_mp` grow +7% per level in `effects/growth_damage/support/tank.tres`.

**D5. Costs.** ✅ Odd and per ability; stronger and unlocked abilities cost more. The first table was raised to 2.5×
in the "Harder" round (4.5): each cost ×2.5, rounded to the nearest odd number, capped at the smallest pool among the
classes that unlock it, so a full pool can always pay. Each ability's cost is its `cost_effect`
(`effects/sp_cost_<n>.tres`, an `ExecCalcCost`), set with `game/tools/build_cost_pass.tscn` from a JSON table. Ults
(energy) and Block are free of SP.

**D6. Free non-basic moves.** ✅ Provoke and Fyrefly Strike cost SP (D5). Block stays free and gives no SP.

**D7. Cost reduction mechanism.** ✅ The `sp_cost` attribute with `ExecCalcCost`, truncated to whole SP, never below
50% from items.

**D8. New items.** ✅ Metronome, Cadence Charm, Thrift Sigil, Choir Bell, Corrupted Sigil (`content/demo/items/`)
and the accessories Tuning Fork and Spellbinder's Loop (`equipment/`), each with its effect in `effects/`. Added after
the traces (1 in 4.5): Kindled Edge, Frostfire Charm (Fire follow-ups on Physical and Ice hits), Lucid Charm (immune to
Stun and Freeze) and Clarion Bell (the party starts each battle Warded).

**D9. SP restores.** ✅ Retuned: Ether, Honey Cake, Spellweave, Scholar's Tome and Mana Crystal (their effects in
`effects/`). The Waystation rest now heals HP only (4.5).

**D10. The label.** ✅ The player sees "SP"; the attribute stays `mp`. Item and ability descriptions in `content/` are
rewritten with the new numbers.

**D11. "auto" policy.** ✅ First-legal plus the danger-reserve skip.

**D12. Fixture goldens.** ✅ The new `AutoPolicy` rules are gated on units that have a Basic ability, and a new SP
fixture with the `sp-seed-<n>` golden proves the mechanic. Existing goldens are expected unchanged; the real diff is
reported at `/implement`.

**D13. The mirror.** ✅ Your order: (a) stronger items (the SP items already favour the party), (b)
`EnemyDefinition.mirror_limit` (built, off), (c) the per-item effect. The choice is made only after the death map (D16) and the
`winByHeld` numbers.

**D14. The stalled battles.** ✅ Trace both first. If the mirrored drain is confirmed,
`EnemyDefinition.mirror_skip_tags` (`Drain.*`, `Resist.*`) is the proposed fix, brought for approval with the trace.

**D15. Turn limit (new).** ✅ 500 turns instead of 1000. Hitting it is a loss (`TurnLimit`, treated as `Defeat` by the
run, verified on replay); details in 3.2.
- **Still a dev violation:** stalls often come from broken items or interactions, so the dev checks keep flagging
  them (user, 2026-10-27).
- **Production:** the player simply loses, and the analytics record the outcome later.

**D16. The death map first (new).** ✅ Before any balance decision, the gate run maps where attempts end (4.3). It is
shown on today's content (with D15), then again after the SP change. Balance proposals come only from those maps.
- **The balance seeds** are no longer 1–300 but **600 random seeds** (user, 2026-10-27). They are drawn once and
  committed as `game/dev/balance_seeds.json`, so every report on the gate uses the same runs and two maps compare
  like for like.
- **How to run it:** `seed_report --play --seeds <file>` plays a list, and `play_sharded.sh` splits it across shards.

**D23. Balance by buffing (new, user 2026-10-27).** ✅ (Amended: the user then asked for a harder game, so costs, the
rest and overtime were changed to make it harder; underpowered parts are still fixed by buffs and items.) An underpowered party, class or point in the run is fixed by
buffing or by adding items, never by nerfing the enemies or the run. Ordinary enemies, bosses and the mirror are only
changed to fix a broken interaction (a stall, a bug), not to lower the difficulty.

**D24. Ranked innate abilities (new, user 2026-10-27).** Every class's innate ability has three ranks, as in Persona
(Agi → Agilao → Agidyne). Reaching a level swaps in the stronger rank.
- **Data:** a `LevelSkill` row may name `replaces` (an ability tag). When the row is reached, the new rank is granted
  and the old one is not.
- **Replay:** a log that uses rank I after rank II is reached is rejected with 2002 `IllegalAbility`, through the
  existing "unit has no ability" check.
- **Bots and UI:** they need nothing new; they read roles and costs. The Status screen shows "Lv 5 · Fireburst II
  (replaces Fireburst)".
- **Open, my recommendations:**
  - **Which ability:** the class's main non-basic, non-ult skill (Warrior: Ice Blast; Cleric: Heal; Arcanist:
    Fireburst; and so on).
  - **When:** rank II at level 5, rank III at level 10.
  - **Each rank is its own scene:** for example `fireburst_2.tscn`. That keeps each rank's damage, cost, name and
    animation editable on its own. A `build_rank_pass` tool drafts ranks II and III from rank I, for your tuning:
    damage ×1.5 and ×2.1, cost ×1.33 and ×1.67, rounded to odd numbers.
- **Alternative:** one scene with GAS ability levels. It is less visible and can't change names or targeting
  (Persona's Media → Mediarama widens a heal to the whole party).

**D25. Level passives (new, user 2026-10-27).** Levels can also unlock passives that support a class's playstyle.
They are `LevelSkill` rows whose ability is a triggered passive (like Hunter's Instinct), so they need no new system
code. My recommendations:
- **Levels:** one passive at level 3 and one at level 7, so every two or three levels brings something: a passive
  at 3, rank II at 5, a passive at 7, rank III at 10.
- **Content:** the passives go in the D20 content table for your approval.

**D26. Party composition in the gate (new, user 2026-10-27).** The overall win rate mixes good and bad parties, so it
is never read alone. The report adds:
- **`byPair`:** each pair of classes, with its runs, wins and **lift**: the pair's win rate minus what its two
  members' own rates predict. Good pairs stand out even with 600 seeds: 55 pairs at about 65 runs each.
- **`byFeature`:** wins by what the party can do, read from `Ability.Role.*` tags with no ids. Healer, reviver,
  cleanser, taunt, area damage, and how many damage types it has, shown as with/without.
- **`byParty`:** stays, but with 330 possible parties each one appears about twice in 600 runs, so it is only a hint.
- **The gate reads three numbers:** the overall rate, the rate of the parties that have a healer **and** cover two or
  more damage types ("sound parties"), and the worst class's rate. My recommendation is to aim the D25 35–55% band
  (playable-demo) at sound parties, and to fix a class or pair that sits well under the others with buffs or items
  (D23). Whether the overall rate needs its own band is your call.

**D27. Iterate fast (new, user 2026-10-27).** Each balance change is GAS data, so the loop is
"change a `.tres` → run the gate → compare".
- **A quick set:** the first 150 seeds of the balance list (`--seeds-limit 150`), about 25 s on 12 shards, for each
  iteration.
- **The full 600:** to confirm before a change is proposed to you.
- **`--compare <previous report>`:** prints the change in the overall rate, sound parties, each class and pair, and
  the death map.
- **Iteration without your approval:** only on scratch copies (`--content-root` on a `user://` copy of `content/`).
  A change reaches your folders only with your approval, as always.

**D17. Level skills as data (new).** ✅ A `LevelSkill` resource (`level`, `ability`) and
`UnitDefinition.level_skills`, on the base type so characters and enemies share it. Each row is edited in the
inspector like a loadout. Alternatives:
- a `level → ability` Dictionary: one ability per level only, and harder to edit;
- one `AbilitySet` per level: heavier than one row.

**D18. How a character learns (new).** ✅ Automatically: reaching a level grants its skills, derived from
the level the run already stores and hashes. Nothing new is logged; the Status screen shows the "Learns" list, and a
toast plus a battle-feed line announce it. Skills are never forgotten, and there is no slot limit. Learning by
choice (pick one of two at a level) is a later idea; it would need a logged run action.

**D19. Enemy level (new).** ✅ An enemy's level comes only from content:
- **By depth:** `ScalingRules.enemy_level_by_depth`. For The Descent: floors 1–2 → 1, 3–4 → 3, 5–6 → 5, 7–8 → 7,
  9–10 → 9.
- **Plus bonuses:** `EnemyVariant.level_bonus` (Elite +2) and `EncounterSlot.level_bonus`.
- **Skills only:** the level unlocks secret skills and nothing else. Stats keep coming from the depth scaling,
  so floors don't get stronger twice.
- **No wire change:** the battle snapshot already carries `scalingId` and `depth`.

**D20 as built.** Every class's `level_skills` (`content/demo/characters/*.tres`): a passive at 3 and 7, its innate
skill's rank II at 5 and rank III at 9 (`replaces`), names and numbers in the ability scenes. Ranks: Challenge/War Cry,
Greater/Mass Heal, Fireblast/Firestorm, Rousing/Grand Anthem, Iron Hide/Bastion Wall, Glacial Lance/Tomb, Kindle
Blaze/Inferno, Outbreak/Pandemic Bloom, Scorch/Immolate, Mark Quarry/Death Mark, Fracture/Shatterstorm. The Warrior
learns Ice Blast at 3; the Ember Knight's level-3 passive reuses Bellows and the Pyromancer's level-7 passive reuses
Spellweave; Plague Bloom became Corrode. Enemies: `enemy_level_by_depth` on `scaling/descent.tres`, the Elite variant
+2, and secret skills on the Slime, Bat, Golem, Imp, Wisp, Shaman and Lich (`level_skills`), cast through their
brains (a pattern step, or `level_skill_every`).

**D21. One level concept (new).** ✅ `BattleUnit.level` is the real level for party members and enemies.
`effect_level` keeps today's GAS ability and effect levels (party = level, enemies 1), so no existing number moves.
The separate enemy `skill_level` is dropped.

**D22. A read-only `level` attribute (new).** ✅ The `Unit` AttributeSet gains `level`:
- **Written once:** stored ×100 (level 8 = 800) at battle build, then refused by the AttributeSet for every later
  change.
- **Checked at edit time:** the validator flags any effect that targets it.
- **What it is for:** content can read the level with no code. For example, an ExecCalc that hits harder per level,
  or an activation query or condition "level 5 or higher".
- **Hashed:** on units whose AttributeSet has it (the demo and the new SP fixture), so a wrong level is caught on
  replay. The fixtures' frozen sets don't have it, so their goldens stay unchanged.

**D20. Level-skill content (new).** ✅
- **In this slice:** the mechanism, plus moving Warrior's Ice Blast from his starting loadout to his level table at
  level 3 (cost 53).
- **At implementation step 3, for your approval before anything is written:**
  - **Characters:** one learned skill per class, at level 5 or 7, with odd costs in the D5 "Unlocked" tier.
  - **Enemies:** secret skills for about six enemies, at least one per chapter and one boss.
  - **Reuse first:** existing ability scenes are reused where they fit (for example Rockfall for the Golem outside
    its phase, Hex All for the Shaman, Frost Nova for the Frost Wisp). New scenes come only where nothing fits.

**Order of work at `/implement`:**
1. The turn limit (D15), the balance seeds (D16) and the measurement tools: the death map, `held`, `winByHeld`,
   `byPair`, `byFeature`, `--compare`, and the Collector traces. Then the baseline gate run on the 600 seeds, with
   the death map and the numbers to you. The `sp` block comes with the SP system in step 2.
2. The system hooks (`ExecCalcRestore` options, `ExecCalcCost`, hint, validator), level skills (D17–D19), one level concept and the
   read-only `level` attribute (D21, D22), and the SP fixture with its golden and tampered copies.
3. The cost pass and the content (D4, D5, D8, D9 as approved here; the `godot_gas` attributes and tags; Ice Blast
   to Warrior's level table), then the D20 level-skill and secret-skill table for your approval.
4. Bots.
5. The gate again: the second death map, side by side.
6. Balance and mirror proposals from the two maps, for your approval before any change.
