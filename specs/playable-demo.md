# Spec: playable-demo (slice 1d)

Status: 🔨 Implementing: A–E done (E: the export, 3.12), design break next; spec synced 2026-10-26; approved (D1–D6 as recommended, 2026-10-26) · Roadmap: slice 1d · Date: 2026-10-26
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

1. **The demo run** `demo.run.descent`: first two floors, **The Cellar** then **The Crypt** (D1); grown by C3 into the
   ten-floor Descent with two ending routes (3.8 is the run shape as built).
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
  log, 3 and 4a verify its battles and floors, 4b aggregates its picks, 8 drives it with Locust. The Descent takes the
  stairs nine times (`POST /runs/{id}/floors/{n}`), so slice 2 is tested on real content.
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
title screen (presentation/demo/ui/title_menu, a UI policy screen; spec ui-framework)
  run picker: "The Descent" (default) · "Demo run" (one floor) · fixture runs only when the content root is fixtures
  party select: class cards (up to 4) with each class's kit; Details opens class_details
  seed: blank = random code; "Random" button; the seed code shows on every later screen
  Start → GameMain.start_run(character_ids, seed_text, run_id)
each floor: floor_card (Message.Run.FloorEntered) → map_panel → rooms (battle / event / treasure / shop / altar)
  → boss room; boss cleared → stairs_panel "Next floor" (the route choice at the floor-8 stairs, 3.8)
  → the Waystation rest event (3.11) → the next floor
floor 10 boss dead → run Won (is_last_floor) → run_end: summary + Play again (same seed) / New run / Menu
party wiped anywhere → run Lost → run_end with the floor, room and encounter where it ended
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

### 2.3d Sharded reports (2026-10-26)
One report can run as shards in parallel Godot processes: each shard plays a seed range with `--records` (its
per-run records and options beside the report), and `seed_report --merge <shards...> --out <report>` summarizes the
joined records exactly as one process would (tested: three shards equal one run). `game/tools/play_sharded.sh <shards>
<out> <from> <count> [options]` does both, after a parse check of the tool (a script that doesn't parse leaves Godot
idling until `--quit-after`). Balancing runs the gold standard first, alone: the smart policy with four members.
Errors (2026-10-26): every script or engine error raised while a seed plays is in that seed's record and the report's
`"errors"` (`{"seed", "error"}`, also after a merge) and its text; the tool then exits 3. `play_sharded.sh` exits
with the merged report's code, or with a shard's own code (124, 71, 70, 1) when one didn't finish.

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
| `RunController.run_summary() -> Dictionary` | `game/run_controller.gd` | Read-only, derived from `run_log` and state: battles won, enemies defeated, items and armor picked up, coins earned and spent, floors cleared, ended in (room, encounter). Used by the `run_end` screen and the report |
| Export presets `Windows Desktop` / `Dev` / `Full`, `tools/export.sh`, `tools/release_check.sh`, `game/dev/build_entry.tscn`; the GodotGAS patches (F6, 3.12 D34) | `client-godot/export_presets.cfg`, `tools/` | 3.12 (D5, D33–D35); builds in `build/` (gitignored) |

### 3.2 Tags (your `godot_gas/` registry)
`Chapter.Cellar`, `Chapter.Crypt` (added through `sync_tags.tscn --add-missing`). `Chapter.Demo` stays the shared demo
pool (rooms and early encounters).

### 3.3 The run (proposal; ids `demo.<kind>.<id>`, new files made by the builder)
The first, two-floor version of the run (step C). C3 (3.8) replaced its shape; the Crypt content below stays in it.
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
| the shell screens (`presentation/demo/ui/`: `title_menu`, `floor_card`, `pickup_panel`, `run_end`, …) | 3.6 | the shell |

Consequence, accepted unless you say otherwise: the one-floor run no longer rolls the Lich as its boss.

### 3.5 Dev-tool fixes (the list grows while building; each row gets a test)
| # | Limit or wrong assumption | Fix | Test |
|---|---|---|---|
| F1 | One `RunStructure` per content root (`RunController._begin_run` stops otherwise) | 2.2: run id, `default_run`, picker, `new run=` | `test_run_picker` (fixture root with a second run in `user://`), `run_scripted.json` unchanged |
| F2 | No whole-run balance view; `RunPlayer` lives in `tests/` | 2.3: `seed_report --play`, `autorun`, `RunPlayer` in `game/dev/` | `test_seed_report_play` (fixtures, 5 seeds, deterministic JSON, golden `seed_report_play.json`), `test_autorun_command` |
| F3 | Validator doesn't check a run end to end (a floor slot whose chapter has no boss room or no boss encounter only fails at generation) | As built: the per-chapter checks of every room role (the boss room included) and of the boss and normal encounter queries, errors `empty_query` and `zero_weights`, on every chapter | broken fixture `chapters/empty_query.tres` |
| F5 | Auto-play never makes bad or illegal moves, so nothing stresses wrong decisions; nothing checks battle invariants or record → replay on whole runs | 2.3b: chaos policy, illegal moves, invariant checker, replay of every battle | `test_chaos_policy` (fixtures, 5 seeds, all checks on, deterministic report), `test_illegal_moves_refused` (every illegal case: refused, no state change, no log entry, no RNG draw) |
| F6 | Every Godot run leaked at exit (4 objects, 3 resources: GodotGAS `GameplayEffect` and the two scripts it holds): Godot 4.7.2 keeps a script alive when it `@export`s a typed array of its own class (`overflow_effects: Array[GameplayEffect]`); order-dependent, every editor-binary run, about 3 in 5 dev-build runs | The one approved on-disk GodotGAS patch (2026-10-26): `Array[Resource]` (holds GameplayEffects only; nothing in `content/` uses it); recorded in `client-godot/CLAUDE.md` section 0. Second leak, debug template only: a UI sound playing when `dev_run` quit left its playback in the audio server (`Cursor1.wav`, the Hover sound: tearing screens down fires `mouse_entered`, so stopping sounds first is not enough); `Watchdog.quit(code)` frees the current scene, then lets the mixer settle (3 frames, 0.1 s) before quitting, used by `dev_run` | `test_no_leak_at_exit` (the game in a child process prints no exit leak), `test_no_self_typed_exports` (no such export in the addon or our code); both fail with the original line. Audio: 8 of 8 dev-build `dev_run` runs clean (was 5 of 5 leaking) |
| F4 | Release-build behaviour of `Dev` never checked (dev-tools manual checklist) | 3.12: `Dev.is_inert_for`, `load_commands(debug_build)`, the player filter, the release check; recorded in `specs/dev-tools.md` | `test_dev_inert_rule`, `test_console_registry` (release ignores `user://dev_commands/`), `test_export_presets`, `test_export_keeps_what_runs` (per preset), `test_godotgas_patches`, `test_content_roots`; `tools/release_check.sh` once per export; a floor played by hand in the player build |
| F… | Found while building | Added here and in `/sync-spec` | |

