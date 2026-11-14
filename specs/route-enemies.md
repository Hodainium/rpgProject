# Spec: route-enemies (12 new enemies for the four ending-route chapters)

Status: reviewed 2026-11-13 (section 7: Cathedral and Vault Q1-Q6, Coven and Void Q7). Slice: a content slice after cube-style Set 5; the new enemies' cube looks follow in the same slice as two
cube-style sets, 4b (Cathedral and Vault) and 5b (Coven and Void) (spec `cube-style` 6a, "More enemies").

## 1. Purpose & enterprise mapping

The light route of The Descent (spec `playable-demo` 3.8: floor 9 The Silent Cathedral, floor 10 The Vault) has the thinnest enemy
rosters in the run: two regular enemies and one boss each (Cathedral: Choir Seraph, Penitent Knight, the Hallowed Judge; Vault:
Gilded Mimic, Vault Sentry, the Collector). The user asked (2026-11-13) for **three more enemies per chapter, so each floor has six
counting its boss**, decided as:

- per chapter **one elite** (a tougher mini-boss met in its own, rarer encounter; not the floor boss, never `Enemy.Boss`) and **two
  regular enemies**;
- each new enemy has **at least one new ability** that fits its theme, built from existing GodotGAS pieces (effects, statuses, hit
  and damage tags, execution rows); existing abilities are reused where they fit;
- **no new combat mechanic** and no system code. Everything is data in `client-godot/content/demo/` (the user's design folder:
  Claude creates the new files on request; changing an existing file needs the user's OK, see section 7).

**Extended the same day (user, 2026-11-13):** the dark route gets the same treatment, so **The Black Coven** (floor 9) and **The
Void** (floor 10) also get one elite and two regular enemies each (sections 3.4, 3.5). Twelve enemies in all, built from the same
rules.

**Enterprise mapping: none new.** The enemies are content, so they reach the backend only the way all content does: the ruleset
version changes (the content hash), and battles against them are uploaded in the run's action log and verified by replay like any
other. No endpoint, contract, queue, topic, cache key or metric changes. Analytics see new encounter and enemy ids in the log;
ids are never Prometheus labels (root `CLAUDE.md`).

## 2. Sequence flow

N/A for the backend: nothing new travels. In the game, the flow is today's:

1. The floor generator picks each battle room's encounter from the chapter's `encounter_query` (`Chapter.Cathedral` /
   `Chapter.Vault`, not `Encounter.Boss`) by `EncounterDefinition.weight`. The new encounters carry the chapter tag, so they join the
   pool with no change to the chapter files.
2. The elites' encounters have a **lower weight** (0.4 against the regulars' default 1, stored ×100 as 40 and 100), which is what makes them "special": rarer,
   at most as likely as any one regular encounter. No room type, floor rule or generator change.
3. In battle, each enemy acts by its brain (`PatternBrain`, or `TacticalBrain` where noted); the elites change at 50% HP through
   `EnemyDefinition.phases` (`BossPhase`), which is not limited to bosses (to be confirmed in implement by a test; if it is, the
   elite drops its phase rather than gaining code).
