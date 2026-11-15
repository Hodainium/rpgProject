# Spec: floor-chests (a chest stays in the room where it dropped and opens there, like a shop)

Status: spec written 2026-11-14; the user's review answered Q1-Q5 the same day (section 7), ready for `/implement`. Slice: roadmap 5a5, after 5a4
`cube-style` (its Set K drew the three chest states) and before 5e `audio-pass`.

## 1. Purpose & enterprise mapping

Today (spec `keys-and-gear` 2.1-2.3) a chest is a **drop into an inventory**: a cleared room may roll a chest
(`RunController._drop_keys_and_chests`, stream `floor/<n>/chest/<cell>`), `give_chest` appends `{chest, serial}` to
`RunState.chests`, and the player opens it from the Use Item screen whenever they like, on any floor. Opening pays a key (the
Gilded Chest), picks a reward from the chest's run-wide stream `chest/<serial>` and runs its outcomes at once; an item inside
waits as a CHOOSE gift (`pending_gifts`, spec `event-items` D5) and armor goes straight to the armor inventory.

The user decided (roadmap 5a5, 2026-11-13) to make chests work like Isaac's:

- **D1. A chest stays in the room where it dropped** and is opened there. No chest inventory: a chest left behind stays
  in its room and is lost at the stairs, like everything else on the floor.
- **D2. A chest works like a shop.** Paying its price (a key for the Gilded Chest; nothing for the Wooden Chest; free with the
  golden key or `Run.Chest.NoKey`) opens it, and its rewards **spawn as pickups inside the chest**, in that room, the way a shop
  slot holds an item for a price. Taking one is a separate choice (the existing `take`), so the player may leave an item in
  the chest; it stays there, like an unbought shop item.
- **D3. Only items and armor wait in the chest.** A reward that is not an item (coins, keys, the golden key, a party heal, a map
  reveal, another chest) is given as soon as the chest opens.
- **D4. On opening, the rewards pop out of the chest onto the floor** (user, 2026-11-14, review Q3): each item or armor
  piece jumps out and lands next to the chest as an ordinary floor pickup; the chest stays beside them, open and empty. This
  replaces the roadmap's "open and filled while it holds something": the chest is drawn CLOSED, then OPEN_EMPTY. Set K's
  OPEN_FILLED state stays in `PropView` but this slice does not use it. In the run state the pickups still name their chest
  (`"chest": serial`), for analytics and the HUD grouping.
