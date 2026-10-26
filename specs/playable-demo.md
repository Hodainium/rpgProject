# Spec: playable-demo (slice 1d)

Status: 📝 Spec written, approved (D1–D6 as recommended, 2026-10-26) · Roadmap: slice 1d · Date: 2026-10-26
Design intent: `specs/design/game-design.md` sections 1, 3 and 6. Builds on `specs/game-skeleton.md` (run layer,
`RunController`, `GameMain`), `specs/dev-tools.md` (console, script runner, seed report, validator),
`specs/animation-sets.md` (cube unit views), `specs/content-pass.md` (the content base: statuses, affinities, nine
enemies, the Golem and the Lich). Open notes it closes: `specs/dev-tools.md` "Remaining work" (the release-build
check), `specs/content-pass.md` 8 (demo content with a row delay), `specs/ult-interrupts.md` 6 / content-pass 3.8
(ult balance, "design break 1d").

The content lines below were approved as proposed (D4, 2026-10-26). Magnitudes are starting values as a designer types them; once
built they live in the content files, which become the source of truth, and this spec keeps pointers only.

## 1. Purpose & enterprise mapping
A short run **playable start to finish by someone who isn't us**, to show people, and the first real test of the dev
tools on a whole run instead of single rooms. Today `content/demo/` already has every piece (two characters, nine
enemies, two bosses, 65 items, 14 armor pieces, 8 rooms, 2 events, a one-floor run), but no run that strings them
into an arc with a beginning, a rising difficulty and an ending. Four parts:

1. **The demo run** `demo.run.descent`: two floors, **The Cellar** (boss: the Golem) then **The Crypt** (boss: the
   Lich), with battles, events, a treasure room and a shop on each floor (D1). About 15–25 minutes.
2. **The demo shell** (your `presentation/demo/`): a title screen with the run picker, party select with each
   character's kit, a floor title card at the stairs, item and armor descriptions where you pick them, a run summary
   at the end, play again. Placeholder-grade text UI, no new art.
3. **Balance by measurement:** a headless **auto-play report** (the seed report grown with `--play`) that plays
   hundreds of seeds on a fixed policy and reports win rate, where runs die and the party's HP entering each boss.
   It informs your tuning in the design break; no test ever asserts a balance number.
4. **Dev-tool fixes** found by building the demo (3.5). One is already known: a content root may hold only one
   `RunStructure`, so the new run can't sit next to `demo.run.one_floor`.

Plus a **Windows export** (D5) so the demo runs without the editor, which also closes the dev-tools release-build check.

**Enterprise mapping: none at runtime** (client-only, local mode; no service, queue, broker or cache). Indirect:
- The demo is the **traffic generator** of every later slice: slice 2 issues its floor seeds, 2b uploads its run
  log, 3 and 4a verify its battles and floors, 4b aggregates its picks, 8 drives it with Locust. A two-floor run is the
  smallest one that exercises the stairs (`POST /runs/{id}/floors/{n}`), so slice 2 is tested on real content.
- The content hash changes, so `ruleset_version` changes (expected; no server yet).
- **No wire change:** no `Rpg.Contracts` record, no snapshot field, no log entry type. Only content and the run-layer
  entry point (which run to start) change.

Out of scope: local saves and resume (slice 2b), hub, cards and unlocks (slice 5), completion marks and gems, walking
inside rooms, new mechanics or battle hooks, new art (icons, models, VFX beyond what the cube views do), audio
mixing, localisation, a Linux or web export.

## 2. Sequence flow
No server. Everything below runs in the Godot client in local mode.

### 2.1 Playing the demo (player's view)
```
title screen (menu.tscn)
  run picker: "The Descent" (default) · "Demo run" (one floor) · fixture runs only when the content root is fixtures
  party select: Warrior, Cleric (both on by default), kit lines from each character's abilities and description
  seed: blank = random code; "Random" button; the seed code shows on every later screen
  Start → GameMain.start_run(character_ids, seed_text, run_id)
floor 0 "The Cellar": title card → map → rooms (battle / event / treasure / shop) → boss room (Golem)
  boss cleared → "Take the stairs" (map_view NextFloor, existing) → RunController.next_floor()
floor 1 "The Crypt": title card → map → … → boss room (Lich, three phases)
  Lich dead → run Won (is_last_floor) → run_end_view: summary + Play again (same seed) / New run / Menu
party wiped anywhere → run Lost → run_end_view with the floor, room and encounter where it ended
```

### 2.2 Starting a run with several run structures (system fix, 3.5 F1)
```
GameMain.start_run(ids, seed_text, run_id = "")
  → RunController.start_run(content, ids, seed_text, run_id)
      run_id given     → content.runs[run_id], or stop("unknown run 'x'")
      run_id empty     → the only run if there is one; else the run flagged default (RunStructure.default_run);
                         else stop("several runs and none is default: a, b")      (sorted ids, deterministic)
      run_log[0] = {"type": "start_run", "seed", "party", "run": run_id}           ("run" only when several exist)
console: new <characters> [seed] [run=<id>]   (parity with the menu picker)
```
`run_hash()` already covers `run_structure_id`. With one run in the root (fixtures) nothing changes: no log field,
same hash, `run_scripted.json` byte-identical.

### 2.3 Auto-play report (dev tool, 3.5 F2)
```
seed_report.tscn -- --play --count 300 [--run demo.run.descent] [--party a,b] [--from-seed 1] --out report.json
  for each seed (sorted, sequential, one process):
    RunController.start_run(...) → RunPlayer.play(run)            (the test policy, moved to game/dev/, unchanged)
    record: status, floor reached, cell/room/encounter it ended in, party HP% and MP% entering each boss room,
            battles fought, turns per battle, coins spent, items held at the end, run hash
  aggregate → JSON + a text table: win rate, death histogram by encounter id, median boss-entry HP%, median turns
            per battle per encounter, coins per floor
console: autorun [max_steps]   (plays the rest of the current run on the same policy; prints status and floor)
```
The report is **information for your tuning**. Its numbers live only in the report file; tests assert its shape and
determinism on fixtures, never a rate.

