# Spec: keys-and-gear (slice 1f2)

Status: ✅ Done 2026-10-27 (synced to the build; the follow-ups at the end of 6 are done) · all decisions approved
2026-10-27 (section 7; D4 deferred, D11 widened to every bot) · Date: 2026-10-27 ·
Roadmap: slice 1f2, after 1f `ff7-ui` (done) and before 2 `run-checkout`.
Builds on `specs/ff7-ui.md` (the screens, map icons, toasts and follow-ups in its section 6), `specs/game-skeleton.md`
(run state, run log, `RunSeeds` streams, outcomes and conditions), `specs/item-pass.md` 3.5 (armor inventory,
`equip`/`unequip`), `specs/playable-demo.md` (rarity weights, the play report and its smart 4-member gate),
`specs/auto-battle.md` (`Ability.Role.*` and the role pass this slice copies).

## 1. Purpose & enterprise mapping
The run rules the 1f screens already expect:
- **Keys:** a second run currency, as in The Binding of Isaac.
  - **Drops:** a room cleared after a battle drops a key on Isaac's room-clear chance. About 2% of key drops are a
    **golden key**: every locked room and chest on the floor opens for free until the stairs.
  - **Locks:** item rooms (`Room.Type.Treasure`) and shops are locked, except on the first floor (Isaac's Basement I
    rule; D3). Entering one spends a key. Without one, entry is refused with a "Locked" toast.
  - **Items:** add keys, double the keys you find, and open chests without a key.
  - **Shown:** "Keys: n" under Gold, and the lock icon on the map until a room is opened.
- **Chests (new, Isaac-style):** a cleared room can also drop a chest. Chests are a **drop**, not an event: one goes
  into the party's chest inventory and is opened from the menu whenever the player likes.
  - **Wooden Chest:** free to open.
  - **Gilded Chest:** costs a key.
  - **Contents:** a weighted table, mostly armor and weapons from the gear pool, plus coins, keys and heals. Each
    table is content (D6).
- **Gear:**
  - **New pieces:** more weapons and accessories (proposal in D8). The Weapon and Accessory slots are already in The
    Descent's `equipment_slots`, and the Equipment and Armor screens already show them (1f 2.8).
  - **One logged swap:** a gear swap between two characters becomes one action that is checked before anything
    changes. It replaces 1f's unequip → equip → equip chain and closes the "gear swap pre-check" follow-up.
  - **Moving use items:** a new logged action moves or swaps a use item between characters' Item Slots.
- **Usage tags:**
  - **Tags:** `Ability.Usage.Field` and `Ability.Usage.Battle` on abilities and use items. The labels read
    [Field Only], [Battles Only] or [Field and Battles].
  - **Enforced:** a Field-only ability is refused in battle, and a Battle-only one on the map.
  - **Checked:** the validator checks the tags, and a proposal pass drafts them for your content.
- **Room reveal:** an item that shows the event rooms' icons on every floor, like Isaac's mapping items (D10).
- **Events can cost keys and HP,** as they already cost coins: new conditions and outcomes (D7).

**Enterprise mapping:** none yet. This is client-only: run rules in `game/` on top of GAS. No service, queue, broker,
cache or wire contract is touched. What it changes for the distributed system later:
- **Run log (from 2b):** the new log entries (3.4) become ordered, idempotent quick messages, and keys and chests
  become part of the claimed run state.
- **Run verifier (4a):** keys, golden keys and chests replay deterministically from `RunSeeds` streams, so the
  verifier reproduces them like every other run rule.
- **Not yet:** keys are never a reward that leaves the run, so nothing is settled.

**Altars are left for a later slice (D4).** The Void's three `Room.Type.Altar` rooms (playable-demo 3.8) stay exactly
as they are: open, with corrupted items paid for in Void Scars. No lock, no key cost, and no altar content changes
here. `content/demo/floor_rules/void.tres` keeps `locked_room_tags` empty.

Out of scope:
- **Isaac pickups with no counterpart here:** bombs, cards, pills and trinkets.
- **Other chest types:** spiked, mimic, red, stone and mega chests.
- **Isaac's luck stat.**
- **Moving passive items between characters:** only use items move.
- **Server work:** anything slice 2b does with these actions.

## 2. Sequence flow
Client only. Every change goes through a `RunController` method, is checked first, then logged, then applied
(game-skeleton rule). Randomness comes only from `RunSeeds` streams, never from the battle RNG.

