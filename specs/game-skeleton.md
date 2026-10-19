# Spec: game-skeleton (slice 1b)

Status: 📝 Spec written, reviewed 2026-10-19 · Roadmap: slice 1b · Date: 2026-10-19
Design intent: `specs/design/game-design.md` (asset model, GAS mapping in section 2a, seeds in section 5).

## 1. Purpose & enterprise mapping
Build the bones of the run: the data asset types for the world, a seeded Isaac-style floor generator, run state with a
run log, and a minimal clickable flow that strings together the battle kernel from slice 1:

```
main menu (pick 1–4 characters, optional seed) → floor map → click a room → battle or event → back to the map
→ boss room → next floor → … → last boss → run won        (party wiped → run lost)        → main menu
```

After this slice, adding a room, encounter, event, chapter or floor rule is creating a `.tres` file with the right tags.
No code changes are needed for new content.

**Scope line: nothing in this slice changes how a battle plays out.** Battles stay isolated, built from a v1
`BattleSnapshot` exactly as in slice 1 (full HP every battle, no items, no scaling). Everything that would change battle
numbers (loadouts and overrides, enemy definitions and variants, floor scaling, HP/MP carry-over) needs snapshot v2 and
moves to the system-design pass and slice 1d. That keeps this slice from touching `combat/`, the state hash or the goldens.

| Component | Used in this slice | How |
|---|---|---|
| `client-godot/game/` | ✅ new | World asset classes, content index, tag matching, seed derivation, floor generator, run state/log, run controller |
| `client-godot/game/graybox/` | ✅ new | Throwaway system UI (menu, map, 3D room box, battle panel, event panel) so the flow is playable before `presentation/` exists |
| `client-godot/combat/` | ✅ unchanged | Battles run through `Battle.setup()` / `run()` with a v1 snapshot; `ActionRecorder` logs the party's choices |
| `client-godot/tests/` | ✅ | New `tests/game/` system tests; new world fixtures under `tests/fixtures/` |
| `content/` | ✅ new files only | A tiny demo run (section 3.6), created at the user's request. Never edits existing files. |
| `godot_gas/` | ✅ additions only | Demo attributes (draft + dashboard-generated AttributeSet) and demo tags added to the registry. Nothing removed. |
| `presentation/` | ❌ | Untouched. Graybox views stand in until the user's scenes replace them. |
| `Rpg.Contracts`, server, Postgres, Redis, RabbitMQ, Redpanda | ❌ | N/A: the run is local. Wire shapes for runs come from the system-design pass after this slice. |

**Enterprise mapping:** the run is a *client-side workflow driven by a seeded, replayable event log*. The generator is a
pure function `(seed, content) → floor`, like a deterministic batch job whose output can be recomputed for audit, and
the run log is the event-sourced record of the user's decisions. This is what lets the server verify whole runs later.

## 2. Sequence flow
No client → server traffic in this slice. Everything happens in one Godot process.

```
GameMain (game/game_main.tscn, project main scene)
 ├─ GameContent.new(content_root)            scan rooms/, chapters/, floor_rules/, runs/, events/, characters/,
 │                                           layouts/ (+ units/ and encounters/ via ContentIndex), recursive, sorted by path
 ├─ menu view ── start(party ids, seed text) ─▶ RunController.start_run()
 │                                              RunState{seed, party, coins 0, floor 0}, RunLog []
 │
 ├─ RunController.enter_floor(n)
 │    chapter  ← RunStructure.floors[n].chapters, picked with stream "floor/<n>/chapter"
 │    FloorMap ← FloorLayout (hand-made, if the slot has one) or FloorGenerator.generate(chapter, rules, depth n, seeds)
 │    map view shows the start room as visited
 │
 ├─ map view ── enter_room(cell) ─▶ RunController (checks: cell is adjacent to a visited cell)
 │    log {enter_room, floor, cell}; mark visited
 │    room content:
 │      encounter → room view (3D box, enemies on their spawn cells) → battle view
 │                  snapshot v1 {battleId "<runId>/f<n>/c<cell>", seed = per-room combat seed, encounterId, party}
 │                  Battle.setup() + run(controller) with ActionRecorder; ClientGate driven by the battle view
 │                  log {battle, battleId, outcome, finalHash, actionLog}
 │                  Victory → room cleared;  Defeat or TurnLimit → run lost
 │      event     → event view: page text + choices whose conditions hold
 │                  choose(i) → log {choose, page, choice}; outcomes run in order (coins, go to page, start encounter, end)
 │      none      → room cleared on entry (start room; treasure/shop placeholders until slice 1d)
 │    boss room cleared → "next floor" → enter_floor(n + 1), or run won after the last floor slot
 └─ run end view → back to the menu
```