4. Server mode: unchanged. The battle is logged and uploaded; the verifier replays it on the same content (the export must be
   rebuilt so the worker's ruleset version matches, as for any content change).

## 3. Data contracts

**No C# DTOs, queues, topics or Redis keys.** The contracts are the content resources below. Numbers are written here as a designer
types them (stored ×100 in the files, root `CLAUDE.md` number policy); the `.tres` files stay the source of truth once built, and
these first values are a starting point for the balance gate (section 6), not a promise.

Reference (today, floor 9-10): regulars HP 520-1100, ATK 260-420, DEF 150-380, SPD 80-125, toughness 60-160; bosses HP
5000-9000. Enemy levels come from `ScalingRules.enemy_level_by_depth` as for every Descent enemy.

### 3.1 The Silent Cathedral

| Enemy | Rank | HP / ATK / DEF / SPD / Tough. | Tags | Abilities (new in **bold**) | Brain |
|---|---|---|---|---|---|
| **Bell Ringer** `demo.enemy.bell_ringer` | regular | 640 / 300 / 180 / 110 / 80 | `Enemy.Type.Ringer`, `Weakness.Fire` | **Toll**: all party, Physical 50%, and every hit delays its target's next action by 20% (`ExecutionRow.delay`); `strike` | Pattern: Toll, Strike, Strike |
| **Candle Acolyte** `demo.enemy.candle_acolyte` | regular | 480 / 320 / 140 / 125 / 60 | `Enemy.Type.Acolyte`, `Resist.Fire`, `Weakness.Ice` | **Votive Flame**: one target, Fire 110%, Burn at 60%; **Vigil**: every ally heals 10% of max HP and loses its debuffs (heal + cleanse effects; built, section 7b) | Pattern: Votive Flame, Votive Flame, Vigil |
| **Glass Saint** `demo.enemy.glass_saint` | **elite** | 2600 / 380 / 260 / 100 / 240 | `Enemy.Type.Saint`, `Enemy.Rank.Elite`, `Resist.Ice`, `Resist.Fire`, `Weakness.Physical` | **Prism Ray**: all party, Ice 70%, Vulnerable at 40%; **Stained Ward**: Ward on every ally; `smite`. Phase at 50% HP, *Cracked*: Haste on itself and **Shard Rain** joins its pattern (all party, Physical 60%, Bleed at 50%) | Pattern: Prism Ray, Stained Ward, Smite (Cracked: Shard Rain, Prism Ray, Smite) |

Theme and role: the Cathedral today is healing (Seraph's Hymn, Bless) and a wall (Penitent's Provoke). The Bell Ringer adds tempo
pressure (action delay), the Acolyte the chapter's only Fire attacker and a healer that punishes slow kills, and the Glass Saint a
high-toughness elite that is brittle to Physical, which the Judge (weak to Physical) already teaches.

### 3.2 The Vault

| Enemy | Rank | HP / ATK / DEF / SPD / Tough. | Tags | Abilities (new in **bold**) | Brain |
|---|---|---|---|---|---|
| **Tally Clerk** `demo.enemy.tally_clerk` | regular | 460 / 280 / 150 / 135 / 60 | `Enemy.Type.Clerk`, `Weakness.Fire` | **Levy**: one target, Physical 80%, and it loses 15 SP (a new instant effect lowering `mp`); `dispel` | Pattern: Levy, Levy, Dispel |
| **Vault Gargoyle** `demo.enemy.vault_gargoyle` | regular | 900 / 340 / 360 / 90 / 140 | `Enemy.Type.Gargoyle`, `Resist.Physical`, `Weakness.Ice` | **Stone Gaze**: one target, Physical 60%, Stun at 45%; an existing self Defense Up (picked in implement) | Pattern: Stone Gaze, Defense Up, Stone Gaze |
| **Hoard Drake** `demo.enemy.hoard_drake` | **elite** | 3000 / 420 / 240 / 115 / 220 | `Enemy.Type.Drake`, `Enemy.Rank.Elite`, `Resist.Fire`, `Weakness.Ice` | **Gilded Breath**: all party, Fire 75%, Burn at 50%; **Hoard Greed**: Rally (ATK up) on itself and heals 10% of max HP; `bite`. Phase at 50% HP, *Hoard Fury*: Haste on itself, Gilded Breath twice in its pattern | Pattern: Bite, Gilded Breath, Hoard Greed (Fury: Gilded Breath, Bite, Gilded Breath) |

Theme and role: the Vault is greed and guards. The Clerk taxes SP (the party's Skill Points, spec `skill-points`), the Gargoyle is a
slow stunning wall, and the Drake a fire-breathing hoard guard. Two deliberate tensions: the Gargoyle and the Drake are weak to Ice
while the Vault Sentry **drains** Ice, so mixed encounters make the party aim its Ice; and the Clerk's Levy pressures the
Collector fight's SP rhythm without touching the boss.

### 3.3 Encounters (new files, `content/demo/encounters/`)

| Encounter | Chapter tag | Slots | Weight |
|---|---|---|---|
| `demo.encounter.bell_tower` | `Chapter.Cathedral` | Bell Ringer, Bell Ringer | 100 |
| `demo.encounter.vespers` | `Chapter.Cathedral` | Candle Acolyte, Bell Ringer, Choir Seraph | 100 |
| `demo.encounter.glass_saint` | `Chapter.Cathedral` | **Glass Saint**, Candle Acolyte | 40 |
| `demo.encounter.counting_house` | `Chapter.Vault` | Tally Clerk, Tally Clerk, Gilded Mimic | 100 |
| `demo.encounter.gargoyle_watch` | `Chapter.Vault` | Vault Gargoyle, Vault Sentry | 100 |
| `demo.encounter.drake_lair` | `Chapter.Vault` | **Hoard Drake**, Tally Clerk | 40 |

The six existing Cathedral and Vault encounters stay as they are (changing them needs the user's OK; section 7, Q3).

### 3.4 The Black Coven

Today: Cultist (Hex, Curse; `Weakness.Physical`), Bound Demon (Hellfire, Rend; `Drain.Fire`, `Weakness.Ice`), boss the High Witch.

| Enemy | Rank | HP / ATK / DEF / SPD / Tough. | Tags | Abilities (new in **bold**) | Brain |
|---|---|---|---|---|---|
| **Hex Doll** `demo.enemy.hex_doll` | regular | 500 / 300 / 130 / 120 / 50 | `Enemy.Type.Doll`, `Weakness.Fire` | **Pinprick**: one target, Physical 70%, Bleed at 60%; `curse` | Pattern: Pinprick, Curse, Pinprick |
| **Coven Familiar** `demo.enemy.coven_familiar` | regular | 420 / 280 / 120 / 145 / 50 | `Enemy.Type.Familiar`, `Resist.Ice`, `Weakness.Fire` | **Ill Omen**: all party, Ice 40%, Slow at 50%; `bite` | Pattern: Ill Omen, Bite, Bite |
| **Hag Sister** `demo.enemy.hag_sister` | **elite** | 2700 / 390 / 220 / 105 / 200 | `Enemy.Type.Hag`, `Enemy.Rank.Elite`, `Resist.Fire`, `Weakness.Physical` | **Boil Over**: all party, Fire 65%, Burn at 50%; **Cauldron Brew**: every ally heals 12% of max HP and gains Rally; `hex_all`. Phase at 50%, *Bitter Brew*: Haste on itself, Boil Over twice in its pattern | Pattern: Boil Over, Hex All, Cauldron Brew (Bitter: Boil Over, Cauldron Brew, Boil Over) |

Theme: the witch's household. The Doll punishes with bleeds, the Familiar slows the party (fast, frail; weak to Fire, so beside the Bound Demon, who **drains** Fire, the party must aim its Fire, the Vault's tension), and the Hag Sister is a
healing, burning elite; she is weak to Physical where the High Witch is weak to Fire, so the party's answer changes.

### 3.5 The Void

Today: Void Wraith (Chill Touch, Fade; `Drain.Ice`, `Resist.Physical`), the Guardian (`demo.enemy.abyssal_hulk`, the Abyssal Hulk renamed 2026-11-13; Abyss Crush, Tremor; `Weakness.Fire`), boss
the Nameless (`Weakness.Fire`). The new ones avoid a fourth Fire weakness.

| Enemy | Rank | HP / ATK / DEF / SPD / Tough. | Tags | Abilities (new in **bold**) | Brain |
|---|---|---|---|---|---|
| **Null Moth** `demo.enemy.null_moth` | regular | 440 / 290 / 120 / 140 / 50 | `Enemy.Type.Moth`, `Weakness.Physical` | **Dim Wings**: all party, Ice 40%, Weaken (ATK down) at 40%; `bite` | Pattern: Dim Wings, Bite, Bite |
| **Hollow Echo** `demo.enemy.hollow_echo` | regular | 700 / 330 / 220 / 115 / 100 | `Enemy.Type.Echo`, `Resist.Fire`, `Weakness.Ice` | **Echo Strike**: one target, two Physical hits of 50% (two execution rows); `strike`; passive **Resound**: when hit on its weakness, strikes back for 40% ATK Physical (on `Event.Damage.Taken.Weakness`, section 7b) | Pattern: Echo Strike, Strike, Echo Strike |
| **Void Devourer** `demo.enemy.void_devourer` | **elite** | 3100 / 430 / 250 / 100 / 230 | `Enemy.Type.Devourer`, `Enemy.Rank.Elite`, `Resist.Ice`, `Weakness.Physical` | **Consume**: one target, Physical 120%, and the passive **Gorge** heals the Devourer 10% of max HP (section 7b); **Gravity Well**: all party, no damage, every target's next action delayed 25%, Slow at 40%; `tremor`. Phase at 50%, *Starving*: Haste on itself, Consume twice in its pattern | Pattern: Gravity Well, Consume, Tremor (Starving: Consume, Gravity Well, Consume) |

Theme: what is left in the dark. The Moth weakens, the Echo hits twice and counters a hit on its weakness (Resound), and the Devourer is a tempo-and-sustain elite.
The Hollow Echo is weak to Ice while the Void Wraith **drains** Ice, the same aiming tension as in the Vault.

**Coven and Void encounters (new files):**

| Encounter | Chapter tag | Slots | Weight |
|---|---|---|---|
| `demo.encounter.doll_circle` | `Chapter.Coven` | Hex Doll, Hex Doll, Cultist | 100 |
| `demo.encounter.familiars` | `Chapter.Coven` | Coven Familiar, Coven Familiar, Bound Demon | 100 |
| `demo.encounter.hag_sister` | `Chapter.Coven` | **Hag Sister**, Coven Familiar | 40 |
| `demo.encounter.moth_swarm` | `Chapter.Void` | Null Moth, Null Moth, Null Moth | 100 |
| `demo.encounter.echoes` | `Chapter.Void` | Hollow Echo, Void Wraith | 100 |
| `demo.encounter.devourer` | `Chapter.Void` | **Void Devourer**, Null Moth | 40 |

Elite drops (25%, like the light route's): the Hag Sister the Witch's Eye, the Void Devourer the Vampire Fang (the Void Scar is a curse, the altars' price, so it is no reward).

### 3.6 Other new data

- **New abilities** (`content/demo/abilities/`, each with an `Ability.*` tag and an animation from the default set): Toll, Votive
  Flame, Vigil, Prism Ray, Stained Ward, Shard Rain, Levy, Stone Gaze, Gilded Breath, Hoard Greed (light route); Pinprick,
  Ill Omen, Boil Over, Cauldron Brew, Dim Wings, Echo Strike, Consume, Gravity Well and the passive Resound (dark route). They reuse today's effects
  (`damage`, `burn`, `bleed`, `stun`, `vulnerable`, `ward`, `haste`, `rally`, `heal`, `cleanse`, `slow`, `weaken`, `vampire_heal`) except these:
- **New effects:** `sp_drain_15` (instant, `mp` −15, clamped at 0 by the attribute set), for Levy; as built (7b), the percent heals `vigil_heal` (10%), `cauldron_brew_heal` (12%), `hoard_greed_heal` (10%), `gorge_heal` (10%), and the empty `gravity_pull` that carries Gravity Well's delay.
- **New tags** (in `godot_gas/tag_registry.tres`, the user's file, so on the user's OK): twelve `Enemy.Type.*` tags (Ringer, Acolyte,
  Saint, Clerk, Gargoyle, Drake, Doll, Familiar, Hag, Moth, Echo, Devourer), `Enemy.Rank.Elite` and one `Ability.*` tag per new
  ability (nineteen; Resound as `Ability.Passive.Resound`); checked by `game/tools/sync_tags.tscn`.
- **Drops:** each regular enemy drops an existing food item at the regulars' usual chance (3-8%). Each elite only has a **chance to
  drop an item** (user, Q5), through the same `drop_item` / `drop_chance` as every enemy: the Glass Saint the Halo, the Hoard Drake
  the Golden Idol, the Hag Sister the Witch's Eye, the Void Devourer the Vampire Fang, at 25% (a starting value; the encounter has no `rewards`).
- **XP:** `RunStructure.xp_per_enemy` is flat, so an elite gives what any enemy gives. Paying elites more would be a rule change
  (not in this spec).
- **Overtime:** the boss enrage and party exhaustion (`overtime_turn`) stay boss-only; elites have none.

## 4. Failure modes

Content only, so the risks are content risks; no backend failure path changes and no root acceptance scenario is newly covered.

| Risk | Guard |
|---|---|
| A new ability is broken or not deterministic (a verified battle could be rejected 2002) | Each new enemy is fought in a headless battle and replayed by `ReplayRunner` to the same final hash (test below). A replay mismatch stays a verdict with `errorCode` 2002 under the root error contract; nothing here changes that path. |
| A new tag, ability or effect is missing or misspelled | `validate_content.tscn` (unknown tags, missing scenes) and `sync_tags.tscn` run clean. |
| `BossPhase` refuses a non-boss | The phase test (section 6) proves an elite's phase fires; if it cannot, the phase is dropped from the elite (no code change). |
| The new enemies make the light route much harder or easier | The balance gate (section 6) runs before and after; the numbers go to the user before any tuning. |
| The server's verifier runs an old ruleset | Unchanged rule: re-export the full build after content changes (`tools/dev_stack.sh`, `tools/export.sh full`). |
| The Collector's mirror or overtime picks up an elite | Elites have neither `Enemy.Boss` nor `mirror_party_items`; the boss queries need `Encounter.Boss`, which the new encounters do not have. |

Root acceptance scenarios 1-7: N/A (no settlement, queue, outbox, cache or verifier change).

## 5. Observability

N/A: no new metric. Encounters and enemies are never Prometheus labels; the play report (`seed_report --play`) already reports
deaths per encounter and floor, which is how these enemies are watched.

## 6. Test plan

**Godot (`tools/godot_tests.sh`):**
- `tests/game/test_route_enemies.gd` (new): for each of the twelve enemies, a headless battle against a fixed demo party on a fixed
  seed in which every new ability is used at least once (asserted from the battle log, `BattleLog`), then a replay through
  `ReplayRunner` reaching the same final hash; Levy lowers the target's `mp` by 15 and never below 0; Vigil heals its allies and removes
  their debuffs; Toll delays every target; Resound strikes back when the Echo is hit on its weakness and starts no chain with the party's counters; drops obey the card pool; each elite's phase fires below 50% HP and changes its pattern.
- The content validator over `content/` (existing test) stays clean; `sync_tags` reports no missing tag.
- Seed report: over the 600 balance seeds, the four route chapters (both routes) draw every new encounter, and the elites' encounters
  appear at roughly their weight's share (0.4 / (sum of weights) of battle rooms, ± a tolerance), with no elite on any other chapter.
- No golden should move: the committed goldens use the fixtures or runs that never reach floors 9-10. If one moves, it is
  investigated and regenerated on purpose, never worked around.

**Balance gate (spec `skill-points` D16, D26, D27; the user's gold standard):** the smart 4-member play report on
`game/dev/balance_seeds.json` (600 seeds, `play_sharded.sh`) before the new enemies (baseline) and after them, compared with
`--compare`: overall win rate, win rate per route, deaths on floors 9 and 10 by encounter, and each new encounter's loss share.
The numbers go to the user before any tuning; tuning is done on the `.tres` values (or with `--set` what-ifs first).

**.NET:** no change; `dotnet test` must still pass. Optional on demand: `tools/e2e.sh verify_demo_content` with the rebuilt export.

## 7. Decisions (user, 2026-11-13)

- **Q1. The six designs:** kept as proposed.
- **Q2. Elite rarity:** encounter weight 40 against the regulars' 100.
- **Q3. Existing encounters:** left alone; only the six new encounters are added.
- **Q4. Tags:** OK to add the `Enemy.Type.*` tags, the `Ability.*` tags and `Enemy.Rank.Elite` (on the elites) to
  `godot_gas/tag_registry.tres` (with Q7: twelve types and nineteen abilities, section 3.6).
- **Q5. Elite reward:** only a chance to drop an item (section 3.6); no encounter `rewards`.
- **Q6. Looks:** the new enemies' looks go through the cube-style A/B process in this slice: Set 4b (Cathedral, Vault) and Set 5b
  (Coven, Void), after the content is built.
- **Q7. Coven and Void (2026-11-13):** the six designs of sections 3.4 and 3.5 kept, with weight 40 and 25% elite drops as in
  Q2 and Q5, and three changes: the Hollow Echo's counter is a new passive **Resound** (`retaliate` needs `State.Taunting`, which
  the Echo never has, and a passive is no pattern step), at 40% so area attacks are not punished too hard; the Void Devourer
  drops the **Vampire Fang** (Epic, `Pool.Treasure`), not the Void Scar (a curse); the Coven Familiar is **weak to Fire** (was
  Physical), so the Familiars encounter sets Fire against the Bound Demon's Fire drain.

### 7b. Built differently from 3.x (user, 2026-11-13, during /implement)

The engine has no data for some of the designs above; the user chose these data-only versions (no new combat mechanic):

- **Build:** one builder, `game/tools/build_route_enemies.tscn`, creates every new file (never overwrites); the tags are added
  to the registry by hand.
- **Elite phases:** `PatternBrain` has one rotation and a `BossPhase` can only add abilities, tags and effects. Each elite has a
  four-step pattern whose fourth step is an ability its phase grants (with Haste); before the phase that step falls back to its
  first ability, like the Golem's Rockfall. Glass Saint: Prism Ray, Stained Ward, Smite, *Shard Rain* (Smite before). Hoard
  Drake: Bite, Gilded Breath, Hoard Greed, *Fury Breath* (a copy of Gilded Breath; Bite before). Hag Sister: Boil Over, Hag's Hex,
  Cauldron Brew, *Bitter Boil* (a copy of Boil Over; Hag's Hex before). Void Devourer: Gravity Well, Consume, Tremor, *Ravenous
  Maw* (a copy of Consume; Tremor before).
- **Hag's Hex** (`Ability.Haghex`, all party, Vulnerable and Weaken at 50% each) replaces `hex_all`, which needs the High
  Witch's `State.Phase.Two`.
- **Vigil:** no brain uses a non-ult heal "when an ally is below half" or aims at the lowest HP, and `cleanse` removes every
  debuff: Vigil heals all allies 10% and cleanses them, on a pattern.
- **Consume:** no effect heals by part of the damage (`vampire_heal` is a flat 15 HP). Consume and Ravenous Maw carry
  `Ability.Type.Consume`; its `Event.Ability.Used.Consume` triggers the passive **Gorge** (`Ability.Passive.Gorge`, 10% of max HP).
- **Gravity Well** has no damage: its delay rides an empty instant effect (`effects/gravity_pull.tres`) that always lands.
- **Resound** fires on `Event.Damage.Taken.Weakness` (review fix): on every hit it answered the party's counters (Thorn Mail,
  Retaliate, Thornbark, Corrupted Thorns) until the chain cap of 10. The party's counters are Physical and the Echo is weak to
  Ice, so a chain stops after one exchange.
- **Drops obey the card pool** (review fix): three elite drops are collectible (Golden Idol, Witch's Eye, Vampire Fang). A drop
  outside the run's card pool becomes an item-room item (`Pool.Treasure`, not held or seen) from the pool, else a food item
  (`Pool.Food`), else nothing; only that case draws more from the drop stream, so runs without a pool are unchanged
  (`RunController._pooled_drop`; spec `card-collection` 2.5).
- **Food drops:** the regulars drop `rations`, `honey_cake`, `roast_haunch` or `hearty_feast` (the `Pool.Food` items).
- **Tags** beyond Q4's count, for the above: `Ability.Furybreath`, `Ability.Bitterboil`, `Ability.Ravenousmaw`, `Ability.Haghex`,
  `Ability.Passive.Gorge`, `Ability.Type.Consume`, `Event.Ability.Used.Consume`, `Event.Damage.Taken.Weakness`.

## 8. Out of scope

New combat mechanics, a separate elite room type, paying elites more XP or gems, and new items.
