# Spec: dev-tools (slice 1c)

Status: ✅ Done (synced with the implementation 2026-10-20; the end-to-end harness synced 2026-10-27) · Roadmap: slice
1c · Date: 2026-10-20
Design intent: `specs/design/game-design.md` section 6 (tool list). Builds on `specs/game-skeleton.md` (content types,
generator, run layer). Server boundary: `specs/server-authority.md` section 0 (dev tools are **client-only**; cheats are
refused on server runs, while play commands play a server run the way the screens do).

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
| `client-godot/combat/` | ✅ small change | `Battle` accepts a dev decision (apply an effect: `kill`, `heal`) only when `allow_dev` is set; `ActionRecorder.submit_dev`; `ContentIndex.add_root` (dev content) and `overlay` (sandbox) |
| `client-godot/tests/` | ✅ | New system tests, a broken-content fixture root, new goldens |
| `project.godot` | ✅ changed | Autoload `Dev` (console host; it registers the `dev_console` input action at start), plugin `rpg_dev` enabled |
| `content/` | ✏️ written **by Godot when you save**, and by the dock when you click Create (a new file only; never overwrites) | Claude never uses the dock or the grid to write your folders; tests write only to `user://` |
| `presentation/demo/` | ✏️ two small edits, approved (section 3.9) | Menu (Random fills a seed code), map view (`reveal`) |
| `Rpg.Contracts`, server, Postgres, Redis, RabbitMQ, Redpanda | ❌ | N/A: dev tools are client-only (`server-authority` section 0). No cheat is ever sent or rewarded: cheats are refused on server runs. Play commands on a server run reach the server only as play does (through `ServerLink`); the end-to-end harness (E1–E8) drives the server that way |

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
No client → server traffic of their own. The dock and the room grid run in the Godot editor; everything else runs in
the game. In server mode (slice 2 onward) a cheat command is refused while the current run is a server run (the
console checks `run.state.seeds().server_mode()`), and Play (sandbox) always uses local mode.

