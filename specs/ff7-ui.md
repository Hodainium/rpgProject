# Spec: ff7-ui (slice 1f)

Status: ✅ Done 2026-10-27 (synced to the build; remaining work in 6) · all decisions approved 2026-10-27 ·
Roadmap: slice 1f, after 1e `auto-battle`; 1f2 `keys-and-gear` follows it · Date: 2026-10-27
Builds on `specs/ui-framework.md` (policy, slots, entries, theme), `specs/gameplay-messages.md` (the message bus),
`specs/ult-interrupts.md` (ult presses at any time), `specs/auto-battle.md` (Auto, `Ability.Role.*`).
Approved sample: https://claude.ai/artifact/TacH8V7tg6E1FsHzTFR7aN (Battle, Exploration v3, Equipment, Armor,
Status).

## 1. Purpose & enterprise mapping
The game gets an FF7 look, an FF7-style battle screen and a new exploration HUD:
- **One shared window theme.** Every window is a blue vertical gradient with a light border and a darker inner ring.
  Text is white with a black shadow. All of it lives in the theme, so **every UI element made later looks like this
  with no per-scene work**, and every existing screen is restyled through the same theme.
- **Battle layout:**
  - **Party window, bottom left:** one row per member with the active pointer, name, statuses, HP and MP (number and
    bar), an ult bar with its percentage that pulses at 100%, and a **ULT** button that works at any time.
  - **Command window, bottom right:** Attack, Ability, Block, Item. Ability, Item and a two-ult chooser open a list
    in the same window, with Back.
  - **Top window:** with HINT on and a list open, the hovered entry's name, cost, description and target type.
    Otherwise it shows the target prompt.
  - **Battle feed, top left:** one-line toasts for what happens ("Warrior used Ice Blast", "Critical hit!", "Warrior
    did 212 damage to Golem", "Golem is broken!", "Cleric is down!"). They stack, fade after 3 seconds, and at most
    four show at once.
  - **Turn order, top right**, as in Honkai: Star Rail. The acting unit is a larger card marked NOW, followed by the
    upcoming units and their action values. Queued ults sit at the front.
- **Exploration layout:**
  - **No fixed banner.** Short Isaac-style **toasts** at the top centre: an item picked up, or the chapter and floor
    on entering a floor. Holding **Tab** keeps the floor toast up.
  - **Party strip, bottom left:** the same rows as in battle, without the ULT button.
  - **Menu, bottom right:** Equipment, Armor, Use Item, Use Ability and Status, then **Gold** greyed out. **Keys**
    joins it in 1f2.
  - **Map, top right**, as today. The turn order takes that spot only during battles.
- **Four menu screens on one shared layout:**
  - **Description window** at the top.
  - **List of what fits the hovered or selected slot** below it.
  - **Characters** at the bottom.
  - **Middle menu** for the action (Equip, Swap, Take off).
  - **Equipment** has the **Weapon** and **Item Slot** columns. **Armor** has **Head, Body, Arms, Legs** and
    **Accessory**.
  - **Status** has **Info, Held Items** and **Status** tabs on the left, with details to the right.
- **Use Item:** pick an item, then a party member.
- **Use Ability:** pick a party member, then the ability, then a target if needed.
- **A toast system in the Lyra style:** one host panel plus a rules file you edit. A new toast is a rule, not code.

**Enterprise mapping: none.** This is client-only presentation, so no service, queue, broker, cache or wire contract
is involved. Run rules don't change in 1f: every action the new screens take is an existing logged `RunController`
action. Combat, run hashes and replays are unchanged (section 4). The Block ability (F3) is content and travels as an
ordinary logged action. The new mechanics (keys, single-action swaps, moving use items, Field/Battle tags) are 1f2
`keys-and-gear`.

Out of scope: gamepad and keyboard focus beyond what Godot gives buttons by default, screen transition animations,
new unit art, localisation, and everything listed for 1f2.

## 2. Sequence flow
Client only; no server.

### 2.1 Theme (all screens)
```
UIPolicy.theme (ui_theme.tres) → UIManager sets it on the layout root (unchanged mechanism)
  PanelContainer/styles/panel      = UIWindowStyle (gradient #3a4fb8 → #1b2577 → #121a5a, border #d8dbe6 2 px,
                                     inner ring #4b5276 2 px, radius 7, drop shadow)
  Label / Button / CheckBox / OptionButton fonts = the window font (F2), white, shadow or outline black 1 px
  Button styles normal/hover/pressed/disabled/focus = transparent / white 14% / white 22% / transparent, dim text
  ProgressBar variations HpBar, MpBar, UltBar (fills: #6fd1ff→#e8f7ff, #8be38f, #b0238f→#ff7ad9)
  type variations: the list lives in ui_theme.tres (WindowPanel, not Window: Window is a Godot class name; Hint,
                   Toast, FeedLine, TurnCard*, UltButton*, CommandButton/CommandText, ListEntry, SlotButton*,
                   MemberRow*, RowName*, MapTile*, LegendTile, Toggle*, StatusChip, EquippedMark, Feed*, Gold,
                   Greyed, Caption…); colours and sizes are tuned there
any new screen built from PanelContainer / Label / Button already has the look; nothing else to do
```

### 2.2 Toasts (Lyra's accolade host, on our message bus)
```
UIToastHost (UIScreen, in a slot; your scene) owns a UIToastSet (your .tres):
  rules: Array[UIToastRule]  { channel: Message.* tag, match EXACT|PARTIAL, verbs (empty: any),
                               require_tags / ignore_tags (the message's tags, e.g. Hit.Critical, Ability.Type.Ultimate),
                               kicker/title/subtitle formats: {instigator} {target} {amount} (magnitude ÷ 100) {count}
                               {verb} {text} and the message data keys (UIToastRule.KNOWN_FIELDS); unknown = empty,
                               seconds, sound (played through the sound board when shown), colour variation,
                               priority, hold_action }
  max_visible (top toast host 1, battle feed 4), stack: QUEUE (one after another) or STACK (lines pile up, oldest out),
  max_queued (QUEUE; lowest priority dropped first), clear_on (channels that empty the host),
  entry_scene (the toast or feed line scene; set_item(toast, ctx), optional leave() to fade out)
receive(channel, message): hands the host a message sent before it existed (the run's first floor)
host.bind → GameplayMessages.listen(rule.channel, …) per rule → message arrives → each matching rule makes a toast
  QUEUE: waits its turn; STACK: appended, the oldest leaves past max_visible; each fades after its seconds (real
  time, so battle speed never shortens it)
hold toasts: a rule with hold_action (input action) shows while the action is held (Tab → the floor toast), using
  the latest message on its channel (the floor entered)
```
Two hosts in the demo policy:
| Host | Slot | Active | Rules (your set) |
|---|---|---|---|
| `run_toasts` (replaced `floor_card`) | `UI.Slot.Hud.Toast` (top centre) | `UI.State.Run` | `run_toasts.tres`: `Message.Run.ItemTaken`, `Message.Run.FloorEntered` (also the Tab hold), `Message.Run.LevelUp`; 1f2 adds `Message.Run.KeyFound` as one more rule. The texts live in the file |
| `battle_feed` (replaced `battle_callouts`) | `UI.Slot.Hud.Feed` (top left) | `UI.State.Run.Battle` | `battle_feed.tres`: AbilityUsed (ults ignored, left to Interrupt), Damage with `Hit.Critical` then every Damage, Broken, Downed, UnitDied, Interrupt, OneMore, Phase, Resisted, TurnSkipped; clears on `Message.Battle.Started`. The texts live in the file |

Message data added for toasts: `Message.Run.FloorEntered` carries `chapterName`; `Message.Run.ItemTaken` carries
`instigatorName` (the member), `rarity` and `description`. A pickup reads "Ranger got Hunter's Gloves!" with the item name in its
rarity colour: the rule's title marks it `[rarity={rarity}]{target}[/rarity]`, and the toast entry (a RichTextLabel
title, theme variation `ToastTitle`) colours it from the theme's `Rarity<X>` variation (an unknown rarity keeps the
normal colour).

