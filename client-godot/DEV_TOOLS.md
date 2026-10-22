---
title: RPG Dev Tools
subtitle: A user guide for the Godot editor plugin, the in-game console and the headless tools
meta: Project: turn-based roguelike on Godot 4.7.2 .NET + GodotGAS
meta: Covers: dev-tools (slice 1c), item pass, animation sets (slice 1c3)
meta: Updated 2026-10-21. Full spec: specs/dev-tools.md
footer: RPG Dev Tools - user guide
toc: true
---

<!-- The front matter above is for building a PDF of this guide; it is ignored when reading the file. -->

## 1. The tools at a glance

The dev tools make content iteration fast: build a room and play it in seconds, jump to any run state, see what a
seed generates without playing it, and catch broken content the moment you save it. They are deliberately basic.
**Godot's own inspector stays the editor for your data**; the tools only add what the inspector can't do.

| Tool | Where | What it does |
|---|---|---|
| RPG Content dock | Godot editor, dock panel | Create a new asset from a template, validate all content, set the Play settings |
| Room grid | Inspector, on any room | Clickable 13 x 7 grid: paint spawns, props, pedestals, shop slots; toggle doors |
| Play buttons | Inspector, on rooms, encounters, enemies, characters, layouts | Save and start the game straight into a sandbox with that asset |
| Console | In the running game, backtick key | Play commands, cheats, content tools; Tab completion and history |
| Seed runner | Console `seeds` | One seed's floor without playing it; statistics over many seeds; tune floor rules |
| Seed codes | Anywhere a seed is typed | Short codes like `K7QP 2M9X` with a check character |
| Content validator | Dock, console, room grid, tests, headless | Broken references, empty pools, bad rooms, layouts, events, items |
| Animation sets | Inspector + console `anim` | A unit's look as data: nine animation slots with fallback |
| Script runner | Headless (`dev_run.tscn`) | Plays a text file of console commands without a window and writes JSON |

**Where the code lives** (all system code, none of it in your design folders):

- `client-godot/addons/rpg_dev/`: the editor plugin "RPG Dev Tools" (dock, room grid, Play buttons).
- `client-godot/game/dev/`: console, commands (`commands/`, one file each), sandbox, validator, templates, seed runner.
- `client-godot/game/dev/content/`: dev-only effects (kill, heal, revive) and dev stat items.
- `client-godot/game/tools/`: headless tool scenes (`dev_run`, `validate_content`, `seed_report`, builders).
- `specs/dev-tools.md`: the full spec.

## 2. Five-minute tour: from nothing to a fight

This goes through the whole loop once: a new enemy, an encounter that uses it, a room to fight it in, then playing it.

1. Open the project in the Godot editor (`H:\Godot\Godot_v4.7.2-stable_mono_win64.exe`). Find the **RPG Content** dock.
2. Under **Create**, pick type `enemy`, type the id `demo.enemy.wolf` and click **Create**. The file
   `content/demo/enemies/wolf.tres` appears and opens in the inspector, with **every stat already listed**. Change the
   numbers you care about and give it at least one ability.
3. Create an `encounter` with id `demo.encounter.wolves`. In the inspector, add slots and drag `wolf.tres` into them.
4. Create a `room` with id `demo.room.den`. The room grid appears above its fields. Pick **Enemy** in the palette, set
   **Slot** to 1 and click a cell on the right; repeat for slot 2. Player spawns 1-4 are already in the left column.
5. Give the room its type and chapter **as tags** with the tag picker (`content/demo/rooms/arena.tres` shows the tags
   a battle room uses). Save with Ctrl+S.
6. Press **Play this encounter** on the encounter (or **Play this room** on the room). The game starts in a second or
   two, straight into the fight. Close the game window to return to the editor.
7. In the game, press the backtick key to open the console and try `state`, `give`, `heal`, `kill enemies`.
8. Back in the dock, click **Validate content** to see anything still missing.