### 2.1 Room clear → key and chest drops
```
_clear_room(cell, after_battle = true), not the boss room (D2):
  coins       as today (ScalingRules, stream floor/<n>/drop/<cell>), unchanged
  key roll    stream floor/<n>/key/<cell>:  roll(key_drop_chance)            Isaac: 20%
              hit → roll(golden_key_chance)                                    Isaac: ~2% of key drops
                    golden → state.golden_key = true, toast "You found a golden key!"
                    normal → add_keys(1 × key multiplier), toast "You found a key!"  (Twin Fob: 2, "a key ring")
  chest roll  stream floor/<n>/chest/<cell>: roll(chest_drop_chance)          Isaac: 5%
              hit → weighted pick from RunStructure.chest_drops (Wooden / Gilded, D5)
                    → state.chests.append({"chest": id, "serial": state.chest_serial++})
                    toast "You found a Wooden Chest!"
  on_room_cleared item hooks as today (after the drops)
no drop → no toast
```
Streams are per cell, so a drop never depends on the order of rooms. The tuning values live in content (3.3), and
the code defaults are all 0. The fixture runs therefore never drop keys or chests, and their goldens stay as they
are.

### 2.2 Entering a locked room
```
locked(cell) = cell's special_tag ∈ chapter.floor_gen_rules.locked_room_tags
               and the run uses keys (RunStructure.uses_keys(): key or chest drops, or starting keys; the one-floor
                   run shares the Cellar's rules and never locks)
               and floor_index ≥ RunStructure.unlocked_floors (Isaac: floor 1 open, D3)
               and not cell["opened"] and not visited, and never in a sandbox
can_enter(cell)  unchanged (Isaac adjacency); a locked cell is still "enterable" — the key is checked in enter_room
enter_room(cell):
  locked and no golden key and keys = 0 → refused "Locked: you need a key" (warning toast, nothing logged)
  locked → golden key ? free : keys −= 1;  cell["opened"] = true
  log {"type": "enter_room", "floor", "cell", "unlock": "key" | "golden"}   ("unlock" only when it opened a lock)
  plays the room as today
map_cell / big map: MapCells sets kind "lock" (and "locked": true) while RunController.room_locked(cell) (read-only),
  so the existing lock icon, LOCKED name and "Locked (needs a key)" text show with no change to the map files
next_floor → golden_key = false (Isaac: the golden key lasts one floor); keys and chests carry over
```

### 2.3 Opening a chest (any time on the map)
```
Use Item screen lists chests first (D9): "Wooden Chest · OPEN" / "Gilded Chest · OPEN · 1 KEY" (OPEN when free:
  golden key or Run.Chest.NoKey); hover: CHEST, its description and, when it can't open, why; refused → refuse line
open_chest(index):
  refused when: in a battle or event, no such chest, a Gilded Chest with no key, no golden key and no Lockpick tag
  log {"type": "open_chest", "floor", "chest": id, "serial": n}
  pay: golden key or Run.Chest.NoKey ? free : keys −= 1                        (Gilded only)
  stream "chest/<serial>" (run-wide: the same chest gives the same contents on any floor, at any time)
  rolls = 1, or 2 with Run.Chest.Double (Warden's Key, Isaac's Mom's Key)
  each roll: weighted pick of a ChestReward, then its outcomes in order (RunOutcome: GiveEquipment with a query,
             GainCoins, GainKeys, ApplyPartyEffect, GiveItem, GiveChest)
  remove the chest; Message.Run.ChestOpened; each gift sends its usual message (ItemTaken-style toast for gear)
```
Gear from a chest goes into the armor inventory, as all armor does (playable-demo D9). "For your active party
members" is D6.

### 2.4 Gear swap (one action)
```
gear screen SWAP (the piece is worn by another member B, the screen is on member A, slot tag T):
  swap_gear(A, piece):
    checks, nothing changed yet: A exists and doesn't already wear piece; B = the first other member wearing piece in T
    (starting loadouts can give several members the same piece, e.g. each class's Iron Sword); not in a battle
    log {"type": "swap_gear", "floor", "slot": A, "from": B, "equipment": piece}
    A's piece in T (if any) → B's T;  piece → A's T     (nothing passes through the bag)
EQUIP (from the bag) and TAKE OFF stay equip / unequip, unchanged
```

### 2.5 Moving use items (one action)
```
gear screen, Item Slot column, an entry held by member B, the screen on member A:
  MOVE HERE (A has a free use slot) / SWAP (A's selected Item Slot holds item X):
  move_item(B, item, A, X = &""):
    checks, nothing changed yet: B holds item in a use slot; A ≠ B; X empty → A has a free use slot; X set → A holds X;
    after the move both capacities still fit (an item with extra_use_slots changes capacity); not in a battle
    log {"type": "move_item", "floor", "slot": B, "item": item, "to": A, "swap": X or null}
    item → A (its cooldown travels with it); X → B
dead members can give and receive (like equip); the 1f greyed text goes away
```