### 3.6 Shell (your `presentation/demo/`; D3)
As built, the screens are UI policy screens in `presentation/demo/ui/` (spec `ui-framework`):
- `title_menu`: run picker (`GameMain.runs()`), class cards with each class's kit (`class_card`, `class_details`),
  the seed field.
- `floor_card`: the floor's title over the map for two seconds of real time on `Message.Run.FloorEntered`.
- `pickup_panel` / `pickup_row`: the item's or armor's `description`, price in shops, an altar's curse price.
- `run_end`: `run_summary()` lines, the seed code, **Play again** (same seed, same party), **New run**, **Menu**.
- Battle speed toggle 1× / 2× (`battle_panel`: `Engine.time_scale` while a battle shows; presentation, never combat state; the
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
Uncommon 25, Rare 12, Legendary 3 (tiers renamed by D16; weights as built in `runs/descent.tres`
`rarity_weights_x100`); Wisp choir grants `Drain.Ice` to every wisp; Bound dead's first Toad gets an
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
events still appear. The Vault's treasure rooms draw from `Pool.Treasure` (they once drew from a `Pool.Vault` too; that pool was removed 2026-11-09, spec card-collection).

**System (two battle hooks and one generator option; no wire change):**
| Hook | Where | Rule |
|---|---|---|
| **H9 Mirror** (D11): `EnemyDefinition.mirror_party_items: bool` | `combat/battle.gd` (v2 setup) | The boss is also granted the `grants` AbilitySet of every **item and armor piece the party holds** (from the snapshot's `items`, `equipmentIds`, `useSlots`; party slot order, then the order listed). Usable items' use abilities are not copied. A party-wide item applies to the boss's side. A passive the boss already has is skipped, as for party members |
| **H10 Per-item scaling** (D11): `EnemyDefinition.per_item_effect: GameplayEffect` | same | Applied once per item and armor piece held (the same count as H9), after floor scaling. The effect must stack (validator error `per_item_not_stacking`) |
| **Boss rotation** (D12): `ChapterDefinition.boss_rotation: bool` (default false) | `game/floor_generator.gd` | The chapter's boss candidates (sorted ids) are shuffled once per run by the stream `chapter/<chapter id>/bosses`; the chapter's floor *k* (counted over the run's floor slots) takes entry *k* mod *n*. Stateless: nothing new in the run state or the run hash. Off = today's pick, so fixtures don't change |
| **Route choice** (D15): `FloorSlot.pick: RANDOM \| CHOICE \| ROUTE` (default RANDOM), `ChapterDefinition.route_tag` (`Route.Light`, `Route.Dark`) | `game/defs/floor_slot.gd`, `game/run_controller.gd`, `game/dev/seed_report.gd` | RANDOM: today's seeded pick (`floor/<n>/chapter`). CHOICE: `next_floor(chapter_id)` names one of the slot's chapters; the run log's `next_floor` entry gets `"chapter"` (only on CHOICE slots, so old logs are unchanged); no draw. ROUTE: the slot's chapter whose `route_tag` matches the previous floor's chapter; no draw. The auto and chaos policies pick a CHOICE from their own stream `dev/route/<floor>`, so reports cover both routes. The seed report takes `--route <chapter id>` (default the first) |
| **Price in max HP** (D17): `RoomPlacement.price_item: ItemDefinition` | `game/defs/`, `game/floor_generator.gd`, `RunController.take` | A pedestal with a price item costs no coins: taking it gives the buyer the price item too (a curse such as Void Scar), even past their item capacity. As built there is no `stackable` flag: a price item may be held several times and adds up through its FREE-stacking effects. Logged as a `buy`; the items travel in the snapshot's existing `items` list (no wire change) |
| Validator | `game/dev/content_validator.gd` | `boss_rotation_short` (warning): a rotating chapter with fewer bosses than its floors in a run; `per_item_not_stacking` (error); `choice_slot_single` (warning): a CHOICE slot with one chapter; `route_unmatched` (error): a ROUTE slot with no chapter for a route its previous slot can give; `price_item_not_stacking` (warning: the price item's effects refresh instead of stacking) |

Both hooks read only the snapshot and content, so the verifier rebuilds the same boss; fixtures and goldens without
them are byte-identical. A new combat golden `mirror-seed-9` (a fixture mirror boss against a fixture party holding
items and armor) pins H9 and H10.

**Depth scaling** `demo.scaling.descent` (typed %, enemies only; replaces `basic` on the Cellar and the Crypt, so
`one_floor` also uses floor 1's step): HP, ATK and DEF rise per floor; values as built in
`content/demo/scaling/descent.tres` and its `effects/scale_depth_*.tres` (tuned in C4 and C6).

**New enemies** (base stats, toughness and speed as built in `content/demo/enemies/<id>.tres`; tuned after the
proposal, most final-floor bosses to less HP):
| Enemy | Chapter | Affinities | Moves and brain |
|---|---|---|---|
| Rat King (boss) | Cellar | weak Fire | Gnaw (Physical, Bleed 60%), Swarm (all, Physical); at 50% a Frenzy phase (Haste, Swarm unlocked); PatternBrain |
| Bone Warden (boss) | Crypt | resist Physical, weak Fire, Immune.Control | Shield Bash (Stun 40%), Bone Wall (Defense Up and Taunt); at 40% a Ward phase; ult Ossuary (all, Physical) |
| Cinder Hound | Forge | resist Fire, weak Ice | Searing Bite (Fire, Burn) |
| Anvil Guard | Forge | drain Fire, weak Ice | Hammer Down (Physical, heavy toughness damage), Brace (Defense Up) |
| Smelter | Forge | weak Physical | Stoke (allies' ATK up), Slag (Fire, Slow); PatternBrain |
| Forgemaster (boss) | Forge | resist Fire, weak Ice | Hammer, Fire Bolt; at 60% Molten Armor (drain Fire, Defense Up); at 30% Meltdown (all, Fire, Burn); TacticalBrain ult |
| Brass Colossus (boss) | Forge | weak Ice and Physical | Piston (Physical), ult Overheat (all, Fire); breaking it is the way in (toughness 300) |
| Leech | Hollow | drain Physical, weak Fire | Latch (Physical, Bleed) |
| Gutter Maw | Hollow | weak Ice | Bile (2 stacks of Poison), Devour (Physical, heavy) |
| Vein Weaver | Hollow | resist Ice, weak Fire | Entangle Lash (row delay), Hemorrhage (all, Bleed 50%); PatternBrain |
| Mother Heart (boss) | Hollow | weak Fire | Pulse (all, Physical), Regen on itself; at 50% Bleeding Out (all, Bleed and Vulnerable); ult Systole |
| Twin Hearts (boss pair) | Hollow | one weak Fire, one weak Ice | Pulse, Mend on the other; ult when the other is below 50% (TacticalBrain) |
| Choir Seraph | Cathedral | resist Ice | Hymn (heal allies, Regen), Ward on an ally |
| Penitent Knight | Cathedral | resist Physical, Immune.Control | Shield Bash (Stun), Provoke (Taunt) |
| Hallowed Judge (boss) | Cathedral | resist Fire, weak Physical | Smite, Dispel (party buffs), Purify on itself; phases at 60% and 25%; ult Judgement (single, Doom-like) |
| Gilded Mimic | Vault | weak Physical | Snap (Physical, high crit) |
| Vault Sentry | Vault | drain Ice, weak Fire | Lockdown (Freeze 50%), Spiked Plating (strikes back when hit) |
| The Collector (final boss) | Vault | weak Physical | Appraise (Vulnerable), Repossess (Dispel), Gilded Ray (all, Ice); at 50% a Hoard phase (Ward and Haste); ult Liquidate (single, huge); **mirror** (H9) and per-item scaling (H10, `effects/collector_per_item.tres`) |

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
weights as built: `runs/descent.tres` `rarity_weights_x100`.

**The dark route's enemies:**
| Enemy | Chapter | Affinities | Moves and brain |
|---|---|---|---|
| Cultist | Coven | weak Physical | Hex (Vulnerable), Curse (Weaken); PatternBrain |
| Bound Demon | Coven | drain Fire, weak Ice | Hellfire (Fire, Burn), Rend (Physical, Bleed) |
| High Witch (boss) | Coven | resist Ice, weak Fire | Hex All, Dispel, Doom; phases at 60% (Ward each turn) and 25% (Haste, Hellfire unlocked); TacticalBrain ult Black Mass (all, Ice) |
| Void Wraith | Void | drain Ice, resist Physical | Chill Touch (Ice, Freeze 40%), Fade (Defense Up) |
| Abyssal Hulk | Void | weak Fire | Crush (Physical, heavy toughness), Quake (all) |
| The Nameless (final boss) | Void | resist Physical and Ice, weak Fire | Unmake (single, huge), Entropy (all, Bleed and Slow), Silence (Stun 50%); phases at 66% and 33%, each clearing its debuffs; ult Oblivion (all, huge) (no mirror) |

Encounters: Coven 3 (cultists, demon and cultist, elite demon), Void 3 (wraiths, hulk and wraith, elite hulk). Boss
rooms: one per chapter. **The Void's altars:** `Room.Type.Altar` (a new special room type), two pedestals each,
`Pool.Void`, price item **Void Scar** (Common, `Item.Curse`; a max HP loss that stacks per copy, value in `content/demo/items/`).

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

### 3.9 Amendment C4 (2026-10-26, D19–D22): tuning pass, smart policy, chaos injection, status immunity
The first ten-floor reports gave 0% wins (auto and chaos), most deaths on floors 3–5 to the Bone Warden, and one
battle stuck at the turn cap (a Leech nest draining Physical).

**Tuning pass (D19, your files made in C3):** Bone Warden 3600 → 2600 HP, 320 → 240 DEF, `Resist.Physical` removed;
`demo.scaling.descent` floors 3–6 HP +20/35/50/65 → +10/20/30/45%; Leech `Drain.Physical` → `Resist.Physical`.

**Smart policy (D20):** `SmartController` (`game/dev/`), deterministic and RNG-free, plays well: a dead ally is
revived; an ally under 45% HP is healed; otherwise the (ability, target) with the best score: estimated damage ×
weakness 2, resist ½, drain never; ×1.5 against a target the hit can break; ×1.3 against a target it can kill; ×
the number of targets for area moves; costed moves only while MP is above 30%. A ready ult is cast when it hits two or
more enemies or a boss. `seed_report --play --policy smart`, `autorun policy=smart`. Expected to win more than `auto`.

**Chaos injection (D21):** chaos plays on top of the smart policy. `--chaos <percent>` (default 100, today's
behaviour) is the share of decisions that are chaotic (random legal moves, illegal attempts at `--illegal`); the rest
are smart. `--chaos-from <floor>` (default 1) plays smart until that floor, so chaos also reaches the late floors.
The chaos draw (does this decision go chaotic) comes from the policy's own stream, like every chaos draw.
`autorun policy=chaos chaos=30 from=5`.

**Status immunity (D22):** `Immune.<Status>` (`Immune.Bleed`, `Immune.Burn`, `Immune.Poison`, `Immune.Freeze`,
`Immune.Stun`, `Immune.Slow`, `Immune.Entangle`, `Immune.Vulnerable`, `Immune.Weaken`, `Immune.AttackDown`,
`Immune.DefenseDown`, `Immune.Exposed`) and `Immune.Debuff` (all of them), as GAS data: each debuff effect's
`application_query` ignores its own `Immune.<Status>` and `Immune.Debuff` (Freeze and Stun keep `Immune.Control`), so
GodotGAS refuses the effect and no status roll is drawn (existing rule, H2). A unit or item becomes immune by holding
the tag. Validator warning `status_without_immunity`: a `Status.Debuff.*` effect whose query doesn't ignore its
immunity tags. Vein Cloak goes back to the spec'd **+150 max HP, immune to Bleed**.

### 3.10 Amendment C5 (2026-10-26, D23–D27): nine new classes, four-member parties, balance for four
The run is meant for a party of four, but the demo has two characters, which is the main reason every report so far
gives 0% wins. C5 adds nine classes (eleven in all) and tests parties of one to four, with four-member runs evaluated
the closest. **Class values are a proposal for review (D26).** All kits are content on existing hooks: no battle code.

**Roles (a loose guideline, HSR-style paths):**
| Class | Role | Element | Fantasy |
|---|---|---|---|
| Warrior (existing) | damage dealer / off-tank | Physical | Cleave, Execute, Provoke |
| Cleric (existing) | support: healer | — | heals, Sanctuary, Resurrection, Purify |
| **Arcanist** | damage dealer: magic | Fire and Ice | MP-hungry spells, area damage |
| **Bard** | support: buffs, debuffs, statuses | Physical | a Robin-style ult: the party acts at once and hits harder |
| **Ranger** | specialist: follow-ups | Physical | weakness hits trigger follow-ups, follow-ups charge the ult |
| **Cryomancer** | damage dealer: control | Ice | freezes, breaks, Blizzard |
| **Pyromancer** | damage dealer: damage over time | Fire | Burn on everything, a fast ult |
| **Bulwark** | tank: power from being hit | Physical | taunts, each hit taken stacks Fury (ATK) and charges the ult |
| **Ember Knight** | damage dealer: break | Fire | implants a Fire weakness, breaks it, and deals the most damage to Broken enemies (like HSR's Firefly) |
| **Shatterweaver** | support: break | Physical | raises the party's toughness damage and damage to Broken enemies (like HSR's Dahlia) |
| **Plaguewright** | support: statuses | Physical | spreads Poison and Bleed and makes everyone's debuffs last longer |

Playstyles the classes are meant to mix in (loosely; every class fits other teams too): break (Ember Knight,
Shatterweaver, Cryomancer, Ranger), damage over time (Pyromancer, Plaguewright, Bard), follow-ups (Ranger, Bulwark),
sustain (Cleric, Bulwark, Bard).

**Kits** (every class also has the shared ult-charge passives and the three break passives, like today's two; each ult
can't be cast while controlled, D3; "MP" is the skill's cost). Base stats (HP, MP, ATK, DEF, SPD, and extras such as
the Ranger's crit rate and the Pyromancer's ult charge gain) as built in `content/demo/characters/<id>.tres`:
| Class | Basic | Skills | Passive | Ult |
|---|---|---|---|---|
| Arcanist | Arcane Bolt: Ice 90% | Fireburst (15 MP): Fire blast 140% + 60% adjacent; Frost Nova (20 MP): all enemies Ice 70% | Spellweave: +6 MP on each kill | Meteor: all enemies Fire 200%, heavy toughness |
| Bard | Dissonance: Physical 70%, Weaken 60% | Anthem (15 MP): the party Attack Up and Haste; Discord (15 MP): all enemies Vulnerable 80%, Slow 50% | Encore: +10 ult charge when an ally gets a One More | Finale: the party acts at once (advance 100%), +30% ATK for 2 turns |
| Ranger | Quick Shot: Physical 100% | Mark Prey (10 MP): Physical 80%, the target becomes weak to Physical (2 turns) | Hunter's Instinct: a weakness hit triggers a 50% ATK follow-up; each follow-up +10 ult charge | Rain of Arrows: all enemies Physical 130% |
| Cryomancer | Frost Jab: Ice 100%, toughness 30 | Glacial Spike (15 MP): Ice 160%, Freeze 35%; Blizzard (20 MP): all enemies Ice 70%, Slow | Cold Snap: +20 ult charge on a break | Absolute Zero: all enemies Ice 160%, Freeze 50% |
| Pyromancer | Ember: Fire 100% | Ignite (10 MP): Fire 80% + Burn 60; Inferno (20 MP): all enemies Fire 60% + Burn 40 | Kindling: +8 ult charge on each Fire hit | Supernova: all enemies Fire 220% + Burn 100 |
| Bulwark | Shield Slam: Physical 80%, toughness 40 | Fortify (10 MP): Defense Up and Taunt | Retaliation: when hit, a 40% ATK counter, +1 Fury (+10% ATK, up to 5, 2 turns) and +10 ult charge | Bastion: the party gains Ward and Defense Up |
| Ember Knight | Searing Slash: Fire 100%, toughness 30 | Kindle Brand (15 MP): Fire 150%, toughness 50, the target becomes weak to Fire (Seared, 2 turns) | Ashen Resolve: +40% damage to Broken enemies | Complete Combustion: 3 turns of +30 SPD, +50% toughness damage, +40% damage to Broken enemies, and Fyrefly Strike unlocked (Fire 200% + 80% adjacent, toughness 60, Seared on every hit; free) |
| Shatterweaver | Fault Line: Physical 80%, toughness 40 | Fracture Field (15 MP): the party +30% toughness damage and +25% damage to Broken enemies (3 turns); Splinter (10 MP): Physical 60%, toughness 50, Vulnerable | Resonance: +20 ult charge on a break | Shatter Chorus: all enemies Physical 60% with toughness 80, then Fracture Field on the party |
| Plaguewright | Infect: Physical 70%, Poison 60% | Contagion (15 MP): all enemies 2 stacks of Poison (80%); Lingering Malady (15 MP): the party's debuffs last 1 more turn (3 turns) | Virulence: its own debuffs last 1 more turn; +10 ult charge when one is resisted | Pandemic: all enemies Poison, Bleed, Burn 60 and Vulnerable |

New effects: Fury (`Status.Buff.Fury`, stacks to 5), Finale (+30% ATK, 2 turns), Combustion (`Status.Buff.Combustion`
plus `State.Combustion`, which Fyrefly Strike's activation query requires), Fracture (`Status.Buff.Fracture`), Malady
(`Status.Buff.Malady`, +1 `debuff_turns`), Seared (`Weakness.Fire` and `Status.Debuff.Exposed`, 2 turns, refused by
`Immune.Exposed` and `Immune.Debuff`). Mark Prey's weakness reuses Exposed (Physical). The break effects themselves
are the existing break passives, whose bursts hit a Broken target, so damage to Broken enemies strengthens them.

**Testing parties of one to four (D24):**
| Option | Rule |
|---|---|
| `--party a,b,c,d` | a fixed party, as today |
| `--party-size N` (1–4; default 4) | per seed, N different selectable characters drawn from the stream `dev/party/<seed>` (sorted ids), so every class appears across seeds |
| `--party-size mixed` | per seed, a size of 1 to 4 from the same stream, then the members |
| Report | adds `bySize` (runs and wins per party size), `byCharacter` (runs and wins per class) and `byParty` (the most played compositions), so four-member win rates can be read on their own |

**Balance target (D25):** with four members on the smart policy, 35–55% of runs won on The Descent; auto lower; chaos
lower still, but most chaos runs reach floor 5 or later. Smaller parties are expected to win less. The report informs
your tuning; no test asserts a rate.

Last smart 4-member report (2026-10-27, after `auto-battle`: roles, consumables kept, cleanse and buff rules):
106/300 won (35.33%, was 35.7%), 259 runs reach floor 10, deaths mostly the Nameless (68) and the Collector (67), 0
violations.

### 3.11 Amendment C6 (2026-10-26, D28–D32): experience and levels, a rest stop between floors, healing, food drops
The first four-member reports (smart 0/300) show why balance can't come from numbers alone: the party never grows
(every member stays level 1 for ten floors) and its HP drains floor after floor (median boss-entry HP 96% on floor 1,
about 25% from floor 7). C6 adds growth and recovery, all as run-layer data: battles still rebuild everything from the
snapshot, which already carries each member's level. **Values are a proposal for review (D32).**

**Experience and levels (D28):**
| Piece | Where | Rule |
|---|---|---|
| `RunStructure.xp_per_enemy`, `xp_per_boss`, `xp_to_level: Array[int]` | `game/defs/run_structure.gd` | After a **won** battle every living member gains `xp_per_enemy` per enemy beaten (`xp_per_boss` for an `Enemy.Boss`); `xp_to_level[k]` is the total XP for level k + 2. Empty `xp_to_level` = no XP at all (fixtures and older runs unchanged) |
| Level-ups | `RunController` | Checked after every battle and every event outcome; a member may gain several at once; logged in the run log only through the battle or choice that caused it (re-derived on replay). Run hash: `xp` joins the member line only when the run has a curve |
| `CharacterDefinition.level_effect: GameplayEffect` | `game/defs/character_definition.gd`, `combat/battle.gd` (v2 party setup) | Applied once per level above 1 at battle start and in field mode (FREE stacking); the verifier rebuilds it from the snapshot's `level` (no wire change) |
| `GainXp(amount)`, `GainLevel(count)` outcomes | `game/defs/outcomes/` | For events (and rewards): to every living member, or to `character` when set |
| Validator | | `level_not_stacking` (error); `xp_curve_order` (error: thresholds must rise) |

**Rest stop between floors (D29):** `RunStructure.rest_event: EventDefinition`. Taking the stairs logs `next_floor` as
today and then opens the rest event before the next floor is built (its cell is −1, nothing on the map); when the
event ends, the next floor starts. A rest event can't start an encounter (validator `rest_event_encounter`, error).
The demo's **Waystation**: "A quiet waystation between floors. The lamps are warm." Choices: **Rest** (the party heals
50% of max HP and MP, the fallen get up with 25% HP), **Train** (every living member gains 1 level), **Move on**.

**Healing events (D30, `Event.Demo`):** Healing Spring (drink: heal 35%; bathe: heal 70%, pay 10 coins), Wandering
Medic (15 coins: full heal and revive the fallen), Old Tutor (a free level for the party, or 40 XP each and 10 coins).

**Food drops (D31, Castlevania IGA style):** `EnemyDefinition.drop_item: ItemDefinition` and `drop_chance` (typed %,
low). After a won battle, one roll per beaten enemy that has a drop, on the stream `floor/<n>/drop/<cell>` (after the
coin roll); a hit gives the item to the first member who can hold it, like an event gift (lost with a warning when
nobody can). Food is a **usable consumable** the player uses in battle or on the map, so the waystation and a healer
stay the main recovery. Demo food (`Pool.Food`, never in item pools): Rations (one ally heals 15% HP; Common), Roast
Haunch (one ally heals 30% HP), Honey Cake (one ally regains 40% MP), Hearty Feast (the party heals 25% HP; Rare).
Chances 2–6%, on some enemies only (beasts and brutes drop meat, casters cake), up to 8% on bosses.

**Demo numbers (D32):** as built in `runs/descent.tres` (`xp_per_enemy`, `xp_per_boss`, `xp_to_level`, levels 2–15)
and the growth effects `effects/growth_damage.tres`, `growth_support.tres` and `growth_tank.tres` (max HP, ATK and DEF
per level, FREE stacking; each class's `level_effect` names one).

### 3.12 Amendment E (2026-10-26, D5 as built, D33–D35): the Windows export, export levels, the release check
Status: built 2026-10-26.

**Presets** (`client-godot/export_presets.cfg`), one per level, made by `tools/export.sh <level>` (through
`tools/watch.sh`; output in the repo root's `build/<folder>/`, gitignored, outside the Godot project so the editor
never scans it):

| Level | Preset | Template | Ships | Folder | Use |
|---|---|---|---|---|---|
| `player` | `Windows Desktop` | release | the game only | `build/demo/` | the demo for people |
| `dev` | `Windows Desktop Dev` | debug | + `game/dev/` whole (console commands, dev content, players and reports), `game/tools/dev_run.*` | `build/dev/` | drive the exported build with console scripts, as in the editor |
| `full` | `Windows Desktop Full` | debug | everything, plus the non-resource files tests read (`*.json, *.txt, *.cfg, *.sha256`) | `build/full/` | the test suite, play reports and headless runners against the exported pack |

The debug presets also write `rpgDemo.console.exe` (stdout for headless runs). The level is the preset alone: no
runtime switch. `Dev` is active in a debug build and inert in a release one (`Dev.is_inert_for(display, debug_build)`),
so the player build has no console, no cheat commands (the command files are not in its pack) and never reads
`user://dev_commands/` (`DevConsole.load_commands(debug_build)`). Dev builds are local only. All levels share
`user://` (`app_userdata/rpgDemo`) with editor runs.

**Starting a scene in a dev or full build:** the official 4.7 templates are compiled without path overrides (a scene
or `--path` on the command line aborts; `--script` is ignored), which keeps the player build closed. The dev and full
presets add the custom feature `dev_build`; the project setting `application/run/main_scene.dev_build` makes
`game/dev/build_entry.tscn` their main scene, which opens the scene in the user arg `--scene <res://...>` (or the
game). Examples: `build/dev/rpgDemo.console.exe --headless --quit-after 100000 -- --scene
res://game/tools/dev_run.tscn --script <file> --out <json>`; the suite: `tools/godot_tests.sh --build
build/full/rpgDemo.console.exe`. Tests that start a child Godot build its arguments with `TestCase.scene_args`;
tests that read project source or editor files call `skip_in_export()` and count as skipped there.

**Player exclusions** (closed over their dependencies; the shipped dev files are `dev`, `watchdog`,
`script_error_log`, `dev_console`, `dev_command`, `dev_context`, `content_templates`, `room_grid_ops`,
`play_request`, `sandbox_request`): `tests/`, `game/tools/`, `game/dev/scripts/`, `game/dev/commands/`,
`game/dev/content/`, `game/dev/build_entry.*`, `combat/headless/`, `addons/rpg_dev/`, and the reports and
controllers in `game/dev/` (`chaos_controller`, `content_validator`, `dev_report`, `invariant_checker`, `play_main`,
`play_report`, `run_player`, `scripted_controller`, `seed_report`, `seed_runner`, `smart_controller`,
`ui_policy_check`, `validation_issue`). **Dev exclusions:** `tests/`, `game/tools/` except `dev_run.*`,
`combat/headless/`, `addons/rpg_dev/`. **Full:** none.

**Content roots in an export:** `GameMain.content_roots()` lists only the roots the build has (the player and dev
builds have no `tests/fixtures/`); a saved root the build lacks falls back to `res://content/`; the title menu hides
the picker when there is one root.

**GodotGAS patch for exports (D34, revised 2026-10-26):** GodotGAS 1.1.2 names `EditorInterface` in runtime code
(`managers/gameplay_cue_manager.gd` once, `utilities/project_settings.gd` twice; guarded by
`Engine.is_editor_hint()`, but GDScript resolves the name at parse time and export templates have no editor
classes), so in any export the `GameplayCueManager` autoload failed to load. Fixed in the addon on disk, like the
leak in F6: those lines reach it through `Engine.get_singleton(&"EditorInterface")` (the same object in the editor,
never reached in a game), each marked "rpgProject patch". `test_godotgas_patches` fails when a GodotGAS update
brings a bare editor class name back into a runtime script (and names the line); `test_cue_manager_loaded` checks
the autoload in any build, the full export included. Scripts export as binary tokens, as by default. (First built as
an export-time plugin that patched only the exported copies and needed text script export; replaced at the user's
request.)

**Release check (D35):** `tools/release_check.sh <shots folder> [player|dev]` (through `tools/watch.sh`; the work is
`tools/release_check.py`): starts the build in a 1600×900 window with its own log file, waits for the title screen,
takes a shot, sends a backtick keypress by scan code (the console listens on the physical key), takes a second shot,
closes the window, and fails on any `SCRIPT ERROR` or `ERROR:` log line or when the console's area (the top third)
changed against the expectation. `dev` is the control: its console must open, which proves the keypress reached the
game. Takes focus for a few seconds. Playing a floor in the player build stays a manual check; the same floor is
played on the exported dev build with `dev_run` in a window.

**No .NET assembly yet:** the project has no C# scripts, so an export has no `data_rpgDemo_*` folder. Slice 2 (the
first C# script, server sync) must check that the export carries `Rpg.Client`.

**As built, 2026-10-26:** the player pack is 5.0 MB (dev 5.2, full 6.4). The release check passes on the player build
(title screen, console area unchanged, no errors in the log) and on the dev control (console opened, 76% of its area
changed). The full build runs the suite: 340 passed, 5 skipped (the tests that read project source). The dev build played seed 7's
first floor in a window (treasure, shop, the merchant event, the Golem won, both members to level 2). The exit leaks
seen on the way are fixed (3.5 F6).

## 4. Failure modes
Server failure scenarios (root `CLAUDE.md` 1–7): **none apply** (no server, no wire change). What this slice
protects is that **adding a second run and a second floor doesn't change any existing replay**, which scenario 5
(tampered log → 2002) and the later run verifier (4a) rely on. A battle mismatch stays a verdict (`Rejected`,
`errorCode` 2002, a `MismatchReason`); no new reason.

| Failure | Behaviour | Test |
|---|---|---|
| Fixture root (one run) replayed after F1 | Same log, same run hash: the `"run"` field is written only when several runs exist | `run_scripted.json` golden unchanged |
| Several runs, none named, none default | `stop("several runs and none is default: …")`, run never starts, end view shows it | `test_run_picker` |
| Two runs flagged default | Validator error `run_default_twice` (none flagged: warning `run_no_default`) | broken fixtures `runs/default_a.tres`, `runs/default_b.tres` |
| Unknown `run=` id | Command fails, names the id; menu can't offer it | `test_run_picker` |
| A floor that can't generate (no boss room for its chapter) | Validator error before play (F3: `empty_query` / `zero_weights`); at generation the existing runner error | broken fixture `chapters/empty_query.tres` |
| Second floor's battles draw from the wrong stream | Can't: floor seeds are `floor/<n>/…` (`RunSeeds`), unchanged | existing `test_generation` (fixtures), plus `test_demo_floors_differ_per_seed`: for seeds 1–20, a chapter's two floors (Cellar 1–2, Crypt 3–4) differ in layout, rooms, encounters, enemies or pickups |
| Report differs between two runs of the same seeds | Not allowed: one process, sequential seeds, no wall-clock in the JSON | `test_seed_report_play` runs it twice and compares |
| Illegal move submitted (chaos or a player's UI bug) | Refused: no state change, no log entry, no RNG draw; the decision is asked again | `test_illegal_moves_refused` |
| Illegal move found in a log on replay | 2002 `IllegalAbility` / `InvalidTarget` (existing reasons) | existing tampered goldens |
| Strange but legal battle (wasted ults, heals on full HP, drain hits) | Replays Verified with the same hash | `test_chaos_policy` replays every battle |
| Chaos policy changes the battle's RNG | Can't: own `dev/chaos/<seq>` stream; checked by replaying without the policy | `test_chaos_policy` |
| Speed toggle changes combat | Can't: `time_scale` affects presentation; combat awaits only the gate | `test_demo_battle_speed_keeps_combat`: one demo battle through `GameMain` with the views and the battle panel's own Skip and Speed buttons, animations skipped, 1× and 2× (the gate waiting on the animations; about 30 ms, 3.4 s and 1.7 s): the same final hash and run hash |
| Cursed chest's 20% damage on a dead or low member | Existing outcome rules (`apply_party_effect` skips the dead unless `include_dead`; whether it can kill is pinned as built, not changed here) | `test_demo_events` pins the built rule, direction only |
| Encounter grants or a slot brain change replays | Read from content by encounter id and slot; the verifier builds the same units | `test_encounter_grants_replay` (record → replay Verified), existing goldens unchanged |
| Rewards on a lost battle | Never applied | `test_encounter_rewards` |
| Rarity weights change existing pools | Only when set; empty weights use the old draw | `test_rarity_weights` (fixtures: same picks without weights; with weights the draw counts follow them over many seeds) |
| Export ships the console | `Dev` inert in release (dev-tools spec); command files not in the player pack | F4: tests and `tools/release_check.sh` |
| A shipped file needs an excluded one (parse error in the build only) | Export fails to start or a screen breaks | `test_export_keeps_what_runs` per preset |
| A GodotGAS upgrade brings a patched bug back | The test names the file and line; re-apply the patch (3.12 D34, F6) | `test_godotgas_patches` |

## 5. Observability
N/A: client-only slice, no service runs. Local signals: the auto-play report (2.3), the validator report, the script
runner JSON, `run_summary()` on the end screen. Prometheus metrics for runs and floors start with slice 2 and 6
(never per-item or per-encounter labels).

## 6. Test plan
System tests stay on `tests/fixtures/` (fixtures gain nothing but a second run created in `user://` by the test), so
existing fixtures and goldens stay byte-identical.

**System tests:** `test_run_picker` (one run, several with a default, several without, unknown id, two defaults),
`test_seed_report_play` (+ golden `tests/fixtures/golden/game/seed_report_play.json`), `test_autorun_command`,
`test_run_summary` (fixture scripted run: counts match its log), `test_chaos_policy` and `test_illegal_moves_refused`
(F5), `test_invariant_checker` (a dev effect pushes HP past max in a fixture battle → the checker reports it), parity entries for `new run=` and `autorun` in
`test_tool_parity`, the validator broken fixtures `chapters/empty_query.tres` and `runs/default_a.tres` / `default_b.tres`.

**Demo content tests** (`tests/game/test_demo_run.gd`, reads `content/demo/`, direction only, never tuned numbers):
- `test_demo_run_full_descent` (was `test_demo_run_two_floors`): `demo.run.descent` is the default; every floor ends
  in its chapter's boss, a chapter's two floors meet different bosses, both routes reach floor 10; item rooms only
  where the chapter has them (none in the Hollow, the Cathedral and the Coven; four treasure rooms in the Vault; three
  altars in the Void).
- `test_demo_run_completes`: `RunPlayer` on seeds 1–10 always ends (Won or Lost, never a runner error or the step
  cap), and the stairs are taken on every run that clears the Golem.
- `test_demo_events`: each new event's choices are enabled under their conditions and do what the text says
  (direction: coins go down, an item arrives, an encounter starts).
- `test_demo_encounter_features` (was `test_demo_crypt_encounters`): the Wisp choir drains Ice, Bound dead's first
  Toad lashes with Entangle (its row delay fires), beating the wounded knight drops his helm into the armor inventory.
  Also `test_demo_endings`, `test_demo_status_immunity`, `test_demo_ults_*`, `test_demo_items_replay`.
- `test_content_valid`: 0 errors.

- `test_demo_c6_events` (3.11): Healing Spring (drinking heals; bathing needs and takes 10 coins and heals more),
  Wandering Medic (needs 15 coins; full heal, the fallen get up), Old Tutor (a level each, or XP and 10 coins), the
  Waystation as The Descent's rest stop (rest heals HP and MP and raises the fallen; train gives a level; move on
  changes nothing).
- `test_demo_battle_speed_keeps_combat` (4, 3.6): skipped animations, 1× and 2× give the same battle and run hash.
- `test_demo_floors_differ_per_seed` (4): for the same seed, a chapter's two floors are generated differently (each
  floor draws from its own `floor/<n>/…` stream).

**Golden vectors:** no new combat golden (no battle rule changes). `seed_report_play.json` (fixtures) pins the
report's shape and determinism. A recorded demo run is **not** a golden (your tuning would break it daily); the slice
2 spec decides whether the server tests want one.

**Manual (once, before calling the slice done):** play `The Descent` start to finish in the window, win and lose
once each; play one floor in the exported player build (`build/demo/rpgDemo.exe`). That it starts on the title
screen with no console and no errors is automated (`tools/release_check.sh`, F4, 3.12).

**Export tests (3.12):** `test_export_presets`, `test_export_keeps_what_runs` (each preset's exclusions are closed
over their dependencies), `test_godotgas_patches` (no editor class names in GodotGAS runtime scripts, no
self-typed exports, the cue manager loaded), `test_no_leak_at_exit`, `test_content_roots`,
`test_dev_inert_rule`, `test_console_registry` (a release build ignores `user://dev_commands/`); the whole suite
also runs inside the `full` build (`tools/godot_tests.sh --build build/full/rpgDemo.console.exe`).

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
C6. 3.11: XP, levels and level effects, the rest stop, food drops, GainXp/GainLevel (system, tests on fixtures);
   then the content (Waystation, three events, four foods, growth effects; edits to the eleven classes and The
   Descent shown); reports at party sizes 1-4 and the tuning toward D25.
C5. 3.10: the party options and report breakdown (system, tests on fixtures); the six classes through a builder
   (`build_classes.tscn`; new files only); reports at party sizes 1-4; a tuning pass toward D25 as edits, each shown.
C4. 3.9: the tuning pass, the immunity tags and queries (your files, shown as edits), the smart controller and chaos
   injection (system, tests on fixtures), then both reports plus a smart one on the ten-floor run.
C3. 3.8: H9 mirror, H10 per-item scaling, boss rotation, validator rules, the `mirror-seed-9` golden and system tests
   (fixtures); then the content builder (`build_full_descent.tscn`), the edits to your files, demo tests, and a play
   and chaos report on the ten-floor run. Step D (screens) comes after C3.
C2. 3.7: system first (encounter grants, slot brain, rewards, armor to inventory, rarity weights, validator, tests),
   then your files after the rarity table is approved.
D. Shell (3.6), each file shown as a diff.
E. ✅ Export presets (player, dev, full), `build/` in `.gitignore`, F4 check (3.12); then the design break: your
   tuning on the report.
F. `/sync-spec playable-demo`, roadmap ✅, root `CLAUDE.md` table (`content/demo/` the ten-floor Descent), the
   dev-tools checklist line (done in E). Spec synced 2026-10-26; what is left: your tuning, the manual checks in 6.

## 8. Later
- Local saves and resume (2b), a hub and unlocks (5), completion marks and gems.
- More floors and chapters; Delirium-style mixed floors (`rooms_from_any_chapter` exists, unused).
- A floor-layout grid in the inspector (`specs/dev-tools.md` Later).
- Status icons, flash VFX, music per chapter (`ChapterDefinition` has no music field yet).

## 9. Decisions
All approved as recommended (user, 2026-10-26). F5 (chaos policy, 2.3b) added the same day at the user's request. The edits to existing files (D3) are still each shown as `old → new`
when made.
- **D1 run length: two floors** (Cellar → Crypt; superseded by D13 and D15, the ten-floor Descent), recommended: the smallest run with stairs, a difficulty step and
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

Decided 2026-10-26 by the user (amendment C4, 3.9):
- **D19 the tuning pass** as listed in 3.9.
- **D20 a smart policy** for tests, beside auto and chaos.
- **D21 chaos is injected on top of the smart policy,** at a rate and from a floor, so chaos reaches the late floors.
- **D22 status immunity per status** (`Immune.<Status>`, `Immune.Debuff`), as GAS application queries; Vein Cloak is
  immune to Bleed.

Decided 2026-10-26 by the user (amendment C5, 3.10):
- **D23 nine new classes** (Arcanist, Bard, Ranger, Cryomancer, Pyromancer, Bulwark; then D27: Ember Knight,
  Shatterweaver, Plaguewright), loosely by role.
- **D24 tests use parties of one to four,** drawn per seed, with the report broken down by size, class and party.
- **D25 balance for four:** the smart policy with four members wins 35–55%; four-member results are read first.
- **D26 (to review):** the class values in 3.10.
- **D27 three more classes for playstyles:** a Firefly-like breaker, a Dahlia-like break support and a status
  support; classes stay loose enough to fit different teams.

Decided 2026-10-26 by the user (amendment C6, 3.11):
- **D28 characters gain XP from every battle and level up** after any battle or event; events can grant XP or a level.
- **D29 a rest stop between floors** (Persona's subway was only the concept; not a subway).
- **D30 events that heal** the party.
- **D31 some enemies have a low chance to drop food** (2–8%), a usable item, Castlevania style; the rest stop and a healer
  are the main recovery.
- **D32 (to review):** the numbers in 3.11.

Decided 2026-10-26 by the user (amendment E, 3.12):
- **D5 as built:** a release preset `Windows Desktop` to `build/demo/` (repo root), the player exclusions in 3.12.
- **D33 export levels** `player`, `dev` (minimal dev tools) and `full` (everything), one preset each, so Claude can
  drive and test exported builds.
- **D34 patch GodotGAS on disk** (revised the same day; first built as an export-time patch), with a test that fails
  when an update brings the bug back.
- **D35 a release check script** for what can be checked from outside the player build; a floor played by hand.