> **Tip:** The validator always says what a new asset still needs ("a unit with no abilities", "an encounter with no
> slots"), so you can always see what to fill in next.

<!-- pagebreak -->

## 3. Making assets: the RPG Content dock

The dock has three parts: **Create**, **Validate** and **Play settings**.

### Create

1. Pick a **type**.
2. Type an **id** (for example `demo.enemy.slime`).
3. Optionally change the **folder**. It remembers the last one used; the first time it is
   `res://content/demo/<type folder>/`.
4. Click **Create**. The file is named after the last part of the id (`demo.enemy.slime` becomes `slime.tres`), saved,
   and opened in the inspector.

| Type | Default folder | What the template fills in |
|---|---|---|
| character | characters/ | id, display name (from the id), the attribute set most units use, **every stat of that set** at its default, a cube colour, `selectable`, the default view (empty = the cube) |
| enemy | enemies/ | The same as a character, without `selectable` |
| encounter | encounters/ | id, display name, weight 1, no slots (add enemies in the inspector) |
| loadout | loadouts/ | Just the id |
| room | rooms/ | id, display name, all four doors, `min_doors` 1, weight 1, player spawns 1-4 in the left column |
| item | items/ | id, display name, `PASSIVE`, weight 1, price 0 |
| event | events/ | id, display name, one page with one choice that ends the event |
| animation_set | animation_sets/ | An empty animation set whose fallback is the default set (section 11) |

**Create never overwrites.** It refuses an id the type already uses and a file that already exists, and names the
existing file. The console command `create <type> <id> [folder]` uses the same templates.

> **Note:** Equipment has no template yet. Make a piece of equipment by duplicating one in `content/demo/equipment/`
> (right-click, Duplicate in the FileSystem dock) and changing its id, slot and effects.

### Validate

**Validate content** runs the content validator over the content root (from Play settings) and lists every issue.
**Double-click an issue to open its file.** "No problems." means you're clean. Section 10 lists every check.

### Play settings

Set once, used by every Play button. Saved in `user://dev_tools.cfg`.

| Field | Meaning |
|---|---|
| party | Character ids, comma separated. Empty = the first two selectable characters. |
| seed | A number or a seed code. |
| depth | Floor index (0 = the first floor). Affects enemy scaling and which RNG streams are used. |
| chapter id | Empty = automatic (the first chapter whose room query matches the room, else the first chapter). |
| content root | Where content is read from, normally `res://content/`. |

## 4. Editing in the inspector

Every content class is a documented `@tool` resource with the tag picker and typed stats, so the normal inspector is
where you edit:

- **Encounters**: slots, enemies, loadout overrides, forced variants.
- **Characters and enemies**: stats, abilities, `view` (their look, section 11).
- **Loadouts, items, equipment, events**.
- **A room's type, chapter and pool membership**: all **tags** on the asset, picked with the tag picker.
- **Placements** in a room (item, item pool query, loadout, price): open them with the room grid's **Select** tool.

**Numbers:** type designer numbers as you think of them (`150` for 150 %, `80.5` for a flat value). The authoring
fields store them x100 as whole numbers for you. Never type basis points.

An item in a room is always a **pedestal** or a **shop slot** placement, with a fixed item (or equipment) or an item
query (a pool). A pedestal in a battle room unlocks when the fight is won.

<!-- pagebreak -->

## 5. The room grid

Select any room (`RoomDefinition`) in the FileSystem dock. Above its normal fields you get:

- a **palette**: Player, Enemy, Prop, Pedestal, Shop, Erase, Select, and a **Slot** number;
- the **13 x 7 grid** of cells;
- four **door buttons** around the edges (North, East, South, West);
- a live **problems** list under the grid ("No problems." when it's fine);
- a **Play this room** button.

| Tool | Clicking a cell | Slot number means |
|---|---|---|
| Player | Places a player spawn | Party slot (1-4) |
| Enemy | Places an enemy spawn | Encounter slot |
| Prop | Places an event prop | - |
| Pedestal | Places an item pedestal (free pickup) | - |
| Shop | Places a shop slot (bought with coins) | - |
| Erase | Removes the placement in that cell | - |
| Select | Opens that placement in the inspector (the back arrow returns to the room) | - |

- **One placement per cell**: painting on an occupied cell replaces what was there.
- Every click is one undo step: **Ctrl+Z** undoes, **Ctrl+S** saves, like any inspector edit.
- Use **Select** to set a pedestal's or shop slot's item, item query and price, or an enemy spawn's loadout.
- Doors are toggled by the edge buttons. A room needs at least `min_doors` doors; the validator warns if the generator
  can produce a door combination no room accepts.

### Without a window: the grid command

The `grid` console command makes the same edits through the same code, on an **in-memory copy** until you save.
Coordinates are 0-based: x from 0 to 12, y from 0 to 6; doors sit on the middle row and column.

```
grid demo.room.den show                 # prints the grid as text
grid demo.room.den paint 10 2 enemy 1   # enemy spawn, encounter slot 1, at x=10 y=2
grid demo.room.den paint 6 3 pedestal   # an item pedestal in the middle
grid demo.room.den erase 6 3
grid demo.room.den door n               # toggle the north door
play room demo.room.den                 # plays the unsaved copy
grid demo.room.den save                 # writes it (or: save <path>)
```

> **Tip:** Spawn counts matter: a room with a fixed encounter needs at least as many enemy spawns as the encounter has
> slots, and any battle room needs a player spawn. The grid's problem list flags both.

## 6. Play buttons and Play settings

Rooms, encounters, enemies, characters and floor layouts get a **Play this ...** button in the inspector. It saves the
asset first, then starts `game/dev/play_main.tscn` with the Play settings from the dock.

| Play on | You get |
|---|---|
| A room | That room as a one-room sandbox floor, with your party. Its content plays (fight, event, shop...). |
| An encounter | A fight with it, in the chapter's first normal battle room (else any room with an enemy spawn). |
| An enemy | The same room, against a one-slot encounter built around that enemy. |
| A character | A new normal run with that character in slot 1 (plus the saved party). |
| A floor layout | That hand-made floor, start room already cleared. |

- A sandbox never goes to a next floor. When the room is cleared you stay there (pickups still takeable).
- If the party dies, the run-end screen's button closes the sandbox.
- Close the game window to return to the editor.
- Console equivalent: `play <room|encounter|enemy|character|layout> <id or path>`.

> **Tip:** Floor layouts don't have a grid editor yet: edit them in the inspector and test them with Play (or
> `layout <id>`).

<!-- pagebreak -->

## 7. The console

Press the **backtick key** (left of 1) in any scene of the running game: the menu, the map, a battle, a sandbox.

| Key / rule | What it does |
|---|---|
| Tab | Completes the command name, then each argument from its kind (content ids, slots, tags...). Press again to cycle; a list shows when there are several matches. |
| Up / Down | History. The last 50 lines are kept in `user://dev_console_history.txt`. |
| `help` / `help <command>` | Lists all commands, or shows one command's usage. |
| "quoted args" | Arguments with spaces can be quoted. |
| Floors are 0-based | `stage 0` is the first floor (the code's own numbering). |
| Slots 1-4 | Party members are numbered by their party slot. |
| Choices are 0-based | `choose 0` picks the first event choice. |
| Targets | In battle, `E1`, `E2` ... are enemies and `P1`, `P2` ... party members. |
| Ids or paths | Most commands take an id (`demo.room.arena`) or a path (`res://...`, `user://...`). |

### Play commands and cheats

**Play commands** do exactly what the screens do. A run played only through them stays clean: same run hash as the
same choices made by clicking.

**Cheats** change the run in ways the game wouldn't. Each one is **written into the run log** as a `dev` entry and marks
the run as a **dev run** (`dev=1` in the run hash). Dev runs are never uploaded or rewarded, and cheats are switched
off once the game is connected to the server. Cheats still go through the real systems: unit changes are
GameplayEffects or items applied by GAS, run changes go through `RunController`.

### A short session

```
new demo.character.warrior,demo.character.cleric K7QP 2M9X   # start a run (seed code with its space)
map                      # the floor as text; ENTER marks where you can go
enter 3                  # walk into cell 3
state                    # party HP/MP/ult charge, items, coins...
give demo.item.fire_bomb 1
stat atk 3               # +30 ATK for slot 1, permanently, through GAS
spawn demo.encounter.golem
auto off
act <ability tag> E1     # Tab completes the ability
kill enemies             # applied at the next party decision
seed                     # shows the seed and copies it to the clipboard
```

<!-- pagebreak -->

## 8. Console command reference

### Play commands (the run stays clean)

| Command | Does |
|---|---|
| `help [command]` | Lists commands, or one command's usage. |
| `new <id,id,...> [seed]` | Starts a run with 1-4 characters and a seed (number or code; default 1). |
| `seed [seed]` | No argument: shows the run's seed (code and number) and copies it. With one: a new run, same party, that seed. |
| `state [json]` | Floor, cell, coins, party (HP/MP/ult charge read through GAS), items, use slots, equipment, open event or battle. `json` prints it the way the script runner writes it. |
| `map` | The floor as text: index, cell, role, room id, content, pickups, visited/cleared, ENTER where you can go. |
| `enter <cell>` | Enters a room (the index from `map`). |
| `choose <choice>` | Picks an event choice (0 = the first). |
| `take <placement> <slot>` | Takes or buys a pickup for a party member. Armor ignores the slot and goes to the armor inventory. |
| `wear <equipment> <slot>` | Equips a piece from the armor inventory (map only); the replaced piece goes back. |
| `unwear <slot> <slot tag>` | Takes off what a member wears in that equipment slot, e.g. `Equipment.Slot.Head` (map only). |
| `items [tag]` | Lists every item and piece of equipment, or only those with a tag (e.g. `Pool.Shop`). |
| `use <slot> <ability> [target slot]` | Field action on the map. |
| `act <ability> [target]` | In battle: the waiting member uses an ability on a target (`E1`, `P2`...). |
| `auto [on\|off]` | Auto battle on/off (no argument toggles). |
| `next` | Next floor after the boss. |
| `shot <name>` | Screenshot to `user://shots/<name>.png` (needs a window). |
| `clear` | Clears the scrollback. |

### Content tools (same code as the editor buttons)

| Command | Does | Editor equivalent |
|---|---|---|
| `create <type> <id> [folder]` | New asset from a template; never overwrites. | Dock: Create |
| `validate [errors]` | Runs the validator; `errors` hides warnings. | Dock: Validate |
| `grid <room> <op> ...` | `paint <x> <y> <kind> [slot]`, `erase <x> <y>`, `door <n\|e\|s\|w>`, `show`, `save [path]`. | Room grid |
| `play <kind> <id or path>` | Plays the asset in a sandbox. | Play buttons |
| `seeds` | Opens the seed runner. | - |
| `anim <unit> [slot]` | Shows a unit's view and animation set; with a slot, plays it on screen. | - |

### Cheats (logged; the run becomes a dev run)

| Command | Does |
|---|---|
| `give <item> [slot]` | The item as if picked up (default: the first member who can hold it). |
| `remove <item>` | Removes the item from its holder. |
| `equip <equipment> [slot]` | Equips a piece of equipment directly (default slot 1). |
| `stat <attribute> [count] [slot]` | Adds `count` dev stat items (negative = downs). Steps: max_hp 100, max_mp 50, atk/def/spd 10, crit_rate/crit_dmg 5 %, max_energy 10. |
| `effect <effect path> [slot]` | Applies any GameplayEffect `.tres` outside battle. Instant effects stick; lasting ones end with the field context (use `stat` or `give` for permanent changes). |
| `heal [slot]` | Full HP and MP. In battle: at the next party decision. |
| `revive [slot]` | Dead members back at 1 HP, outside battle. |
| `kill [enemies\|party\|<slot>]` | In battle: HP to 0 at the next party decision, with real death handling. Killing one slot doesn't use up the turn. |
| `coins <n>` | Adds coins (negative removes; never below 0). |
| `spawn <encounter>` | Starts that fight in the current room (floor scaling and elite rolls apply). |
| `spawn item <item> [price]` | Puts a pedestal (price 0) or shop slot with that item or equipment in the current room. Numbered from 1000; take it with `take`. |
| `spawn pool <tag> [price]` | The same, with the item picked from a pool tag. |
| `stage <floor>` | Jumps to a floor (0 = the first); party and inventory kept. |
| `room <room>` | Plays one room now (keeps the party; without a run, starts a sandbox). |
| `layout <layout>` | Plays a hand-made floor now. |
| `reveal` | Shows the whole map. |
| `win` | Ends the run as won (to test the run-end screen). |

> **Note:** `give`, `stat`, `equip` and `remove` during a battle change the run, which the battle captured when it
> started, so they apply from the next battle or field action. The console tells you so.

<!-- pagebreak -->

## 9. Seed codes and the seed runner

### Seed codes

Seeds can be typed as 8-character codes such as `K7QP 2M9X`: 7 characters of seed plus one check character (Luhn mod
32). They work anywhere a seed is typed: the menu, `new`, `seed`, the Play settings, the seed runner.

- Case doesn't matter; spaces and dashes are ignored; `O` reads as 0 and `I`/`L` as 1.
- **A typo is refused** ("not a seed") instead of silently loading a different run.
- Plain numbers still work and mean exactly what they always did. The menu's Random button fills in a code.

### Seed runner (console: `seeds`)

**One seed:** enter a seed or code, a floor number and a chapter (auto = what the run would pick). It generates floors
0..n in order and draws the map: roles, room ids and every room's resolved content (encounter, elite variants, event,
pedestal and shop items with prices) and the generation attempts. **Play this seed** starts a normal run with it.

**Many seeds:** from seed S, count N (default 100), floor n. It reports failures (click one to view it), attempts and
room counts (min/avg/max), dead ends, and how often each room, encounter, event, elite and item appears.

**Rules panel:** base rooms, rooms per depth, random extra rooms, max rooms and branch % on a copy of the chapter's
`FloorGenRules`. Changes re-run the report live; **Save** writes the rules file. **Back to the game** returns to the menu.

> **Tip:** Run many-seeds mode after adding rooms or changing pools: a room that never shows up, or a seed that fails
> to generate, is visible at once.

## 10. The content validator

The validator checks references and structure, **never balance**, so tuning numbers can't fail it. It runs from the
dock, the console (`validate`), live under the room grid, as a test over your `content/` (`test_content_valid`) and
headless (`validate_content.tscn`, exit code 3 on errors).

| Code | Level | Finds |
|---|---|---|
| content_index | error | Duplicate ids, a file of the wrong class in a content folder |
| missing_id | error | A definition with an empty id |
| dangling_ref | error | An empty entry where content is required (slot without enemy, chapter without rules, ...) |
| bad_loadout_ref, bad_skill | error | A loadout that can't be resolved; a skill the character doesn't have |
| empty_query | error | A query a floor depends on matches nothing (room roles, encounter, boss, event queries) |
| empty_item_pool | warning | A placement's item query matches nothing (error if there is no fallback item) |
| zero_weights | error | A pool whose matches all have weight 0 |
| doors_unsatisfiable | error / warning | `min_doors` above the room's doors; a door mask no room accepts |
| placement_outside, placement_overlap | error | A placement off the 13 x 7 grid, or two in one cell |
| spawn_mismatch | warning | Fewer enemy spawns than encounter slots; no player spawn |
| placement_kind, placement_both | warning / error | A field that doesn't fit the placement kind; both item and equipment set |
| bad_equipment, bad_equipment_slot | error | Equipment without a slot, or a slot no run structure lists |
| no_description | warning | An item or piece of equipment without a description |
| trigger_unregistered | warning | A triggered ability listening to an event the battle never sends (a typo) |
| bad_layout, bad_event, bad_item | error | Broken layouts, event page jumps, usable items without an ability |
| unknown_tag, reserved_tag | warning / error | A tag not in the registry; content using the reserved `Dev.` prefix |
| incomplete | warning | What a new asset still needs (no abilities, no slots) |
| generation_fails | error | A floor that fails to generate for one of the test seeds |
| view_missing, animation_set_loop, animation_set_profile, ability_montage_path | warning | Look problems (section 11). Never errors: a look can't break a run. |

<!-- pagebreak -->

## 11. Animation sets and the anim command

> **Note:** This is the newest part (slice 1c3): built, with its spec sync still to do on the roadmap.

A unit's look is data. An **animation set** (`UnitAnimationSet`) has nine slots, each an `Animation`:

| Slot | Plays when |
|---|---|
| idle (loop) | Battle setup and on the map |
| walk (loop) | Reserved for in-room walking (later) |
| hit / block | Taking damage, as an additive flinch on top of whatever plays |
| death, then dead (loop) | The unit dies; holds the last pose |
| revive | Brought back |
| victory | Battle won |
| cast | Generic cast; the ability's own animation plays as a montage on top |

- **Empty slots fall back** to the fallback set (by default the demo cube set,
  `presentation/demo/animation_sets/default.tres`).
- A character's or enemy's **`view`** field is the path to its view scene. Empty = the default cube view. The view
  scene's `UnitAnimator` node picks the animation set.
- Ability animations stay with the abilities in `content/`: their `execute` keys still time the hits.
- For humanoid models: import with Retarget, Bone Map set to `SkeletonProfileHumanoid` and Rename Skeleton on, so one
  set serves every humanoid model.

### Making one

1. Dock: type `animation_set`, an id, **Create**. You get an empty set that falls back to the default.
2. Drag animations into the slots you want to change; leave the rest empty.
3. Set it on your view scene's `UnitAnimator`, and point the unit's `view` at that scene.
4. Press **Play** on the character or enemy to see it in a sandbox.

### Checking one

```
anim demo.enemy.golem          # view, set, which slots are own / fallback / empty, lengths, problems
anim demo.enemy.golem death    # also plays 'death' on that unit's views on screen
```

## 12. Headless tools and scripts

Everything also works without a window. These are the commands Claude uses, and you can run them yourself from a
terminal in `H:\rpgProject`. Always pass `--quit-after` so the process can't hang.

### Script runner: play a whole run from a text file

One console command per line; blank lines and `#` comments are skipped. Battles run on auto unless `--manual`.

```
H:\Godot\Godot_v4.7.2-stable_mono_win64_console.exe --headless --path client-godot \
    --quit-after 100000 res://game/tools/dev_run.tscn -- --script my_run.txt --out state.json
  options: --content-root res://tests/fixtures/   --manual   --commands <folder>
           --window --shots <dir>   (drop --headless; then `shot <name>` saves screenshots)
  exit code: 0 ok, 2 a command failed (the line is named), 1 tool error
```

The JSON holds the seed, status, floor, coins, party (HP/MP/energy, items, equipment, gear), armor, the last battle's
hit log, the run hash, the dev flag and the reply to every command. Example script:
`game/dev/scripts/item_pass.txt`.

### Other tools

| Scene | Does |
|---|---|
| `res://game/tools/validate_content.tscn` | The validator over `content/`. Exit 0 ok, 3 content errors. |
| `res://game/tools/seed_report.tscn -- --from 1 --count 1000 --floor 0 --out report.json` | Many-seeds statistics as JSON. |
| `res://game/tools/sync_tags.tscn [-- --add-missing]` | Checks every tag in content against the registry; regenerates `gameplay_tags.gd`. |
| `res://game/tools/generate_attributes.tscn [-- --check]` | Regenerates AttributeSet scripts from `attributes_draft.cfg`. |
| `res://tests/run_tests.tscn [-- --filter <text>]` | The Godot test suite (includes the content test over your `content/`). |

<!-- pagebreak -->

## 13. Writing your own console command

A command is **one file** in `game/dev/commands/`. The console finds it on its own: no registration, autocomplete
included.

1. Copy `game/dev/commands/_template.gd` to a new file (files starting with `_` are ignored).
2. Set `name`, `usage`, `help`, `cheat` and `arg_kinds` in `_init()`.
3. Fill in `run(ctx, args)`. Return the reply text; on an error return `ctx.fail("why")`.

```
extends DevCommand

func _init() -> void:
    name = "example"
    usage = "example <item> [slot]"
    help = "What it does, in one line."
    cheat = false                       # true = logged as dev, refused when connected
    arg_kinds.assign(["item", "slot"])  # drives Tab completion

func run(ctx: DevContext, args: PackedStringArray) -> String:
    var why := ctx.need_run()           # "" when a run is active
    if why != "":
        return ctx.fail(why)
    var item = ctx.find("item", args[0] if args.size() > 0 else "")
    if item == null:
        return ctx.fail(ctx.error)      # includes the closest ids
    return "found " + str(item.id)
```

`DevContext` gives you `game`, `run` (`RunController`), `content`, `battle`, `recorder`, `console` and the helpers
`need_run()`, `arg_int(args, i, fallback)`, `find(kind, id)`, `table_of(kind)`, `fail(message)`.

- Change units **through GAS** (effects, items) and the run **through `RunController`**.
- A cheat calls `ctx.run.dev_log(name, args)` first: it logs the command, marks the run, and returns the only RNG
  stream it may use.
- **Throwaway commands** go in `user://dev_commands/` instead: they load in debug builds, can't replace a built-in name
  and never touch the repo. Permanent ones get a test.

> **Tip:** You can also just ask Claude for a command. Claude can add permanent ones to `game/dev/commands/`, or write
> a throwaway one to check something with the script runner and leave nothing behind.

## 14. Rules, safety and troubleshooting

### What the tools never do

- **Never overwrite your files.** Create refuses existing ids and files; the grid only writes when you save.
- **Never touch the server.** Dev tools are local-mode only; cheats are refused once connected; a dev run can't be
  uploaded.
- **Never leak into normal play.** Dev items carry the `Dev` tag and are skipped by every pool; dev commands draw only
  from their own `dev/<k>` RNG streams, so later rooms and floors are unchanged.
- **Never fool the verifier.** A battle containing a dev kill or a dev item is rejected on replay (code 2002).
- **Never run in the headless verifier.** The `Dev` autoload is inert without a window.

### Troubleshooting

| Problem | Try |
|---|---|
| No RPG Content dock or room grid | Project, Project Settings, Plugins: enable "RPG Dev Tools". Reopen the project after pulling. |
| Backtick does nothing | Make sure the game window has focus. The console is off in release builds and headless runs. |
| "cheats are off" | You're connected to a server (or in a release build). Use local mode. |
| "no item 'x'" | A typo in an id; the reply lists the closest ids. Use Tab to complete. |
| Play opens the menu | The play request was missing or already used. Press Play again. |
| Changes made by Claude don't show | Accept Godot's "reload from disk" prompt. Save All before asking Claude to edit `.tres`/`.tscn` files. |
| `give` mid-battle did nothing | It applies from the next battle or field action. |
| A seed code is refused | Check for a typo; the check character catches single-character mistakes. |

<!-- pagebreak -->

## A. One-page cheat sheet

```
EDITOR
  RPG Content dock   Create <type> <id> | Validate content
                     Play settings: party, seed, depth, chapter, content root
  types              character enemy encounter loadout room item event animation_set
  room grid          Player Enemy Prop Pedestal Shop Erase Select + Slot
                     edge buttons = doors | Ctrl+Z undo | Ctrl+S save
  Play this ...      room | encounter | enemy | character | layout

CONSOLE  backtick to open | Tab completes | Up/Down history
         floors and choices 0-based | party slots 1-4 | targets E1, P2
  run      new <ids> [seed]   seed [seed]   state [json]   map
           enter <cell>   choose <n>   next
  items    items [tag]   take <placement> <slot>
           wear <equipment> <slot>   unwear <slot> <slot tag>
  field    use <slot> <ability> [target slot]
  battle   act <ability> [target]   auto [on|off]
  tools    create <type> <id>   validate [errors]   play <kind> <id>
           grid <room> paint|erase|door|show|save
           seeds   anim <unit> [slot]   shot <name>   clear   help [command]

CHEATS  (logged; the run becomes a dev run)
  give <item> [slot]   remove <item>   equip <equipment> [slot]   coins <n>
  stat <attr> [n] [slot]   effect <path> [slot]   heal [slot]   revive [slot]
  kill [enemies|party|slot]   spawn <encounter>
  spawn item <id> [price]   spawn pool <tag> [price]
  stage <floor>   room <room>   layout <layout>   reveal   win

HEADLESS  (from H:\rpgProject; always --quit-after)
  dev_run.tscn -- --script f.txt --out state.json
                  [--manual] [--content-root ..] [--window --shots dir]
  validate_content.tscn
  seed_report.tscn -- --count 1000 --floor 0 --out r.json
  sync_tags.tscn
  run_tests.tscn -- --filter <text>
```