The graybox views only **call** `RunController` methods and **listen** to its signals (`floor_entered`, `room_entered`,
`battle_requested`, `event_page_shown`, `room_cleared`, `run_ended`). `RunController` holds no UI. `presentation/` can
later replace any graybox view by assigning its own scene to `GameMain`'s exported view slots.

## 3. Data contracts

### 3.1 Content asset classes (system code in `game/defs/`; designers fill them in `content/`)
Every asset has `id: StringName` (unique per type), `display_name: String` and, where it is pooled, `tags: Array[StringName]`
(GodotGAS tag picker, `@export_custom(PROPERTY_HINT_NONE, "gas::tag")`). Weights and chances are typed as decimals and
stored ×100 (`Fixed.from_typed`). Counts and grid cells are plain integers. No asset contains a tag literal the code
depends on: the tags that mean "start room", "boss room" etc. are themselves fields of `FloorGenRules`.

| Class | Fields |
|---|---|
| `RoomDefinition` | `id`, `display_name`, `tags` (room type + chapters), `doors` (flags N/E/S/W: sides that *may* have a door), `min_doors` (1 = can be a dead end), `weight`, `content_mode` (`NONE`, `ENCOUNTER`, `ENCOUNTER_QUERY`, `EVENT`, `EVENT_QUERY`), `encounter`, `event`, `content_query` (`GameplayTagQuery`; empty = use the chapter's query), `placements: Array[RoomPlacement]` |
| `RoomPlacement` | `cell: Vector2i` (inside the 13×7 room grid), `kind` (`PLAYER_SPAWN`, `ENEMY_SPAWN`, `EVENT_PROP`), `slot: int` (party slot or encounter enemy index, 1-based). More kinds (pickups, pedestals, shop slots, interactables) arrive with 1c/1d. Missing spawns fall back to a default formation. |
| `EncounterDefinition` (exists in `combat/`, extended) | add `display_name`, `tags`, `weight`. Combat fields unchanged, so battles and hashes don't change. |
| `EventDefinition` | `id`, `display_name`, `tags`, `weight`, `pages: Array[EventPage]` (page 0 is the first) |
| `EventPage` | `text` (multiline), `choices: Array[EventChoice]` |
| `EventChoice` | `label`, `conditions: Array[RunCondition]` (all must hold, otherwise the choice is shown disabled), `outcomes: Array[RunOutcome]` (run in order) |
| `RunCondition` (base) | `holds(run) -> bool`. Built in: `CoinsAtLeast(amount)`, `HasCharacter(character)`. Content may add subclasses, as with ExecCalcs. |
| `RunOutcome` (base) | `apply(run) -> void`. Built in: `GainCoins(amount)`, `LoseCoins(amount)` (floors at 0), `GoToPage(index)`, `StartEncounter(encounter)`, `EndEvent`. Content may add subclasses. Heal/damage and items come with 1d. |
| `CharacterDefinition` | `id`, `display_name`, `unit: UnitDefinition`, `portrait: Texture2D`, `selectable: bool` (unlocks/gacha later) |
| `ChapterDefinition` | `id`, `display_name`, `tags` (the chapter's own tag, e.g. `Chapter.Basement`), `room_query`, `encounter_query`, `boss_encounter_query`, `event_query` (all `GameplayTagQuery`), `floor_gen_rules: FloorGenRules` |
| `FloorGenRules` | `grid_size: Vector2i` (default 9×8), `base_rooms`, `rooms_per_depth`, `random_extra_rooms`, `max_rooms`, `branch_chance` (typed %, default 50), `max_attempts` (default 100), `start_room_tag`, `normal_room_tag`, `boss_room_tag`, `special_room_tags: Array[StringName]` (one dead end each, in order) |
| `RunStructure` | `id`, `display_name`, `floors: Array[FloorSlot]` |
| `FloorSlot` | `chapters: Array[ChapterDefinition]` (one picked per run: alt paths), `rooms_from_any_chapter: bool` (Delirium-style), `layout: FloorLayout` (optional: use this hand-made floor instead of generating) |
| `FloorLayout` | `id`, `display_name`, `start: Vector2i`, `cells: Array[FloorLayoutCell]` |
| `FloorLayoutCell` | `cell: Vector2i`, `room: RoomDefinition`, `encounter` / `event` (optional overrides of the room's content), `role` (`NORMAL`, `START`, `BOSS`, `SPECIAL`) |

Content folders scanned under the content root: `rooms/`, `chapters/`, `floor_rules/`, `runs/`, `events/`,
`characters/`, `layouts/`, plus `units/` and `encounters/` through the existing `ContentIndex`. Subfolders are allowed
(e.g. `rooms/basement/`). The run uses the single `RunStructure` in `runs/`; more than one is a content problem until
the hub can choose (later).

**Tag pools (GAS-first):** pools are GodotGAS `GameplayTagQuery` resources, the same ones abilities use.
`GameplayTagQuery.matches()` only accepts an ASC, so `TagMatch.matches(query, tags: Array[StringName])` evaluates the same
five fields with the same rules against a plain tag list, including parent matching (`Chapter` matches
`Chapter.Basement`). A test runs every case through both `TagMatch` and the addon's `matches()` on a throwaway ASC, so the
two can never disagree. An empty query matches everything.

### 3.2 Floor generation (Isaac-style, integers and seeded RNG only)
Input: `ChapterDefinition`, its `FloorGenRules`, depth `n` (0-based), `rooms_from_any_chapter`, the per-floor seeds.
Output: `FloorMap` = cells `{cell, room id, role, content id, doors}` plus the start cell. Cells are visited in
**index order** (`y * width + x`) wherever order matters. Isaac generator, adapted:

1. `target = min(max_rooms, base_rooms + rooms_per_depth × n + layout_rng.randi_range(0, random_extra_rooms))`.
2. Start at the centre cell `(width / 2, height / 2)`. Breadth-first queue. For each queued cell, look at the neighbours
   in the order N, E, S, W. Skip a neighbour if it is outside the grid, already filled, the target is reached, it already
   has more than one filled neighbour (no loops, no 2×2 blobs), or the `branch_chance` roll fails
   (`layout_rng.randi_range(0, 9999) >= branch_chance`). Otherwise fill it and queue it.
3. If the queue empties before reaching `target`, or there are fewer dead ends than `1 + special_room_tags.size()`, start
   a new attempt on the same RNG. After `max_attempts` failures, generation fails with a content problem naming the rules.
4. **Dead end:** a filled cell other than the start with exactly one filled neighbour.
   **Boss:** the dead end with the greatest breadth-first distance from the start (ties: lowest index).
   **Special rooms:** for each tag in `special_room_tags`, in order, one of the remaining dead ends picked with
   `layout_rng` from the list sorted by index. Every other cell is normal; the start cell is the start room.
5. **Room choice**, per cell in index order, with `rooms_rng`. The cell's door mask is the set of sides with a filled
   neighbour. Candidates are rooms that
   - have the role's type tag (`start_room_tag`, `normal_room_tag`, `boss_room_tag` or the special tag),
   - match the chapter's `room_query` (with `rooms_from_any_chapter`: any chapter's `room_query` in the `RunStructure`),
   - have `doors` covering the mask, and
   - have `min_doors` no greater than the number of doors in the mask.
   Candidates are sorted by id and picked by weight (`randi_range(0, total − 1)`). No candidates → content problem naming
   the cell, role, door mask and chapter.
6. **Content**, per cell in index order, with `content_rng`: a fixed encounter or event is used as is. A query picks from
   encounters/events matching `content_query` (or the chapter's `encounter_query`/`event_query`, or
   `boss_encounter_query` for the boss room), sorted by id, by weight. Resolved at generation, so a seed fully determines
   a floor before you set foot in it (Isaac behaviour).

A hand-made `FloorLayout` skips steps 1–5 and takes its cells as given (it still gets content picks for rooms that use a
query). Layouts are checked when loaded: cells inside the grid, connected, exactly one start and one boss.

### 3.3 Seeds and RNG streams
Seeds are decimal strings of non-negative int64, as in `BattleSnapshot`. `RunSeeds.derive(parent: int, label: String) -> int`:
```
rng := RandomNumberGenerator.new(); rng.seed = parent ^ label.hash()
return ((rng.randi() & 0x7FFFFFFF) << 32) | rng.randi()     # non-negative int63
```
`String.hash()` and `RandomNumberGenerator` are Godot's own code, so this is the same on Windows and Linux. A golden
vector pins it.

| Stream | Seed | Used for |
|---|---|---|
| `floor/<n>/chapter` | `derive(run, …)` | picking the chapter for floor slot `n` |
| `floor/<n>/layout` | `derive(run, …)` | steps 1–4 |
| `floor/<n>/rooms` | `derive(run, …)` | step 5 |
| `floor/<n>/content` | `derive(run, …)` | step 6 |
| `floor/<n>/combat/<cell index>` | `derive(run, …)` | the battle seed for that room (does not depend on the order rooms are visited) |
| `floor/<n>/event/<cell index>` | `derive(run, …)` | reserved for random event outcomes (none built in yet) |

Because each stream is separate, the order in which you explore never changes a later floor or another room's battle.
**The one non-seeded draw:** the menu picks a new run seed with Godot's global RNG when the seed field is empty. It is
shown on screen so the run can be replayed. (Later the server will issue run seeds.)

### 3.4 Run state, run log and run hash (local only in this slice)
- `RunState`: `run_id`, `seed`, `run_structure_id`, `party` (slot → character id, 1–4), `coins`, `floor_index`,
  `chapter_id`, `map` (the `FloorMap` plus `visited`/`cleared` per cell), `current_cell`, `status` (`ACTIVE`, `WON`, `LOST`).
- `RunLog` entries, appended in order: `{enter_room, floor, cell}`, `{battle, floor, cell, battleId, outcome, finalHash,
  actionLog}` (the slice 1 `ActionLog` shape), `{choose, floor, cell, page, choice}`, `{next_floor, floor}`.
- `RunHasher.hash(state)`: sorted `key=value` lines → SHA-256, same style as state hash v1. Integers only, ids as
  strings, cells by index. Used by the determinism tests; not a wire format yet.

Snapshot v1 for each battle: `{schemaVersion: 1, battleId, seed (the room's combat stream), encounterId, party: [{slot,
unitDefId: character.unit.id, level: 1}]}`. This is exactly what `/battle/start` will freeze in slice 2.

### 3.5 Demo content (new files in the user's folders, at the user's request)
A deliberately tiny run whose only job is to prove the data-driven GAS pipeline end to end: **one floor, start to boss,
several battles in a row and one event.** Everything goes through GodotGAS assets, so once this works the user can tune
and add content by hand. Values are placeholders, chosen to be easy to read rather than balanced; every file and value
is listed in the implementation summary for playtesting.

- **AttributeSet** `DemoAttributeSet` with HP, MaxHP, MP, MaxMP, ATK, DEF, SPD, CritRate, CritDmg, Energy, Toughness
  (defaults and clamps from `specs/design/combat-design.md`). Made the GodotGAS way: a set in the dashboard draft
  (`godot_gas/attributes_draft.cfg`), compiled by the dashboard's generator into `godot_gas/attributes/`. If the
  generator can't be driven headless, the user clicks Generate once. Clamps live in the generated set's
  `pre_attribute_change` hook if the generator supports it, otherwise in a thin subclass in `content/`.
- **Tags** added to `godot_gas/tag_registry.tres` (append only; `gameplay_tags.gd` regenerated through the dashboard):
  `Room.Type.Start`, `Room.Type.Normal`, `Room.Type.Boss`, `Room.Type.Treasure`, `Room.Type.Shop`, `Room.Type.Secret`,
  `Chapter.Demo`, `Encounter.Boss`, `Event.Demo`, `Ability.Basic.Strike`, `Ability.Skill.Blast`, `Ability.Enemy.Bite`,
  `Ability.Enemy.Crush`. (The GodotGAS `Example.*` tags stay; deleting them needs an explicit yes first.)
- **GAS content:** an `ExecCalc_StandardDamage` (the formula in `combat-design.md`, ×100 integer math via `Fixed`),
  a damage effect, an MP cost effect (instant, `MP −` the cost) used as the skill's GAS cost.
- **Abilities** (each a `BattleAbility` scene + animation with `execute` keys): character *Strike* (single target),
  character *Blast* (blast targeting, costs MP), enemy *Bite* (single), boss *Crush* (all party).
- **Units:** 2 characters (`demo.unit.knight`, `demo.unit.mage`) wrapped by `CharacterDefinition`s; 2 enemies
  (`demo.unit.slime`, `demo.unit.bat`) and 1 boss (`demo.unit.golem`), all with the default `EnemyBrain`.
- **Encounters:** 3 normal (tagged `Chapter.Demo`), 1 boss (tagged `Chapter.Demo`, `Encounter.Boss`).
- **Events:** 2, tagged `Event.Demo` (e.g. "a coin on the floor": take it / leave it; "a sleeping bat": sneak past /
  fight it with `StartEncounter`).
- **World:** chapter `demo.chapter`, `FloorGenRules` for 6–7 rooms with no special rooms, start room, boss room and three
  normal rooms (all-doors, two-door and dead-end variants so every door mask has a candidate), one event room, and a
  one-floor `RunStructure`.

- **Look: coloured cubes.** Every unit is a cube in its own colour (`display_color`, a new metadata field on
  `UnitDefinition`; not read by combat and not in the state hash). Each ability's animation moves the acting cube so you
  can see which move ran: *Strike* jumps, *Blast* spins, *Bite* flashes, *Crush* jumps and spins. The same animation
  carries the `execute` keys, so this also proves the animation → execution pipeline from slice 1 with real timing.

Folders: `content/{attributes,abilities,animations,effects,exec_calcs,units,characters,encounters,events,rooms,chapters,floor_rules,runs}/`.
`content/` stays the user's: after this slice the demo files are theirs to tune, rename or delete.

### 3.6 Graybox views (system code, throwaway)
- **Menu:** selectable characters as toggles (max 4, slot = click order), seed field, content-root switch
  (`res://content/` or `res://tests/fixtures/`, remembered in `user://`), Start.
- **Map:** the floor grid. Visited cells, plus cells adjacent to a visited cell, are drawn (unvisited ones show their
  role icon: boss, special); adjacent ones are clickable. Revisiting a cleared room is allowed and does nothing.
- **Room (3D):** a 13 × 7-unit box (1 unit per cell), with door gaps on the sides in the cell's door mask. Units are
  cubes on their spawn cells in their `display_color` (grey if unset); an event prop is a yellow cube. The battle starts
  as soon as the room appears, in the same 3D room.
- **Unit view:** `UnitView` (Node3D) with a `Body` (`MeshInstance3D`, cube) and an `AnimationPlayer`. Ability animations
  animate `Body:position`, `Body:rotation`, `Body:scale` or `Body:transparency` (flash). Their `execute` keys call
  `ClientGate.release_execution()`, and the animation's end calls `release_finished()`.
- **Battle panel** (overlay): unit list with HP and MP, the acting party unit's abilities (disabled when the cost can't be
  paid), target buttons, and a Skip toggle (`ClientGate.skip()`) to run animations instantly. Enemy turns run automatically.
- **Event panel:** page text, choice buttons (disabled when conditions fail).
- **Run end:** won/lost, seed, floors reached → menu.

## 4. Failure modes
None of the root `CLAUDE.md` acceptance scenarios is in scope: there is no server, queue or store yet. This slice lays
the groundwork for scenarios 5 and 6 at run level (seeded, logged, hashed). Local failure modes:

| Case | Behaviour | Test |
|---|---|---|
| Duplicate id, or a file of the wrong class in a content folder | `GameContent.problems` lists it; the menu shows the problems and won't start | `test_game_content_problems` |
| A required tag query matches nothing (no boss rooms for a chapter, no encounters) | Generation fails with a message naming the chapter, role and query | `test_generation_no_candidates` |
| Rules can't be met (too few dead ends within `max_attempts`) | Generation fails naming the `FloorGenRules` | `test_generation_attempts_exhausted` |
| Invalid hand-made layout (disconnected, no boss, cell outside the grid) | Load fails naming the layout and cell | `test_layout_validation` |
| Seed text not a non-negative int64 | Menu rejects it | `test_seed_parse` |
| Click on a cell that isn't adjacent to a visited cell | `enter_room` refuses and logs nothing | `test_run_navigation` |
| Battle runner error (content error inside combat) | Run stops with the runner error shown; not counted as a loss | `test_run_battle_runner_error` |
| Defeat or turn limit | Run status `LOST` | `test_run_lost` |

## 5. Observability
N/A: no server or metrics in this slice. The run end view shows the seed and the run hash, and the game prints the seed
and each floor's generation attempt count to the Godot log for debugging.

## 6. Test plan
All tests run in the existing in-house runner (`res://tests/run_tests.tscn`) against **fixtures only**. Content in
`content/` can never fail them.

### Fixtures (new, generated by `tests/tools/build_fixtures.tscn`, frozen)
`tests/fixtures/{rooms,chapters,floor_rules,runs,events,characters,layouts}/`: two chapters (`fixture.chapter.a`, `.b`)
tagged `Fixture.Chapter.A/B`; rooms for each role, with door masks covering every case, including one-door dead ends
and a multi-chapter room tagged with both chapters; three fixture characters wrapping the existing fixture units;
encounters tagged for pools (the existing encounters get tags and weights); two events (one with a condition and a
`StartEncounter` outcome); a 2-floor `RunStructure`; one hand-made `FloorLayout`. Fixture tags live under `Fixture.*`
and are not added to the user's tag registry (`TagMatch` doesn't need the registry).

