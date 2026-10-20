# Dev tools: what you get

> **Status: planned, not built yet.** This is what slice 1c (`specs/dev-tools.md`) gives you once it's implemented.
> The Godot editor feasibility check for the content tools passed on 2026-10-20.

The goal is to get the raw game running and easy to test. These tools are deliberately basic. Godot's own inspector
stays the editor for your data; the tools add only what the inspector can't do.

## 1. Making content (in the Godot editor)

### New content dock
A dock called **RPG Content**:
1. Pick a type: character, enemy, encounter, loadout, room, item or event.
2. Type an id and click **Create**.
3. It makes `<folder>/<id>.tres` from a basic template and opens it in the inspector.

| Type | What the template fills in |
|---|---|
| Character / enemy | Attribute set, **every stat already listed** (you only change numbers), a cube colour |
| Encounter | Weight 1, no slots yet (add enemies in the inspector) |
| Loadout | Just the id |
| Room | All four doors, player spawns 1–4 |
| Item | Passive, weight 1, price 0 |
| Event | One page with one choice that ends the event |

It never overwrites an existing file or reuses an id. **Validate** lists anything broken or still to fill in, and
clicking an issue opens its file.

### Room grid
Select a room and a **13 × 7 clickable grid** appears above its normal fields:
- Paint player spawns, enemy spawns, event props, item pedestals and shop slots from a palette; erase them.
- Toggle the four doors.
- Ctrl+Z undoes and Ctrl+S saves, as usual.
- Click a placement to edit its item, item pool, loadout or price in the normal inspector.
- Problems with the room show live under the grid.

### What stays in the normal inspector
Encounters (slots, enemies, loadout overrides, forced variant), loadouts, enemies, characters, items, events. That's
also where the room's **type, chapter and pools** are set, all as **tags** with the tag picker. An item in a room is
an item pedestal or shop slot, with a fixed item or a pool. A pedestal in a battle room unlocks when the fight is won.

### Play buttons
On rooms, encounters, enemies, characters and floor layouts. **Play** saves and starts the game straight into:

| You press Play on | You get |
|---|---|
| A room | That room, with your party |
| An encounter | A fight with it in a battle room |
| An enemy | A fight against that enemy alone |
| A character | A new run with that character in the party |
| A floor layout | That floor |

Party, seed, floor depth and chapter for Play are set once in the dock.

## 2. Testing in the game

### Console (backtick key, any screen)
Tab completes commands and content ids. Up and Down go through your history. Floors count from 0.

**Play commands** (do what the screens do; the run stays clean):
`new`, `state`, `map`, `enter`, `choose`, `take`, `use`, `act`, `auto`, `next`, `seed`, `validate`, `help`, `clear`,
`shot` (screenshot), `seeds` (opens the seed runner).

**Cheats** (logged, and the run is marked as a dev run):

| Command | Does |
|---|---|
| `give <item>` / `remove <item>` / `equip <equipment>` | Inventory, as if picked up |
| `stat <attribute> [count]` | Permanent stat up (or down with a negative count), as stackable dev items |
| `heal` / `revive` / `effect <file>` | HP and MP, revive, or any GameplayEffect, outside battle |
| `kill [enemies\|party\|slot]` | In battle: kills at the next party decision (real death handling) |
| `coins <n>` | Add or remove coins |
| `spawn <encounter>` | Start that fight in the current room |
| `spawn item <item> [price]` / `spawn pool <tag>` | Put a pedestal (or shop slot) in the current room |
| `stage <floor>` / `room <room>` / `layout <layout>` | Jump to a floor, a single room or a hand-made floor |
| `reveal` / `win` | Show the whole map / end the run as won |

Cheats are switched off once the game is connected to the server.

### Seed runner
- **One seed:** shows the floor it generates as a map, with every room's encounter, elites, event and items, without
  playing it.
- **Many seeds** (for example 1000): failures, attempts, room counts, and how often each room, encounter, event and
  item shows up. Use it to tune floor rules.

### Seed codes
Seeds can be typed as short codes like `K7QP 2M9X`. A typo is refused rather than loading a different run. Plain
numbers still work.

## 3. Checking content automatically
- **Validator:** missing or wrong references, duplicate ids, pools that match nothing, rooms whose doors can't fit,
  bad placements, events and items. It runs as a test over your `content/`, in the console, from the dock and under
  the room grid. It never judges balance, so tuning can't fail it.
- **Headless reports:** `validate_content.tscn` and `seed_report.tscn` print results and exit with a code.

## 4. For Claude (and scripts)
`game/tools/dev_run.tscn` plays a text file of console commands with no window and writes the final state as JSON:
party stats, items, coins, run hash, and the reply to every command. With a window it can also save screenshots
(`shot`). This lets Claude play your content end to end and tell you exactly which step failed.

### Everything also works without a window
Every button has a command that runs the same code, so Claude (and scripts) can use every tool:
`create` (dock), `grid … paint/erase/door/show/save` (room grid), `play <kind> <id>` (Play buttons), `validate`,
`seed_report.tscn`, `shot`. Any new tool or button must come with its command. Claude tests on `user://` copies and
only changes your `content/` files through the normal permission prompts.

### Adding commands
- **A permanent command** is one file in `game/dev/commands/`, copied from `_template.gd`. The console finds it on
  its own: no registration, autocomplete included. It gets a test.
- **A throwaway command** goes in `user://dev_commands/`, outside the project. Claude can write one to check a single
  thing, run it with the script runner (`--commands <folder>`), and leave nothing behind in the repo. It can't
  replace a built-in command and is ignored in release builds.
- A command can use the run, the content index and the current battle. It changes units through GAS and the run
  through `RunController`, the same as everything else. If it needs something the run layer doesn't offer yet, that's
  a small change to system code, never to your content.

## Not in this slice
- A grid for floor layouts (edit them in the inspector for now; Play works on them).
- Room sizes and shapes (all rooms are one cell).
- A strict animation controller and animation set, so new characters slot in without hand-wiring animations (its own
  slice 1c3 `animation-sets`).