### 2.3b Chaos policy: bad and illegal moves (dev tool, 3.5 F5)
The auto policy plays sensibly, so it never stresses the decisions a real player gets wrong. The chaos policy does.
```
seed_report.tscn -- --play --policy chaos [--illegal 20] --count 500 ... --out report.json
console: autorun [max_steps] [policy=chaos]
each party decision (ChaosController, a PresentationGate-free controller like ScriptedController):
  policy RNG = RunSeeds stream "dev/chaos/<battle seq>"            (its own stream; never the battle RNG)
  with chance --illegal %: submit an illegal move, one of
      unaffordable skill (MP or charge), dead or missing target, ally-only ability on an enemy (and the reverse),
      ult by a Controlled unit, an ability the unit doesn't have
    → expect: refused, no state change, no log entry, no RNG draw; the policy then picks a legal move
  else: uniform over every legal (ability, target) pair, good or bad
      (hitting a drain or resist, healing a full-HP ally, cleansing nothing, an ult on the last weak enemy)
  at each ult window: press a random charged ult with chance 50%, random target (wasted ults included)
invariant checks (InvariantChecker, after every action, ult and trigger drain):
  no runner error · HP in [0, max_hp], MP in [0, max_mp], energy in [0, max_energy], toughness in [0, max] ·
  dead units hold no statuses · the battle ends within the turn cap (existing runner limit)
after every battle: replay the recorded request in the headless runner → Verified with the same final hash
first violation → report entry {seed, floor, battle seq, action index, invariant, details} and the request plus its
  trace saved next to the report (`trace_main --diff` finds the divergent action for a replay failure)
```
A violation is a **bug report**, never tuned away in content. The chaos stream is dev-only: it never reaches the run
log, so a chaos run's log replays like any other.

### 2.4 Authoring loop (unchanged tools, now on a whole run)
Builder scene `game/tools/build_demo_run.tscn` adds the approved new files to `content/demo/` (never overwrites, like
the earlier builders; run with your go-ahead). Then: `sync_tags.tscn --add-missing` for the new chapter tags →
`validate_content.tscn` → `seed_report.tscn --floor 0/1` (map shapes) → `seed_report.tscn --play` (balance) → play it in
the window → tune → repeat. Every friction in that loop becomes a row in 3.5.

## 3. Data contracts
**No wire contracts change.** No new `Rpg.Contracts` records, RabbitMQ queues, Redpanda topics or Redis keys: N/A,
client-only slice. The contracts here are Godot content types and the run-layer entry point.

### 3.1 System changes (`game/`, `game/dev/`, `game/tools/`)
| Change | Where | Notes |
|---|---|---|
| `RunStructure.default_run: bool = false` | `game/defs/run_structure.gd` | Picks the run when several exist and none is named; validator error if two are default |
| `RunController.start_run(..., run_id: StringName = &"")` | `game/run_controller.gd` | 2.2; the `"run"` log field only when the root holds several runs |
| `GameMain.start_run(ids, seed_text, run_id)`, `GameMain.runs()` (sorted, for the picker) | `game/game_main.gd` | |
| `RunPlayer` moved `tests/game/` → `game/dev/run_player.gd` | | Policy unchanged; tests keep using it |
| `run=<id>` on `new`; new command `autorun [max_steps]` | `game/dev/commands/` | parity test entries |
| `--play` mode, `--policy auto\|chaos`, `--illegal <percent>` | `game/tools/seed_report.gd` | 2.3, 2.3b |
| `ChaosController`, `InvariantChecker` | `game/dev/` | 2.3b; the checker reads state only, never changes it |
| `RunController.run_summary() -> Dictionary` | `game/run_controller.gd` | Read-only, derived from `run_log` and state: battles won, enemies defeated, items and armor picked up, coins earned and spent, floors cleared, ended in (room, encounter). Used by `run_end_view` and the report |
| Export preset `Windows Desktop` | `client-godot/export_presets.cfg` | Release build to `build/demo/` (gitignored); excludes `tests/`, `game/dev/scripts/`; D5 |

### 3.2 Tags (your `godot_gas/` registry)
`Chapter.Cellar`, `Chapter.Crypt` (added through `sync_tags.tscn --add-missing`). `Chapter.Demo` stays the shared demo
pool (rooms and early encounters).

### 3.3 The run (proposal; ids `demo.<kind>.<id>`, new files made by the builder)
| Asset | Proposal |
|---|---|
| `demo.run.descent` "The Descent" | Two floor slots: [Cellar], [Crypt]; `default_run = true`; same fallback item and equipment slots as `one_floor` |
| `demo.chapter.cellar` (existing) | Boss query `Encounter.Boss` + `Chapter.Cellar` (edit, 3.4); rooms and encounters unchanged (`Chapter.Demo`) |
| `demo.chapter.crypt` "The Crypt" | Rooms: any of `Chapter.Demo`, `Chapter.Crypt`, ignoring `Room.Type.Boss` unless `Chapter.Crypt`; encounters `Chapter.Crypt`, not boss; boss `Encounter.Boss` + `Chapter.Crypt`; events `Event.Demo`; floor rules `demo.rules.crypt`; scaling `demo.scaling.basic` (its depth-2 effect applies) |
| `demo.rules.crypt` | Like `small` with `base_rooms` 6 and `max_rooms` 9 (one more battle than the Cellar) |
| `demo.room.sanctum` "Lich's sanctum" | `Room.Type.Boss`, `Chapter.Crypt`, the same placements as the Golem's den (boss mode) |
| Crypt encounters (`Chapter.Crypt`) | `demo.encounter.crypt_guard` Knight + Shaman (Stun, heals); `demo.encounter.wisp_choir` three Frost Wisps (Freeze, Ice drain); `demo.encounter.ember_watch` Fire Imp + Knight elite (variant `elite`); `demo.encounter.bound_dead` Bog Toad + Shaman with an Entangle row with `delay` (closes content-pass 8) |
| New events (`Event.Demo`, both floors) | `demo.event.cursed_chest`: take a rare item from `Pool.Treasure` and every member takes 20% max HP damage, or leave · `demo.event.wounded_knight`: pay 15 coins (coins ≥ 15) for an armor piece, or fight him (`start_encounter` Knight elite) for it, or leave · `demo.event.librarian`: two pages, read (go to page 2: pick one of two fixed items) or leave |

