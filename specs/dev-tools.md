# Spec: dev-tools (slice 1c)

Status: 📝 Spec written, awaiting review · Roadmap: slice 1c · Date: 2026-10-20
Design intent: `specs/design/game-design.md` section 6 (tool list). Builds on `specs/game-skeleton.md` (content types,
generator, run layer). Server boundary: `specs/server-authority.md` section 0 (dev tools are **client-only** and
disabled when connected).

## 1. Purpose & enterprise mapping
Make content iteration fast, **only for mechanics that already exist**: build a room and play it in seconds, jump to
any run state, see what a seed generates without playing it, and catch broken content the moment it's saved.

| Tool | Summary |
|---|---|
| **Console** | Isaac-style, backtick key, works in every scene. A command registry where a new command is one file; Tab autocomplete from content ids; history. Play commands drive the game like the screens do; cheats are logged in the run log and mark the run as a dev run. |
| **Script runner** | Runs a file of console commands headlessly against a content root and writes the resulting state as JSON, so a whole run can be played and checked without a window, by you, by tests, or by Claude. A `shot` command saves a screenshot when run with a window. |
| **Sandbox** | Plays one room (or one hand-made floor) with a chosen party, seed, depth and chapter, inside a normal `RunController`. Shared by the console (`room`, `layout`) and the **Play** buttons. |
| **New content dock** (Godot editor) | Pick a type (character, enemy, encounter, loadout, room, item, event), type an id: creates `<folder>/<id>.tres` from a basic template (characters and enemies with every stat pre-filled) and opens it in Godot's inspector. A Validate button lists content problems. |
| **Room grid** (inspector add-on) | A clickable 13 × 7 grid above a `RoomDefinition`'s normal fields: paint player and enemy spawns, event props, item pedestals and shop slots from a palette; toggle doors. Godot's own undo and save. |
| **Play buttons** (inspector add-on) | On rooms, encounters, enemies, characters and layouts: save, then start the game straight into a sandbox with that asset. |
| **Seed runner / generation viewer** | One seed: the generated floor as a map, with every room's resolved content, no playing. Many seeds: success rate, attempts, room counts and how often each room, encounter, event and item appears, to tune `FloorGenRules`. Also a headless report tool. |
| **Content validator** | Dangling or empty references, duplicate ids, queries that match nothing, rooms whose doors can't be satisfied, invalid placements, layouts and events. Runs as a test over `res://content/`, in the console, from the dock, and live under the room grid. |
| **Short seed codes** | `K7QP 2M9X`-style 8-character codes with a check character, typed anywhere a seed is typed. Decimal seeds keep working unchanged. |

Built only on what exists: no hub, gacha, server sync or in-room walking. Rooms stay **1×1** (one map cell, 13 × 7);
room sizes and shapes are deferred (see "Later"). Commands and tools act through `RunController`, `FloorGenerator`
and `ContentIndex` methods, never by reimplementing rules.

**Godot's inspector is the content editor.** Every content class is already a documented `@tool` resource with the
tag picker and typed stats, so encounters, loadouts, enemies, characters, items and events are edited there as they
are today. This slice adds only what the inspector lacks: creating a new asset in one step, placing things on a room's
grid, and playing an asset straight away. Room type, chapter and pool membership are **tags on the asset**; an item in
a room is an item pedestal or shop slot placement with a fixed item or an item query (a pedestal in a battle room
unlocks when the fight is won). No new content mechanics.

**Every tool is usable without a window (Claude parity).** Whatever a button does, a console command or headless tool
does too, through the same code: the dock's Create is `create`, the room grid is `grid`, the Play buttons are
`play`, the seed runner is `seed_report.tscn`, the validator is `validate` / `validate_content.tscn`. So Claude can
drive every tool through the script runner (2.6), and **any future tool or editor button must ship with its command**
(a test checks the pairs below). Claude never points `create` or `grid` at your `res://content/` on its own: it uses
`user://` copies for its own tests, and Claude Code's normal permission prompts (Write/Edit) for your files.

| Button / tool | Command or headless tool |
|---|---|
| Dock: Create | `create <type> <id> [folder]` (same `content_templates.gd`) |
| Dock: Validate | `validate` |
| Room grid: paint / erase / door | `grid <room id or path> paint <x> <y> <kind> [slot]` · `erase <x> <y>` · `door <n\|e\|s\|w>` · `show` (prints the grid as text) · `save [path]` (same `room_grid_ops.gd`) |
| Play button | `play <room\|encounter\|enemy\|character\|layout> <id or path>` (same sandbox as `play_main`; paths may be `user://`) |
| Seed runner | `seed_report.tscn`, console `map` |
| Screenshot | `shot <name>` with the runner's `--window` |

| Component | Used in this slice | How |
|---|---|---|
| `client-godot/game/dev/` | ✅ new | Console, commands, sandbox and Play entry scene, seed runner, validator, room grid operations, content templates (system-owned) |
| `client-godot/addons/rpg_dev/` | ✅ new | Our own Godot editor plugin: the dock, the room grid and Play buttons in the inspector (system-owned; never touches `addons/GodotGAS/`) |
| `client-godot/game/` | ✅ changed | Seed codes in `RunSeeds`; dev entries and sandbox in `RunController`/`RunState`; `FloorGenerator.check_layout` and single-room resolve; `GameMain` sandbox mode |
| `client-godot/game/tools/` | ✅ new | `seed_report.tscn` (headless seed statistics), `validate_content.tscn` (headless validator) |
| `client-godot/combat/` | ✅ small change | `Battle` accepts a dev decision (apply an effect: `kill`, `heal`) only when `allow_dev` is set; `ContentIndex` extra root and `find_item` |
| `client-godot/tests/` | ✅ | New system tests, a broken-content fixture root, new goldens |
| `project.godot` | ✅ changed | Autoload `Dev` (console host), input action `dev_console`, plugin `rpg_dev` enabled |
| `content/` | ✏️ written **by Godot when you save**, and by the dock when you click Create (a new file only; never overwrites) | Claude never uses the dock or the grid to write your folders; tests write only to `user://` |
| `presentation/demo/` | ✏️ two proposed small edits, each asked first (section 3.9) | Menu (Random fills a seed code), map view (`reveal`) |
| `Rpg.Contracts`, server, Postgres, Redis, RabbitMQ, Redpanda | ❌ | N/A: dev tools are client-only (`server-authority` section 0). Nothing they do is ever sent or rewarded. |