### 2.6 Usage tags
```
BattleAbility.usage(): Field and/or Battle from asset_tags Ability.Usage.Field / Ability.Usage.Battle;
                       neither tag → today's rule (no enemy target and the query allows State.Infield → both,
                       else Battle) so fixtures and untagged content keep working (validator warns)
enforced once, in CombatASC.can_activate_ability (only for tagged abilities): Field-only needs State.Infield,
                   Battle-only needs it absent. Every caller (turn actions, ult windows, enemy brains, Auto, field mode)
                   goes through it.
refused in battle: a Field-only ability is never a legal action; a logged one is IllegalAbility → 2002 in replay
refused on the map: Battle-only abilities never appear in field_options() and Battle.perform refuses them (IllegalAbility)
AbilityHint.usage → [Field Only] | [Battles Only] | [Field and Battles] from usage(); the screens are unchanged
Auto / smart policy: read the same legality, so nothing extra
validator: usage_missing (warning), usage_mismatch (error: Field tag but the query forbids State.Infield, Battle tag
           but the query requires it, Field-only with an enemy target)
build_usage_pass.tscn: drafts tags (enemy target, an ult or forbids State.Infield → Battle; requires State.Infield
           → Field; else both) into a report; --write adds them as a text edit (as build_role_pass). Applied to all 62
           demo party abilities (2026-10-27), with Provoke, Anthem, Fortify, Fracture Field and Lingering Malady
           changed to Battle-only by hand (a taunt and turn-based buffs that do nothing on the map)
```

### 2.7 Room reveal
```
RevealRooms outcome (mode EVENTS | ALL) on the item's on_pickup and on_floor_start hooks
  EVENTS → state.reveal_events = true   (room_type_known: event icons show on shown rooms)
  ALL    → state.revealed = true        (the dev reveal's flag: the whole layout and every type)
_reset_floor clears reveal_events; the item's on_floor_start sets it again. View flags, not hashed (like revealed)
```

## 3. Data contracts
No C# change: `Rpg.Contracts` has no run DTOs yet (slice 2b adds them, and they will mirror 3.4). No RabbitMQ, Redpanda
or Redis. The contracts here are GDScript run state, content types and the run log.