### Unit tests (`tests/game/`)
| Test | Proves |
|---|---|
| `test_tag_match` | `TagMatch` agrees with `GameplayTagQuery.matches()` on an ASC for every field, parent matching and the empty query |
| `test_seed_derive` | golden vector: fixed `(parent, label)` → fixed output; outputs non-negative; different labels differ |
| `test_generation_deterministic` | same seed → identical `FloorMap` twice, and in a fresh process (golden map hash) |
| `test_generation_rules` | over 200 seeds: room count in range, connected, start at the centre, boss is the farthest dead end, every special tag placed once on a dead end, no cell with ≥ 2×2 filled neighbours, every room's `doors` covers its mask and `min_doors` holds |
| `test_generation_pools` | rooms only come from the chapter's query; `rooms_from_any_chapter` draws from both chapters; a multi-chapter room appears under both |
| `test_generation_no_candidates`, `test_generation_attempts_exhausted`, `test_layout_validation` | failure messages from section 4 |
| `test_streams_independent` | visiting rooms in different orders gives the same battle seeds and the same next floor |
| `test_layout_load` | a hand-made layout loads as given; query rooms still get content |
| `test_event_flow` | conditions disable choices; outcomes run in order; `GoToPage`, coins never below 0, `StartEncounter` starts a battle |
| `test_run_navigation`, `test_run_lost`, `test_run_battle_runner_error` | section 4 |
| `test_run_scripted` | a scripted player (the slice 1 `ScriptedController` for battles, fixed choices for events) plays the fixture run to the end twice: identical `RunLog` and run hash; golden run hash |
| `test_game_content_problems`, `test_seed_parse` | section 4 |