`Message.Battle.AbilityUsed` is new: `BattleMessages` broadcasts it from a new presentation-only `Battle` signal
`ability_activated(unit_id, ability_tag, target_id)`, emitted in `Battle._activate` just before activation when the
ability can activate (so "X used Y" comes before the hits it causes); the message carries the ability's asset tags.
It has no effect on state or the hash (2.6 of `gameplay-messages`: combat never broadcasts; it only emits signals the
bridge reads).

### 2.3 Battle HUD (policy entries, state `UI.State.Run.Battle`)
```
hud.tscn gains slots: UI.Slot.Hud.Top (top centre), UI.Slot.Hud.Toast (top centre, above Top), UI.Slot.Hud.Feed
  (top left), UI.Slot.Hud.Bottom.Left, UI.Slot.Hud.Bottom.Right
policy (battle only):
  battle_party_panel   → Bottom.Left   rows = UIList of member_row (ULT button shown)
  command_panel        → Bottom.Right  pages: COMMANDS (a vertical list: Attack, Ability, Block, Item; the same
                                       list_window component as the other lists) | LIST (abilities, items, ults) | TARGET
  top_window           → Top           hint (HINT on and a LIST page open) or the target prompt
  turn_order_panel     → Right         replaces map_panel while in battle (map_panel's rule is already UI.State.Run.Map)
  battle_feed          → Feed          2.2
  battle_panel         → removed from the policy once the panels cover it (F7)
```

### 2.4 A party turn
```
recorder.action_requested(unit) → command_panel shows COMMANDS for unit; party panel moves the pointer
Attack  → the unit's ability tagged Ability.Type.Basic (F4) → TARGET page; field units become pickable;
          a TARGET pick (or the target buttons in the window) → recorder.submit_action(tag, target)
Ability → LIST of unit.action_abilities() minus Basic, Block and items; entry text = name, cost
Item    → LIST of unit.item_abilities (the existing use slots)
Block   → the unit's Block ability (F3) → submit_action(tag, "") at once
hover/focus a LIST entry → top_window shows its hint (if HINT on); pick → TARGET or submit
Back (button or Esc through UIScreen.handles_back) → previous page; UIManager.back() asks active HUD panels when no
  layer screen closes, so Esc reaches the command window
TARGET entries show the target's HP, toughness, BROKEN and weaknesses (what the old battle panel listed); party
  statuses, BROKEN, KNOCKED DOWN and DOWN are chips on the party rows
```