The Golem becomes the Cellar's only boss and the Lich the Crypt's. No new enemy, ability or item: the content pass
already covers the mechanics; the demo strings them together.

### 3.4 Edits to your existing files (each shown as `old → new` before it is made; D3)
| File | Change | Used by |
|---|---|---|
| `content/demo/encounters/golem.tres` | tags `Encounter.Boss, Chapter.Demo` → `Encounter.Boss, Chapter.Cellar` | Cellar boss query |
| `content/demo/encounters/lich.tres` | tags `Encounter.Boss, Chapter.Demo` → `Encounter.Boss, Chapter.Crypt` | Crypt boss query |
| `content/demo/rooms/boss.tres` | tags `Room.Type.Boss, Chapter.Demo` → `Room.Type.Boss, Chapter.Cellar` | keeps the Golem's den out of the Crypt |
| `content/demo/chapters/cellar.tres` | boss query `Encounter.Boss, Chapter.Demo` → `Encounter.Boss, Chapter.Cellar`; room query adds `Chapter.Cellar` (any of) | both runs |
| `content/demo/runs/one_floor.tres` | none (it keeps working; its boss is now always the Golem) | |
| `presentation/demo/menu.*`, `run_end_view.*`, `map_view.*`, `pickup_panel.*` | 3.6 | the shell |

Consequence, accepted unless you say otherwise: the one-floor run no longer rolls the Lich as its boss.

### 3.5 Dev-tool fixes (the list grows while building; each row gets a test)
| # | Limit or wrong assumption | Fix | Test |
|---|---|---|---|
| F1 | One `RunStructure` per content root (`RunController._begin_run` stops otherwise) | 2.2: run id, `default_run`, picker, `new run=` | `test_run_picker` (fixture root with a second run in `user://`), `run_scripted.json` unchanged |
| F2 | No whole-run balance view; `RunPlayer` lives in `tests/` | 2.3: `seed_report --play`, `autorun`, `RunPlayer` in `game/dev/` | `test_seed_report_play` (fixtures, 5 seeds, deterministic JSON, golden `seed_report_play.json`), `test_autorun_command` |
| F3 | Validator doesn't check a run end to end (a floor slot whose chapter has no boss room or no boss encounter only fails at generation) | Rule `run_floor_unplayable` (error): for each floor slot and chapter, the boss room query, boss encounter query and the special-room tags each match ≥ 1 | broken fixture `runs/no_boss_floor.tres` |
| F5 | Auto-play never makes bad or illegal moves, so nothing stresses wrong decisions; nothing checks battle invariants or record → replay on whole runs | 2.3b: chaos policy, illegal moves, invariant checker, replay of every battle | `test_chaos_policy` (fixtures, 5 seeds, all checks on, deterministic report), one `test_illegal_<case>` per illegal move (refused, no state change, no log entry, no RNG draw) |
| F4 | Release-build behaviour of `Dev` never checked (dev-tools manual checklist) | Checked on the D5 export; recorded as done in `specs/dev-tools.md` | manual, once per export |
| F… | Found while building | Added here and in `/sync-spec` | |

### 3.6 Shell (your `presentation/demo/`; D3)
- `menu`: run picker (`GameMain.runs()`), party toggles with each character's ability names and `description`,
  the seed field (existing).
- Floor title card: a label over the map for two seconds on `floor_entered` ("Floor 2 · The Crypt").
- `pickup_panel`: the item's or armor's `description` under its name (field exists since item-pass), price in shops.
- `run_end_view`: `run_summary()` lines, the seed code, **Play again** (same seed, same party), **New run**, **Menu**.
- Battle speed toggle 1× / 2× (`Engine.time_scale` on the battle view only; presentation, never combat state; the
  gate still waits on `execute` keys, so replay is unaffected).
- Ability animations: every demo ability already moves or spins the cube (`Body` position and rotation tracks);
  where you want a **flash**, it is an extra track on your animation files, done in the design break, not here.