**Enterprise mapping:** this is the *developer-experience and data-quality* layer that a production data platform
puts in front of its pipelines. The validator is a **schema and referential-integrity check run in CI** (like
dbt tests or a schema registry's compatibility check) that blocks broken reference data before it ships. The seed
runner is a **batch simulation / what-if harness** over a pure function `(seed, content) → floor`, reporting
distributions the way a risk team back-tests a model over many scenarios. The console's dev actions are an
**audited admin override**: every override is written into the same ordered event log as normal actions and taints
the record, and overrides are **disabled in production** (connected mode), like break-glass access that only exists in
a dev environment. Seed codes are human-friendly identifiers with a **check digit** (Luhn mod N, as in card numbers
and ISINs), so a typo is refused instead of silently loading the wrong scenario.

## 2. Sequence flow
No client → server traffic. The dock and the room grid run in the Godot editor; everything else runs in the game.
In server mode (slice 2 onward) cheat commands are refused and Play always uses local mode.

### 2.1 Console
```
any scene ── key `dev_console` (backtick, physical key) ─▶ Dev (autoload, CanvasLayer 128) toggles the console
 └─ Enter "give sword 2"
     DevConsole.execute(line)
       tokens ← split on spaces ("quoted args" allowed)
       command ← registry[tokens[0]]                       registry = every DevCommand in res://game/dev/commands/
       cheat and not Dev.cheats_allowed()  → "cheats are off while connected"
       ctx ← DevContext{ game: first node in group "game_main" (or null), run: game.run, content: game.content }
       command.run(ctx, args) → text shown in the console and printed to stdout
         cheat commands call RunController.dev_*(...)
           RunController appends {"type":"dev","command":"give","args":["sword","2"]} to run_log
           state.dev = true                          run hash gains "dev=1" (only when true: goldens unchanged)
           builds the same objects content would (a GameplayEffect, an item, a RunOutcome) and runs them through
           the same code (3.3): unit changes go through GAS, never by writing numbers into run state
           any randomness draws from the stream "dev/<k>" (k = dev entries so far), never from another stream
```

### 2.2 Sandbox (console `room` / `layout`, Play buttons)
```
caller ─ GameMain.start_sandbox(SandboxRequest) ─▶ RunController.start_sandbox(content, request)
  request = {party: [character ids], seed, depth, chapter_id, room: RoomDefinition
             | layout: FloorLayout, encounter/event override}
  run state as start_run (party from default loadouts, same seed), plus state.sandbox = true and state.dev = true
  log {"type":"sandbox", "room" | "layout": id, "depth", "chapter", "seed"}
  room:   a one-cell FloorMap holding the room (it is the start cell), content resolved by FloorGenerator on the
          streams floor/<depth>/... ; the room is entered at once (its content triggers like any unvisited room)
  layout: FloorGenerator.from_layout(layout, chapter, pools) as floor <depth>; normal play on that floor
  room cleared / boss cleared → stays on the room (pickups still takeable); no next floor in a sandbox
  party dead → run lost; run-end view's button → GameMain emits sandbox_closed (instead of returning to the menu)
```
Inside a running game, the console's `room <id>` replaces the current floor with a sandbox floor and keeps the party
and inventory (it's a `dev` entry, not a new run). With no run active it starts a sandbox run with the party last
picked in the menu.

### 2.3 New content dock
```
Godot editor ── dock "RPG Content" (addons/rpg_dev)
  type ▾ (character, enemy, encounter, loadout, room, item, event) · id · folder (default: the last one used,
  first time res://content/demo/<type folder>/)
  Create → template (3.8) with the id → ResourceSaver.save(<folder>/<id>.tres) → EditorInterface.edit_resource(it)
           refused if the id is already used by that type (ContentIndex) or the file exists
  Validate → ContentValidator over res://content/ → issue list; clicking one opens its file
  Play settings: party, seed, depth, chapter (user://dev_tools.cfg), used by every Play button
```

### 2.4 Room grid and Play buttons
```
select a RoomDefinition in Godot → EditorInspectorPlugin adds, above its normal fields:
  palette: player spawn 1–4, enemy spawn 1–n, event prop, item pedestal, shop slot, eraser
  13 × 7 grid: click paints the selected kind into that cell (one placement per cell; painting replaces);
               the eraser removes; four edge buttons toggle the doors
  each click = one RoomGridOps call wrapped in EditorUndoRedoManager (Ctrl+Z works); Godot marks the file
               unsaved and Ctrl+S saves it, like any inspector edit
  clicking a placement selects it in the room's Placements list, where its other fields (item, item query,
               loadout, price) are edited in the normal inspector
  under the grid: ContentValidator.check_room(room), live
Play (on rooms, encounters, enemies, characters, layouts):
  save the resource → write user://dev_play.cfg {kind, path, party, seed, depth, chapter}
  → EditorInterface.play_custom_scene("res://game/dev/play_main.tscn")
  play_main.tscn: GameMain with its usual screens, then a sandbox (2.2) from the request:
    room → that room · layout → that floor
    encounter → the first battle room (by id) of the request's chapter, with the encounter as its override
    enemy → the same room with a one-slot encounter built in memory around the enemy
    character → a new normal run with that character in slot 1 (plus the saved party)
```
The game starts in a second or two; closing its window returns to the editor.

### 2.5 Seed runner
```
seed_runner.tscn
  one seed:   seed (code or decimal), floor n, chapter (auto = what the run structure would pick)
              floors 0..n generated in order with one pools object (so seen items carry forward as in a run)
              → map drawn: roles, room ids, per-cell content (encounter, elite variants, event, pedestal/shop items
                with prices), generation attempts; "Play this seed" starts a normal run
  many seeds: from seed S, count N (default 100), floor n
              → SeedReport: failures (seed + error, click to view), attempts min/avg/max, rooms min/avg/max,
                dead ends, and frequency tables for rooms, encounters, events, elites, items
              rules panel: edit a copy of the chapter's FloorGenRules live and re-run; Save writes the rules file
game/tools/seed_report.tscn -- --content-root res://content/ --from 1 --count 1000 --floor 0 --out report.json
              same SeedReport as JSON, for tuning outside the editor and for the golden test
```

### 2.6 Script runner (headless play, for tests and for Claude)
```
game/tools/dev_run.tscn -- --content-root res://content/ --script run.txt --out state.json [--seed K7QP2M9X]
                           [--party warrior,cleric] [--window --shots shots/] [--commands <folder>]
  --commands: copies the folder's *.gd into user://dev_commands/ first, so a script can use throwaway commands
  GameMain without screens (headless) → for each line of run.txt: DevConsole.execute(line), echo "> line" + reply
  battles: `auto` picks each party action with the battle panel's Auto rule; no presentation gate waits
  → state.json: {seed, status, floor, cell, coins, party (read through GAS: hp/mp/energy and maxima), items,
     run hash, dev flag, warnings, every command with its reply}; exit 0, 2 if a command failed, 1 tool error
  --window: runs with rendering (no --headless) so `shot <name>` saves the viewport to <shots>/<name>.png
```
Play commands (3.2) are not cheats: a script that only plays leaves the run clean, with the same run hash as the
same choices made on screen.

### 2.7 Content validator
```
ContentValidator.validate(content: ContentIndex, options) → Array[ValidationIssue]   (pure; no scene, no I/O)
  used by: test_content_valid (res://content/), test_content_validator (fixtures + broken fixtures),
           console `validate`, the dock, the room grid (room scope), game/tools/validate_content.tscn (exit 0 ok, 3 errors)
```

## 3. Data contracts
No C# records, no wire format: nothing in this slice crosses the network. Everything below is GDScript data in
`client-godot/`.

### 3.1 Short seed codes (`RunSeeds`)
- Alphabet (Crockford base32): `0123456789ABCDEFGHJKMNPQRSTVWXYZ` (no I, L, O, U). Digit value = index.
- A code is **8 characters**: 7 data characters carrying a **35-bit** seed (most significant first), then one check
  character computed with **Luhn mod 32** over the 7 data characters. Shown as `XXXX XXXX`.
- `RunSeeds.to_code(seed) -> String`: only for `0 ≤ seed < 2^35`; otherwise `""` (the seed is shown as a decimal).
- `RunSeeds.from_code(text) -> int`: uppercase; drop spaces and `-`; map `O→0`, `I→1`, `L→1`; exactly 8 characters of
  the alphabet with a correct check character, else `-1`.
- `RunSeeds.parse(text)` (used by `start_run`) accepts a decimal **or** a code. Decimal parsing is unchanged (a
  string of digits only is always a decimal), so every existing seed and golden means the same thing.
- `RunSeeds.random_code() -> String`: a code for a seed from Godot's global RNG (the one allowed non-seeded draw, as
  the menu's Random button already is).
- `RunSeeds.display(seed) -> String`: the code when there is one, else the decimal.
- Seed codes are a local-mode feature; in server mode the server issues floor seeds and the seed field is hidden.

### 3.2 Console
```gdscript
class_name DevCommand extends RefCounted        # one file per command in res://game/dev/commands/
var name: String                # what you type, lower case
var usage: String               # "give <item> [slot]"
var help: String                # one line
var cheat: bool                 # changes run state → logged as dev, refused when cheats are off
var arg_kinds: Array[String]    # per position, for autocomplete: "item", "equipment", "encounter", "event", "room",
                                # "layout", "character", "chapter", "command", "slot", "floor", "int", "seed", "text"
func run(ctx: DevContext, args: PackedStringArray) -> String   # the reply; "" = done silently
```
- **Registry:** `DevConsole` loads every `*.gd` in `res://game/dev/commands/` (sorted by path) whose script extends
  `DevCommand`; a duplicate name is a startup warning, the first one wins. Adding a command = adding one file.
  In debug builds it also loads `user://dev_commands/*.gd` after the built-in ones: **throwaway commands** that never
  touch the repo (for example one Claude writes to check one thing). A throwaway command can't replace a built-in
  name.
- **Writing a command** (also in `client-godot/DEV_TOOLS.md` and `client-godot/CLAUDE.md`): copy
  `game/dev/commands/_template.gd`, set `name`, `usage`, `help`, `cheat`, `arg_kinds`, and fill in `run()`.
  `DevContext` gives `game` (`GameMain`), `run` (`RunController`, null outside a run), `content` (`ContentIndex`),
  `battle` (the running `Battle` or null), `recorder` (its `ActionRecorder`), and helpers `arg_item(args, i)`,
  `arg_slot(...)` and so on, which return a value or a ready-made error reply. Rules: change units through GAS
  (effects, items), change the run through `RunController` (a cheat calls `run.dev_log(name, args)` first, which
  logs it, sets `dev` and returns the `dev/<k>` stream for any randomness), and never draw from another stream. If a
  command needs something the run layer doesn't expose yet, add a small method to the system code; never to content.
  Permanent commands get a test; throwaway ones don't.
- **Autocomplete:** Tab completes the command name, then the current argument from its kind (content ids sorted, from
  the current `ContentIndex`; slots from the party); repeated Tab cycles; a list shows when there are several.
- **History:** Up/Down; the last 50 lines in `user://dev_console_history.txt`.
- **Output:** scrollback in the console and `print()` to stdout (so headless runs and tests see it).
- **`Dev` autoload** (`game/dev/dev.gd`): hosts the console; `cheats_allowed()` is true in local mode (slice 2 makes
  it `not ServerLink.connected`). It is **inert** when `DisplayServer.get_name() == "headless"` or in a release build
  (`not OS.is_debug_build()`): no input handling, no UI, so the headless verifier never runs dev code.
- `GameMain` adds itself to the group `game_main` (one line); that is how commands find the run. Nothing in
  `combat/` references `game/dev/` (purity test).

**Numbers in the console are the code's own numbers:** floors are **0-based** (`stage 0` is the first floor, as in
`RunState.floor_index` and the `floor/<n>/…` stream labels); party slots are the run state's slot numbers (1–4).

| Command | Cheat | Does |
|---|---|---|
| `help [command]` | | Lists commands, or one command's usage |
| `new <party ids> [seed]` | | Starts a run (play command, like the menu) |
| `state [json]` | | Prints floor, cell, coins, party (HP/MP/ult charge and maxima read through GAS), items, use slots, equipment, open event or battle |
| `map [json]` | | Prints the floor as text: role, room id, content, visited/cleared per cell, which cells can be entered |
| `enter <cell>` | | `enter_room` (play command) |
| `choose <choice>` | | Event choice, 0-based like everything in the console (play command) |
| `take <placement> <slot>` | | Take or buy a pickup (play command) |
| `use <slot> <ability> [target slot]` | | Field action (play command) |
| `act <ability> [target]` / `auto [on\|off]` | | In battle: one party action, or Auto for the rest of the battle (play commands) |
| `next` | | Next floor after the boss (play command) |
| `shot <name>` | | Saves the viewport as a PNG (`user://shots/` or the runner's `--shots` folder); needs a window |
| `clear` | | Clears the scrollback |
| `validate [errors]` | | Runs the validator on the current content root; prints counts and issues |
| `seed [seed]` | | No argument: prints the run's seed (code and decimal) and copies it to the clipboard. With one: starts a new run with the same party and that seed (not a cheat: it's a fresh run) |
| `give <item> [slot]` | ✅ | A `GiveItem` outcome with that item: held like a picked-up item, so its `AbilitySet` is granted through GAS at every battle start and in the field (a usable item needs a free use slot) |
| `remove <item>` | ✅ | A `RemoveItem` outcome |
| `equip <equipment> [slot]` | ✅ | A `GiveEquipment` outcome (its `AbilitySet` granted through GAS like any equipment) |
| `stat <attribute> [count] [slot]` | ✅ | Gives `count` (default 1; negative = downs) **dev stat items** for that attribute (3.3): each is an item whose `AbilitySet` holds one infinite GAS modifier, so the bonus is re-derived through GAS every battle, stacks per copy and shows in the party panel. Never a number written into run state |
| `effect <effect path> [slot]` | ✅ | Applies any `GameplayEffect` `.tres` (yours or a dev one) to living members (or one) in the field context, like an `ApplyPartyEffect` outcome. Out of battle only. Instant effects stick (HP, MP, ult charge); lasting ones end with the field context, as for any out-of-battle effect: use `stat` or `give` for something permanent |
| `coins <n>` | ✅ | A `GainCoins` / `LoseCoins` outcome (coins are run state, not a unit attribute; this is what an event does) |
| `heal [slot]` | ✅ | `game/dev/content/effects/dev_heal.tres` (instant: `hp` and `mp` set to `max_hp` / `max_mp`, attribute-based) on living members. Out of battle through the field context; in battle as a dev decision (3.6) |
| `revive [slot]` | ✅ | `dev_revive.tres` (instant, `hp` to 1) on dead members through the field context, the way a revive item works |
| `kill [enemies\|party\|<slot>]` | ✅ | In battle only. Queued; at the next party decision the battle applies `dev_kill.tres` (instant, `hp` to 0) through GAS, then the usual death and end checks (3.6) |
| `win` | ✅ | Ends the run as Won (tests the run-end screen; run status, not a unit change) |
| `stage <floor>` | ✅ | Enters floor `<floor>` (0-based) of the run structure (party and inventory kept) |
| `room <room>` | ✅ | Sandbox floor with that room (2.2) |
| `layout <layout>` | ✅ | Sandbox floor from that layout |
| `spawn <encounter>` | ✅ | Starts a battle with that encounter in the current room (like an event's `StartEncounter`; enemies resolved with the floor's scaling, elite rolls from `dev/<k>`) |
| `spawn item <item> [price]` | ✅ | Adds a pickup to the current room (price 0 = free pedestal, else a shop slot). Taken with the normal Take/Buy, so pickup rules, `on_pickup` and the "give to" picker are the real ones. Usable after the room is cleared, like any pickup |
| `spawn pool <tag> [price]` | ✅ | Same, with the item picked by weight from unlocked items carrying `<tag>` (same pick as a pedestal's `item_query`, on `dev/<k>`) |
| `reveal` | ✅ | Sets `state.revealed`; `RunController` emits `map_revealed`; the map view shows every room |
| `seeds` | | Opens the seed runner (so the user's menu needs no Dev button) |
| `create <type> <id> [folder]` | | The dock's Create: a new asset from its template (refuses existing ids and files) |
| `grid <room> <op> …` | | The room grid without a window: `paint`, `erase`, `door`, `show`, `save` on a room loaded by id or path (edits an in-memory copy until `save`) |
| `play <kind> <id or path>` | | A Play button: the same sandbox for a room, encounter, enemy, character or layout |

### 3.3 Dev commands go through GAS
A dev command is **a content action without a content file**: it builds the same object content would use and runs it
through the same code. Nothing writes a unit's numbers directly.

| Changes | Goes through | Commands |
|---|---|---|
| A unit's attributes, now | An instant `GameplayEffect` applied by GAS (field context out of battle, a dev decision in battle) | `heal`, `revive`, `kill`, `effect` |
| A unit's attributes, for the rest of the run | An **item** (or equipment) held in run state, whose `AbilitySet` GAS grants at every battle start and field context, the only way anything permanent exists (game-skeleton 3.1: stats are always re-derived) | `stat`, `give`, `equip` |
| Run-level values (coins, inventory, pickups) | The existing `RunOutcome`s and pickup code | `coins`, `give`, `remove`, `spawn item`, `spawn pool` |
| Where the run is | `RunController` (floors, rooms, sandbox, run end) | `stage`, `room`, `layout`, `spawn`, `win`, `reveal` |

To make that possible, `RunController.apply_party_effect` gains an optional slot list (`apply_member_effect(effect,
slots, include_dead)`), the same field-context path with fewer targets.

**Dev content** (`res://game/dev/content/`, system-owned, built by `game/tools/build_dev_content.tscn`):
- `effects/dev_heal.tres`, `dev_revive.tres`, `dev_kill.tres` (instant, on the shared `hp` / `mp` attributes).
- **Dev stat items**, one up and one down per attribute a character keeps between battles: `dev_up_<attr>` /
  `dev_down_<attr>` for `max_hp`, `max_mp`, `atk`, `def`, `spd`, `crit_rate`, `crit_dmg`, `max_energy`. Each is a
  `PASSIVE` `ItemDefinition` (`applies_to` `HOLDER`, tag `Dev`) whose `AbilitySet` holds one saved infinite
  `GameplayEffect` with one additive modifier of one **step**: `max_hp` 100, `max_mp` 50, `atk` / `def` / `spd` 10,
  `crit_rate` / `crit_dmg` 5 %, `max_energy` 10 (typed values, stored ×100). `stat atk 3` = three `dev_up_atk`
  copies = +30 ATK, stacking because ability-set effects stack (game-skeleton 3.4).
- `ContentIndex` loads this folder as an **extra root** only when `Dev.cheats_allowed()`, into its own `dev_items`
  table: dev items are **never in any pool** (queries never see them, so no generation or golden can change), and
  `ContentIndex.find_item(id)` looks in `items` then `dev_items` (the battle and the run use it instead of
  `items[id]`). The headless verifier never loads the folder, so a battle snapshot holding a dev item can never
  verify.
- Attribute names come from your `UnitAttributeSet`; if one is renamed, the validator reports the dev effect
  (`dangling_ref`) and `stat` refuses that attribute.

### 3.4 Run state and log additions
- `RunState.dev: bool` (false). `canonical_lines()` appends `dev=1` **only when true**, so non-dev hashes and every
  existing golden are unchanged. `RunState.sandbox: bool`, `RunState.revealed: bool` (view flag, not hashed).
- New run log entries: `{"type":"dev","command":<name>,"args":[...]}` and `{"type":"sandbox",...}` (2.2).
- New RNG stream label: `dev/<k>`, the k-th dev entry of the run (0-based). No other stream is ever touched by a dev
  command, so a dev command never shifts later rooms or floors.
- A dev run is still **deterministic**: replaying its log with the same commands gives the same run hash (tested).
  It is never uploaded: from slice 2 the action queue refuses a run with `state.dev`.

### 3.5 Sandbox request
```gdscript
class_name SandboxRequest extends RefCounted
var party: Array[StringName]          # 1–4 character ids
var seed: int                          # run seed; streams are the usual floor/<depth>/... under it
var depth: int = 0                     # floor index (0-based), for scaling and stream labels
var chapter_id: StringName = &""       # "" = the first chapter (by id) whose room_query matches the room, else the first chapter
var room: RoomDefinition               # either room …
var layout: FloorLayout                # … or layout
var encounter: EncounterDefinition     # optional override of the room's content
var event: EventDefinition             # optional override
```
The room's role comes from its tags against the chapter's `FloorGenRules` (boss tag → boss, a special tag → special,
otherwise normal), so a boss room resolves `boss_encounter_query` as in a real floor.

### 3.6 Battle dev decision (`combat/`)
- `Battle.allow_dev: bool` (false). `RunController` sets it only in local mode. The replay runner never sets it.
- `ActionRecorder.submit_dev(name: StringName, effect: GameplayEffect, targets: String)`, where `name` is `Dev.Kill`
  or `Dev.Heal` and the effect is the matching dev effect (3.3), passed in by the run so `combat/` never references
  `game/dev/`. The next `choose()` returns `{"dev": name, "effect": effect, "targets": "enemies" | "party" |
  "<slot>"}` instead of waiting for the player.
- `Battle._take_action`: a `dev` choice with `allow_dev` applies the effect to the chosen units with
  `apply_to_units` (GAS, the same call event effects use), drains the trigger queue, runs `_check_deaths` /
  `_check_end` as after an action, and records an ordinary `ActionEntry`: `{"turn", "actor", "ability": <name>,
  "target": <targets>, "checkpoint"}`. It has the existing entry shape, so the replay runner's request check and the
  C# `ActionEntry` record accept it unchanged. It doesn't use up the actor's turn: if the battle goes on, the same
  actor is asked again.
- **On replay** (`allow_dev` false) no unit has the ability `Dev.Kill` or `Dev.Heal`, so `validate_action` returns
  `IllegalAbility` and the battle is **Rejected with 2002** like any other illegal action. No new `MismatchReason`,
  no contract change. (`Dev.*` is a reserved tag prefix; the validator flags content that uses it.)
- `give`, `stat`, `equip` and `remove` during a battle change run state, which a battle captured at its start, so they
  apply from the next battle or field action; the console says so.

### 3.7 Content validator
```gdscript
class_name ValidationIssue extends RefCounted
var severity: String   # "error" | "warning"
var code: String       # stable, e.g. "dangling_ref", see table
var path: String       # resource path (+ "::field[index]")
var message: String    # names the content, the field and what's wrong
```
`ContentValidator.validate(content, {"generate_seeds": 20})` returns issues sorted by (severity, path, code).
`check_room(room, content)` and `check_layout(layout, content)` run the subsets the room grid and Play need.

| Code | Severity | Finds |
|---|---|---|
| `content_index` | error | Every `ContentIndex.problems` entry (duplicate ids, wrong class) |
| `missing_id` | error | A definition with an empty `id` |
| `dangling_ref` | error | A null entry where content is required: encounter slot without enemy, floor slot without chapters, chapter without rules or scaling, layout cell without room, `GiveItem`/`StartEncounter` without item/query/encounter, … |
| `bad_loadout_ref` | error | A `LoadoutRef` that `ContentIndex.resolve_loadout` can't resolve |
| `bad_skill` | error | A loadout skill not in the character's abilities or `learnable_skills`; an ability scene that isn't a `BattleAbility` |
| `empty_query` | error | A query a floor depends on matches nothing: each role's room query (start, normal, boss, each special tag) per chapter; `encounter_query`, `boss_encounter_query`; `event_query` when an event room can use it; a room's `content_query` |
| `empty_item_pool` | warning | A placement's `item_query` matches no item (the run falls back to `fallback_item`); error if there is no `fallback_item` |
| `zero_weights` | error | A pool whose matches all have weight 0 |
| `doors_unsatisfiable` | error / warning | Error: `min_doors` greater than the doors the room has. Warning per chapter and role: a door mask the generator can produce that no candidate room accepts (dead-end roles: each single-door mask; normal: all 15 masks), so a seed can fail |
| `placement_outside` | error | A placement cell outside the 13 × 7 grid |
| `placement_overlap` | error | Two placements on one cell |
| `spawn_mismatch` | warning | A room with a fixed encounter has fewer enemy spawns than encounter slots; a room with an encounter has no player spawn |
| `placement_kind` | warning | Shop slots in a room whose tags aren't a shop type, pedestals in a battle room, `price` on a non-shop slot |
| `bad_layout` | error | Everything `FloorGenerator.check_layout` refuses: not connected, not exactly one start and one boss, outside the grid, doors don't fit |
| `bad_event` | error | `GoToPage` out of range; a page with no choices |
| `bad_item` | error | `USABLE` without `use_ability`; `COOLDOWN` with `cooldown_battles` 0 |
| `unknown_tag` | warning | A `gas::tag` value not in the registry (the check `sync_tags.tscn` already does, shared) |
| `generation_fails` | error | With `generate_seeds` > 0: a floor slot that fails to generate for one of seeds 1..N (names the seed and the error) |

Balance is never checked: tuning can't fail the validator.

### 3.8 Editor add-on (`addons/rpg_dev/`)
**Templates** are code in `game/dev/content_templates.gd` (no template files to keep in sync). `create(type, id)`
returns a new resource; the dock saves it.

| Type | Default folder | Template |
|---|---|---|
| Character | `characters/` | id, display name (from the id), `attribute_set` = the set most existing units use, `stats` pre-filled with **every attribute of that set** at its default (so you only change numbers), a display colour, `selectable` |
| Enemy | `enemies/` | The same, without `selectable` |
| Encounter | `encounters/` | id, display name, weight 1, no slots (add enemies in the inspector) |
| Loadout | `loadouts/` | id |
| Room | `rooms/` | id, display name, all four doors, `min_doors` 1, weight 1, player spawns 1–4 in the left column |
| Item | `items/` | id, display name, `PASSIVE`, weight 1, price 0 |
| Event | `events/` | id, display name, one page with one choice that ends the event |

- The validator lists what a new asset still needs (a character with no abilities, an encounter with no slots), so
  "what do I fill in next" is always visible.
- **Room grid operations** are a plain class, `game/dev/room_grid_ops.gd` (`paint(room, cell, kind, slot)`,
  `erase(room, cell)`, `toggle_door(room, side)`), so tests drive them headless. The inspector add-on only draws the
  grid and wraps each call in `EditorUndoRedoManager`. It reads and writes resource properties and calls the content
  classes' `@tool` methods; it never instantiates abilities or runs GAS in the editor.
- **Play** writes `user://dev_play.cfg` and calls `EditorInterface.play_custom_scene`. `play_main.tscn` reads the
  request once and deletes it; with no request it opens the menu, so F6 on it is harmless.
- The plugin is ours (`addons/rpg_dev/plugin.cfg`), enabled in `project.godot`; GodotGAS's own plugin is untouched.
- **Feasibility spike (2026-10-20, passed):** a throwaway plugin ran inside the Godot 4.7.2 editor (headless, on a
  copy of the project) and confirmed: loading and duplicating a demo room, appending a `RoomPlacement`, calling the
  room's `@tool` methods and typed setters; building a `ContentIndex` over `res://content/` and calling it (non-`@tool`
  system classes work when created from editor code); `EditorUndoRedoManager` do/undo/redo on `placements`; an
  `EditorInspectorPlugin` receiving the `RoomDefinition` and adding a 13 × 7 button grid; save/reload through
  `ResourceSaver`; creating a new room file in `res://` and registering it with the editor filesystem; and that
  `EditorInterface.play_custom_scene` exists. Not covered headless: actually launching Play (checked by hand at
  implementation).

### 3.9 Proposed edits to your `presentation/demo/` files (asked one by one at implementation)
| File | Change | Why |
|---|---|---|
| `menu.gd` | Random fills `RunSeeds.random_code()` instead of `str(randi())` | Seed codes |
| `map_view.gd` | Show every room when `run.state.revealed`; refresh on `map_revealed` | `reveal` |
Without them the tools still work; only those two features don't show in your screens.

### RabbitMQ / Redpanda / Redis
N/A: no backend in this slice.

## 4. Failure modes
None of the root `CLAUDE.md` acceptance scenarios is in scope (no server). The slice protects **scenario 5** ahead
of time: dev changes are logged and taint the run (`dev=1` in the run hash), cheats are refused when connected, the
`Dev` autoload is inert headless, and a battle log with a dev decision is rejected with 2002 on replay. Local
failure modes:

| Case | Behaviour | Test |
|---|---|---|
| Unknown command or wrong arguments | Reply with the usage; nothing changes, nothing logged | `test_console_errors` |
| Cheat while cheats are off | Refused, nothing logged | `test_console_cheats_off` |
| Unknown content id in a command | "no item 'x'" plus the closest ids; nothing changes | `test_console_errors` |
| `kill` outside a battle | Refused with a reason | `test_console_kill` |
| `kill` while an enemy is acting | Queued until the next party decision; dropped with a message if the battle ends first | `test_console_kill` |
| `give` with no one able to hold the item | Refused before the outcome runs (not lost, unlike an event gift) | `test_console_give` |
| `stat` for an attribute the AttributeSet doesn't have | Refused, listing the attributes that have dev items | `test_console_stat` |
| `give` / `stat` during a battle | Applied to run state; takes effect from the next battle or field action (said in the reply) | `test_console_stat` |
| `effect` in battle, or with a file that isn't a `GameplayEffect` | Refused | `test_console_effect` |
| `spawn item` in a room not yet cleared | Added; takeable once the room is cleared, like any pickup | `test_console_spawn_item` |
| Dev items leaking into pools or generation | Impossible: separate `dev_items` table no query sees; proven with goldens and a pool test | `test_dev_items_never_pooled` |
| A snapshot holding a dev item replayed | Fails: the verifier's index has no dev items | `test_replay_rejects_dev_item` |
| A dev command changing later rooms or floors | Impossible by construction (`dev/<k>` stream); proven | `test_dev_streams_isolated` |
| A battle log with a dev entry replayed | Rejected, 2002 `IllegalAbility` | `test_replay_rejects_dev_battle` |
| `Dev` autoload in the headless verifier | Inert; every replay golden unchanged | existing goldens + `test_dev_inert_headless` |
| A command file that fails to load or duplicates a name | Startup warning naming the file; other commands work | `test_console_registry` |
| Bad seed code (typo, wrong length, bad check) | Refused with "not a seed" | `test_seed_codes` |
| Dock: id already used, or the file exists | Refused, naming the existing file; nothing written | `test_content_templates` |
| Room grid: two placements in one cell, or outside the grid | Impossible: painting replaces, the grid is 13 × 7 | `test_room_grid_ops` |
| Play with an unsaved or broken asset | Play saves first; broken content shows as content problems in the game, like the menu does | `test_play_request` |
| Play request file missing or stale | `play_main` opens the menu; the request is deleted after one use | `test_play_request` |
| Broken content | Each validator code reported once, naming the file and field | `test_content_validator` |

## 5. Observability
No Prometheus metrics: nothing runs on the server. Local signals instead:
- Console output goes to stdout as well as the scrollback.
- `validate_content.tscn` and `seed_report.tscn` print a one-line summary and exit with a code (0 ok, 3 content
  errors, 1 tool error), so they can run in CI later.
- `SeedReport` (JSON): `{floor, from, count, failures: [{seed, error}], attempts: {min, avg_x100, max},
  rooms: {min, avg_x100, max}, dead_ends: {...}, rooms_used: {id: n}, encounters: {id: n}, events: {id: n},
  elites: {variant id: n}, items: {id: n}}`, integers only, keys sorted.

## 6. Test plan
All in the Godot suite (`tests/game/` unless noted), on `tests/fixtures/` only, except the one content test.

### Fixtures
- **Broken content root** `tests/broken_fixtures/` (frozen, built by `tests/tools/build_fixtures.tscn`): one file per
  validator code, each named after it (`rooms/doors_unsatisfiable.tres`, …). Separate root, because `ContentIndex`
  scans `tests/fixtures/` recursively and must keep seeing valid content.
- Nothing is added to `tests/fixtures/` that a fixture chapter's queries could match, so no existing golden changes.

### Unit and system tests
| Test | Proves |
|---|---|
| `test_seed_codes` | Golden vectors (seed ↔ code), round trip for 1000 seeds, normalisation (lower case, spaces, `-`, `O/I/L`), every single-character substitution at every position is refused, decimal parsing unchanged, `display()` |
| `test_console_registry` | Every file in `game/dev/commands/` loads; names unique; every command has usage and help; a test-only command file is picked up without code changes; a command in `user://dev_commands/` is loaded in debug, can't shadow a built-in, and is ignored in a release build; `_template.gd` itself is not registered |
| `test_console_autocomplete` | Command names; argument completion by kind from fixture ids, sorted; Tab cycling |
| `test_console_errors` / `test_console_cheats_off` | Section 4 rows; run log and hash unchanged afterwards |
| `test_console_give`, `_remove`, `_equip`, `_coins`, `_heal`, `_revive`, `_stage`, `_spawn`, `_win`, `_reveal` | Each command's effect on fixture run state, its `dev` log entry, `dev=1` in the hash; `stage 0` is the first floor; `heal`/`revive` change HP only through the field context (no direct writes: the run state's HP equals what GAS read back) |
| `test_console_stat` | `stat atk 3 1` → three `dev_up_atk` items on slot 1; `party_stats()` (read through GAS) and the next battle's ATK are +30 typed (3000 stored); `stat atk -1` lowers it; unknown attribute refused; mid-battle reply |
| `test_console_effect` | A fixture instant effect changes HP/MP through the field context; a lasting one is gone afterwards; refused in battle and for non-effects |
| `test_console_spawn_item` | `spawn item` / `spawn pool` add a pickup; Take and Buy work through `take()` with coins, `on_pickup` and use-slot rules; `spawn pool` is deterministic per `dev/<k>` |
| `test_dev_items_never_pooled` | With the dev root loaded, every fixture floor golden and the scripted-run golden are unchanged, and no query matches a dev item |
| `test_replay_rejects_dev_item` (`tests/combat/`) | A snapshot whose party holds `dev_up_atk`, replayed without the dev root, does not verify |
| `test_console_kill` | Kill enemies → Victory through normal death handling (death triggers fire, coin drop and cooldowns as after a real win); kill party → Lost; kill one slot → battle goes on, same actor asked again; refused outside a battle; queued during an enemy turn |
| `test_dev_streams_isolated` | A run with `give`/`spawn` mid-floor has the same next floor (canonical map lines) as without |
| `test_dev_run_replays` | Replaying a dev run's log (commands included) twice gives the same run hash |
| `test_scripted_run_unchanged` | The existing scripted-run golden still matches (no `dev` line) |
| `test_replay_rejects_dev_battle` (`tests/combat/`) | A log with a `dev` entry → Rejected, 2002, `IllegalAbility` |
| `test_dev_inert_headless` | Under `--headless` the `Dev` autoload has no children and handles no input |
| `test_purity` (extended, `tests/combat/`) | `combat/` never references `game/dev/` or `Dev` |
| `test_sandbox_room` | Each fixture room type in a sandbox: battle room fights, event shows, shop sells, boss resolves the boss query; hash golden for (room, seed 7, party, depth 0) |
| `test_sandbox_layout` | The fixture layouts play as floor 0 in a sandbox |
| `test_content_validator` | Fixtures: zero errors. Broken root: exactly the expected (code, path) pairs, nothing else |
| `test_content_valid` *(content test)* | `ContentValidator` over `res://content/` with 20 generation seeds: no errors (warnings printed). Like content goldens, a failure means your content is broken, not the system; skipped if `content/` has no run structure |
| `test_seed_report` | `SeedReport` for fixture seeds 1..50, floor 0, equals `golden/game/seed_report.json` |
| `test_content_templates` | Every template, saved to `user://` and loaded through a `ContentIndex`, has its id and the expected defaults; character and enemy stats hold every attribute of the set; the validator reports only the listed "fill this in" issues; refusing a used id or existing file |
| `test_room_grid_ops` | Paint each kind, replace, erase, toggle each door, on a fixture room copy; `check_room` after each |
| `test_play_request` | `play_main` with each request kind on fixtures starts the right sandbox (room, encounter, enemy, character, layout); no request → menu; the request is consumed |
| `test_tool_parity` | Every dock and inspector action has its command (the parity table), and both paths give the same result: `create` vs the dock's create function, `grid` ops vs `RoomGridOps`, `play` vs a `play_main` request, on fixtures and `user://` only |
| `test_dev_script_runner` | A script of play commands only replays the fixture scripted run and ends with **the scripted-run golden's hash** and no dev flag; a script with a cheat sets the flag; a failing command gives exit 2 and names the line |
| `test_dev_tool_scenes` | Each tool scene (console, seed runner, `play_main`) instantiates with the fixture root and runs 10 frames without errors (needs `--quit-after`) |

### Golden vectors
`golden/game/seed_codes.json` (seed ↔ code pairs incl. 0, 1, 2^35 − 1), `seed_report.json`, `sandbox_room.json`.
Existing goldens must not change; any diff there is a bug in this slice.

### C#
N/A: no contract changes.

### Done when
`dotnet build` / `dotnet test` and the Godot suite pass; `test_content_valid` passes on your `content/`; by hand, in
the Godot editor: create an enemy, an encounter using it and a room with the dock; paint the room on the grid
(Ctrl+Z works); press Play on each and land in the right fight; a seed code typed in the menu starts the same run
every time; the console's `give` works in a running game.

### Suggested implementation order (one slice, five checkpoints, tests green at each)
1. Content validator (+ broken fixtures, headless tool, content test) and seed codes.
2. **Content creation first** (the user's priority): sandbox, `play_main`, content templates and the dock, room grid,
   Play buttons.
3. Console, `Dev` autoload, play commands and the script runner, cheats, dev log entries, battle dev decision.
4. Seed runner (model + headless report, then the scene).
5. The proposed `presentation/demo/` edits.

## Files this slice creates or changes (system-owned unless noted)
```
client-godot/project.godot                    autoload Dev, input action dev_console
client-godot/game/run_seeds.gd                seed codes
client-godot/game/run_state.gd                dev, sandbox, revealed
client-godot/game/run_controller.gd           dev_* methods, apply_member_effect, start_sandbox, map_revealed, allow_dev
client-godot/game/game_main.gd                group game_main, start_sandbox, sandbox_closed
client-godot/game/floor_generator.gd          check_layout (shared with from_layout), single-room resolve for the sandbox
client-godot/game/dev/                        dev.gd (autoload), dev_console.gd/.tscn, dev_command.gd, dev_context.gd,
                                              sandbox_request.gd, commands/*.gd, content_validator.gd,
                                              validation_issue.gd, seed_report.gd, seed_runner.gd/.tscn,
                                              content_templates.gd, room_grid_ops.gd, play_main.gd/.tscn
client-godot/addons/rpg_dev/                  plugin.cfg, plugin.gd, content_dock.gd/.tscn, room_inspector.gd,
                                              play_button_inspector.gd
client-godot/game/tools/seed_report.tscn, validate_content.tscn, build_dev_content.tscn, dev_run.tscn
client-godot/game/dev/content/                dev effects and dev stat items (3.3), built by build_dev_content
client-godot/combat/battle.gd, action_recorder.gd   dev decision, allow_dev
client-godot/combat/content_index.gd           extra root, dev_items, find_item (battle and run use it)
client-godot/tests/game/test_*.gd             section 6
client-godot/tests/broken_fixtures/           new root
client-godot/tests/fixtures/golden/game/      new goldens
client-godot/tests/tools/build_fixtures.gd    builds the broken fixtures
client-godot/presentation/demo/               (yours) the edits in 3.9, each asked first
specs/roadmap.md, CLAUDE.md, client-godot/CLAUDE.md   status, current-state table, ownership row for game/dev/
```

## Decisions (proposed, for review)
1. **Godot's inspector is the editor** (2026-10-20, at the user's request: data-driven, don't over-engineer). We add
   only a create-from-template dock, a room grid and Play buttons as a small editor plugin of our own. Godot keeps
   doing saving, undo and every field. (Replaces the earlier in-game editor screens.)
2. **Cheats are logged, not hidden:** a `dev` entry in the run log and `dev=1` in the run hash, so a dev run is still
   replayable and can never pass as a clean one.
3. **`kill` goes through GAS** (an instant effect at the next party decision, option A of the review) instead of
   ending the battle from outside or at every turn, so death handling, triggers and the end check are the real ones
   and the action log contract is unchanged. On replay a dev entry is an illegal action (2002).
4. **Seed codes carry 35 bits plus a Luhn mod 32 check character** (34 billion codes). Larger seeds still work as
   decimals.
5. **Rooms stay 1×1** in this slice (2026-10-20, at the user's request): room sizes and shapes are not a priority.
6. **The validator never checks balance**, so tuning can't fail it; `test_content_valid` is a content test, like
   content goldens.
7. **The console uses the code's numbers** (2026-10-20, at the user's request): floors 0-based, slots as stored.
8. **Dev commands change units through GAS** (2026-10-20, at the user's request): GameplayEffects for changes now,
   items whose AbilitySets GAS grants for the rest of the run (dev stat items). GAS only where it makes sense:
   coins and run status stay plain run-state code through the existing RunOutcomes.
9. **Items in rooms stay placements** (2026-10-20): pedestals and shop slots, with a fixed item or a pool query; a
   pedestal in a battle room unlocks when the fight is won. No encounter drop table.

## Later (not in this slice)
- **Floor layout grid** in the inspector (the same add-on for `FloorLayout`: assign rooms and roles to map cells).
  Until then layouts are edited in the inspector and played with Play or `layout <id>`.
- **Strict animation controller and animation set for characters** (user, 2026-10-20): a fixed set of named
  animations every unit provides, so a new character or enemy slots in without hand-wiring each ability's animation
  and `execute` keys. Roadmap slice 1c3 `animation-sets`.
- **Room sizes and shapes** (Isaac's 2×1, 1×2, 2×2, L rooms). Deferred at the user's request. When it comes back:
  a `shape` field defaulting to 1×1 (old files unchanged), door bits per edge, a separate `floor/<n>/shapes` stream
  gated by a `FloorGenRules` chance defaulting to 0, so existing floors and goldens stay byte-identical.