### 2.5 Ults
```
ULT on a member row (enabled when unit.asc.can_activate_ability(ult) and not already queued):
  one ult  → as today: target pick if needed (TARGET page), then recorder.submit_ult(...)
  two ults → command_panel LIST page "ULT · <name>" with both, then as above
queued presses: button shows QUEUED; turn_order_panel puts a gold card at the front; cleared on fire or refusal
```

### 2.6 Turn order and hints
```
turn_order_panel listens to Message.Battle (turn started, action done, delay/advance, unit died) and redraws from
  TurnManager.preview(count) → [{unit, av}]: a pure look-ahead on a copy of the AV table (same tie rule as
  next_actor, resets to full_av after each simulated turn); never touches the live table; count = export (default 7)
hints: BattleAbility.description (new @export_multiline) → top_window body; target text from BattleAbility.targeting
  (ONE ENEMY, ALL ENEMIES, ONE ALLY, ALL ALLIES, SELF); cost from the cost effect's MP modifier ("12 MP", "ULT 100%")
HINT toggle in command_panel → GameMain setting battle_hints (Settings screen too; default on, F8)
```

### 2.7 Exploration HUD (F6)
```
policy (UI.State.Run.Map):
  party_strip      → Bottom.Left    member_row entries (no ULT button)
  explore_menu     → Bottom.Right   Equipment, Armor, Use Item, Use Ability, Status (UIPushButtons, layer GameMenu)
                                    + "Gold: n" (Greyed); "Keys: n" appears when the run has keys (1f2)
  map_panel        → Right          unchanged
  run_toasts       → Toast          2.2 (always in a run, also over battles and events)
  pickup_panel, event_panel, stairs_panel keep their slots, restyled by the theme
  party_panel, field_panel, floor_card → removed from the policy (their jobs move to the screens below; F7-style
                                    deletion after you confirm)
```

### 2.8 Gear screens (Equipment and Armor: one screen, two configurations)
```
gear_screen.tscn (GameMenu layer) with export slot_columns: Array[GearColumn] { title, slot tag or USE_ITEMS }
  equipment.tres: [Weapon → Equipment.Slot.Weapon, Item Slot → USE_ITEMS 1, Item Slot 2 → USE_ITEMS 2]
  armor.tres:     [Head, Body, Arms, Legs, Accessory → Equipment.Slot.*]
layout: description window (top) · list window (below it) · character grid (bottom) · middle menu (modal)
hover a slot   → preview: the list shows what fits that slot (white border, "PREVIEW (CLICK TO SELECT)");
                 the description window shows the slot's piece. Leaving returns to the selected slot.
click a slot   → select it (gold border)
Item Slot 2    → a third column, shown only while at least one party member has two use slots (USE_ITEMS
                 columns take an index: Item Slot = 1, Item Slot 2 = 2, shown when any member's capacity ≥ index);
                 members with one use slot show LOCKED there (not selectable; hover explains how it unlocks)
list entries   → every piece that fits: worn ones marked E; hover → description + "Equipped by: X" or "In the bag"
click an entry → middle menu: EQUIP (from the bag), SWAP (worn by another character), TAKE OFF (worn here), CANCEL
EQUIP          → RunController.equip(slot, piece)                          (existing, logged; the old piece → bag)
TAKE OFF       → RunController.unequip(slot, tag)                          (existing, logged)
SWAP (armor, weapon) in 1f → three existing logged actions in order (F11):
                 unequip(other, tag) → equip(me, piece) → equip(other, my old piece) if I had one
                 1f2 replaces them with one logged swap action
Item Slot list → the party's use items (marked E, with "Equipped by"); SWAP / EQUIP disabled with
                 "Moving items arrives with keys-and-gear" until 1f2 adds the logged move (F12)
```

### 2.9 Use Item and Use Ability
```
Use Item (screen, GameMenu): the party strip stays at the bottom; description window + list above it
  list = RunController.field_options() entries with an "item", plus the party's use items that aren't usable now
  label: [Field and Battles] when usable on the map, [Battles Only] otherwise (greyed) — today's rule (no enemy
  target); 1f2 replaces it with the Ability.Usage.* tags and adds [Field Only]
  pick an item → party rows become pickable (gold outline) → RunController.use_field(holder, ability, target_slot)
  ALL_* items apply at once; the result is a message-line notification ("Ether · used on Arcanist")
  the lists come from RunController.field_catalog() (every action ability and use item, with "usable" and targets)
Use Ability: pick a party member first (rows pickable) → list of that member's field_options() abilities plus the
  rest (greyed, [Battles Only]) → pick → target member if SINGLE_* → use_field(member, ability, target)
Back (top left, as on every menu screen) steps back one stage (target → list → member → map); while the screen is
open the map and other overlapping HUD panels are hidden
```