### 3.7 Amendment C2 (2026-10-26, D7–D10): encounter grants, rewards, armor to the inventory, rarity weights
Found while building C: an encounter couldn't change its enemies (no Ice drain on the Wisp choir), the default brain
never uses an extra skill (no Entangle with a row delay), an event fight couldn't drop anything, and event armor was
worn at once. Rarity tags existed but did nothing.
| Change | Where | Rule |
|---|---|---|
| `EncounterDefinition.grants: AbilitySet` | `combat/encounter_definition.gd` | Granted to **every** enemy of the encounter (tags, effects, abilities), after the variant (D8) |
| `EncounterSlot.grants: AbilitySet`, `EncounterSlot.brain: EnemyBrain` | `combat/encounter_slot.gd` | One enemy: its grants after the encounter's; `brain` replaces the definition's brain for that enemy |
| Battle setup | `combat/battle.gd`, `battle_unit.gd` | v2 snapshots only (run battles): read from the encounter by `encounterId` and slot number, so the verifier rebuilds them from content. **No wire change**; v1 and encounters without them build exactly as before (goldens unchanged) |
| `EncounterDefinition.rewards: Array[RunOutcome]` | `combat/encounter_definition.gd`, `game/run_controller.gd` | Applied in order after a **won** battle (rooms and event fights alike), before the room clears; logged by the battle entry they follow; gift picks draw from the existing `floor/<n>/gift/<k>` stream |
| `GiveEquipment` puts the piece in the armor inventory (D9) | `game/defs/outcomes/give_equipment.gd`, `RunController.give_equipment` | Never worn on its own; its `character` field is removed. Only a character's starting loadout is worn at run start |
| `RunStructure.rarity_weights` (typed %, stored ×100 by `Item.Rarity.*` tag) | `game/defs/run_structure.gd`, `game/floor_generator.gd`, `game/run_seeds.gd` | A pool candidate's weight is its own weight × its rarity's weight / 100 (no rarity tag: ×1). Empty = picks exactly as before (fixtures unchanged) |
| Validator | `game/dev/content_validator.gd` | grants and rewards checked like ability sets and event outcomes; `rarity_unknown` (warning) for a weight on a tag no item uses; `no_rarity` (warning) for a pooled item or piece without an `Item.Rarity.*` tag when the run has weights |

Content (your files, D10, each shown as `old → new`): tags `Item.Rarity.Uncommon` and `Item.Rarity.Legendary`; a
tier per item and armor piece (proposal table in chat, approved before editing); The Descent's weights Common 60,
Uncommon 25, Rare 12, Legendary 3; Wisp choir grants `Drain.Ice` to every wisp; Bound dead's first Toad gets an
Entangle skill with a row `delay` and a `PatternBrain` (closes content-pass 8); the knight duel rewards the Warden
Helm; the wounded knight's paid helm goes to the armor inventory.

### 3.8 Amendment C3 (2026-10-26, D11–D18): the full Descent, 10 floors, two ending routes
The demo becomes a full Isaac-shaped run, longer and harder, so wins and losses spread out and the play report and
chaos policy see far more mechanic paths. **Content values are a proposal for review (D14);** once built they live in
the content files.