- **D5. The map marks a room with something left in it** (user, 2026-11-14, review Q5): on the minimap, the Tab view and
  the big map, a room that holds a closed chest or an untaken free pickup (a chest's item, a pedestal item) is drawn in a
  different colour.

What stays the same: the drop rolls and their streams, the chest definitions and their reward tables, the price rules, the
run-wide content stream `chest/<serial>` (so a chest holds exactly what it held before; only *where* it is and *how its items
are handed out* change), `Run.Chest.Double`, the messages `ChestFound` / `ChestOpened`.

**Enterprise mapping: one small contract addition, no new infrastructure.** A run rule change, so the ruleset version changes
and the run goldens are re-recorded. `open_chest` stays an existing action type (now also naming its `cell`) and the items
taken from a chest travel as ordinary `take` actions; both are uploaded, checkpointed and replayed by the step verifier like
every other run action (spec `run-verify`). For player analytics (roadmap slice 4b / 7) `open_chest` carries what the chest
offered, as `ItemOffer`s with a new `OfferSource.Chest` (decision Q4), so "items left in chests" is measurable from the event log.
No endpoint, queue, topic, Redis key or metric changes.

## 2. Sequence flow

### 2.1 A chest appears (room clear, `GiveChest`, the `chest` cheat)

```
_clear_room(cell) → _drop_keys_and_chests(cell)        unchanged roll on floor/<n>/chest/<cell>
  hit → give_chest(def)
give_chest(def):                                         every source lands in the CURRENT room (state.current_cell)
  cell["chests"] (created on first use) .append({"chest": id, "serial": state.chest_serial, "opened": false})
  state.chest_serial += 1
  Message.Run.ChestFound (toast "A Wooden Chest appeared!"), pickups_shown(cell)
```

- **A chest from a chest** (the Gilded Chest's 2% `GiveChest` Wooden Chest) appears closed in the same room, after the first
  one has opened (D3: not an item, so given at once).
- **Where there is no room** (a `GiveChest` in the rest event between floors): a validator error
  `give_chest_outside_room` (user, Q2), so content cannot do it; it should never happen (no content does today). Should one
  slip through anyway, `give_chest` warns (`ScriptErrorLog`-visible, so tests and reports fail) and gives nothing.

### 2.2 Opening (in the room)

```
HUD pickup panel row "Wooden Chest · OPEN" / "Gilded Chest · OPEN · 1 KEY"  (or console `open <n>`, or a bot)
open_chest(serial):
  refused when: not active, a battle or event pending, a gift waiting, the room not cleared,
                no closed chest with that serial in the current room, a key needed and none (unchanged reason text)
  log {"type": "open_chest", "floor", "cell", "chest": id, "serial": n}
  pay: unchanged (golden key / Run.Chest.NoKey free; else keys −= 1 for needs_key)
  chest["opened"] = true
  stream chest/<serial>, rolls 1 (2 with Run.Chest.Double), each a weighted ChestReward, its outcomes in order:
    GiveItem        → the item (fixed, or picked by its query from the chest stream, as today) becomes a pickup
    GiveEquipment   → the piece (picked by its query from the chest stream, as today) becomes a pickup
    anything else   → applied now, as today (coins, keys, golden key, party effect, reveal, GiveChest → 2.1)
  pickup = FloorGenerator.pickup_entry(placement, thing, 0) + {"chest": serial}
           placement = 2000 + the number of chest pickups already in the cell (unique per cell; 1000+ stays the dev spawn)
  Message.Run.ChestOpened {description: what was given at once, then "N inside" / "Empty!"}, pickups_shown(cell)
```

- `give_item` / `give_equipment_from` learn one more destination: while a chest opens (`_chest_rng` set, the existing
  marker) they append a pickup to the opening chest instead of giving. `GiveItem.recipient` and `GiveItem.character` mean
  nothing inside a chest (today's D5 override of CHOOSE is replaced by "it waits in the chest"; the taker is chosen at
  `take`). Chests no longer use `pending_gifts`; `_chest_toasts` goes away.
- A query that finds nothing (an empty pool) gives nothing, as today; a chest whose every roll was a non-item is open and
  empty at once.

### 2.3 Taking from an open chest

The existing `take(placement, slot)` path, unchanged: price 0, so it logs `take`; an item goes to `slot` (food is eaten on
pickup, spec `food-items`), armor to the armor inventory. Leaving the room leaves the pickup in the chest (D2); coming back
shows it again. `Message.Run.ItemTaken` keeps `source: take` with `"chest": serial` in its data (presentation may word the
toast "from the chest").

### 2.4 Leaving the floor

`next_floor` drops the map, so chests and their pickups go with it. No more carry-over (keys and the golden key are unchanged:
keys carry over, the golden key lasts one floor).

### 2.5 Upload and verification (unchanged pipeline)

```
client journal: open_chest → RunActionRequest {type: open_chest, floor, cell, chestId, serial, coinsAfter, offers[Chest]}
                take       → RunActionRequest {type: take, cell, placement, itemId, kind, characterId, price 0}
POST /api/v1/runs/{id}/actions → run_actions (idempotent by seq) → a step per checkpoint → verify.segment
StepRunner: RunWire.apply("open_chest") → run.open_chest(serial) in the logged cell; the claimed state hash must match
```

The server only stores and forwards these; it never knows what a chest is (no game logic in C#).

### 2.6 Presentation (never in a hash, snapshot or upload)

- **Where a chest stands:** `RoomView3D` places each chest of the room on a free floor tile picked from the room's grid
  (not a placement, not a pickup tile, not a door lane), in serial order, nearest the room's centre first. View-only, so
  it can change without touching a run.
- **States (D4):** `PropView.chest(look, state, text)`: CLOSED, then OPEN_EMPTY once opened. On open the lid swings up (a
  tween on `lid_pivot`, about 0.4 s in game time).
- **The pop-out (D4):** each of the chest's pickups is drawn the way any floor pickup is (armor by `armor_look` in its
  rarity colour, an item as today's item prop), on its own free floor tile next to the chest (the free tiles around it,
  nearest first, in placement order). When the chest opens, each pickup starts inside the chest and jumps to its tile on an
  arc (about 0.5 s, staggered 0.15 s, in game time; `loot_glow` on landing). A room entered later shows them already on
  their tiles. Taken ones vanish like pedestal items. Purely a view tween: the run state has the pickups from the moment
  `open_chest` returns.
- **The HUD pickup panel** (`pickup_panel.gd`) lists, per chest of the room in serial order: a closed chest as one row
  with OPEN / OPEN · 1 KEY (disabled with `why` when it cannot open), an open chest as a small header ("Gilded Chest") and
  its untaken pickups as ordinary pickup rows (the give-to picker for items). The pedestals and shop rows keep their place.
- **The Use Item screen** loses its chest section (spec `keys-and-gear` D9 superseded).
- **The map tint (D5):** `MapCells.of()` adds `"leftover": bool` per cell: shown, visited, and holding a closed chest or an
  untaken pickup with price 0 and no `priceItem` (shops stay as they are; their stock is not "left over"). The minimap, the
  Tab view and the big map draw such a room's tile in `leftover_color` (an export on the map drawing, in `presentation/`,
  default a warm gold) instead of the visited colour; the current room keeps its "here" look. Presentation only.

## 3. Data contracts

### 3.1 Contracts (`src/Rpg.Contracts/Runs/RunActions.cs`)

```csharp
public enum OfferSource { Treasure, Shop, BossReward, Other, Chest }   // + Chest, appended (string-serialized; order kept)

// RunAction: no new field. Doc comments change:
/// <param name="Cell">enter_room / choose / take / buy / open_chest: the room (open_chest: the chest's room, spec floor-chests).</param>
/// <param name="ChestId">open_chest: the chest (spec keys-and-gear).</param>
/// <param name="Serial">open_chest: the chest's run-wide serial.</param>
/// <param name="Offers">enter_room: every pickup on offer in that room; open_chest: what the chest put inside (Source Chest).</param>
```

- `RunWire.offers(state, cell)` reports a pickup with a `chest` field as `Source: Chest` (also when the room is re-entered).
- The golden JSON for `RunAction` / `ItemOffer` in `Rpg.Contracts.Tests` gains an `open_chest` case with `cell` and offers.
- The server must accept `Chest` before any client sends it: both ship in this slice's one PR.

### 3.2 Run state, hash and snapshot (`game/`)

| What | Before | After |
|---|---|---|
| `RunState.chests` | the inventory `[{chest, serial}]` | **removed** |
| cell `"chests"` | (absent) | `[{"chest": StringName, "serial": int, "opened": bool}]`, **present only in a cell that ever held a chest** |
| cell `"pickups"` entry | `{placement, item, price, taken[, kind, keys, priceItem]}` | + optional `"chest": serial` on a chest's pickup |
| `RunState.chest_serial` | next serial | unchanged |
| hash line | `keys=n\|golden=0/1\|chests=id:serial,...\|serial=n` (when any non-zero) | `keys=n\|golden=0/1\|serial=n` (same condition minus the inventory) |
| cells in the hash | every field (`StateHasher.canonical`) | unchanged rule, so a cell's `chests` and a pickup's `chest` are covered automatically |
| `RunSnapshot` v1 | top-level `"chests"`, `CELL_KEYS` fixed | top-level `"chests"` removed; `"chests"` an **optional** cell key (restored with StringName ids and ints); `schemaVersion` stays 1 (Q1) |

Runs that never see a chest hash exactly as before (no cell gets the key, the hash line is unchanged when it has no chest
part). Runs with chests change hash: the keyed scripted run golden `golden/game/run_keyed.json` and any seed-report golden
with chests are re-recorded (intended, CLAUDE.md "no workarounds for tests").

### 3.3 `RunController` (system code)

- `give_chest(def)`: into the current cell (2.1). `chests()` → `room_chests()`: the current room's chests for screens and
  bots, `[{"serial", "chest", "name", "description", "opened", "filled", "needs_key", "free", "can_open", "why"}]`.
- `open_chest(serial: int) -> String` (was an inventory index). Checks first, nothing changes on a refusal.
- `_chest_problem(serial)` adds "clear the room first" and "no chest %d here".
- `run_summary()` (only on runs that use keys): `chestsOpened` (unchanged), `chestsLeft` = closed chests on floors left
  behind plus those in the current floor's rooms; new `chestItemsLeft` (untaken chest pickups left behind), only when above 0.
- Gone: `state.chests`, `_chest_toasts`, the chest branch of `give_item`'s CHOOSE override.

### 3.4 Content and validator

- No content file changes: `wooden_chest.tres` and `gilded_chest.tres` keep their tables. Their descriptions still read
  right ("Free to open: armor or a weapon, coins, a heal or a key.").
- Validator: `give_chest_outside_room` (error, decision Q2): a `GiveChest` in the run structure's `rest_event`. The existing
  `give_choose_outside_event` wording drops "a chest" (CHOOSE inside a chest is now meaningless, not an error: a warning
  `chest_recipient_ignored` when a chest's `GiveItem` sets a recipient or a character).

### 3.5 Bots, console, `dev_run`

| Who | Change |
|---|---|
| `RunPlayer` (auto, smart) | Each map step in a cleared room: open the room's chests first (same rule: the Wooden always, a key-priced one only with a key to spare after the floor's unopened locked rooms, or free), then `_take_pickups` (which now also sees the chest's pickups: items to the first who can hold them, food to the lowest HP share as today, armor always). The `pending_gifts` wait after `_open_chests` goes away. |
| `RunPlayer` chaos | `chest_no_key` (a closed key-priced chest in the room, no key), `chest_index` → `chest_missing` (a serial not in this room), new `chest_uncleared` only if a chest can stand in an uncleared room (it cannot today, so not added). |
| Console | `chests`: the current room's chests (`<serial> <name> closed\|open, n inside` and OPEN / why); `open <serial>`; `chest <id>` (cheat) drops it in the current room; `take <placement>` already covers chest pickups; `state` and `dev_run` JSON show the room's chests instead of the inventory. |
| `dev_report` | `chests` lists the current room's chests with serial, opened, items inside. |

## 4. Failure modes

| Case | Behaviour | Test |
|---|---|---|
| Refused open (no key, wrong serial, not cleared, battle/event/gift pending, chest already open) | nothing changes: no log entry, same hash, same keys and coins | `test_floor_chests` refusals; chaos `run_action_not_refused` |
| Take from a chest | the shop path: `can_hold`, already taken, no such pickup; a chest's pickup is never priced | `test_floor_chests` |
| Same chest, same contents | contents come from `chest/<serial>` only, so opening it on a later visit, after other actions, gives the same pickups | `test_floor_chests` (open early vs. late, compare pickups) |
| Idempotent upload | unchanged: seq + body comparison (spec `server-authority` 2.2) | existing |
| Resume / snapshot round trip with an open, half-emptied chest | restored exactly (StringName ids, ints), same hash | `test_run_authority` resume-equivalence over the keyed run; `test_snapshot_fields_are_covered` over the new cell keys |
| An old save holding inventory chests | refused with "a save from an older build" (user, Q1), local and server mode alike: `RunSnapshot` restore rejects a top-level `"chests"` key; Continue shows the refusal and offers a new run (no players yet, dev saves only) | `test_floor_chests` |
| **Tampered log (acceptance scenario 5)** | a step that takes a chest pickup the replay never created, or claims a different hash after `open_chest`, is a Rejected step with **2002** (`ReplayMismatch`, reason from `StepMismatchReason`), never an HTTP error | `test_step_runner`: a tampered copy of the keyed run's chest step (a `take` with a forged placement) |
| A chest left behind | gone at `next_floor`; counted in `chestsLeft` / `chestItemsLeft` | `test_floor_chests` |

Scenarios 1-4, 6 and 7 are untouched (no settlement, cache, broker or ruleset routing change).

## 5. Observability

No new Prometheus metrics: `rpg_run_actions_total{type}` already labels `open_chest` and `take` (a fixed set; never chest or
item ids, CLAUDE.md cardinality rule). Analytics get `open_chest` offers with `Source: Chest` through the existing run action
log. Dev side: the play report's keys line adds "chest items left %d".

## 6. Test plan

Godot (`tools/godot_tests.sh`), on the fixtures (`fixture.chest.crate` free, `fixture.chest.strongbox` keyed) in the keyed
world `tests/game/keys_world.gd`:

- **`test_floor_chests`** (new): a room-clear drop lands in that cell, not an inventory; `ChestFound`; open in the room
  (key paid, log entry with `cell`, `opened`), its item and armor become pickups with `chest`, its coins/keys/heal are given
  at once; take one, leave one, leave the room and come back: still there;
  `Run.Chest.Double` fills one chest with both rolls; a chest from a chest appears closed in the room; the golden key and
  `Run.Chest.NoKey` open for free; every refusal from section 4; same contents opened early or late; `next_floor` drops
  them and `chestsLeft` / `chestItemsLeft` count them; a `GiveChest` from an item hook lands in the current room.
- **Updated:** `test_keys_and_gear` (inventory tests become room tests), `test_event_items` (a chest no longer queues a
  CHOOSE gift), `test_explore_hud` (the pickup panel's chest rows, OPEN, header and items; the Use Item screen has no chest
  section), `test_dev_console` (`chests`, `open`, `chest`, `state`), `test_cube_props` (the room view draws a room's chest
  closed, then open and empty with its pickups on free tiles beside it, none on a placement or door lane; the pop-out tween
  ends with each pickup on its tile; a room entered later places them at once), the chaos cases.
- **Map tint:** `test_explore_hud` / map tests: `MapCells` `leftover` is true for a room with a closed chest, with an untaken
  chest item, with an untaken free pedestal; false for a shop with stock, an emptied room, an unvisited room; the three maps
  use `leftover_color`.
- **Run authority:** `test_run_authority` snapshot round trip and resume equivalence over the re-recorded keyed run
  (now with an open, half-emptied chest); `test_snapshot_fields_are_covered` changes every leaf of a cell's `chests` and a
  pickup's `chest`.
- **Verification:** `test_step_runner` verifies the re-recorded keyed run step by step and rejects a tampered chest step
  with 2002; `RunWire.to_wire` golden for `open_chest` with `cell` and `offers`.
- **Goldens re-recorded:** `golden/game/run_keyed.json` (and any seed-report golden whose run drops a chest); the combat
  goldens are untouched.
- **Validator:** `give_chest_outside_room`, `chest_recipient_ignored`, on `tests/broken_fixtures/`.
- **Old saves:** a snapshot with a top-level `"chests"` is refused by restore, and Continue reports it.

.NET (`tools/dotnet_test.sh`): `Rpg.Contracts.Tests` golden JSON for `OfferSource.Chest` and an `open_chest` action with
`cell` and offers; the existing run-action endpoint tests accept it (a `RunActionsTests` case uploading an `open_chest` with
Chest offers).

Balance: the smart 4-member gate (`balance_seeds.json`, `--compare` against the last report) once, to show the change of
who-gets-what (bots now take chest items like pedestals instead of as gifts) moves nothing beyond noise. Not a gate.

Playtest (the user): a live window (`dev_run --local` + hold) on The Descent with chest drops forced (`chest` cheat), to
judge the lid, the pop-out, the empty chest beside its items, the map tint and the panel.

## 7. Decisions (user, 2026-11-14, review)

- **Q1. Old saves** holding inventory chests: **refused** ("a save from an older build"), local and server mode.
- **Q2. A chest with no room** (a `GiveChest` in the rest event): **a validator error** `give_chest_outside_room`; it
  should never happen.
- **Q3. The rewards in 3D:** **they pop out of the chest onto the floor** as ordinary floor pickups; the open, empty chest
  stays beside them (D4). This replaces the roadmap's wording ("open and filled").
- **Q4. Analytics offers on `open_chest`** with `OfferSource.Chest`: **yes** (3.1).
- **Q5. The map:** **a room with a closed chest or a free untaken pickup is drawn in a different colour** (D5). Read here as
  free pickups only (chest items, pedestal items), not a shop's priced stock.

## 8. Out of scope

Other chest types (spiked, mimic, red, stone, mega; `keys-and-gear` out of scope), clicking the chest in 3D to open it (the
HUD panel and console do it, as with pedestals), a chest sound (5e `audio-pass`), new chest content.

Spec updates at `/sync-spec`: `keys-and-gear` 2.3 and D9 (inventory, Use Item screen), `event-items` D5 (chest gifts),
`cube-style` (Set K's "ready for 5a5").