### 2.10 Status screen
```
status_screen.tscn (GameMenu): party strip at the bottom (click selects, hover previews a member)
  tabs top left (vertical): Info, Held Items, Status (click selects, hover previews); details window to the right
  Info       → CharacterDefinition.description + the kit: each ability's name and BASIC / ABILITY / ULT / PASSIVE
  Held Items → the member's passive items (member["items"]); hover → name, rarity, description
  Status     → HP, MP, XP, ult charge, then the stats (ATK, DEF, SPD, crit rate, crit damage, weakness damage,
               break power, healing, DEF ignored, debuff turns): current value and the bonus over the class base
               at this level, from RunController.member_stats(slot) (F13)
```

### 2.11 Map: minimap, Tab view, big map (F16)
```
room cells (one map_cell entry for all three views; icons are SVG files in presentation/demo/ui/icons/map/,
  white with a black drop shadow, tinted by the theme):
  shown rooms   = visited rooms and the rooms touching them; nothing else
  tile          = your room: gold tile, white border, NO icon · visited: navy · unexplored: darker navy, no "?"
  icons only for room types: item = gift box, shop = "$", boss = skull, event = "!", locked = lock (1f2)
  the start room has no mark (after you leave it, it is a plain visited room)
  item, shop and boss icons show on unexplored rooms too (their doors give them away, as in Isaac); an EVENT icon
  shows only once the room is visited, unless the run reveals room types (MapReveal, below)
  MapReveal: map_cell asks RunController.room_type_known(index) (new, read-only): visited, or kind ≠ event, or
  state.revealed (today's dev `reveal` cheat). A room-reveal item (Isaac's mapping items) is 1f2 content: an item
  effect that sets the same flag, so the map needs no change
minimap (map_panel, Right, UI.State.Run.Map): view only; its cells no longer move the party. Clicking it pushes
  big_map.
Tab held (input show_floor_info) → the minimap grows in place (cell size × 2, title "MAP · <chapter> · FLOOR n");
  while Tab is held the floor toast is centred horizontally in the free space to the left of the grown map (the
  run toast host reads the map panel's left edge), so the two never overlap; release → back to normal. No legend
  here. View only.
big_map (screen on menu_frame: Back top left, description window at the top, the map as the content; the party
  strip and the bottom menu are hidden while it is open):
  the whole floor grid in a viewport larger than the screen: drag or mouse wheel pans it, RECENTER centres the
  current room; opening it centres the current room
  each room: its icon and its name under it (ITEM, SHOP, BOSS, EVENT, LOCKED; plain rooms unnamed)
  hover a room → description: kind (an unrevealed event room reads "Room"), VISITED / UNEXPLORED, "Click to
  travel here" or "You are here"
  HELP (next to RECENTER) → the map legend: a modal in the centre of the screen over a dark overlay that covers
  everything else; it lists only the room-type icons (item, shop, boss, event, locked) and one line on the tiles;
  CLOSE, a click on the overlay or Back closes it. Only the big map has HELP.
  click a room → RunController.enter_room(index) (existing, logged; can_enter already allows exactly the visited
  rooms and the rooms touching one, Isaac rule). Refused → a warning toast. Success → the map closes and the room
  plays (battle, event, pickups) as it does today. A drag that moved more than a few pixels never counts as a click.
  locked item rooms and shops (1f2): marked "NEEDS A KEY"; the travel rule check and key cost come with 1f2
```
Today's map panel enters rooms from its cells; that moves to the big map only, so travel is always a deliberate
action from one place. The dev console's room commands are unchanged.