### 2.1 Console
```
any scene ── key `dev_console` (backtick, physical key) ─▶ Dev (autoload, CanvasLayer 128) toggles the console
 └─ Enter "give sword 2"
     DevConsole.execute(line)
       tokens ← split on spaces ("quoted args" allowed)
       command ← registry[tokens[0]]                       registry = every DevCommand in res://game/dev/commands/
       cheat and not console.cheats_allowed  → "cheats are off while connected"
       ctx ← DevContext{ game: first node in group "game_main" (or null), run, content (the run's), battle, recorder }
       command.run(ctx, args) → {ok, text}: shown in the console and printed to stdout (ok = false after ctx.fail())
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
and inventory (it's a `dev` entry, not a new run). With no run active it starts a sandbox run with the Play settings'
party (else the first two selectable characters, `PlayRequest.party_for`). Unsaved rooms, rooms outside the content
root and encounters built in memory are played through `ContentIndex.overlay()`, a copy of the index; the shared
index is never changed. A sandbox room's start cell is not pre-cleared (its content plays); a layout's start is.

### 2.3 New content dock
```
Godot editor ── dock "RPG Content" (addons/rpg_dev)
  type ▾ (character, enemy, encounter, loadout, room, item, event) · id · folder (default: the last one used,
  first time res://content/demo/<type folder>/)
  Create → template (3.8) with the id → ResourceSaver.save(<folder>/<last id segment>.tres) → edit_resource(it)
           (demo.enemy.slime → slime.tres); refused if the id is already used by that type or the file exists
  Validate → ContentValidator over the content root → issue list; double-click one to open its file
  Play settings: party, seed, depth, chapter, content root (user://dev_tools.cfg, [play]), used by every Play button
```

### 2.4 Room grid and Play buttons
```
select a RoomDefinition in Godot → EditorInspectorPlugin adds, above its normal fields:
  palette: Player, Enemy, Prop, Pedestal, Shop, Erase, Select, and a slot number (party or encounter slot)
  13 × 7 grid: click paints the selected kind into that cell (one placement per cell; painting replaces);
               Erase removes; four edge buttons toggle the doors
  each click = one RoomGridOps call wrapped in EditorUndoRedoManager (Ctrl+Z works); Godot marks the file
               unsaved and Ctrl+S saves it, like any inspector edit
  Select + click a placement opens it in the inspector, where its other fields (item, item query, loadout,
               price) are edited; the inspector's back arrow returns to the room
  under the grid: ContentValidator.check_room(room), live
Play (on rooms, encounters, enemies, characters, layouts):
  save the resource → write user://dev_play.cfg {kind, target: its path} (settings come from dev_tools.cfg)
  → EditorInterface.play_custom_scene("res://game/dev/play_main.tscn")
  play_main.tscn: GameMain with its usual screens, then a sandbox (2.2) from the request:
    room → that room · layout → that floor
    encounter → the first normal battle room (by id) of the chapter (else any room with an enemy spawn), with the
                encounter as its override
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
                dead ends, and frequency tables for rooms, encounters, events, elites, items (failures listed,
                not clickable)
              rules panel: base rooms, rooms per depth, random extra rooms, max rooms and branch % on a copy of the
                floor's first chapter's FloorGenRules; re-run live; Save writes the rules file
  "Back to the game" returns to game_main.tscn
game/tools/seed_report.tscn -- --content-root res://content/ --from 1 --count 1000 --floor 0 --out report.json
              same SeedReport as JSON, for tuning outside the editor and for the golden test
```

### 2.6 Script runner (headless play, for tests and for Claude)
```
game/tools/dev_run.tscn -- --script run.txt [--out state.json] [--content-root res://content/] [--manual]
                           [--window --shots shots/] [--commands <folder>]
  --commands: copies the folder's *.gd into user://dev_commands/ first, so a script can use throwaway commands
  GameMain with its screens, animations skipped (skip_animations) → for each line (blank and # lines skipped):
     DevConsole.execute(line), echo "> line" + reply, then wait for any battle to finish
  battles: on auto (DevConsole's copy of the battle panel's rule: first usable ability, first valid target);
     --manual: the runner stops waiting when a party member waits, for `act`
  start a run with `new <ids> [seed]` (there are no --seed / --party options)
  → state.json (DevReport.state_of): {seed, seedDecimal, status, floor, chapter, cell, coins, party (read through
     GAS: hp/mp/energy and maxima, items, use slots, equipment, skills, gear), armor, event, battle, lastBattle,
     dev, sandbox, runHash, warnings, runnerError, commands: [{line, command, ok, reply}], failed: ["line n: ..."]}
     (spec item-pass: armor = the armor inventory; gear = every run slot and what fills it; lastBattle =
     RunController.battle_log: hits with hit_tags, triggered activations, breaks, recoveries, One More actions)
  exit 0, 2 if a command failed, 1 tool error
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
                                # "layout", "character", "unit", "chapter", "command", "slot", "attribute",
                                # "play_kind", "type", "grid_op", "place", "side", "target", "ability", "on_off",
                                # "int", "seed", "text"
func run(ctx: DevContext, args: PackedStringArray) -> String   # the reply (may await); errors: return ctx.fail(why)
```
- **Registry:** `DevConsole` loads every `*.gd` in `res://game/dev/commands/` (sorted by path, files starting with
  `_` skipped) whose script extends `DevCommand`; a duplicate name is a startup warning, the first one wins. Adding a command = adding one file.
  In debug builds it also loads `user://dev_commands/*.gd` after the built-in ones: **throwaway commands** that never
  touch the repo (for example one Claude writes to check one thing). A throwaway command can't replace a built-in
  name.
- **Writing a command** (also in `client-godot/DEV_TOOLS.md` and `client-godot/CLAUDE.md`): copy
  `game/dev/commands/_template.gd`, set `name`, `usage`, `help`, `cheat`, `arg_kinds`, and fill in `run()`.
  `DevContext` gives `game` (`GameMain`), `run` (`RunController`, null outside a run), `content` (the run's
  `ContentIndex`), `battle` (the running `Battle` or null), `recorder` (its `ActionRecorder`), `console`, and helpers:
  `need_run()` (why there is no active run, or ""), `arg_int(args, i, fallback)` (null when not a whole number),
  `find(kind, id or path)` (null and `error` with the closest ids), `table_of(kind)`, `fail(message)`. Rules: change units through GAS
  (effects, items), change the run through `RunController` (a cheat calls `run.dev_log(name, args)` first, which
  logs it, sets `dev` and returns the `dev/<k>` stream for any randomness), and never draw from another stream. If a
  command needs something the run layer doesn't expose yet, add a small method to the system code; never to content.
  Permanent commands get a test; throwaway ones don't.
- **Autocomplete:** Tab completes the command name, then the current argument from its kind (content ids sorted, from
  the current `ContentIndex`; slots from the party); repeated Tab cycles; a list shows when there are several.
- **History:** Up/Down; the last 50 lines in `user://dev_console_history.txt` (`keep_history` off for the script
  runner and tests).
- **Output:** scrollback in the console and `print()` to stdout (so headless runs and tests see it).
- **`Dev` autoload** (`game/dev/dev.gd`): hosts the console (UI built in code; it registers the `dev_console`
  action, backtick by physical key, if the project has none); `cheats_allowed()` is `OS.is_debug_build()`; on top of it,
  `DevConsole.execute` refuses a cheat while the current run is a server run (slice 2: there is no global "connected"
  flag; a local run or a sandbox played while linked still allows cheats). It is **inert** when `DisplayServer.get_name() == "headless"` or in a release
  build: no input handling, no UI, so the headless verifier never runs dev code (`Dev.is_inert_for(display,
  debug_build)` is the rule, testable without an export). Exported builds (spec `playable-demo` 3.12): the player
  build is a release export without the commands; the `dev` and `full` exports are debug builds with them. Battles' auto play lives in
  `DevConsole` (`auto_battle`, attached to GameMain's `battle_prepared`).
- `GameMain` adds itself to the group `game_main` (one line); that is how commands find the run. Nothing in
  `combat/` references `game/dev/` (purity test).

**Numbers in the console are the code's own numbers:** floors are **0-based** (`stage 0` is the first floor, as in
`RunState.floor_index` and the `floor/<n>/…` stream labels); party slots are the run state's slot numbers (1–4).

| Command | Cheat | Does |
|---|---|---|
| `help [command]` | | Lists commands, or one command's usage |
| `new <id,id,...> [seed]` | | Starts a run (play command, like the menu); a seed code may be typed with its space. In server mode the seed is ignored and the reply is "starting on the server" (the run starts when the server answers; follow with `wait run`) |
| `server [<url> [player] \| off \| ruleset \| check]` | | Spec server-authority 3.7: shows the mode and the run's floor seeds; `<url> [player]` links (saved in the Settings), `off` goes back to local mode, `ruleset` prints the ruleset version, `check` (E3) asks the server whether it agrees with the run |
| `wait run \| floor <n> \| stopped \| notice <text> [seconds]` | | E3: waits for something the server drives (default 30 s) |
| `expect <field\|server.key> <value>` | | E3: fails unless that field of the run's report equals the value |
| `e2e server-stop \| server-start \| redis-flush [seconds]` | | E3: a fault step for `tools/e2e.sh` (needs `dev_run --control`) |
| `state [json]` | | Prints floor, cell, coins, party (HP/MP/ult charge and maxima read through GAS), items, use slots, equipment, open event or battle |
| `map` | | Prints the floor as text: index, cell, role, room id, content, pickups, visited/cleared, ENTER where you can go |
| `enter <cell>` | | `enter_room` (play command) |
| `choose <choice>` | | Event choice, 0-based like everything in the console (play command) |
| `take <placement> <slot>` | | Take or buy a pickup (play command; armor ignores `<slot>` and goes to the armor inventory) |
| `wear <equipment> <slot>` | | Spec item-pass: equips a piece from the armor inventory on member `<slot>`, map only; the replaced piece goes back (play command, the party panel's Equip) |
| `unwear <slot> <equipment slot tag>` | | Takes off what member `<slot>` wears in that slot (e.g. `Equipment.Slot.Head`), back to the armor inventory, map only (play command) |
| `items [tag]` | | Lists every item and piece of equipment (id, kind or slot, pools, description), or only those carrying `<tag>` |
| `use <slot> <ability> [target slot]` | | Field action (play command) |
| `act <ability> [target]` / `auto [on\|off]` | | In battle: one party action, or Auto for the rest of the battle (play commands). Auto also presses every ult that can fire (spec ult-interrupts) |
| `ult <unit> <ult tag> [target]` | | Spec ult-interrupts: party member `<unit>` (P1..P4) casts its ult out of turn at the next ult window, retargeted if the target is gone (play command, the battle panel's ult buttons) |
| `trace [on\|off]` | | Spec atomic-battles: the next battles carry a determinism trace (hash and canonical lines after every action) and save `<battleId>.record.json` + `.request.json` to `user://traces/` (`DevConsole.traces_dir`), to diff against `combat/headless/trace_main.tscn` |
| `next` | | Next floor after the boss (play command) |
| `shot <name>` | | Saves the viewport as a PNG (`user://shots/` or the runner's `--shots` folder); needs a window |
| `clear` | | Clears the scrollback |
| `validate [errors]` | | Runs the validator on the current content root; prints counts and issues |
| `seed [seed]` | | No argument: prints the run's seed (code and decimal) and copies it to the clipboard. With one (a code may keep its space): starts a new run with the same party and that seed (not a cheat: it's a fresh run) |
| `give <item> [slot]` | ✅ | `dev_give`: the item received as if picked up (`_receive_item`, the path pickups and `GiveItem` use), so its `AbilitySet` is granted through GAS at every battle start and in the field (a usable item needs a free use slot) |
| `remove <item>` | ✅ | `dev_remove` → `remove_item` (what `RemoveItem` calls) |
| `equip <equipment> [slot]` | ✅ | `dev_equip` → `give_equipment` (what `GiveEquipment` calls; granted through GAS like any equipment) |
| `stat <attribute> [count] [slot]` | ✅ | Gives `count` (default 1; negative = downs) **dev stat items** for that attribute (3.3): each is an item whose `AbilitySet` holds one infinite GAS modifier, so the bonus is re-derived through GAS every battle, stacks per copy and shows in the party panel. Never a number written into run state |
| `effect <effect path> [slot]` | ✅ | Applies any `GameplayEffect` `.tres` (yours or a dev one) to living members (or one) in the field context, like an `ApplyPartyEffect` outcome. Out of battle only. Instant effects stick (HP, MP, ult charge); lasting ones end with the field context, as for any out-of-battle effect: use `stat` or `give` for something permanent |
| `coins <n>` | ✅ | `dev_coins` → `add_coins` (what `GainCoins` / `LoseCoins` call; coins are run state, not a unit attribute) |
| `heal [slot]` | ✅ | `game/dev/content/effects/dev_heal.tres` (instant: `hp` and `mp` set to `max_hp` / `max_mp`, attribute-based) on living members. Out of battle through the field context; in battle as a dev decision (3.6) |
| `revive [slot]` | ✅ | `dev_revive.tres` (instant, `hp` to 1) on dead members through the field context, the way a revive item works; refused when nobody is dead |
| `kill [enemies\|party\|<slot>]` | ✅ | In battle only. Queued; at the next party decision the battle applies `dev_kill.tres` (instant, `hp` to 0) through GAS, then the usual death and end checks (3.6) |
| `win` | ✅ | Ends the run as Won (tests the run-end screen; run status, not a unit change) |
| `stage <floor>` | ✅ | Enters floor `<floor>` (0-based) of the run structure (party and inventory kept) |
| `room <room>` | ✅ | Sandbox floor with that room (2.2) |
| `layout <layout>` | ✅ | Sandbox floor from that layout |
| `spawn <encounter>` | ✅ | Starts a battle with that encounter in the current room (like an event's `StartEncounter`; enemies resolved with the floor's scaling, elite rolls from `dev/<k>`) |
| `spawn item <item or equipment> [price]` | ✅ | Adds a pickup to the current room (price 0 = free pedestal, else a shop slot), numbered from 1000 and added to the run's seen items. Taken with the normal Take/Buy, so pickup rules, `on_pickup` and the "give to" picker are the real ones. Usable after the room is cleared, like any pickup |
| `spawn pool <tag> [price]` | ✅ | Same, with the item picked by weight from unlocked items and equipment carrying `<tag>` (same pick as a pedestal's `item_query`, `FloorGenerator.pick_pickup`, on `dev/<k>`) |
| `reveal` | ✅ | Sets `state.revealed`; `RunController` emits `map_revealed`; the map view shows every room |
| `goto <cell \| boss \| special tag>` | ✅ (2026-10-26, from a screenshot helper) | `RunController.dev_goto`: moves into any room of the floor, no adjacency needed; it plays as if entered (battle, event, pickups) |
| `bossdone` | ✅ (2026-10-26) | `RunController.dev_boss_done`: the boss room is cleared without a battle, rewards or XP; the stairs open (last floor: Won) |
| `xp <amount> [slot]`, `xp level <count> [slot]` | ✅ (2026-10-26) | `RunController.dev_xp`: the GainXp / GainLevel outcome paths, so level-ups, class growth and `Message.Run.LevelUp` happen as in play; refused on a run without `xp_to_level` |
| `seeds` | | Opens the seed runner (so the user's menu needs no Dev button) |
| `create <type> <id> [folder]` | | The dock's Create: a new asset from its template (refuses existing ids and files) |
| `grid <room> <op> …` | | The room grid without a window: `paint`, `erase`, `door`, `show`, `save` on a room loaded by id or path (edits an in-memory copy until `save`) |
| `play <kind> <id or path>` | | A Play button: the same sandbox for a room, encounter, enemy, character or layout (a room opened with `grid` plays its unsaved copy) |

### 3.3 Dev commands go through GAS
A dev command is **a content action without a content file**: it builds the same object content would use and runs it
through the same code. Nothing writes a unit's numbers directly.

| Changes | Goes through | Commands |
|---|---|---|
| A unit's attributes, now | An instant `GameplayEffect` applied by GAS (field context out of battle, a dev decision in battle) | `heal`, `revive`, `kill`, `effect` |
| A unit's attributes, for the rest of the run | An **item** (or equipment) held in run state, whose `AbilitySet` GAS grants at every battle start and field context, the only way anything permanent exists (game-skeleton 3.1: stats are always re-derived) | `stat`, `give`, `equip` |
| Run-level values (coins, inventory, pickups) | The existing `RunOutcome`s and pickup code | `coins`, `give`, `remove`, `spawn item`, `spawn pool` |
| Where the run is | `RunController` (floors, rooms, sandbox, run end) | `stage`, `room`, `layout`, `spawn`, `win`, `reveal`, `goto`, `bossdone`, `xp` |

To make that possible, `RunController.apply_party_effect` gains an optional slot list (`apply_member_effect(effect,
slots, include_dead)`), the same field-context path with fewer targets. The dev methods on `RunController`:
`dev_log`, `dev_give`, `dev_remove`, `dev_equip`, `dev_coins`, `dev_apply` (heal / revive / effect), `dev_stat`,
`dev_win`, `dev_stage`, `dev_sandbox`, `dev_spawn`, `dev_spawn_item`, `dev_reveal`, `dev_battle` (kill / heal in
battle); each checks first, then logs, then acts. `RunController.allow_dev` (true in local mode) is copied to battles.

**Dev content** (`res://game/dev/content/`, system-owned, built by `game/tools/build_dev_content.tscn`):
- `effects/dev_heal.tres`, `dev_revive.tres`, `dev_kill.tres`: instant, plain `GameplayEffectModifier` OVERRIDEs on
  the shared `hp` / `mp` attributes (heal reads the target's `max_hp` / `max_mp`, attribute-based).
- **Dev stat items**, one up and one down per attribute a character keeps between battles: ids `dev.up.<attr>` /
  `dev.down.<attr>` (files `items/dev_up_<attr>.tres`, effects `effects/dev_up_<attr>.tres`) for `max_hp`, `max_mp`, `atk`, `def`, `spd`, `crit_rate`, `crit_dmg`, `max_energy`. Each is a
  `PASSIVE` `ItemDefinition` (`applies_to` `HOLDER`, tag `Dev`) whose `AbilitySet` holds one saved infinite
  `GameplayEffect` with one additive modifier of one **step**: `max_hp` 100, `max_mp` 50, `atk` / `def` / `spd` 10,
  `crit_rate` / `crit_dmg` 5 %, `max_energy` 10 (typed values, stored ×100). `stat atk 3` = three `dev_up_atk`
  copies = +30 ATK, stacking because ability-set effects stack (game-skeleton 3.4).
- `GameMain.load_content` adds this folder with `ContentIndex.add_root` only while `Dev.cheats_allowed()`. Dev items
  sit in the normal `items` table (so battles, the run and your screens find them as usual) and are **never in any
  pool**: `FloorGenerator.pick_item` skips items tagged `Dev` (`FloorGenerator.DEV_TAG`), so no generation or golden
  can change. The headless verifier never loads the folder, so a battle snapshot holding a dev item can't verify.
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
  "<slot>"}` instead of waiting for the player. `ActionRecorder.waiting_for` names the unit whose decision is
  awaited (for `act` and auto play); `pending_dev()` counts queued dev decisions. A decision still queued when the
  battle ends stays on that recorder and is simply never applied (each battle gets a new recorder).
- `Battle._take_action`: a `dev` choice with `allow_dev` applies the effect to the chosen units with
  `apply_to_units` (GAS, the same call event effects use), drains the trigger queue, runs `_check_deaths` /
  `_check_end` as after an action, and records an ordinary `ActionEntry`: `{"turn", "actor", "ability": <name>,
  "target": <targets>}` (no `checkpoint` since spec atomic-battles). It has the existing entry shape, so the replay runner's request check and the
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
`check_room(room, content)` (content may be null: references then aren't resolved) and `check_layout(layout,
content)` run the subsets the room grid and Play need. `report()` and `error_count()` format results.

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
| `placement_both` | error | Spec item-pass: a placement with both a fixed `item` and a fixed `equipment` |
| `bad_equipment` | error | Equipment with no `slot` |
| `bad_equipment_slot` | error | Equipment whose slot is in no run structure's `equipment_slots` (checked when any run lists its slots) |
| `no_description` | warning | An item (not tagged `Dev`) or piece of equipment with no `description` |
| `ult_triggered` | error | Spec ult-interrupts: an ability tagged `Ability.Type.Ultimate` that is a triggered passive |
| `ult_no_cost` | warning | An ult without a cost effect (it could fire at every ult window) |
| `ult_no_charge` | warning | An enemy with an ult but no triggered passive (abilities, default-loadout skills, item grants) that could charge it |
| `trigger_unregistered` | warning | A triggered ability whose `trigger_event_tag` is in a battle event family (`Event.Damage.*`, `Event.Unit.*`, …) but not an event the battle sends (a typo such as `Event.Damage.Delt`) |
| `placement_kind` | warning | A field that doesn't belong to the placement's kind: a `price` on anything but a shop slot, an item or item query on anything but a pedestal or shop slot, a loadout on anything but an enemy spawn |
| `bad_layout` | error | Everything `FloorGenerator.check_layout` refuses: not connected, not exactly one start and one boss, outside the grid, doors don't fit |
| `bad_event` | error | `GoToPage` out of range; a page with no choices |
| `bad_item` | error | `USABLE` without `use_ability`; `COOLDOWN` with `cooldown_battles` 0 |
| `unknown_tag` | warning | A `gas::tag` value not in the registry (the same check as `sync_tags.tscn`, walked over the content index) |
| `reserved_tag` | error | Content using the reserved prefix `Dev.` (dev decisions, 3.6) |
| `incomplete` | warning | What a new asset still needs: a unit with no abilities, an encounter with no slots |
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

### 3.9 Edits to your `presentation/demo/` files (approved 2026-10-20, done)
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
| Unknown command or wrong arguments | Reply with the usage; nothing changes, nothing logged | `test_console_errors_and_cheats_off` |
| Cheat while cheats are off | Refused, nothing logged | `test_console_errors_and_cheats_off` |
| Unknown content id in a command | "no item 'x'" plus the closest ids; nothing changes | `test_console_errors_and_cheats_off` |
| `kill` outside a battle | Refused with a reason | `test_console_spawn_and_kill` |
| `kill` while an enemy is acting | Queued until the next party decision (one still queued when the battle ends is never applied) | `test_console_spawn_and_kill` (at a party decision); the enemy-turn case is untested |
| `kill <slot>` | That member dies through GAS; the battle goes on and the same actor is asked again (no turn used) | `test_console_battle_edges` |
| `give` with no one able to hold the item | Refused before anything changes, not logged (not lost, unlike an event gift) | `test_console_battle_edges` |
| `stat` for an attribute the AttributeSet doesn't have | Refused, listing the attributes that have dev items | `test_console_cheats` |
| `give` / `stat` during a battle | Applied to run state; takes effect from the next battle or field action (said in the reply) | `test_console_battle_edges` |
| `effect` in battle, or with a file that isn't a `GameplayEffect` | Refused, and nothing goes in the run log. The reply says why: "could not open effect <path>: no such file", "could not use <path> as an effect: it is a RoomDefinition, not a GameplayEffect", or the usage when no path is given | `test_console_effect` |
| `spawn item` in a room not yet cleared | Added; takeable once the room is cleared, like any pickup | `test_console_cheats` (cleared room only) |
| Dev items leaking into pools or generation | Impossible: pools skip the `Dev` tag | `test_dev_items_never_pooled` |
| A snapshot holding a dev item replayed | Setup stops with the runner error "unknown item 'dev.up.…'" (the verifier's index has no dev items); never verifies | `test_replay_rejects_dev_item` |
| A dev command changing later rooms or floors | Impossible by construction (`dev/<k>` stream); proven | `test_dev_streams_isolated` |
| A battle log with a dev entry replayed | Rejected, 2002 `IllegalAbility` | `test_replay_rejects_dev_battle` |
| `Dev` autoload in the headless verifier | Inert; every replay golden unchanged | existing goldens + `test_dev_inert_headless` (`tests/combat/test_purity.gd`) |
| A tool script with a parse error that no test loads | Caught: every script under `res://game/` must compile | `test_game_scripts_compile` |
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
- **Broken content root** `tests/broken_fixtures/` (frozen, built by `tests/tools/build_broken_fixtures.tscn`): one file per
  validator code, each named after it (`rooms/doors_unsatisfiable.tres`, …). Since spec item-pass both fixture builders
  only add missing files (existing ones keep their bytes and uids) unless run with `-- --rebuild`. Separate root, because `ContentIndex`
  scans `tests/fixtures/` recursively and must keep seeing valid content.
- Nothing is added to `tests/fixtures/` that a fixture chapter's queries could match, so no existing golden changes.

### Unit and system tests
| Test | Proves |
|---|---|
| `test_seed_codes_*` (golden, round trip, normalisation, refuse typos, decimals unchanged) | Golden vectors (seed ↔ code), round trip for 1000 seeds, normalisation (lower case, spaces, `-`, `O/I/L`), every single-character substitution at every position is refused, decimal parsing unchanged, `display()` |
| `test_console_registry` | Every file in `game/dev/commands/` loads; names unique; every command has usage and help; a test-only command file is picked up without code changes; a command in `user://dev_commands/` is loaded in debug, can't shadow a built-in, and is ignored in a release build; `_template.gd` itself is not registered |
| `test_console_autocomplete` | Command names; argument completion by kind from fixture ids, sorted (Tab cycling is UI only: manual) |
| `test_console_errors_and_cheats_off` | Section 4 rows; run log and hash unchanged afterwards |
| `test_console_play_commands_stay_clean` | `new`, `map`, `enter`, `state` never mark the run; the same choices made directly on `RunController` give the same run hash |
| `test_console_cheats` | `give`, `remove`, `equip`, `coins` (never below 0), `stat` (three `dev.up.atk` items = +30 ATK read through GAS, a down item lowers it, an unknown attribute refused), `effect` (an instant effect sticks), `heal` (back to max through GAS), a death through `dev_kill.tres` and `revive` (1 HP), `reveal`, `spawn item` / `spawn pool` and buying the spawned slot with `take`, `stage 1`, `win`; every cheat logged, `dev=1` in the hash |
| `test_console_spawn_and_kill` | `kill` refused outside a battle; `spawn` fights on auto; with auto off, `kill` ends the battle as a Victory through normal death handling, logged as an ordinary `Dev.Kill` action entry; `kill party` → Lost |
| `test_console_create_grid_play` | `create` writes a template and never overwrites; `grid show/paint/door` edit a copy; `play room` plays the unsaved copy; `grid save` writes it; `play enemy`, `play character` |
| `test_console_seed_codes` | `new` and `seed` take a code typed with its space; a bad code is refused |
| `test_dev_streams_isolated` | A run with `coins`, `stat` and a spawned fight (dev content loaded) has the same next floor (canonical map lines) as without |
| `test_dev_run_replays` | The same dev commands twice give the same run hash |
| `test_dev_kill_through_gas`, `test_dev_decision_needs_allow_dev`, `test_replay_rejects_dev_battle` (`tests/combat/test_dev_battle.gd`) | A dev kill applies through GAS and is logged as `Dev.Kill`; without `allow_dev` nothing is applied; a log with a dev entry → Rejected, 2002, `IllegalAbility` |
| `test_combat_never_references_dev_tools`, `test_dev_inert_headless` (`tests/combat/test_purity.gd`) | `combat/` never references `game/dev/`, `Dev.`, `DevConsole`, `RunController`; under `--headless` the `Dev` autoload has no children and handles no input |
| `test_console_effect` | A room file or a missing file is refused (no script error, nothing logged); a lasting effect ends with the field context; refused during a battle |
| `test_console_battle_edges` | `give` refused (and not logged) when no one can hold a usable item; `give` / `stat` mid-battle say they apply from the next battle; `kill <slot>` kills that member, the battle goes on, the same actor is asked again, logged as `Dev.Kill` with its target |
| `test_replay_rejects_dev_item` (`tests/combat/test_dev_battle.gd`) | A snapshot holding `dev.up.atk`, replayed on the fixtures without dev content, stops with "unknown item" and never verifies |
| `test_dev_items_never_pooled` | With the dev content loaded, floors for seeds 1..20 are unchanged, and a match-everything pool never picks a dev item in 200 draws |
| `test_game_scripts_compile` | Every script under `res://game/` compiles |
| `test_sandbox_room` | Each fixture room type in a sandbox: battle room fights, event shows, shop sells, boss resolves the boss query and never ends the run as won; no next floor; hash golden for (room, seed 7, party, depth 0); deterministic |
| `test_sandbox_unsaved_room` | An unsaved room plays from memory; the shared content index is untouched |
| `test_sandbox_layout` | The fixture layout plays as floor 0 in a sandbox, start cleared |
| `test_check_layout` | `FloorGenerator.check_layout` accepts the fixture layout and refuses a broken copy |
| `test_content_validator_fixtures_clean`, `_broken_root`, `_room_check` | Fixtures: zero errors. Broken root: every expected error (code, file), no unexpected error, the expected warnings and some `unknown_tag`. `check_room` works without a content index |
| `test_content_valid` *(content test)* | `ContentValidator` over `res://content/` with 20 generation seeds: no errors (warnings printed). Like content goldens, a failure means your content is broken, not the system; skipped if `content/` has no run structure |
| `test_seed_report` | `SeedReport` for fixture seeds 1..50, floor 0, equals `golden/game/seed_report.json`; no failures |
| `test_seed_report_matches_a_run`, `test_seed_report_rules_copy` | One seed shows the same rooms as a real run's floor; floor 1 generates after floor 0; tuned rules are used on a copy, the original untouched |
| `test_content_templates` | Every template, saved to `user://` and loaded through a `ContentIndex`, has its id and the expected defaults; character and enemy stats hold every attribute of the set; the validator reports only the listed "fill this in" issues; refusing a used id or existing file |
| `test_room_grid_ops` | Paint each kind, replace, erase, toggle each door, on a fixture room copy; `check_room` after each |
| `test_play_request` | `PlayRequest.build` for each kind on fixtures (room, encounter in a battle room, enemy as a one-slot encounter, character in slot 1, layout, by path); unknown ids and wrong kinds refused; the request file is read once and deleted |
| `test_tool_parity` | Every dock and inspector action has its command (the parity table); the inspector's undoable grid results equal what `grid` applies (the dock's Create and `create` share `ContentTemplates.save_new`) |
| `test_dev_script_runner` | The runner as a separate headless process on fixtures: exit 0 and a JSON with every command and the dev flag; a failing command → exit 2, naming the line (clean play is proven by `test_console_play_commands_stay_clean`) |
| `test_dev_tool_scenes` | The seed runner and `play_main` scenes open with their scripts compiled and run 10 frames (the console has no scene) |

### Golden vectors
`golden/game/seed_codes.json` (seed ↔ code pairs incl. 0, 1, 2^35 − 1), `seed_report.json`, `sandbox_room.json`.
Existing goldens must not change; any diff there is a bug in this slice.

### C#
N/A: no contract changes.

### Done when
Met 2026-10-20: `dotnet build` / `dotnet test` and the Godot suite (136 tests) pass; `test_content_valid` passes on
your `content/` (0 errors, 0 warnings). Checked in the editor by a headless probe on a copy of the project (dock
loads, grid appears on a room, paint and undo, Create with all 13 stats, Validate); still to try by hand, in
the Godot editor: create an enemy, an encounter using it and a room with the dock; paint the room on the grid
(Ctrl+Z works); press Play on each and land in the right fight; a seed code typed in the menu starts the same run
every time; the console's `give` works in a running game.

### Suggested implementation order (one slice, five checkpoints, tests green at each)
1. Content validator (+ broken fixtures, headless tool, content test) and seed codes.
2. **Content creation first** (the user's priority): sandbox, `play_main`, content templates and the dock, room grid,
   Play buttons.
3. Console, `Dev` autoload, play commands and the script runner, cheats, dev log entries, battle dev decision.
4. Seed runner (model + headless report, then the scene).
5. The approved `presentation/demo/` edits.

## Files this slice creates or changes (system-owned unless noted)
```
client-godot/project.godot                    autoload Dev, plugin rpg_dev enabled
client-godot/game/run_seeds.gd                seed codes
client-godot/game/run_state.gd                dev, sandbox, revealed, dev_commands
client-godot/game/run_controller.gd           start_sandbox / enter_sandbox_floor, dev_* methods, apply_member_effect,
                                              map_revealed, allow_dev
client-godot/game/game_main.gd                group game_main, start_sandbox, sandbox_closed, recorder, skip_animations,
                                              dev content root
client-godot/game/floor_generator.gd          layout_map / check_layout (shared with from_layout), single_room, DEV_TAG
client-godot/game/dev/                        dev.gd (autoload), dev_console.gd, dev_command.gd, dev_context.gd,
                                              dev_report.gd, sandbox_request.gd, play_request.gd, play_main.gd/.tscn,
                                              commands/*.gd (35 + _template.gd), content_validator.gd,
                                              validation_issue.gd, content_templates.gd, room_grid_ops.gd,
                                              seed_report.gd, seed_runner.gd/.tscn
client-godot/game/dev/content/                dev effects and dev stat items (3.3), built by build_dev_content
client-godot/addons/rpg_dev/                  plugin.cfg, plugin.gd, content_dock.gd, rpg_inspector.gd, room_grid.gd
client-godot/game/tools/                      seed_report, validate_content, build_dev_content, dev_run (.gd/.tscn)
client-godot/combat/battle.gd, action_recorder.gd   dev decision, allow_dev, submit_dev, waiting_for
client-godot/combat/content_index.gd           add_root (dev content), overlay (sandbox), _index / _table_for
client-godot/tests/game/                      test_seed_codes, test_content_validator, test_dev_content,
                                              test_dev_console, test_seed_runner, test_scripts_compile
client-godot/tests/combat/                    test_dev_battle; test_purity extended
client-godot/tests/broken_fixtures/           new root, built by tests/tools/build_broken_fixtures.tscn
client-godot/tests/fixtures/golden/game/      seed_codes.json, sandbox_room.json, seed_report.json
client-godot/presentation/demo/               (yours) menu.gd, map_view.gd: the edits in 3.9, approved
specs/roadmap.md, CLAUDE.md, client-godot/CLAUDE.md   status, current-state table, ownership row for game/dev/
```

## Decisions (review, 2026-10-20)
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

## Decisions made during implementation (2026-10-20)
10. **Dev items live in the normal `items` table** (loaded with `ContentIndex.add_root`) and pools skip the `Dev` tag,
    instead of a separate `dev_items` table and `find_item`: battles, the run and the user's screens find them with no
    lookup changes, and generation still never sees them.
11. **`placement_kind` checks fields, not room tags:** spotting a shop room would need a hard-coded content tag, and a
    pedestal in a battle room is valid (it unlocks on the win).
12. **Two more validator codes:** `incomplete` ("fill this in", for new assets) and `reserved_tag` (`Dev.*`).
13. **The `dev_console` action is registered by the `Dev` autoload** at start (backtick by physical key) rather than
    stored in `project.godot`, so it works without editing project input settings.
14. **UI built in code** (console overlay, dock, inspector panels): no `.tscn` files to keep in sync.
15. **The script runner runs GameMain with its screens** (animations skipped), so `shot` captures the real game, and has
    no `--seed` / `--party` (`new` does both).
16. **Templates read stats from the nearest `@tool` attribute set in the editor** (a hand-written subclass such as
    `DemoUnitAttributes` can't be instantiated there).

## Headless safeguards and parallel runs (added 2026-10-26)
Two hangs so far (2026-10-19, 2026-10-26) left a headless Godot idling after a script failed to load, and from the
outside a stalled run looks the same as a slow one. Every headless run now has a liveness signal and a hard stop, and
independent work uses the machine's cores.

| Layer | Where | Rule |
|---|---|---|
| **Watchdog** (in the engine) | autoload `Watchdog` (`game/dev/watchdog.gd`), active only when `DisplayServer` is headless | Quits with **70** when the main scene's root script failed to load (the scene declares a script, the node has none: a parse error), with **124** after `--idle-limit` seconds (default 180) without a `Watchdog.beat(label)`, and with **71** when a script or engine error (`ScriptErrorLog`) is followed by 30 s without a beat (the error most likely killed the run's main coroutine; 2026-10-26). Both stop messages list the last errors. Prints `[watchdog] alive: <beats>, last <label>` every 30 s while beats arrive (silence means no progress). Beats: each test (`run_tests`), each seed and battle (play report), each script line (`dev_run`) |
| **Watcher** (outside) | `tools/watch.sh [--idle S] [--timeout S] [--log F] [--name N] -- <command>` | Runs any command with its output in a log; every 30 s prints `[watch:<name>] <seconds>, <log size>: <last line>`; kills the whole process tree (Windows `taskkill /T`) and exits **124** when the log stays silent for `--idle` seconds (default 180) or the run passes `--timeout` (default 3600). Catches a frozen engine too, where the watchdog can't run |
| **Parallel tests** | `run_tests.tscn -- --shard i/n` (test files whose sorted index is i mod n); `tools/godot_tests.sh [-j N] [-- runner args]` | Runs N watched shards (default 8), merges the `ok`/`FAIL` lines and totals, exits 1 on any failure or stall. `--update-goldens` always runs as one shard (goldens are written once) |
| **Parallel reports** | `game/tools/play_sharded.sh` (2.3d) | Shards go through `tools/watch.sh`; exits with the merged report's code (0, or 3 on a stopped run, a violation or an error), or a shard's own code (124, 71, 70, 1) naming its log (until 2026-10-26 it always exited 0) |
| **No silent errors** (2026-10-26, user) | `ScriptErrorLog` (`game/dev/script_error_log.gd`, a Godot `Logger`) in `run_tests`, `PlayReport.many`, `seed_report.tscn`, `dev_run.tscn` and the Watchdog | A GDScript runtime error only aborts its function (callers go on with null), so a run could look fine. Every script or engine error (not `push_error`, not warnings) now fails it: the test (spec combat-replay-core "Test runner"), the play report (`"errors"` per seed, exit 3), any `seed_report` mode (exit 3), the `dev_run` line it happened on (`"errors"`, exit 2; `"startupErrors"`) |
| **.NET** | `tools/dotnet_test.sh [args]` | `dotnet test` through the watcher (the test platform already runs projects and classes in parallel) |
| **Clean exit** (2026-10-26) | `Watchdog.quit(code)` frees the current scene (its sounds stop, nothing can start one), waits 3 frames and 0.1 s, then quits | A sound still playing at quit leaks its playback at exit; `dev_run` quits through it (spec `playable-demo` F6) |
| **Silent runs** (2026-10-26, user) | `tools/watch.sh` exports `RPG_MUTE=1` (unless set); `Watchdog._ready` mutes the Master bus when `RPG_MUTE=1` or the user arg `--mute` | Window runs Claude starts make no noise. Sounds still play and mix into the muted bus, so audio errors still show; `RPG_MUTE=0 tools/watch.sh ...` keeps the sound |

Builders, imports and golden updates stay sequential (they write shared files). Claude runs every headless Godot and
`dotnet test` command through these tools.

## End-to-end harness (added 2026-10-27)
Status: ✅ Built 2026-10-27 (`2d30598`), synced. Builds on `server-authority` Part A (slice 2, built 2026-10-27).

### E1. Purpose & enterprise mapping
The unit and system suites prove each side alone: the .NET tests run the real server on Testcontainers, and the Godot
tests run the client against a fake bridge. Nothing committed proves that **the real client and the real server work
together**. On 2026-10-27 this was checked once by hand: a throwaway command, a server started and stopped by hand,
and a "smoke" player left in the dev database. The harness makes that check one watched command, `tools/e2e.sh`, that
anyone (Claude included) can rerun and that later slices extend with their own scenarios.

**What it runs, per scenario:** the real `Rpg.GameServerApi` (its own process and port, Development environment, its
own fresh Postgres database and Redis database index, a test seed secret, the **real ruleset gate** with only the
project's live ruleset version accepted), and the real game headless (`dev_run.tscn` with `GameMain`, the C#
`ServerBridge`, `ServerLink`), driven by a committed script of console commands. Afterwards it checks what the client
reports (`expect`), what the server says (`server check`), what Postgres holds (a `.sql` file) and what `/metrics`
shows (a `.metrics` file).

**Enterprise mapping:** a *staging smoke and chaos suite*: deploy the real services on throwaway state, drive them
through the real client, inject faults (a service stopped, a cache flushed) and assert the system's own records
afterwards. The fault steps are what make offline-first claims testable: "the client keeps playing and syncs when the
server comes back" can't be shown by a unit test.

| Component | Used | How |
|---|---|---|
| `Rpg.GameServerApi` | ✅ | Started per scenario (`dotnet <dll>`, a free port), stopped and restarted by fault steps |
| PostgreSQL | ✅ | A database `e2e_<stamp>_<scenario>` per scenario, created and dropped by the harness (`--keep` keeps it) |
| Redis | ✅ | A database index per scenario (1–15, never 0), flushed before the scenario and by the `redis-flush` fault |
| RabbitMQ | ✅ (readiness only) | The server needs it to report ready; no queues until slice 3 |
| Redpanda, outbox | ❌ | N/A until slice 4 |
| `Rpg.Contracts`, `Rpg.Client` | ✅ (unchanged) | Through `ServerBridge` |
| `client-godot` | ✅ | `dev_run.tscn` headless; new console commands and runner flags (E3) |

### E2. Sequence flow
```
tools/e2e.sh [scenario ...] [--keep] [-j N]            (default: every client-godot/tests/e2e/*.txt, in parallel)
  once: infra up? (pg_isready, redis-cli ping, rabbitmq ping in the compose containers) → else exit 1 "run
        cd infra && docker compose up -d"; credentials from infra/.env
  once: dotnet build src/Rpg.GameServerApi (watched); ruleset version = print_ruleset_version.tscn (watched)
  per scenario (parallel, each with its own port, database, Redis index, control folder, output folder):
    CREATE DATABASE e2e_<stamp>_<scenario>; FLUSHDB on Redis index i
    start the server (dotnet <dll>, not watched: see below), env: ASPNETCORE_ENVIRONMENT=Development,
        ASPNETCORE_URLS=http://127.0.0.1:<port>,
        ConnectionStrings__Postgres (the e2e database), ConnectionStrings__Redis (…,defaultDatabase=<i>),
        RabbitMq__Uri, Seeds__Secret=<test secret>, Ruleset__AcceptAny=false, Ruleset__Accepted__0=<live version>
        (plus the scenario's own "#! env KEY=VALUE" lines, e.g. a wrong ruleset)
    poll /health/ready until 200 (about 60 tries, else fail with the server log)
    dev_run.tscn -- --script <scenario>.txt --out state.json --content-root res://tests/fixtures/
                    --server http://127.0.0.1:<port> --player e2e-<scenario> --control <folder>     (watched)
      each line → DevConsole.execute; a fault step (`e2e <action>`) writes <folder>/request and waits for
      <folder>/done, which the harness's control loop writes after acting:
        server-stop | server-start | redis-flush
    checks: dev_run exit 0 (every command ok, incl. expect / wait / server check)
            <scenario>.sql: every line is a query that must return t (psql against the e2e database)
            <scenario>.metrics: every line is a regex that must match the final /metrics scrape
    stop the server; DROP DATABASE (unless --keep); FLUSHDB
  → build/e2e/<stamp>/<scenario>/ {server.log, godot.log, state.json, metrics.txt, sql.txt, control.log}
  → one line per scenario "ok|FAIL <scenario> (<seconds>s)", exit 0 all ok, 1 any failure, 124 a stall
```
**The server is not run through `tools/watch.sh`:** the watcher kills anything quiet for 180 s, and a server is
legitimately quiet. The harness owns its lifetime instead: its pid lives in a file (`server.pid`), so the control loop
(a subshell) can stop and restart it; the scenario stops it at the end, and a trap stops it on Ctrl+C. The Godot run is
watched, which bounds every scenario. A failed setup (database or Redis) still falls through to the cleanup. Every
`docker compose exec` reads stdin from `/dev/null`, so a `.sql` file read line by line isn't swallowed.
Inside the game, a server-mode run started from a script goes through the real path: `new` → `GameMain.start_run` →
`ServerLink.start_run` (POST /runs) → `RunController.start_server_run`; the stairs → `floor_seed_needed` →
`ServerLink` (POST /floors/{n}, retried while the server is down) → `provide_floor_seed`.

### E3. Data contracts
No new C# records, endpoints, tables, queues, topics or Redis keys: the harness drives what exists. New on the client
side (dev tools only; none of it ships in the player build):

| Piece | Where | Contract |
|---|---|---|
| `dev_run.tscn -- --server <url> [--player <name>]` | `game/tools/dev_run.gd` | Links `GameMain` to the server through `ServerLink.create(url, player)` (a new constructor `from_settings` also uses), **without writing the Settings**, so e2e never changes `user://game_main.cfg` |
| `dev_run.tscn -- --control <folder>` | `game/tools/dev_run.gd` | The folder for `e2e` requests (below) |
| `wait <condition> [seconds]` | `game/dev/commands/wait.gd` (play command, not a cheat) | Waits frame by frame (beating the Watchdog) until the condition holds, default 30 s, else fails with the run's state. Conditions: `run` (a run is active and not waiting for a seed; after `new` in server mode), `floor <n>` (floor index n entered), `stopped` (the run stopped on a runner or server error), `notice <text>` (a `Message.Notification` containing text arrived since the previous command) |
| `expect <field> <value>` | `game/dev/commands/expect.gd` | Compares a top-level field of `DevReport.state_of` (e.g. `floor`, `status`, `runnerError`) or `server.<key>` (below) with the value as text; fails with both values otherwise |
| `server check` | `game/dev/commands/server.gd` | GET /runs/{id}: status Active and `currentFloor` equal to the client's floor; POST /floors/{current} (a free retry): the same seed as the client's. Fails on any difference. Read-only for the run |
| `e2e <action> [seconds]` | `game/dev/commands/e2e.gd` | Fault step: writes `<control>/request` with the action, waits for `<control>/done` (default 60 s), deletes both. Fails when no `--control` was given. Actions: `server-stop`, `server-start`, `redis-flush` |
| `new` in server mode | `game/dev/commands/new.gd` | Replies "starting on the server" (the run starts when the server answers; follow with `wait run`) instead of reading a run that doesn't exist yet |
| `RunPlayer.play` (and `autorun`) | `game/dev/run_player.gd` | Stops when the run waits for a floor seed and says "waiting for floor n's seed" (not a failure), so `autorun` then `wait floor n` crosses the stairs on random server seeds |
| `DevReport.state_of` → `"server"` | `game/dev/dev_report.gd` | Server mode only: `{"runId", "floorSeeds": {"0": "…"}, "waitingForFloor"}`; local reports are unchanged (goldens) |
| Scenario files | `client-godot/tests/e2e/<name>.txt` (+ optional `.sql`, `.metrics`) | A `dev_run` script; lines `#! env KEY=VALUE` are server settings for this scenario (read by the harness, skipped by `dev_run` as comments) |

**First scenarios (Part A).** Every scenario crosses the stairs with `autorun policy=smart`: the default `auto` policy
lost on floor 0 in one run, and the smart policy cleared floor 0 on all 100 seeds measured (fixtures, two-floor run,
knight and medic; the losses are on floor 1), which matters because server seeds are random.
1. `stairs`: `new` on the fixtures' two-floor run → `wait run` → `expect server.waitingForFloor -1` → `server check`
   → `autorun policy=smart` (to the stairs) → `wait floor 1` → `server check` → `expect floor 1`, `expect status
   Active`. SQL: one player `e2e-stairs`, one Active run on floor 1, two `run_floors` rows. Metrics:
   `rpg_run_starts_total{…result="created"…} 1`, `rpg_floor_seeds_total{…issued…} 1` and `{…repeated…} 2` (each
   `server check` asks for the current floor again).
2. `offline_stairs`: `e2e server-stop` before `autorun policy=smart`, then `wait notice Connecting` (right after
   `autorun`: `wait notice` looks from the previous command's start on), `expect server.waitingForFloor 1`, `expect
   floor 0`, `e2e server-start`, `wait floor 1 90`, `server check`, `expect floor 1`. Proves the client keeps the run
   while the server is gone and syncs at the stairs once it is back (ServerLink backoff, `Connecting…`).
3. `redis_flush`: `stairs` up to `wait floor 1`, then `server check` **twice** (the first fills the cache after the
   stairs deleted it, the second is a real Redis hit), `e2e redis-flush`, `server check`. Metrics: both
   `rpg_cache_reads_total{…source="redis"…}` and `{…source="postgres"…}`. **Scenario 4** end to end.
4. `ruleset_refused`: `#! env Ruleset__Accepted__0=0.0.0.none+0000000000000000`; `new` → `wait notice 1001` →
   `expect run ""` (with no run the report is `{"run": null}`). SQL: no runs. Metrics:
   `rpg_run_starts_total{…result="rejected"…} 1`.

### E4. Failure modes
| Case | Behaviour | Test |
|---|---|---|
| Infra not running | Exit 1 at once, naming the missing service and the compose command | manual (`test_e2e_check` covers only parsing and the tools) |
| Server never ready | The scenario fails after about 60 readiness tries with the last 40 server log lines | manual (break a setting) |
| A command fails or times out (`wait`, `expect`, `server check`) | `dev_run` exits 2 naming the line; the scenario fails; logs kept | `test_new_and_wait_in_server_mode`, `test_expect_command`, `test_server_check_command`; a wrong `.sql` line checked by hand (fails, names the line, keeps the logs) |
| Godot or the server stalls | `tools/watch.sh` kills the tree, exit 124, the scenario fails | existing watch tests |
| A fault action never acknowledged | `e2e` fails after its timeout; the harness logs an unknown action and acknowledges with an error | `test_e2e_command` |
| Harness interrupted (Ctrl+C) | A trap stops every server it started and drops its databases (unless `--keep`) | manual |
| Parallel scenarios | Separate ports, databases, Redis indexes, control and output folders; at most 15 at once (Redis indexes 1–15) | `-j 4` run in "Done when" |
| Dev data and settings | Never touched: no database 0 / `rpg_db`, no Redis index 0, `--server` writes no Settings | `test_dev_run_server_flag_keeps_settings` |

Acceptance scenarios (root `CLAUDE.md`): **4** (Redis flushed) gets its end-to-end proof in `redis_flush`. Later
slices add theirs as scenarios: **5** (tamper → a 2002 verdict) and **1**, **2** (duplicate and redelivered
settlement) in slices 3–4, **3** (Redpanda down) with the `redpanda-stop`/`-start` actions in slice 4, **7** (load)
stays Locust's (slice 8).

### E5. Observability
No new instruments. The harness scrapes `/metrics` once per scenario (saved as `metrics.txt`) and checks the
scenario's `.metrics` regexes against it, so each scenario also proves the counters it should move do move.

### E6. Test plan
- **Godot (fixtures, fake bridge, no network)**: `test_new_and_wait_in_server_mode` (`new`'s server-mode reply; each
  condition; a timeout fails with the state), `test_wait_notice_sees_a_refusal` (a 1001 refusal arrives as a notice,
  no run starts), `test_expect_command`, `test_e2e_command` (a request file appears, a written `done` completes it, no `--control`
  fails), `test_server_check_command` (agreement passes; a different floor or seed fails), `test_run_player_stops_waiting`
  (autorun stops at the stairs of a server run and reports the floor), `test_dev_run_server_flag_keeps_settings`
  (`ServerLink.create` writes nothing), `test_dev_report_server_block` (present in server mode only; local
  `DevReport` goldens unchanged), `test_e2e_scenarios_lint` (every `tests/e2e/*.txt` names only known commands and
  well-formed `#! env` lines; every `.sql` line is a single statement). Test shards run one file's tests in parallel
  processes that share `user://`, so `test_e2e_command` uses a control folder per process.
- **Harness self-check**: `tools/e2e.sh --check` (no Docker needed for the parse part) lists the scenarios, validates
  their files and checks that the tools exist; `test_build_bats`-style test `test_e2e_check` runs it.
- **Not in the regular suites**: the full harness needs Docker and starts servers, so `tools/godot_tests.sh` and
  `tools/dotnet_test.sh` never run it. It runs on demand and before a server slice counts as done.
- **Done when:** `tools/e2e.sh` passes all four scenarios locally, in parallel (`-j 4`), twice in a row, leaving no
  `e2e_*` database, no server process and no change to `user://game_main.cfg`; `stairs` with a deliberately wrong
  `.sql` line fails and keeps its logs. **Met 2026-10-27:** three parallel passes of all four scenarios (about 7 s
  each), no `e2e_*` database left, no server running, `game_main.cfg` byte-identical; a copy of `stairs` with a wrong
  `.sql` line failed naming it, kept its logs and exited 1.

### E7. Files
```
tools/e2e.sh                                  the harness (bash, watched; Git Bash on Windows)
client-godot/tests/e2e/                       stairs, offline_stairs, redis_flush, ruleset_refused (.txt/.sql/.metrics)
client-godot/game/tools/dev_run.gd            --server, --player, --control
client-godot/game/server_link.gd              ServerLink.create(url, player)
client-godot/game/dev/commands/               wait.gd, expect.gd, e2e.gd (new); server.gd (check); new.gd (server mode)
client-godot/game/dev/dev_console.gd          control_dir; every Notification recorded for `wait notice`
client-godot/game/dev/run_player.gd           stops while the run waits for a floor seed
client-godot/game/dev/dev_report.gd           "server" block in server mode
client-godot/tests/game/test_e2e_tools.gd     the tests in E6
```

### E8. Decisions (2026-10-27, approved with the build)
1. **A harness script, not a mock server.** The real server is cheap to run; a mock would duplicate the contract and
   drift. The fake bridge already covers the client without a network.
2. **Throwaway state per scenario** (database, Redis index, port), never the dev database or Redis index 0, and no
   Settings writes: e2e runs can't disturb your play data, and scenarios run in parallel.
3. **Faults through a file-based control channel** (`e2e <action>` ↔ the harness loop), so one script can stop and
   restart the server or flush Redis mid-run. Small and dev-only; extended per slice (Redpanda, workers).
4. **The real ruleset gate**: the harness accepts only the live version, so a ruleset mismatch between the client and
   what the server was told is caught too.
5. **On demand, not in the regular suites**: it needs Docker and real processes; the regular suites stay fast and
   offline.
6. **Fixtures content** (`res://tests/fixtures/`, the two-floor run): stable and quick; the user's tuning can't fail it.

## Remaining work
- **Seed field in server mode** (3.1 note, "Later"): the title menu (your `presentation/`) still shows the seed field
  while linked; `GameMain.start_run` ignores the seed in server mode. Hiding it is a `presentation/` change, yours to
  approve.
- `kill` queued during an enemy turn: tested since `content-pass` (`test_kill_queued_during_enemy_turn`, driven by
  the battle's signals).
- **Manual checklist** (no headless test possible):
  - [x] In an exported release build, the `Dev` autoload is inert (backtick opens nothing) and a script in
    `user://dev_commands/` is never loaded. Done 2026-10-26 on the player export (spec `playable-demo` 3.12, F4):
    `test_dev_inert_rule` (`Dev.is_inert_for`), `test_console_registry` (`load_commands(false)` ignores
    `user://dev_commands/`), the command files are not in the player pack, and `tools/release_check.sh` checks the
    real build (backtick by scan code, the console area unchanged; the dev build as the control). Rerun it after
    each player export.
  - [ ] In the console overlay, repeated Tab cycles through the completions (command names, then argument ids) and
    shows the list when there are several.
- `status <unit>` (spec `content-pass`): a unit's statuses with turns and stacks; `test_status_command`.
- Fixed after the sync (2026-10-20): `effect` with a non-GameplayEffect file now refuses instead of raising a script
  error; `Battle` setup reports an unknown held item as a runner error ("unknown item 'x'") instead of crashing, like
  unknown equipment and use-slot items already did.

## Later (not in this slice)
- **Floor layout grid** in the inspector (the same add-on for `FloorLayout`: assign rooms and roles to map cells).
  Until then layouts are edited in the inspector and played with Play or `layout <id>`.
- **Strict animation controller and animation set for characters** (user, 2026-10-20): a fixed set of named
  animations every unit provides, so a new character or enemy slots in without hand-wiring each ability's animation
  and `execute` keys. Roadmap slice 1c3 `animation-sets`.
- **Room sizes and shapes** (Isaac's 2×1, 1×2, 2×2, L rooms). Deferred at the user's request. When it comes back:
  a `shape` field defaulting to 1×1 (old files unchanged), door bits per edge, a separate `floor/<n>/shapes` stream
  gated by a `FloorGenRules` chance defaulting to 0, so existing floors and goldens stay byte-identical.