### 3.1 Run state (`game/run_state.gd`)
| Field | Type | Hashed |
|---|---|---|
| `keys` | int, 0–99 (Isaac's cap) | `keys=n|golden=0/1|chests=id:serial,...|serial=n`, one line, only when any of them is non-zero |
| `golden_key` | bool, this floor only | in the line above |
| `chests` | Array of `{"chest": StringName, "serial": int}` | in the line above |
| `chest_serial` | int, next chest serial | in the line above |
| `reveal_events` | bool, this floor only | no (view flag, like `revealed`) |
| map cell `"opened"` | bool, only on opened locked cells | `|opened` appended to the cell line only when true |

Runs that never see a key or chest hash exactly as before.

### 3.2 System code
- **`RunController`:**
  - **Methods:** `add_keys`, `give_golden_key`, `give_chest`, `room_locked`, `open_chest`, `swap_gear`, `move_item`,
    `give_equipment_from`, `reveal_rooms`, `party_hp_at_least`, `chests()` (read-only list for the screen and bots:
    index, name, `needs_key`, `free`, `can_open`, `why`), and the cheats `dev_keys`, `dev_golden_key`, `dev_chest`.
  - **Changes:** `enter_room` gets the lock check; `_clear_room` gets the drops; `next_floor` drops the golden key;
    `field_options` and `field_catalog` use `usage()`.
- **`FloorGenRules`:** `locked_room_tags: Array[StringName]` (gas::tag, default empty).
- **`RunStructure`:**
  - **Key and chest fields:** `starting_keys`, `unlocked_floors`, and `key_drop_chance`, `golden_key_chance` and
    `chest_drop_chance` (typed %, stored ×100).
  - **Chest table:** `chest_drops: Array[ChestDrop]` (`chest`, `weight`).
  - **Helpers:** `uses_keys()` (any key or chest drop, or starting keys) and `MAX_KEYS` (99).
- **`ContentIndex.chests`:** chests are indexed by id like other content (`chest <id>`, `open_chest`).
- **New content types (`game/defs/`):**
  - **`ChestDefinition`:** `id`, `display_name`, `description`, `icon`, `needs_key`, `rewards: Array[ChestReward]`.
  - **`ChestReward`:** `weight`, `outcomes: Array[RunOutcome]`, `rolls_min` and `rolls_max` (repeat the outcomes;
    Isaac's "2–6 pickups").
  - **`ChestDrop`.**
- **Outcomes:**
  - **New:** `GainKeys(amount)`, `LoseKeys(amount)`, `GiveGoldenKey`, `GiveChest(chest)`, `RevealRooms(mode)`.
  - **`GiveEquipment` gains `query` and `prefer_open_slot`.** With no fixed piece, it picks from the equipment pool by
    query with rarity weights, never a piece the party holds or has seen. It uses the gift stream, as `GiveItem` does.
    D6 decides how `prefer_open_slot` works.
- **New conditions:** `KeysAtLeast(amount)`, `PartyHpAtLeast(percent)` (D7).
- **Run modifier tags** on `ItemDefinition.tags`, read by `RunController` from held items: `Run.Keys.Double`,
  `Run.Chest.Double`, `Run.Chest.NoKey`. New mechanics are tags plus content, never code per item.
- **Usage:**
  - **Ability:** `BattleAbility.usage()`, plus the legality hook in `combat/` that refuses abilities by usage.
  - **`AbilityHint`:** gets `USAGE_FIELD`.
- **Messages:** `GameplayMessages.RUN_KEY_FOUND` (`Message.Run.KeyFound`, data `{"amount", "golden"}`),
  `RUN_CHEST_FOUND`, `RUN_CHEST_OPENED`. Refused entry uses the existing warning toast path.
- **Tools:**
  - **Validator checks:** `usage_missing`, `usage_mismatch`, `bad_chest` (no rewards, or a weight ≤ 0),
    `locked_room_tag_bad` (a boss, start or normal room tag), `locked_room_tag_unknown` (not a special room tag),
    `run_modifier_unknown`, and `inline_effect`: a granted effect (item or equipment `grants`) must be its own `.tres`,
    because the state hash names active effects by file and a battle with an inline one can't replay (found when the
    new gear was first written with inline effects).
  - **Proposal pass:** `game/tools/build_usage_pass.tscn`.
- **Dev:**
  - **New console commands:** `keys <n>`, `goldkey`, `chest <id>` (cheats, logged with `dev_log`), `open <index>`
    (play), `swap <slot> <piece>`, `move <from> <item> <to> [swap]`.
  - **Bots (D11):** every bot can use keys and chests through the same `RunController` calls the screens use. The
    bots are `RunPlayer` under the auto, smart and chaos policies, the console's `autorun`, and `dev_run` scripts.
    - **Keys:** spend them on item rooms before shops.
    - **Chests:** open them at once (Gilded only with a key to spare).
    - **Gear:** wear found gear in empty slots.
    - **Chaos:** also tries illegal run actions (3.5).
  - **Read-only listings for headless play:** `chests` lists the chest inventory with indices, and `state` shows keys,
    the golden key and the chests, so Claude and scripts can see and open chests without the UI.

### 3.3 Your files (proposals; nothing changes without your OK)
- **Tags** (`godot_gas/tag_registry.tres`, through `sync_tags --add-missing`):
  - **Usage and messages:** `Ability.Usage.Field`, `Ability.Usage.Battle`, `Message.Run.KeyFound`,
    `Message.Run.ChestFound`, `Message.Run.ChestOpened`.
  - **Run modifiers and the chest pool:** `Run.Keys.Double`, `Run.Chest.Double`, `Run.Chest.NoKey`, `Pool.Chest`.
- **`content/demo/runs/descent.tres`:**
  - **Keys:** `starting_keys = 0`, `unlocked_floors = 1`, `key_drop_chance = 20`, `golden_key_chance = 2`.
  - **Chests:** `chest_drop_chance = 5`, `chest_drops = [Wooden 75, Gilded 25]` (D5).
- **`content/demo/floor_rules/`:** `locked_room_tags = [Room.Type.Treasure, Room.Type.Shop]` on `small.tres` (Cellar),
  `crypt.tres` and `forge.tres`. `vault.tres` stays open (its four Hoards and shop on the light route's last floor;
  your decision, 2026-10-27) and `void.tres` is not touched (altars are a later slice, D4).
- **New:** `content/demo/chests/wooden_chest.tres`, `gilded_chest.tres` (D6), plus the items and gear of D8–D10 (each
  piece's stat effect is its own file in `content/demo/effects/`, named like the piece).
- **`content/demo/rooms/shop.tres`:** one more shop slot selling a key for 5 coins (Isaac's price; D12).
- **`content/demo/equipment/iron_sword.tres`:** add `Pool.Treasure`/`Pool.Chest` so it can be found (D8).
- **`presentation/demo/ui/`:**
  - **`run_toasts.tres`:** rules on `Message.Run.KeyFound` ("You found a key!", "You found a golden key!"),
    `ChestFound` and `ChestOpened`.
  - **`explore_menu.gd` / `.tscn`:** a greyed `Keys` label under Gold, "Keys: n" (+ " + golden key" while one is
    held), shown on every run that uses keys (D13).
  - **`gear_screen.gd`:** SWAP calls `swap_gear`, and the Item Slot column gets MOVE HERE and SWAP through
    `move_item`.
  - **`use_screen.gd`:** lists the chests (D9).
  - **`pickup_panel.gd` / `pickup_row.gd`:** a key slot shows as a "Key" row with no "give to" picker (the panel
    skipped pickups it couldn't look up, so keys were not buyable without this).
  - **Map icons:** no change (MapCells reports the lock as a kind, 2.2).
- **Usage tags on every demo party ability and use item:** from the pass (2.6).

### 3.4 Run log entries (new; old entries unchanged, so old logs replay)
```
{"type": "enter_room", "floor", "cell", "unlock": "key" | "golden"}     # "unlock" only when a lock opened
{"type": "open_chest", "floor", "chest": "<id>", "serial": n}
{"type": "swap_gear",  "floor", "slot": A, "from": B, "equipment": "<piece>"}
{"type": "move_item",  "floor", "slot": B, "item": "<item>", "to": A, "swap": "<item>" | null}
```
Replay re-derives everything else (drops, contents, costs). A logged entry whose check fails on replay is a runner
mismatch, the same as any other refused run action today.

### 3.5 Bots and chests (D11)
Every bot reaches chests through `RunController.chests()` and `open_chest(index)`, the same calls the Use Item screen
makes. None of them goes through the UI.

| Bot | What it does with keys and chests |
|---|---|
| `RunPlayer`, auto and smart policies (play report, `autorun`) | Each step on the map, before moving on: open every Wooden Chest, then each Gilded Chest while a key is left over after the floor's unopened locked rooms (or with a golden key or `Run.Chest.NoKey`). Buys keys for sale like any affordable pickup. Locked rooms: it explores unlocked rooms as before and opens a lock it can afford (item rooms first, then shops) when its next pick would be the boss room or nothing else is left, so runs without keys play exactly as before. Found gear goes into an empty slot (the first living member with that slot empty, by slot order), never swapping. |
| `RunPlayer`, chaos policy | The smart moves above, plus, at `--illegal` percent of map steps (stream `dev/chaos/run`), one run action that should be refused (`RunPlayer.RUN_CASES`: `chest_no_key`, `chest_index`, `locked_no_key`, `swap_not_worn`, `swap_self`, `move_not_held`, `move_full`). Each refusal must leave the log and the run hash unchanged; if it doesn't, it is a `run_action_not_refused` violation (exit 3), like a battle invariant. The report's "illegal moves refused" counts these cases next to the battle ones. |
| Console and `dev_run` scripts | `chests` (list), `open <index>`, `keys <n>`, `goldkey` and `chest <id>`, the last three as logged cheats, plus `swap` and `move`. All work headless, with JSON output in `dev_run`. |

Policy choices draw only from the bots' own `dev/...` streams, never from the run's streams, so the same seed and the
same policy always play the same run. The play report counts keys and chests (section 5).

## 4. Failure modes
- **Atomic actions:**
  - **Checks first:** `enter_room` (locked), `open_chest`, `swap_gear` and `move_item` check everything first. A
    refusal changes nothing and logs nothing. Tests drive every refusal, and the run hash is unchanged after each.
  - **Swap pre-check closed:** this ends 1f's partial-swap case (the piece could end up in the bag).
- **Determinism:**
  - **Per-cell drop streams:** key and chest drops draw from their own per-cell streams, so room order cannot change
    them.
  - **Chest stream:** contents come from the chest's serial stream, so opening on another floor or later gives the
    same result.
  - **Battle RNG untouched:** no draw from the battle RNG, so battle goldens are unchanged.
- **Caps and edges:**
  - **Keys cap at 99.** A Skeleton Ring at 98 gives 99.
  - **Golden key on top of keys:** while it is held, a lock spends nothing and the key count stays.
  - **Stairs:** the golden key is gone after the stairs.
  - **Locked boss room:** the boss room is never locked (no `Room.Type.Boss` in `locked_room_tags`; the validator
    errors if it is), so a floor can always be finished.
  - **No keys:** a floor with locked rooms and no keys is still finishable, because only special dead ends lock.
- **Chests:**
  - **Empty pool:** a gear pick with nothing left gives the run's `fallback_item` instead, as item pools do.
  - **Double rolls:** a chest whose reward is `GiveChest` can chain. `Run.Chest.Double` rolls twice, but never
    re-rolls the new chest.
- **Usage:**
  - **Untagged content:** untagged abilities behave as today, so fixtures and system tests are unaffected.
  - **Legality only:** a mis-tagged demo ability is a validator error. In battle it is only refused, never a crash.
  - **Combat goldens unchanged:** they are on fixtures with no usage tags.
- **Goldens:** none changed. `run_scripted.json`, `seed_report.json` and `seed_report_play.json` run on the fixtures,
  whose run has no keys, and runs without keys hash as before. Floor, seed and combat goldens are unchanged too. A new
  golden, `golden/game/run_keyed.json` (`test_keyed_run_golden`), pins the keyed run played by `RunPlayer`: seed 7,
  won on floor 2, three locks opened with keys, a chest opened, found gear worn, and the key and chest counters.
- **Balance** (smart, 4 members, seeds 1–300; the report informs your tuning, no test asserts a rate):
  - **Before the slice:** 106/300 (35.33%).
  - **Today's content, bots wearing found gear (D11):** 94/300 (31.33%), 0 violations. Wearing armor makes the
    Collector, who mirrors the party's held items and armor, the main cause (75 Collector deaths against 67).
  - **With the slice and the usage tags (2026-10-27):** 100/300 (33.33%). Over the 300 runs: 1705 keys found, 703
    spent, 284 chests opened, 18 locked rooms left. 2 violations: two Collector battles hit the 1000-turn cap
    (`turn_limit`).
  - **Chaos** (48 seeds, 30% of decisions): 18 won, 0 violations, 0 errors; its first run found two bugs, now fixed
    (`swap_gear` with a piece two members wear; run violations missing the report's fields).
- **Root acceptance scenarios:** none apply, because this slice has no server. Scenario 5 (tampered log → 2002) later
  covers these entries through the run verifier (4a).

## 5. Observability
N/A for Prometheus: client-only, no service.
- **Dev visibility:**
  - **Console and `dev_run`:** `state` and `dev_run` JSON show keys, golden key and chests.
  - **Run summary** (only on runs that use keys): `keys`, `keysFound`, `keysSpent`, `chestsOpened`, `chestsLeft`,
    `lockedLeft` (locked rooms left unopened). The play report sums them under `"keys"` (`found`, `spent`,
    `chestsOpened`, `chestsLeft`, `lockedLeft`) and prints one line. Gear worn is not counted.
- **Later (2b/analytics):** `KeyFound`, `ChestOpened` and `RoomUnlocked` become run events through the outbox. Chest
  and item ids never become Prometheus labels.

## 6. Test plan
System tests run on fixtures, so `content/` can't fail them. Built: `tests/game/test_keys_and_gear.gd` (19 tests),
two console tests in `test_dev_console.gd`, and in `test_explore_hud.gd` the gear screen's swap and move, the Keys
line, the Use Item chest list, the pickup panel's key row and the key and chest toasts; 414 tests in all. The fixtures gain chests (crate, strongbox), crate gear (dagger, hood), the key items (key fob, warden key,
lockpick, dowsing) and a Field-only and a Battle-only tonic; the keyed run itself is built in memory over them
(`tests/game/keys_world.gd`), because a second run structure on disk would add a `"run"` field to every fixture
run's log.
- **Keys:**
  - **Drops:** the drop chance is honoured from its stream and repeats per seed. There are no drops with chance 0, and
    the fixture runs' hashes are unchanged.
  - **Golden key:** golden keys open locked rooms and Gilded chests for free and end at the stairs.
  - **Cap:** keys stop at 99.
  - **Item modifiers:** `Run.Keys.Double` doubles a found key, `Run.Chest.Double` rolls twice, and
    `Run.Chest.NoKey` opens a Gilded chest with 0 keys.
- **Locks:**
  - **Which rooms lock:** a locked treasure room or shop is refused with 0 keys (nothing logged, hash unchanged).
    Entering one spends one key and logs `unlock`, and re-entering costs nothing. Floors before `unlocked_floors` are
    open, and the boss room is never locked.
  - **Map:** `room_locked` drives the lock kind in `MapCells` (`test_locked_rooms`).
- **Chests:**
  - **Timing:** a chest drops and is kept across floors. Opening it on floor n or floor n+1 gives identical contents.
  - **Refusals:** each refusal case changes nothing.
  - **Contents:** `GiveEquipment` by query respects rarity weights and never repeats a seen piece; `prefer_open_slot`
    behaves as D6 decides.
- **Swaps:**
  - **`swap_gear`:** trades in one entry, works with and without a piece on A, and every refusal changes nothing.
  - **`move_item`:** moves to a free slot and swaps; a capacity overflow is refused, and the cooldown travels with
    the item.
- **Usage:**
  - **Refusals:** a Field-only fixture ability is not a legal battle action (`IllegalAbility`). A Battle-only one is
    missing from `field_options` and refused by `use_field`.
  - **Fallback and labels:** untagged abilities follow today's rule, and `AbilityHint` gives all three labels.
- **Validator:** each new check is driven by in-memory broken content (`bad_chest`, `locked_room_tag_bad`,
  `locked_room_tag_unknown`, `run_modifier_unknown`, `usage_mismatch`, `inline_effect`; `usage_missing` on the
  untagged fixtures); the broken validator fixtures' `refreshing_curse` is an expected `inline_effect`. The validator
  over `content/` reports 0 errors and 0 warnings after the usage pass.
- **Outcomes and conditions:** `GainKeys`, `LoseKeys` (never below 0), `KeysAtLeast` (a golden key doesn't count),
  `GiveGoldenKey`, `GiveChest` (and one without a chest) and `PartyHpAtLeast` (the dead don't count).
- **Messages and toasts:**
  - **When they fire:** `KeyFound`, `ChestFound` and `ChestOpened` fire, with no toast on a clear without a drop.
  - **Rules:** `run_toasts.tres` has a rule on each channel, and on the keyed run a cleared room shows "You found a
    key!" first, with the chest toast queued behind it (`test_run_toasts_cover_keys_and_chests`).
- **Screens:** the Keys line (hidden without keys, "Keys: 0", "+ golden key"), the Use Item chest list (OPEN, OPEN · 1
  KEY greyed with no key, pressing OPEN opens it) and the pickup panel's key row (no "give to" picker, Buy) in
  `test_explore_hud.gd`.
- **Room reveal:** `RevealRooms(EVENTS)` makes `room_type_known` true for event rooms on the current and next floors
  while the item is held.
- **Tool parity:** `test_tool_parity` reaches `keys`, `goldkey`, `chest`, `chests`, `open`, `swap` and `move`.
- **Bots (3.5):**
  - **Fixture run with chests:** on a fixture run with keys and chests, `RunPlayer` (smart) opens every Wooden Chest,
    opens Gilded ones only with a key to spare, opens locked item rooms before shops, and wears found gear in empty
    slots.
  - **Repeatable:** the same seed plays the same run twice.
  - **Chaos:** over seeds 3, 7 and 11 every illegal run action is refused cleanly. On a prepared run (a strongbox,
    no keys, a locked room in reach, a piece in the bag, two full item slots) every one of the seven `RUN_CASES`
    builds and is refused with the log and hash unchanged, and `try_illegal` tries all seven
    (`test_chaos_run_cases_all_build`). An injected bug (a `LeakyRun` whose refusal leaks a
    coin) is caught as a violation with the report's fields.
  - **`dev_run`:** a script opens a chest headless and reads the result from the JSON output.
- **Suites:**
  - **Both pass:** `tools/godot_tests.sh` and `tools/dotnet_test.sh` both pass. The C# side is unchanged; its golden
    cross-check still reads the same combat files.
  - **Play report:** the smart 4-member report runs once (`play_sharded.sh`), and its win rate is reported next to
    35.33% (section 4).

**Follow-ups (done 2026-10-27, at your request):** the keyed golden (moved here from 1f3), the toast rule test, the
screen tests and the seven chaos cases above. Found on the way: `test_console_xp_bossdone_goto` changed the shared
fixture run's XP curve (`assign()` on a shallow duplicate), which failed a later test in the same shard; fixed.

## 7. Decisions (all approved by the user, 2026-10-27, as recommended; D4 deferred, D11 widened)
Isaac numbers come from the community wikis ([Room Clear Awards](https://bindingofisaacrebirth.wiki.gg/wiki/Room_Clear_Awards),
[Keys](https://bindingofisaacrebirth.wiki.gg/wiki/Keys), [Golden Key](https://bindingofisaacrebirth.wiki.gg/wiki/Golden_Key),
[Chests](https://bindingofisaac.fandom.com/wiki/Chests), [Mom's Key](https://bindingofisaacrebirth.wiki.gg/wiki/Mom%27s_Key)).
Where a number is my guess, it says so.

**D1 Key drop.**
- **Isaac's numbers:**
  - **Room clear table:** 22% nothing, 15% coin, 15% heart, 20% key, 15% bomb, 5% chest, 8% card/pill/trinket.
  - **Key variants:** 96% normal, ~2% golden, ~2% charged.
- **Recommended:** roll keys and chests on their own (20% key, 5% chest). Keep today's coin drop as it is, and drop
  the shares we have no pickup for. A key is golden 2% of the time; Isaac's charged key counts as a normal one.
  - **Why:** each chance stays exactly Isaac's, and the coin economy (and balance) doesn't move.
- **Alternative:** one Isaac table that replaces the coin roll (coins 15%). It is truer to Isaac, but it changes
  today's 50–80% coin drops.

**D2 Which clears roll.** Recommended: rooms cleared after a battle, except the boss room. In Isaac, boss rooms give
the boss item instead, and empty rooms give no clear award. Event battles count.

**D3 Locks.**
- **Recommended:** item rooms and shops are locked from floor 2 on; floor 1 is open (`unlocked_floors = 1`).
- **Why:** this is my reading of Isaac's Basement I. I'm sure of it for the treasure room; for the shop, please
  confirm it matches your memory.
- **Starting keys:** 0, as Isaac's own character has (Cain starts with 1).

**D4 Altars: left for a later slice** (user, 2026-10-27). The Void's Altar rooms stay as they are today: open,
with corrupted items paid for in Void Scars. In effect they are the item rooms of the dark route's last floor, and
they are good as they are for now. Whether they lock or take keys is decided in that later slice.

**D5 Chest drop variant.**
- **Recommended:** 75% Wooden (free) and 25% Gilded (one key).
- **Why it's a guess:** I found no Isaac source for the brown versus locked share of room-clear chests.

**D6 Chest contents ("armor or weapons for your active party members").**
- **Wooden Chest (Isaac's brown chest, one roll):**
  - **Gear, 30%:** Common/Rare from `Pool.Chest`. This takes Isaac's bomb share.
  - **Other rewards:** coins 2–4 (35%), a party heal of 20% (20%), 1 key (15%).
- **Gilded Chest (Isaac's golden chest):**
  - **Gear, 20%:** any rarity. This is Isaac's item share.
  - **Pickups, 58%:** 2–4 Wooden rolls.
  - **Use item, 10%:** from `Pool.Treasure` (Isaac's card share).
  - **Passive item, 10%:** from `Pool.Treasure` (Isaac's trinket share).
  - **Chests:** Wooden 1%, Gilded 1%.
- **As built:** the tables live in `content/demo/chests/wooden_chest.tres` and `gilded_chest.tres` (your values). The
  Gilded table differs from the proposal in three places: the use item and passive shares are one 20% item from
  `Pool.Treasure` (no tag tells use items from passives), its 1% Gilded and 1% Wooden are one 2% Wooden (a chest can't
  hold itself), and the 58% pickups are split into coins, keys and a heal (a reward can't roll another chest's table).
- **"For your active party members" (recommended):** the gear pick prefers a slot that a living member has empty, then
  any slot, and the piece goes to the bag. Nothing is worn on its own (D9 of playable-demo).
- **Alternative:** one piece per living member. That is generous, so the tables would need retuning.

**D7 Events paying keys and HP.**
- **Keys:** `KeysAtLeast` and `LoseKeys`, as for coins.
- **HP (recommended):** `PartyHpAtLeast(percent)` gates the choice, and an `ApplyPartyEffect` with a damage effect
  pays. The damage effect is your content, as today. The whole party pays, like Isaac's blood donation on one
  character.
- **Alternative:** the lowest-HP or first living member pays alone. That needs a "who pays" field.

**D8 New gear** (Isaac-style original names; existing stats only). Numbers are starting points for you to tune.

*Weapons:*

| Name | Rarity | Effect | Price |
|---|---|---|---|
| Hunting Knife | Common | +40 ATK, +5 SPD | 6 |
| War Axe | Common | +90 ATK, −5 SPD | 6 |
| Keen Rapier | Rare | +40 ATK, +10% crit rate | 8 |
| Breaker Maul | Rare | +50 ATK, +50% toughness damage | 8 |
| Runed Staff | Rare | +30 ATK, +60 max MP, +15% healing | 8 |
| Hexfang Dagger | Epic | +50 ATK, +30% weakness damage | 10 |
| Headsman's Blade | Epic | +60 ATK, +40% damage to Broken | 10 |
| Sunforged Brand | Legendary | +80 ATK, +20% crit damage, +10% DEF ignored | 12 |

*Accessories:*

| Name | Rarity | Effect | Price |
|---|---|---|---|
| Iron Charm | Common | +80 max HP | 5 |
| Mana Locket | Common | +40 max MP, +10% ult charge gain | 5 |
| Quickstep Anklet | Rare | +8 SPD | 8 |
| Warding Talisman | Rare | −10% damage taken | 8 |

- **Pools:** all are tagged `Pool.Treasure`, `Pool.Shop` and `Pool.Chest`; Epic and Legendary drop `Pool.Shop`.
- **Iron Sword:** add `Pool.Treasure`/`Pool.Chest` to it (a change to an existing file).

**D9 Where chests open.** Recommended: at the top of the Use Item screen ("OPEN", no target pick). It reuses the
screen and its list, and keeps the menu at five entries. The alternative is a sixth menu entry, "Chests".

**D10 Key items and the room reveal** (passive items; the mechanics are tags and outcomes, never code per item):

| Name | Inspired by | Effect | Rarity, pools |
|---|---|---|---|
| Skeleton Ring | Skeleton Key | On pickup: 99 keys | Legendary, Treasure |
| Warden's Key | Mom's Key | On pickup: +2 keys; chests roll their contents twice (`Run.Chest.Double`) | Rare, Treasure + Shop |
| Twin Fob | Humbling Bundle (my recollection) | Every key you find counts twice, a key ring (`Run.Keys.Double`) | Epic, Treasure |
| Lockpick | Paper Clip (my recollection) | Gilded Chests open without a key (`Run.Chest.NoKey`) | Rare, Treasure + Shop |
| Dowsing Rod | The Compass | Every floor: event rooms show their icon (`RevealRooms EVENTS`) | Rare, Treasure + Shop |

- **Optional:** "Surveyor's Map" (Treasure Map: `RevealRooms ALL`, the whole layout), if you want a second mapping
  item.
- **Skeleton Ring at 99:** this is Isaac-faithful and trivialises locks for the rest of the run. Alternative: +5.

**D11 Bots and the play-report policy** (approved and widened, 2026-10-27: every bot must be able to use chests;
details in 3.5).
- **Approved:** the smart and auto runner spends keys on item rooms before shops and opens chests at once (Gilded
  ones only when a key is left after the floor's locked rooms).
- **Chaos:** the policy also tries illegal chest, lock and swap actions and checks that each is refused cleanly.
- **Console and `dev_run`:** they list and open chests headless.
- **Found gear (recommended):** it **wears found gear in an empty slot** (first living member by slot), never
  swapping.
- **Why:** today the report never wears found armor, so chests would not register in the gate. Wearing gear moves the
  gate number by itself, and I'll report it separately from the lock effect (one report with gear wearing on today's
  rules first).

**D12 Keys in the shop.** Recommended: one shop slot sells a key for 5 coins (Isaac's price). It needs a small
`RoomPlacement.keys` field (a slot that sells N keys instead of an item), plus your OK to add the slot to `shop.tres`.

**D13 "Keys: n" visibility.** Recommended: shown under Gold, greyed, whenever the run uses keys (a run structure
with key drops or starting keys), "Keys: 0" included, as Isaac's HUD always shows the counter. Runs without keys
(fixtures, the one-floor run) hide it.