### 2.12 Shared components (F15: build once, reuse everywhere)
Every screen is assembled from the same small set of scenes (the map cells too: `map_cell` draws the minimap, the Tab view and the big map), so the player sees one consistent UI and a new screen
is mostly composition:
| Component (your scene, system base where noted) | Used by |
|---|---|
| `menu_frame.tscn` (`DemoMenuFrame`): **Back at the top left** (`UIBackButton`), description window at the top, a content stack (windows top to bottom, characters last). Screens inherit the scene. Opening one sets `UI.State.Run.Menu`, which hides the HUD panels it would overlap | Equipment, Armor, Use Item, Use Ability, Status, big map |
| `description_window.tscn` (name, kind or usage tag, text, extra line such as "Equipped by") | battle hint, all menu screens, pickup and event panels |
| `list_entry.tscn` (name left, detail right; hover, unhover, action; the CommandButton variation for commands) inside each screen's list window (a PanelContainer with a title and a `UIList`) | battle commands and lists, explore menu, gear, use, held-item and status-tab lists |
| `member_row.tscn` (name, level, statuses, HP, MP, ult; optional ULT button; pickable / selected / preview states) | battle party panel, party strip, use and status screens |
| slot buttons: plain Buttons with the SlotButton / SlotButtonPreview / SlotButtonSelected / SlotButtonLocked variations | gear screens |
| `map_cell.tscn` with `MapCells` (system) and `DemoMapIcons` (`map_icons.gd`: icons and names per room kind; Altar uses $) | minimap, Tab view, big map, legend |
| `party_rows.gd` (`DemoPartyRows`: member_row items from the run outside battle) | party strip, use and status screens |
| `toast.tscn`, `feed_line.tscn` with `UIToastHost` | run toasts, battle feed, any later toast |
| `action_button.tscn` (existing generic button entry) | commands, menus, choices |
Rules: **Back is always top left** on every pushed screen; **list text starts at the window's inner padding** and
the pointer cursor sits over the window's left edge on hover (FF7 style), so it never reserves an empty column; **hover previews, click selects** in every list and grid;
the **description window is always at the top**; the **characters are always at the bottom**. Screens set data on
these components; they don't restyle them. The **title menu, class cards and details, run end, run menu, settings
and confirm dialog** are rebuilt on the same theme and components (they are in 3.2's list), so the main menu matches
the game.

## 3. Data contracts
**No wire contracts change.** No `Rpg.Contracts` record, RabbitMQ queue, Redpanda topic or Redis key is involved.

### 3.1 System code (`game/ui/`, `game/`, `combat/`)
| Type | Change |
|---|---|
| `UIWindowStyle` (new, `game/ui/ui_window_style.gd`) | `extends StyleBox`, `@tool`; exports `top`, `middle`, `bottom` colours, `middle_at` (0–1), `border_color`, `border_width`, `ring_color`, `ring_width`, `corner_radius`, `shadow_color`, `shadow_offset`, `horizontal: bool` (for bar fills); `_draw` paints the gradient, ring and border; content margins = border + ring + padding |
| `UIToastHost` (new, `game/ui/ui_toast_host.gd`) | `extends UIScreen`; `@export toast_set: UIToastSet`; listens per rule (2.2); queue or stack; real-time fade; hold actions; `toasts() -> Array` (for tests and the `ui` console dump) |
| `UIToastSet`, `UIToastRule` (new resources) | 2.2 fields; `UIToastRule.format(message) -> {kicker, title, subtitle}` (pure) |
| `GearColumn` (new resource) | `title`, `slot: StringName` (`gas::tag`) or `use_slot: int` (1, 2, …; the column shows only while some member has that many use slots; members with fewer show it LOCKED) |
| `TurnManager.preview(count) -> Array` (new, `combat/turn_manager.gd`) | pure; works on a duplicate of `av`; presentation only (never called by `Battle.run`) |
| `Battle.ability_activated` (new signal, `combat/battle.gd`) | `(unit_id, ability_tag, target_id)`, emitted in `_activate` before activation; no state change |
| `ActionRecorder.pending_ults()` (new, read-only) | copies of the queued ult presses (party window QUEUED, gold turn cards) |
| `UIBattlePanel` (new, `game/ui/ui_battle_panel.gd`) | base of the battle HUD panels: finds the battle, recorder and gate, redraws once a frame after battle signals |
| `GearSet` (new resource) | `title`, `columns: Array[GearColumn]` (`equipment.tres`, `armor.tres`) |
| `MapCells` (new, `game/ui/map_cells.gd`) | `of(run)`: per grid cell shown / here / visited / kind / enterable, through `room_type_known` |
| `UIManager.point(slot)`, `UIState.MENU_OPEN` | the extension point of a slot; `UI.State.Run.Menu` while the GameMenu layer holds a screen; HUD panels answer Back |
| `RunController.field_catalog()`, `member_kit(slot)` (new, read-only) | every member's action abilities and use items with usable/targets/hint; the whole kit with BASIC / ABILITY / ULT / PASSIVE / ITEM |
| `GameplayMessageRouter` | channels `Message.Battle.AbilityUsed`, `Message.Ui.Hint` (the hint window), `Message.Ui.UltPressed` (ULT presses); verbs `Verb.Use`, `Verb.Hint`, `Verb.Press` |
| Console | `tab on\|off` (holds Tab); `ui press` also matches a button's `ui_text` meta (list entries, map cells, member rows) |
| `AutoPolicy.ROLE_GUARD`, `ScriptedController` | Auto and the dev stand-in player never pick `Ability.Role.Guard` |
| `BattleAbility.description` (new export, `combat/battle_ability.gd`) | text only; not part of the state hash or any log |
| `BattleMessages` | + `Message.Battle.AbilityUsed` (`Verb.Use`, data `abilityName`) |
| `AbilityHint` (new, `game/ability_hint.gd`) | `static of(unit, ability) -> {name, cost, description, target, usage}` |
| `RunController.room_type_known(index) -> bool` (new, read-only) | visited, or not an event room, or `state.revealed`; the map's only rule for showing a room's icon |
| `RunController.member_stats(slot) -> Dictionary` (new, read-only) | `{base: {stat: x100}, current: {stat: x100}, level, xp, xp_to_next}` from the field battle unit vs the class stats at that level; no log entry |
| `RunController.gear_swap(...)` | **not in 1f** (1f2); the UI composes existing `equip`/`unequip` calls (F11) |

### 3.2 Your files (`presentation/demo/ui/`), changed with this slice's approval
| File | Change |
|---|---|
| `ui_theme.tres` | old: one flat grey `panel` and nine label variations → new: 2.1 (keeps every existing variation name; colours retuned for the blue ground, e.g. `Muted` #c6cdf2, rarity colours kept) |
| `fonts/ChakraPetch-*.ttf` + `OFL.txt` (new) | the window font (F2) |
| `hud.tscn` | five new `UIExtensionPoint`s (2.3) |
| `ui_policy.tres` | 2.3 and 2.7 entries; `battle_panel`, `party_panel`, `field_panel`, `floor_card`, `battle_callouts` entries removed (F7) |
| `run_toasts.tres`, `battle_feed.tres` (new `UIToastSet`s), `toast.tscn`, `feed_line.tscn` (new entries) | 2.2 |
| `battle_party_panel`, `party_strip`, `member_row`, `command_panel`, `top_window`, `turn_order_panel`, `turn_card`, `explore_menu` (new) | battle and exploration HUD |
| `menu_frame`, `description_window`, `list_entry`, `party_rows.gd`, `map_icons.gd` (new shared components, 2.12) | every menu screen |
| `map_panel` (reworked: view only, Tab growth, click opens the big map), `map_cell` (new entry), `big_map` (new screen), `map_legend` (new modal), `icons/map/*.svg` (new: gift, dollar, skull, exclamation, lock) | 2.11 |
| `gear_screen` (+ `equipment.tres`, `armor.tres`; the middle menu is part of the screen) (new) | 2.8 |
| `use_screen` (Use Item and Use Ability, one scene with a mode) (new) | 2.9 |
| `status_screen` (new) | 2.10 |
| Every other screen (`title_menu`, `class_card`, `class_details`, `map_panel`, `stairs_panel`, `pickup_panel`, `pickup_row`, `event_panel`, `message_line`, `run_end`, `run_menu`, `settings`, `confirm_dialog`, `action_button`, `armor_row`) | `theme_override_*` entries that fight the theme (fixed colours, flat panel styles) removed or replaced by a variation; sizes and layouts kept. Each file's diff is shown old → new in the implementation summary |
| `battle_panel`, `party_panel`, `member_card`, `field_panel`, `armor_row`, `floor_card`, `battle_callouts` (`.tscn` + `.gd`) | deleted (F7, confirmed) |

### 3.3 Content (yours), tags and input (your registry and project settings)
- Tags: `UI.Slot.Hud.Top`, `.Toast`, `.Feed`, `.Bottom.Left`, `.Bottom.Right`; `UI.State.Run.Menu` (a menu screen
  is open: `UIState` sets it while the GameMenu layer holds a `menu_frame` screen); `Message.Battle.AbilityUsed`;
  `Message.Ui.Hint`, `Message.Ui.UltPressed`; `Verb.Use`, `Verb.Hint`, `Verb.Press`; `Ability.Type.Basic`,
  `Ability.Role.Guard`, `Ability.Block`, `State.Blocking`.
- Input action `show_floor_info` (Tab) in `project.godot`.
- Block (F3): `abilities/block.tscn` (no MP, SELF, applies `effects/blocking.tres`: `State.Blocking`, +`resist_dmg`
  until the unit's next turn), asset tags `Ability.Role.Guard`, added to all 11 classes' ability lists.
- `Ability.Type.Basic` on each class's basic attack (Strike, Arcane Bolt, Quick Shot, …).
- Descriptions on every party ability: drafts proposed by `game/tools/build_description_pass.tscn` (a proposal file
  you edit and apply, like `build_role_pass`); the texts are yours.

### 3.4 Validator (`validate_content.tscn`)
| Code | Level | When |
|---|---|---|
| `ability_description_missing` | warning | a party-usable ability (class kit, item, equipment) has no description |
| `basic_ability_missing` | warning | a class has no `Ability.Type.Basic` ability (Attack is then hidden) |
| `basic_ability_multiple` | error | a class has more than one |
| `toast_channel_unknown` | error | a toast rule's channel isn't a `Message.*` tag the router knows |
| `toast_format_field_unknown` | error | a format names a field the message type never carries |
| `gear_slot_unknown` | error | a gear column's slot isn't in any run structure's `equipment_slots` |
| `ui_slot_unknown` | error (existing rule) | covers the new slots |

## 4. Failure modes
Server failure scenarios (root `CLAUDE.md` 1–7): **none apply.** This slice must keep the following true: **the UI
never changes a battle or a run**, so replays and run hashes are byte-identical with or without it (scenario 5 relies
on this).
| Failure | Behaviour | Test |
|---|---|---|
| `preview` mutates the live AV table | not possible by design (works on a copy); proven | `test_turn_preview_pure` (state hash before == after) |
| Preview disagrees with the real order | the panel redraws after every action, so a wrong card is wrong for one action at most; with no speed changes the preview equals the real sequence | `test_turn_preview_matches` (fixture battle: preview(7) at start == the next 7 actual actors) |
| `ability_activated` changes a battle | it's a signal with no listener in combat; goldens and traces stay identical | existing combat goldens + `test_battle_trace_unchanged` |
| A swap is interrupted halfway (one of its three actions refused) | the actions are checked first (all three valid) and only then sent; a refusal after that leaves a legal state (the piece in the bag) and shows a warning toast; the run log holds only what happened | `test_gear_swap_composed` |
| A toast floods (ten hits in one action) | the feed keeps `max_visible`, the oldest leave first; the run toast queue keeps at most 5 waiting, extra low-priority ones dropped | `test_toast_stack_cap`, `test_toast_queue_cap` |
| A toast rule names a missing field | validator error; at runtime the field shows empty, never a script error | `test_toast_format` |
| A class has no Basic ability | Attack hidden, all abilities in Ability; validator warning | `test_command_panel_pages` |
| A two-ult member queues one, then the other | the second press waits like any press (existing ult rules); both cards shown | `test_ult_chooser` |
| Ability without description | hint shows name, cost and target only; validator warning | `test_ability_hint` |
| Old overrides make a screen unreadable on blue | caught by the contrast check over the theme (text vs window colours ≥ 4.5:1) and the window shots | `test_theme_contrast` |
| Block changes Auto's play rate | Auto never picks `Ability.Role.Guard`; the smart 4-member report must stay 35.33% | play report (manual gate) |
| UI changes a run | screens only call `ActionRecorder` / `RunController`, as today | `test_ui_run_hash_unchanged` (existing) |

## 5. Observability
N/A: client-only, no service. Local signals: the `ui` console dump (now also lists live toasts), validator output,
window shots.

## 6. Test plan
System tests (fixtures and code-built probes, never `presentation/`, so your restyling can't break them):
- `test_ui_window_style`: draws into a viewport without errors; content margins = border + ring + padding;
  `horizontal` flips the gradient.
- `test_toast_format`, `test_toast_rules_match` (exact and partial channels, `when` queries such as `Hit.Critical`),
  `test_toast_stack_cap`, `test_toast_queue_cap`, `test_toast_hold` (a held action keeps the latest floor toast).
- `test_battle_feed_lines` (fixture battle with a probe feed): the used / damage / critical / broken / down lines in
  order, at most four live.
- `test_turn_preview_pure`, `test_turn_preview_matches` (fixture duelist battle).
- `test_ability_hint`: name, cost (MP, ult, none), target text per `Targeting`, missing description.
- `test_command_panel_pages` (probe panel on a fixture battle): COMMANDS → LIST → TARGET → submit; Back from each
  page; Attack hidden with no Basic; Block submits with no target; Item lists only use slots.
- `test_ult_chooser`: one ult goes straight to TARGET or submit; two ults open the chooser; QUEUED state; the gold
  turn card appears and clears.
- `test_gear_screen` (probe gear screen on the fixture armory run): preview on hover, select on click, the Item Slot 2
  column only once a member has two use slots (LOCKED for the others), E marks, EQUIP and TAKE OFF call the existing actions; `test_gear_swap_composed`.
- `test_use_screen`: item then member; member then ability then target; greyed battle-only entries can't be picked.
- `test_map_views` (fixture run): the minimap shows visited and touching rooms only and never travels; an unvisited
  event room has no icon until visited or revealed; your room has no icon; Tab doubles it;
  the big map's click calls `enter_room` for a reachable room and is refused for others; a drag is not a click.
- `test_member_stats`: base vs current at a level, with armor and an item (fixtures).
- `test_battle_hud_policy` / `test_explore_hud_policy`: the right panels in each state; `map_panel` vs
  `turn_order_panel`.
- `test_tool_parity`: `ui press` reaches every command page and menu screen; `ui` lists live toasts.
- Validator: `tests/broken_fixtures/` gets a class with two Basic abilities, an ability without a description, a toast
  rule on an unknown channel and a gear column on an unknown slot.
- Presentation (direction only): `test_demo_ui_policy` (0 errors), `test_theme_contrast` over `ui_theme.tres`, the
  existing compile test.

Golden vectors: none change. The combat goldens use fixtures, so Block in the demo kits doesn't touch them, and
`run_scripted.json` stays byte-identical.
Manual gates:
- **Play report:** the smart 4-member report stays at 35.33%.
- **Window shots** go to `H:\claudeOutShots\2026-10-27 ff7-ui\`:
  - menus: title and class details;
  - exploration: map with an item toast, Tab held (big minimap and floor toast), the big map (centred and panned),
    pickup, event, stairs choice;
  - Equipment with the Item Slot 2 column, Armor with the middle menu, Use Item, Use Ability, Status (each tab);
  - battle: commands, ability list with the hint, target, the two-ult chooser, a queued ult, the feed with four lines;
  - run menu, settings, confirm, and the won and lost end screens.

Remaining work (found by /sync-spec, 2026-10-27):
- **Gear swap pre-check (section 4) not built:** the three actions run in order and stop at the first refusal (a
  refusal line; the piece may end up in the bag). Checking all three before sending any is still to do (or moot once
  1f2 adds the single swap action).
- **The `ui` console dump doesn't list live toasts** (sections 5 and 6).
- **Untested:** the gear screen's hover preview and the Item Slot 2 column (shown only with two use slots, LOCKED for
  the others); `test_tool_parity` reaching every command page and menu screen through `ui press` (only `tab` was
  added); `test_battle_trace_unchanged` as its own test (covered by the unchanged combat goldens and traces); the toast
  and gear validator rules on broken-fixture files (tested on objects built in code instead).

Implementation order:
1. `UIWindowStyle`, `TurnManager.preview`, `ability_activated`, `BattleAbility.description`, `AbilityHint`,
   `member_stats` and their tests.
2. The theme and font. Every screen then picks up the look; the override cleanup follows, screen by screen.
3. The toast system, then the two hosts (`run_toasts` replaces `floor_card`, `battle_feed` replaces `battle_callouts`).
4. The battle panels, slots and policy (the old `battle_panel` kept until step 7).
5. Exploration: party strip, menu, map views and big map, gear screen with both configurations, use screen, status
   screen.
6. Content: Block, Basic tags, the description pass proposal for you to edit.
7. Delete the replaced panels once you confirm. Validator rules, shots, both suites.

## 7. Decisions (all approved by the user, 2026-10-27)
- **F17 Map icons:** white line icons (gift box, $, skull, !, lock; the Void's Altar rooms use $) with no materia orbs; your room is a gold tile
  without an icon; no start or unexplored marks; event rooms stay unmarked until visited unless room types are
  revealed; the legend is a HELP modal on the big map only (centred, dark overlay); while Tab is held the floor
  toast centres in the space left of the grown map.
- **F16 Map:** the minimap is view only; holding Tab grows it in place (Isaac); clicking it opens a big map you can
  drag and scroll (Enter the Gungeon), and travel happens only there, through the existing `enter_room` rule (any
  visited room or a room touching one). No run rule changes; locked rooms and their key cost come with 1f2.
- **F15 Reuse first:** every screen is built from the shared components of 2.12, Back is always at the top left, and
  any overlapping HUD panel hides while a menu screen is open. All existing screens, the main menu included, move to
  the theme and the components.
- **F1 Window look: a small `UIWindowStyle` StyleBox in GDScript** (approved): the gradient, ring and border are
  inspector fields you can tune, and it scales to any size.
- **F2 Font: Chakra Petch** (approved), bundled in `presentation/demo/ui/fonts/` with its licence.
- **F3 Block is a real ability** (approved): one shared content ability on every class, `abilities/block.tscn`,
  applying `effects/blocking.tres` (lowers `dmg_taken`; `resist_dmg` only scales elementally resisted hits, so it was
  the wrong stat). Battle-only through its activation query (no `State.Infield`). Auto and the dev stand-in player
  never pick it. It needs no combat code and is logged and replayed like any action. You tune its numbers.
- **F4 Attack = the ability tagged `Ability.Type.Basic`** (approved), one per class, checked by the validator.
- **F5 Descriptions: a `description` field on abilities plus a proposal pass** that drafts texts for you to edit
  (approved). Applied: the 61 drafts as written (your approval, 2026-10-27), plus hand-written descriptions for the 9
  example-set items that had none; the validator reports 0 warnings.
- **F6 Exploration HUD (rewritten after review):**
  - **Layout:** toasts instead of a banner, the party strip at the bottom left, and a menu at the bottom right
    (Equipment, Armor, Use Item, Use Ability, Status, Gold).
  - **Screens:** the Equipment and Armor gear screens, the Use Item / Use Ability screen and the Status screen, as in
    the approved drafts (2.7–2.10).
  - **Replaced:** today's `party_panel`, `field_panel` and `floor_card`.
- **F7 Replaced panels are deleted after you confirm** (approved), once the new ones cover all they do.
- **F8 HINT is on by default** and the setting is remembered (approved).
- **F9 Roadmap: slice 1f** after 1e, then 1f2 `keys-and-gear` (approved).
- **F10 Toasts as a Lyra-style host plus rules file:**
  - **Build:** one `UIToastHost` scene type and a `UIToastSet` resource you edit. It reads the existing message bus,
    so the run toasts and the battle feed are the same system with different rules. A new toast is a new rule.
    This is recommended.
  - **Alternative:** two hand-written panels (faster to build, but every new toast is code).
- **F11 Gear swaps in 1f are three existing logged actions:** unequip, equip, equip.
  - **Why:** it gives you swapping now without changing run rules or goldens. 1f2 replaces it with one logged swap
    action. This is recommended.
  - **Alternative:** no swap until 1f2 (Swap greyed out).
- **F12 Moving use items between characters waits for 1f2:**
  - **Why:** no action for it exists today. In 1f the Item Slot column shows the items, their descriptions and who
    holds them.
  - **Alternative:** pull just that action forward into 1f, which changes run rules and the scripted-run golden.
- **F13 Status numbers from `RunController.member_stats`:** a read-only call that builds the member's field unit (as
  `field_options` already does) and compares it with the class stats at that level. Nothing is logged.
- **F14 Field/Battle labels in 1f use today's rule:** usable on the map means no enemy target and an activation
  query that allows `State.Infield` (Block's doesn't), shown as [Field and Battles] or [Battles Only]. 1f2 adds the real `Ability.Usage.*` tags and [Field Only], and the labels
  switch over with no UI change.