**Run shape** (`demo.run.descent`; every floor ends in a boss):
| Floors | Chapter (theme) | Special rooms | Bosses (pool; seeded, never twice in a chapter) |
|---|---|---|---|
| 1–2 | The Cellar (existing) | Treasure, Shop | the Golem, **the Rat King** (new) |
| 3–4 | The Crypt (existing) | Treasure, Shop | the Lich, **the Bone Warden** (new) |
| 5–6 | **The Ember Forge** (fire, constructs) | Treasure, Shop | **the Forgemaster**, **the Brass Colossus** |
| 7–8 | **The Hollow** (flesh and blood, like Isaac's Utero) | **none** | **the Mother Heart**, **the Twin Hearts** (a two-unit boss) |
| 9 light | **The Silent Cathedral** (holy, like Isaac's Cathedral) | **none** | **the Hallowed Judge** |
| 10 light | **The Vault** (gilded, like Isaac's Chest) | **4 Treasure** rooms, a Shop | **the Collector** (final boss: mirror and per-item scaling) |
| 9 dark | **The Black Coven** (occult, like Isaac's Sheol) | **none** | **the High Witch** |
| 10 dark | **The Void** (like Isaac's Dark Room) | **3 Altar** rooms (corrupted items for max HP) | **the Nameless** (final boss: just hard, no mirror) |

**Ending route (D15):** after the floor-8 boss the player picks the route at the stairs, like Isaac's light beam and
trapdoor: the light route (Cathedral → Vault) or the dark route (Coven → Void). Floor 10 follows the route of floor 9.

Item sources where there are no item rooms: every boss encounter **rewards** one `Pool.Boss` item (3.7 rewards), and
events still appear. The Vault's treasure rooms draw from `Pool.Treasure` and a new `Pool.Vault`.

**System (two battle hooks and one generator option; no wire change):**
| Hook | Where | Rule |
|---|---|---|
| **H9 Mirror** (D11): `EnemyDefinition.mirror_party_items: bool` | `combat/battle.gd` (v2 setup) | The boss is also granted the `grants` AbilitySet of every **item and armor piece the party holds** (from the snapshot's `items`, `equipmentIds`, `useSlots`; party slot order, then the order listed). Usable items' use abilities are not copied. A party-wide item applies to the boss's side. A passive the boss already has is skipped, as for party members |
| **H10 Per-item scaling** (D11): `EnemyDefinition.per_item_effect: GameplayEffect` | same | Applied once per item and armor piece held (the same count as H9), after floor scaling. The effect must stack (validator error `per_item_not_stacking`) |
| **Boss rotation** (D12): `ChapterDefinition.boss_rotation: bool` (default false) | `game/floor_generator.gd` | The chapter's boss candidates (sorted ids) are shuffled once per run by the stream `chapter/<chapter id>/bosses`; the chapter's floor *k* (counted over the run's floor slots) takes entry *k* mod *n*. Stateless: nothing new in the run state or the run hash. Off = today's pick, so fixtures don't change |
| **Route choice** (D15): `FloorSlot.pick: RANDOM \| CHOICE \| ROUTE` (default RANDOM), `ChapterDefinition.route_tag` (`Route.Light`, `Route.Dark`) | `game/defs/floor_slot.gd`, `game/run_controller.gd`, `game/dev/seed_report.gd` | RANDOM: today's seeded pick (`floor/<n>/chapter`). CHOICE: `next_floor(chapter_id)` names one of the slot's chapters; the run log's `next_floor` entry gets `"chapter"` (only on CHOICE slots, so old logs are unchanged); no draw. ROUTE: the slot's chapter whose `route_tag` matches the previous floor's chapter; no draw. The auto and chaos policies pick a CHOICE from their own stream `dev/route/<floor>`, so reports cover both routes. The seed report takes `--route <chapter id>` (default the first) |
| **Price in max HP** (D17): `RoomPlacement.price_item: ItemDefinition`, `ItemDefinition.stackable: bool` | `game/defs/`, `game/floor_generator.gd`, `RunController.take` | A pedestal with a price item costs no coins: taking it gives the buyer the price item too (a curse such as Void Scar, −10% max HP), even past their item capacity. A stackable item may be held several times; each copy's effects apply in battle (its passives once). Logged as a `buy`; the items travel in the snapshot's existing `items` list (no wire change) |
| Validator | `game/dev/content_validator.gd` | `boss_rotation_short` (warning): a rotating chapter with fewer bosses than its floors in a run; `per_item_not_stacking` (error); `choice_slot_single` (warning): a CHOICE slot with one chapter; `route_unmatched` (error): a ROUTE slot with no chapter for a route its previous slot can give; `price_item_not_stackable` (warning) |

Both hooks read only the snapshot and content, so the verifier rebuilds the same boss; fixtures and goldens without
them are byte-identical. A new combat golden `mirror-seed-9` (a fixture mirror boss against a fixture party holding
items and armor) pins H9 and H10.

**Depth scaling** `demo.scaling.descent` (typed %, enemies only; replaces `basic` on the Cellar and the Crypt, so
`one_floor` also uses floor 1's step): floors 1–10 HP +0/10/20/35/50/65/80/100/120/140, ATK
+10/20/30/40/50/60/70/85/100/115, DEF +0/10/15/20/30/40/50/60/70/80.

**New enemies** (stats as typed; for scale, the Warrior has 1000 HP / 500 ATK and the Cleric 800 HP / 350 ATK; the
Golem has 2000 HP and the Lich 4800):
| Enemy | Chapter | HP / ATK / DEF / SPD / toughness | Affinities | Moves and brain |
|---|---|---|---|---|
| Rat King (boss) | Cellar | 2400 / 300 / 180 / 115 / 120 | weak Fire | Gnaw (Physical, Bleed 60%), Swarm (all, Physical); at 50% a Frenzy phase (Haste, Swarm unlocked); PatternBrain |
| Bone Warden (boss) | Crypt | 3600 / 280 / 320 / 85 / 200 | resist Physical, weak Fire, Immune.Control | Shield Bash (Stun 40%), Bone Wall (Defense Up and Taunt); at 40% a Ward phase; ult Ossuary (all, Physical) |
| Cinder Hound | Forge | 380 / 300 / 90 / 130 / 40 | resist Fire, weak Ice | Searing Bite (Fire, Burn) |
| Anvil Guard | Forge | 700 / 260 / 300 / 80 / 120 | drain Fire, weak Ice | Hammer Down (Physical, heavy toughness damage), Brace (Defense Up) |
| Smelter | Forge | 420 / 200 / 120 / 105 / 40 | weak Physical | Stoke (allies' ATK up), Slag (Fire, Slow); PatternBrain |
| Forgemaster (boss) | Forge | 5200 / 340 / 240 / 100 / 180 | resist Fire, weak Ice | Hammer, Fire Bolt; at 60% Molten Armor (drain Fire, Defense Up); at 30% Meltdown (all, Fire, Burn); TacticalBrain ult |
| Brass Colossus (boss) | Forge | 6400 / 360 / 360 / 75 / 300 | weak Ice and Physical | Piston (Physical), ult Overheat (all, Fire); breaking it is the way in (toughness 300) |
| Leech | Hollow | 360 / 260 / 80 / 120 / 30 | drain Physical, weak Fire | Latch (Physical, Bleed) |
| Gutter Maw | Hollow | 900 / 300 / 140 / 80 / 60 | weak Ice | Bile (2 stacks of Poison), Devour (Physical, heavy) |
| Vein Weaver | Hollow | 440 / 240 / 100 / 115 / 40 | resist Ice, weak Fire | Entangle Lash (row delay), Hemorrhage (all, Bleed 50%); PatternBrain |
| Mother Heart (boss) | Hollow | 7000 / 320 / 220 / 90 / 200 | weak Fire | Pulse (all, Physical), Regen on itself; at 50% Bleeding Out (all, Bleed and Vulnerable); ult Systole |
| Twin Hearts (boss pair) | Hollow | 2 × 3600 / 340 / 200 / 100 / 120 | one weak Fire, one weak Ice | Pulse, Mend on the other; ult when the other is below 50% (TacticalBrain) |
| Choir Seraph | Cathedral | 520 / 260 / 160 / 120 / 60 | resist Ice | Hymn (heal allies, Regen), Ward on an ally |
| Penitent Knight | Cathedral | 900 / 360 / 340 / 85 / 120 | resist Physical, Immune.Control | Shield Bash (Stun), Provoke (Taunt) |
| Hallowed Judge (boss) | Cathedral | 9000 / 400 / 300 / 105 / 240 | resist Fire, weak Physical | Smite, Dispel (party buffs), Purify on itself; phases at 60% and 25%; ult Judgement (single, Doom-like) |
| Gilded Mimic | Vault | 600 / 420 / 150 / 125 / 60 | weak Physical | Snap (Physical, high crit) |
| Vault Sentry | Vault | 1100 / 360 / 380 / 80 / 160 | drain Ice, weak Fire | Lockdown (Freeze 50%), Spiked Plating (strikes back when hit) |
| The Collector (final boss) | Vault | 9000 / 380 / 300 / 110 / 260; **mirror**; **+5% HP, ATK and DEF per item held** | weak Physical | Appraise (Vulnerable), Repossess (Dispel), Gilded Ray (all, Ice); at 50% a Hoard phase (Ward and Haste); ult Liquidate (single, huge) |

Encounters (normal ones tagged `Chapter.<X>`): Forge 4 (hound pack, anvil and smelter, mixed, elite anvil), Hollow 4
(leeches, maw and weaver, mixed, elite maw), Cathedral 3 (seraph and knight, two knights and a seraph, elite knight),
Vault 3 (mimics, sentry and mimic, elite sentry). Boss rooms: one per new chapter (the Golem's den's placements); the
Rat King and the Bone Warden use their chapter's existing boss room.

**New items (24; tier and pools):**
| Chapter | Items |
|---|---|
| Forge (Pool.Treasure, Pool.Shop) | Tempered Edge (Rare: +15% ATK, +20% toughness damage), Bellows (Rare: +15 ult charge on a break), Quench Flask (Common, usable: cleanse the party, 150 Ice to all enemies), Ember Heart (Epic: +20% Fire damage), Slag Plate (armor, Rare: +80 DEF, resist Fire, −6 SPD), Molten Core (Legendary, Pool.Boss: Fire hits Burn the target) |
| Hollow (Pool.Boss, events) | Blood Pact (Epic: +25% damage dealt, Bleed yourself at battle start), Heartstring (Rare: heal 10% max HP on a kill), Clotting Salve (Common, usable: cleanse and Regen one ally), Scar Ring (Epic: resist Physical), Vein Cloak (armor, Rare: +150 max HP, immune to Bleed), Second Heart (Legendary, usable, consumable: revive an ally at 50% HP; an automatic once-per-run revive would need a new hook) |
| Cathedral (Pool.Boss, Pool.Vault) | Halo (Epic: Ward at battle start, +10% healing given), Censer (Rare: Regen on the party at battle start), Relic Shard (Rare: +12% crit rate), Holy Water (Common, usable: cleanse all, heal 20%), Vestment (armor, Epic: +60 DEF, +40 max MP), Seraph Wing (Legendary: +12 SPD for the party) |
| Vault (Pool.Vault, Pool.Treasure) | Gilded Idol (Common: 25 coins on pickup), Ledger (Rare: +2 coins per room cleared), Golden Fleece (Epic: +20% max HP), Appraiser's Loupe (Rare: +20% weakness damage), Crown (armor, Legendary: +10% ATK, DEF and SPD), Mimic Tooth (Epic: crits Bleed the target and heal you 30 HP) |

**Rarity (D16):** four tiers Common, Rare, Epic, Legendary. Today's tiers shift up: Uncommon → Rare, Rare → Epic
(49 files, one tag each); `Item.Rarity.Uncommon` leaves the registry and `Item.Rarity.Epic` joins it. The Descent's
weights: Common 60, Rare 25, Epic 12, Legendary 3.

**The dark route's enemies:**
| Enemy | Chapter | HP / ATK / DEF / SPD / toughness | Affinities | Moves and brain |
|---|---|---|---|---|
| Cultist | Coven | 480 / 300 / 120 / 115 / 40 | weak Physical | Hex (Vulnerable), Curse (Weaken); PatternBrain |
| Bound Demon | Coven | 1200 / 420 / 240 / 90 / 140 | drain Fire, weak Ice | Hellfire (Fire, Burn), Rend (Physical, Bleed) |
| High Witch (boss) | Coven | 9000 / 400 / 260 / 110 / 220 | resist Ice, weak Fire | Hex All, Dispel, Doom; phases at 60% (Ward each turn) and 25% (Haste, Hellfire unlocked); TacticalBrain ult Black Mass (all, Ice) |
| Void Wraith | Void | 800 / 440 / 160 / 130 / 60 | drain Ice, resist Physical | Chill Touch (Ice, Freeze 40%), Fade (Defense Up) |
| Abyssal Hulk | Void | 1800 / 480 / 360 / 80 / 200 | weak Fire | Crush (Physical, heavy toughness), Quake (all) |
| The Nameless (final boss) | Void | 16000 / 460 / 340 / 115 / 300 (no mirror) | resist Physical and Ice, weak Fire | Unmake (single, huge), Entropy (all, Bleed and Slow), Silence (Stun 50%); phases at 66% and 33%, each clearing its debuffs; ult Oblivion (all, huge) |

Encounters: Coven 3 (cultists, demon and cultist, elite demon), Void 3 (wraiths, hulk and wraith, elite hulk). Boss
rooms: one per chapter. **The Void's altars:** `Room.Type.Altar` (a new special room type), two pedestals each,
`Pool.Void`, price item **Void Scar** (Common, `Item.Curse`, stackable: −10% max HP).

**Corrupted items (D18; 15, `Pool.Void`, `Item.Corrupted`, the same tier as the original):** stronger flipsides of
all five legendaries and ten epics, each with a drawback.
| Original | Corrupted flipside |
|---|---|
| Executioner's Seal | crits trigger a 90% ATK follow-up; you take 10% more damage |
| Leech Hide | drain Physical and Ice; weak to Fire |
| Salamander Heart | drain Fire, +20% Fire damage; weak to Ice and Physical |
| Guardian Totem | the party +50 DEF; the party −8 SPD |
| Duelist's Band (armor) | crits trigger a 60% ATK follow-up; −10% max HP |
| Berserker Brand | +40% damage dealt; +20% damage taken |
| Bounty Mark | on a kill +40 ult charge and heal 120 HP; −15% healing received |
| Breaker's Oath | on a break +40 ult charge and +30% ATK for 2 turns; −20% toughness damage |
| Hunter's Mark | weakness hits trigger an 80% ATK follow-up; −10% crit rate |
| Overcharge Coil | after each ult +40 ult charge; −30 max MP (an item can't change an ult's cost) |
| Predator's Fang | +50% damage to Broken enemies; −15% damage to the rest |
| Vampire Fang | heal 35 HP per hit dealt; −20% max HP |
| Thorn Mail | strike back for 150 when hit; −40 DEF |
| War Drum | the party +12 SPD; the party −10% DEF |
| Frost Lantern | Ice hits Freeze 50% of the time; you become weak to Fire |

Edits to your existing files for C3 (each shown `old → new` when made): `runs/descent.tres` (ten floor slots;
`one_floor` unchanged), `chapters/cellar.tres` and `chapters/crypt.tres` (`boss_rotation = true`, scaling `basic` →
`descent`), the Golem and Lich encounters (a `Pool.Boss` reward each), the 49 rarity retags, and the tag registry
(`Item.Rarity.Uncommon` removed; new tags added through `sync_tags --add-missing`).

## 4. Failure modes
Server failure scenarios (root `CLAUDE.md` 1–7): **none apply** (no server, no wire change). What this slice
protects is that **adding a second run and a second floor doesn't change any existing replay**, which scenario 5
(tampered log → 2002) and the later run verifier (4a) rely on. A battle mismatch stays a verdict (`Rejected`,
`errorCode` 2002, a `MismatchReason`); no new reason.

| Failure | Behaviour | Test |
|---|---|---|
| Fixture root (one run) replayed after F1 | Same log, same run hash: the `"run"` field is written only when several runs exist | `run_scripted.json` golden unchanged |
| Several runs, none named, none default | `stop("several runs and none is default: …")`, run never starts, end view shows it | `test_run_picker` |
| Two runs flagged default | Validator error `run_default_twice` | broken fixture |
| Unknown `run=` id | Command fails, names the id; menu can't offer it | `test_run_picker` |
| A floor that can't generate (no boss room for its chapter) | Validator error before play (F3); at generation the existing runner error | broken fixture |
| Second floor's battles draw from the wrong stream | Can't: floor seeds are `floor/<n>/…` (`RunSeeds`), unchanged | existing `test_generation`, plus `test_demo_run_two_floors` checks floor 1 differs from floor 0 for the same seed |
| Report differs between two runs of the same seeds | Not allowed: one process, sequential seeds, no wall-clock in the JSON | `test_seed_report_play` runs it twice and compares |
| Illegal move submitted (chaos or a player's UI bug) | Refused: no state change, no log entry, no RNG draw; the decision is asked again | `test_illegal_<case>` |
| Illegal move found in a log on replay | 2002 `IllegalAbility` / `InvalidTarget` (existing reasons) | existing tampered goldens |
| Strange but legal battle (wasted ults, heals on full HP, drain hits) | Replays Verified with the same hash | `test_chaos_policy` replays every battle |
| Chaos policy changes the battle's RNG | Can't: own `dev/chaos/<seq>` stream; checked by replaying without the policy | `test_chaos_policy` |
| Speed toggle changes combat | Can't: `time_scale` affects presentation; combat awaits only the gate | `test_demo_run_two_floors` headless (no view) vs a scripted window run with 2× give the same run hash (manual, once) |
| Cursed chest's 20% damage on a dead or low member | Existing outcome rules (`apply_party_effect` skips the dead unless `include_dead`; whether it can kill is pinned as built, not changed here) | `test_demo_events` pins the built rule, direction only |
| Encounter grants or a slot brain change replays | Read from content by encounter id and slot; the verifier builds the same units | `test_encounter_grants_replay` (record → replay Verified), existing goldens unchanged |
| Rewards on a lost battle | Never applied | `test_encounter_rewards` |
| Rarity weights change existing pools | Only when set; empty weights use the old draw | `test_rarity_weights` (fixtures: same picks without weights; with weights the draw counts follow them over many seeds) |
| Export ships the console | `Dev` inert in release (dev-tools spec) | F4 manual check |

## 5. Observability
N/A: client-only slice, no service runs. Local signals: the auto-play report (2.3), the validator report, the script
runner JSON, `run_summary()` on the end screen. Prometheus metrics for runs and floors start with slice 2 and 6
(never per-item or per-encounter labels).

## 6. Test plan
System tests stay on `tests/fixtures/` (fixtures gain nothing but a second run created in `user://` by the test), so
existing fixtures and goldens stay byte-identical.

**System tests:** `test_run_picker` (one run, several with a default, several without, unknown id, two defaults),
`test_seed_report_play` (+ golden `tests/fixtures/golden/game/seed_report_play.json`), `test_autorun_command`,
`test_run_summary` (fixture scripted run: counts match its log), `test_chaos_policy` and the `test_illegal_<case>`
tests (F5), `test_invariant_checker` (a dev effect pushes HP past max in a fixture battle → the checker reports it), parity entries for `new run=` and `autorun` in
`test_tool_parity`, the validator broken fixtures `runs/no_boss_floor.tres` and `runs/two_defaults/`.

**Demo content tests** (`tests/game/test_demo_run.gd`, reads `content/demo/`, direction only, never tuned numbers):
- `test_demo_run_two_floors`: `demo.run.descent` is the default; floor 0 is the Cellar with the Golem as boss, floor
  1 the Crypt with the Lich; each floor has a treasure room and a shop; seeds 1–20 all generate.
- `test_demo_run_completes`: `RunPlayer` on seeds 1–10 always ends (Won or Lost, never a runner error or the step
  cap), and the stairs are taken on every run that clears the Golem.
- `test_demo_events`: each new event's choices are enabled under their conditions and do what the text says
  (direction: coins go down, an item arrives, an encounter starts).
- `test_demo_crypt_encounters`: each Crypt encounter is reachable and uses its mechanic (Stun, Freeze, Ice drain, the
  Entangle delay pushes the target's next turn back).
- `test_content_valid`: 0 errors.

**Golden vectors:** no new combat golden (no battle rule changes). `seed_report_play.json` (fixtures) pins the
report's shape and determinism. A recorded demo run is **not** a golden (your tuning would break it daily); the slice
2 spec decides whether the server tests want one.

**Manual (once, before calling the slice done):** play `The Descent` start to finish in the window, win and lose
once each; the exported build starts, plays a floor, and has no console (F4).

`dotnet build` / `dotnet test` green. Both suites pass before the slice counts as done. Headless Godot always with
`--quit-after` and a timeout.

## 7. Implementation order
One uncommitted change set per step, suites green at each:
A. F1 run picker (system + `new run=` + tests), `run_summary()`, F3 validator rule.
B. F2: move `RunPlayer`, `seed_report --play`, `autorun`, tests and the report golden.
B2. F5: illegal-move tests first (they pin how the battle refuses today; a crash found here is fixed in `combat/`
   with its test), then `ChaosController`, `InvariantChecker`, `--policy chaos`; a first chaos report on the demo.
C. Your files, after approval: tags, the 3.4 edits (`old → new`), then `build_demo_run.tscn` for the new content;
   `test_demo_run.gd`. First `--play` report shared with you.
C3. 3.8: H9 mirror, H10 per-item scaling, boss rotation, validator rules, the `mirror-seed-9` golden and system tests
   (fixtures); then the content builder (`build_full_descent.tscn`), the edits to your files, demo tests, and a play
   and chaos report on the ten-floor run. Step D (screens) comes after C3.
C2. 3.7: system first (encounter grants, slot brain, rewards, armor to inventory, rarity weights, validator, tests),
   then your files after the rarity table is approved.
D. Shell (3.6), each file shown as a diff.
E. Export preset, `build/` in `.gitignore`, F4 check; then the design break: your tuning on the report.
F. `/sync-spec playable-demo`, roadmap ✅, root `CLAUDE.md` table (`content/demo/` now a two-floor run), the
   dev-tools checklist line.

## 8. Later
- Local saves and resume (2b), a hub and unlocks (5), completion marks and gems.
- More floors and chapters; Delirium-style mixed floors (`rooms_from_any_chapter` exists, unused).
- A smarter auto-play policy (target weaknesses, use ults at breaks) if the report's dumb policy turns out too far
  from human play to be useful.
- A floor-layout grid in the inspector (`specs/dev-tools.md` Later).
- Status icons, flash VFX, music per chapter (`ChapterDefinition` has no music field yet).

## 9. Decisions
All approved as recommended (user, 2026-10-26). F5 (chaos policy, 2.3b) added the same day at the user's request. The edits to existing files (D3) are still each shown as `old → new`
when made.
- **D1 run length: two floors** (Cellar → Crypt), recommended: the smallest run with stairs, a difficulty step and
  both bosses, short enough to show. Alternatives: one floor (exists; no stairs, no arc), three floors (needs a third
  boss, which is new content beyond this slice).
- **D2 keep `demo.run.one_floor`** next to the new run, picked in the menu (F1), recommended: it stays the quick
  dev run and the existing scripts keep working. Alternative: retire it (a delete, which needs your go-ahead).
- **D3 edits to your files:** the four content edits in 3.4 and the shell files in 3.6, each shown as a diff when made.
- **D4 the content list (3.3):** four Crypt encounters, three events, one room, a chapter, floor rules and the run, as
  proposed; tell me what to cut or change.
- **D5 a Windows export** in this slice, recommended (the demo is "to show people"; it also closes F4). Needs the
  Godot 4.7.2 .NET export templates installed on your machine (Editor → Manage Export Templates).
- **D6 balance stays your call:** the report informs, no test asserts a win rate. Suggested target for the dumb
  policy, only as a starting point: it wins 20–40% of seeds and most deaths are on floor 1, so a human who reads
  weaknesses wins most runs.

Decided 2026-10-26 by the user (amendment C2, 3.7):
- **D7 rarity:** four tiers (Common, Uncommon, Rare, Legendary) that weight pool picks, the weights in content.
- **D8 encounters** can grant to every enemy and per slot, override a slot's brain, and reward a win.
- **D9 armor never auto-equips:** drops, pickups, purchases and event rewards go to the armor inventory; a
  character's starting loadout is still worn at run start.
- **D10** the demo content in 3.7, each existing file shown as `old → new` first.

Decided 2026-10-26 by the user (amendment C3, 3.8):
- **D11 the final boss mirrors the build:** it copies the passives of the party's held items and armor (H9) and
  gains stats per item held (H10).
- **D12 two bosses per 2-floor chapter,** picked by the seed and never twice in a chapter (boss rotation); the
  Cathedral and the Vault have one fixed boss each.
- **D13 the full content set** (3.8), and **C3 inside 1d,** before step D.
- **D14 (to review):** the content values in 3.8.
- **D15 two ending routes,** picked by the player at the floor-8 stairs (Cathedral → Vault, or Coven → Void).
- **D16 rarity is Common, Rare, Epic, Legendary;** today's Uncommon → Rare and Rare → Epic. Replaces D7's tier names.
- **D17 the Void sells corrupted items for max HP** (a stackable curse item as the price).
- **D18 fifteen corrupted items:** the five legendaries and ten epics; the Void's final boss doesn't mirror.