### Golden vectors (`tests/fixtures/golden/`)
`seed_derive.json`, `floor_<seed>.json` (generated map for two seeds), `run_scripted.json` (final run hash and log
length). Regenerated only on purpose with `--update-goldens`, as in slice 1.

### Done when
- [ ] `godot --headless --path client-godot res://tests/run_tests.tscn` passes (the 52 slice 1 tests plus the new ones).
- [ ] `dotnet build` and `dotnet test` pass at the root (unchanged C# side; the battle goldens still match).
- [ ] With the fixtures content root, the project opens to the menu and a full 2-floor fixture run can be played by
      clicking, won and lost.
- [ ] With the `content/` root, the demo run plays from the start room through several battles and an event to the boss
      and a win, and losing ends the run.
- [ ] A test loads the demo content with `GameContent` and reports no problems, and generates its floor for 50 seeds
      without errors (smoke test only; it never asserts balance, so tuning can't fail it).
- [ ] Only new files in `content/`; `godot_gas/` changes are additions; `presentation/` untouched; slice 1 goldens unchanged.
- [ ] Root `CLAUDE.md` status table, `client-godot/CLAUDE.md` section 0 (`game/` ownership row) and the roadmap updated.

## Files this slice creates (system-owned unless noted)
```
client-godot/game/game_main.gd(.tscn), game_content.gd, tag_match.gd, run_seeds.gd, floor_generator.gd, floor_map.gd,
                  floor_layout_loader.gd, run_state.gd, run_log.gd, run_hasher.gd, run_controller.gd
client-godot/game/defs/room_definition.gd, room_placement.gd, chapter_definition.gd, floor_gen_rules.gd,
                       run_structure.gd, floor_slot.gd, floor_layout.gd, floor_layout_cell.gd, character_definition.gd,
                       event_definition.gd, event_page.gd, event_choice.gd
client-godot/game/defs/conditions/run_condition.gd, coins_at_least.gd, has_character.gd
client-godot/game/defs/outcomes/run_outcome.gd, gain_coins.gd, lose_coins.gd, go_to_page.gd, start_encounter.gd, end_event.gd
client-godot/game/graybox/menu, map_view, room_view_3d, battle_panel, event_panel, run_end_view (.gd/.tscn)
client-godot/tests/game/test_*.gd
client-godot/tests/fixtures/{rooms,chapters,floor_rules,runs,events,characters,layouts}/..., golden/{seed_derive,floor_*,run_scripted}.json
```
Created in the user's folders: the demo set in section 3.5 under `content/`, `godot_gas/attributes_draft.cfg`,
`godot_gas/attributes/` (generated). Added to: `godot_gas/tag_registry.tres`, `godot_gas/gameplay_tags.gd` (regenerated).
Changed: `combat/encounter_definition.gd` (three metadata fields), `combat/unit_definition.gd` (`display_color` metadata), `tests/tools/build_fixtures.gd` (world fixtures,
tags on fixture encounters), `project.godot` (main scene → `res://game/game_main.tscn`).

## Decisions (review, 2026-10-19)
1. **Battle-changing features wait for snapshot v2.** Loadouts and overrides, `EnemyDefinition`/`Enemy.Boss` granted as
   tags, variants, floor scaling and HP/MP carry-over move to the system-design pass and 1d. Bosses are boss
   *encounters* here (chosen by `boss_encounter_query`). The ★ marks in `game-design.md` section 3 are updated to match.
2. **Both test data and a demo.** The menu's content-root switch runs the fixture world; Claude also builds the tiny demo
   run in `content/` (section 3.5). The user may tune or replace anything in it.
3. **Map navigation, Isaac rules:** enter any room adjacent to one you've visited; revisit cleared rooms; no fleeing.
4. **Seeds are decimal int64 strings** for now; an Isaac-style short seed code is a display format for 1c.
5. **Room grid fixed at 13 × 7**, rooms 1×1 on the map; sizes and shapes come with the room editor in 1c.
6. **AttributeSet:** Claude creates it through the GodotGAS draft and generator; the user tunes it later in the dashboard.
7. **Tag registry:** Claude may add tags; removing any tag needs the user's explicit yes first.
8. **Graybox views are system code in `game/graybox/`,** replaceable one at a time via `GameMain`'s exported view scenes.
9. **Coins exist in run state;** only events change them in this slice. Drops and shops come in 1d.
10. **Server authority comes later** (roadmap slice 2b `run-authority`): the local run log and seeded streams here are
    shaped so each out-of-battle action can become an authenticated quick message, and each battle a batched log.
11. **Demo look:** coloured cubes; ability animations jump, spin or flash the acting cube and drive the execution timing.
