# Spec: ui-framework (slice 1d, step D2)

Status: 🔨 Implemented, awaiting your review (U1–U5 approved as recommended, 2026-10-26) · Roadmap: inside 1d
`playable-demo`, step D2, after step D and before E ·
Date: 2026-10-26
Builds on `specs/game-skeleton.md` 3.7 (`GameMain` hosts the screens), `specs/playable-demo.md` 3.6 (the demo
screens), `specs/dev-tools.md` (console parity, script runner shots). Model: Unreal's **Lyra** UI (CommonUI's
activatable widgets and layer stacks, the UI extension subsystem, the UI policy, data-driven widget lists), done the
Godot way with GodotGAS tags.

## 1. Purpose & enterprise mapping
Today the shell is ten hand-wired screens. `GameMain` names each one in an export list, and every screen decides its own visibility by checking `main.mode` strings and run
state, and builds its rows (pickups, armor, kit lines, route buttons) in code with inline colors and font sizes.
Adding a screen means editing `GameMain`; adding a menu inside a menu has no mechanism at all; changing a row's look
means editing GDScript.

This slice gives the client a small **UI framework** in the Lyra mould, so that:
- **A new screen or panel is a scene plus one entry in a data resource** (the UI policy), never a code change in
  `GameMain` or in another screen.
- **A menu inside a menu is a button with a scene set in the inspector** (`UIPushButton`), pushed onto a layer stack;
  Back (Esc or a `UIBackButton`) returns to the screen below, which comes back as it was.
- **Panels plug into named slots** (extension points) of a layout, like Lyra's HUD extensions, so the map, the party
  panel or a future minimap can be moved, added or removed in data.
- **Lists are entry scenes** (Lyra's list view with an entry widget): a pickup row, an armor row, a class card, a
  route button are scenes you style in the editor; the code only hands each one its data.
- **Look lives in a Theme** (CommonUI styles): type variations (`HeaderLarge`, `Caption`, `RarityEpic`…) instead of
  `add_theme_*_override` and `modulate` in scripts.
- **What is shown when is data:** the game publishes **UI state tags** (`UI.State.Run.Battle`…); the policy says which
  screens and panels are active for which tags (GodotGAS `GameplayTagQuery`, as abilities and effects already use).

**Enterprise mapping: none.** Client-only presentation: no service, queue, broker, cache or wire contract. Indirect
value: the shell is what people see in the demo and what slice 7's dashboard screenshots and slice 8's Locust runs
drive; a data-driven shell keeps the later server screens (login, run resume, verdict toasts over SignalR in 2b/3,
card collection and packs in 5) to "new scene + policy entry".

Out of scope: gamepad navigation and focus rules (CommonUI's input routing beyond Back), MVVM view models,
localisation, animations between screens, new art, a settings save system beyond what exists (`user://game_main.cfg`).

## 2. Sequence flow
Client only; no server. All framework code is system code in `game/ui/`; every scene and resource it reads is yours
in `presentation/`.

### 2.1 Start-up (Lyra: UIManager subsystem + UI policy → primary game layout)
```
GameMain._ready()
  ui_policy (export; default res://presentation/demo/ui/ui_policy.tres)        replaces the ten scene exports
  UIManager.new(policy) → instantiates policy.layout (your layout scene, root UILayout)
     UILayout registers its UILayerStack children by tag:
        UI.Layer.Game (HUD) · UI.Layer.GameMenu · UI.Layer.Menu · UI.Layer.Modal      (bottom → top)
     every UIExtensionPoint in the layout (and later in any pushed screen) registers by slot tag
  UIState starts publishing state tags (2.2); the manager applies the policy's rules (2.3)
```

### 2.2 UI state tags (system; derived, never stored)
`UIState` (system) recomputes a tag set after each `GameMain.mode_changed` and run signal, and emits
`state_changed(tags)` only when the set changes:
| Tag | When |
|---|---|
| `UI.State.Menu` | `GameMain.mode == "menu"` |
| `UI.State.Run` | a run is on screen (plus exactly one of the run sub-states below) |
| `UI.State.Run.Map` | no battle and no event open |
| `UI.State.Run.Battle` | a battle is being fought |
| `UI.State.Run.Event` | an event page is open (`UI.State.Run.Event.Rest` too for the rest stop, cell −1) |
| `UI.State.Run.Pickup` | (with Map) the current room is cleared and holds untaken pickups |
| `UI.State.Run.Stairs` | (with Map) the stairs are open; `UI.State.Run.Stairs.Choice` when the next floor is a CHOICE |
| `UI.State.End`, `.Won`, `.Lost`, `.Stopped` | `GameMain.mode == "end"` and why |
| `UI.State.Sandbox` | the run is a sandbox (dev) |

### 2.3 Policy rules (Lyra: experience actions "add widgets" + "push to layer")
```
UIPolicy (your .tres)
  layout: PackedScene                                         the primary layout
  screens: Array[UIScreenRule]   { scene, layer tag, active_when: GameplayTagQuery }
  extensions: Array[UIExtension] { slot tag, scene, order, active_when: GameplayTagQuery }
on state_changed(tags):
  each screen rule whose query now matches and isn't on its layer → push(layer, scene)
  each pushed-by-rule screen whose query stopped matching → removed from its stack
  each extension whose query now matches → added to its slot (sorted by order); stops matching → removed
  (screens pushed by a player action, 2.4, are never removed by rules except when their layer is cleared by
   a rule screen with `clears_layer` — e.g. the run-end screen clears GameMenu)
```
The demo policy (proposal; your file):
| Entry | Layer / slot | Active when |
|---|---|---|
| `title_menu` (screen) | Menu | `UI.State.Menu` |
| `hud` (screen, holds the slots below) | Game | `UI.State.Run` |
| `map_panel` | `UI.Slot.Hud.Right` | `UI.State.Run.Map` |
| `stairs_panel` (Next floor / route buttons) | `UI.Slot.Hud.Right` | `UI.State.Run.Stairs` |
| `party_panel` | `UI.Slot.Hud.Left` | `UI.State.Run` |
| `field_panel` (take off / equip armor from the bag, field spells and items) | `UI.Slot.Hud.Left` (order 10) | `UI.State.Run.Map` |
| `pickup_panel` | `UI.Slot.Hud.Center` | `UI.State.Run.Pickup` |
| `event_panel` | `UI.Slot.Hud.Center` | `UI.State.Run.Event` |
| `battle_panel` | `UI.Slot.Hud.Bottom` | `UI.State.Run.Battle` |
| `floor_card` | `UI.Slot.Hud.Overlay` | `UI.State.Run` (shows itself on each new floor, hides when the state leaves Map) |
| `message_line` | `UI.Slot.Footer` (in the layout, so menus show messages too) | always (no query) |
| `run_end` (screen) | Menu | `UI.State.End` |
| `run_menu` (screen, U3 example) | GameMenu | the policy's `back_screens`: Esc on the map (`UI.State.Run.Map`) |
| `confirm_dialog` (root `UIConfirm`) | Modal | the policy's `confirm_scene`, for `ctx.ui.confirm()` |
| `room_view_3d` | not UI: stays the `GameMain` export `room_view` | |

### 2.4 Menus inside menus (CommonUI activatable stack)
```
title_menu: a class card's "Details" (UIPushButton, screen = class_details.tscn, layer = UI.Layer.Menu)
  UIManager.push(UI.Layer.Menu, class_details.tscn, payload = {character})
    stack top title_menu → on_deactivated() (hidden, keeps its state); class_details: bind(ctx), on_pushed(payload), on_activated()
  Back (Esc = ui_cancel, or a UIBackButton) → UIManager.back()
    the topmost non-empty layer pops its top screen (Modal first, then Menu, GameMenu; Game never pops)
    unless that screen's handles_back() returns true (it consumed Back, e.g. closing its own picker)
    title_menu → on_activated() again, as it was
Any screen can also push from code: ctx.ui.push(layer, scene, payload) / ctx.ui.back() / ctx.ui.confirm(text) (Modal)
```

### 2.5 Lists from entry scenes (CommonUI list view)
```
UIList (a container node; export entry_scene: PackedScene)
  set_items(items: Array)  → reuses or instantiates one entry per item, in order; extra entries freed
  each entry (root script with set_item(item, ctx)) builds itself from its item; entries emit their own signals
pickup_panel: %Rows.set_items(run pickups)    entry pickup_row.tscn (rarity, name, price, description, give-to, Take)
party_panel:  %Members.set_items(party)        entry member_card.tscn ; %ArmorBag.set_items(state.armor) → armor_row.tscn
title_menu:   %Classes.set_items(characters)   entry class_card.tscn ; %Runs.set_items(runs) (or an OptionButton)
stairs_panel: %Routes.set_items(choices)       entry action_button.tscn (one generic button entry: {text, action,
              disabled, tooltip, variation, hidden, sound}; also map cells, event choices, field actions, abilities, ults)
```

### 2.6 Headless and the dev tools
- Headless runs (tests, `dev_run` without `--window`, seed reports) never need the UI: `GameMain` builds the UI
  only when `ui_policy` is set, and every rule reacts to state; nothing in the run waits on a screen.
- Console parity (spec dev-tools): new command `ui`: `ui` prints each layer's stack and the active extensions;
  `ui push <scene path> [layer]`, `ui back`, `ui press <node path>` (presses a button by path, so window scripts can
  drive menus: `ui press Menu/TitleMenu/%Start`). The script runner's shots then capture real menu flows.

## 3. Data contracts
**No wire contracts change**: no `Rpg.Contracts` record, RabbitMQ queue, Redpanda topic or Redis key (N/A,
client-only). The contracts are Godot types (system, `game/ui/`) and your resources.

### 3.1 Framework types (system, `game/ui/`)
| Type | Kind | Fields / API |
|---|---|---|
| `UIManager` | `Node` (child of `GameMain`) | `push(layer, scene, payload = {}) -> UIScreen`, `back() -> bool`, `remove(screen)`, `clear(layer)`, `top(layer)`, `confirm(text, yes_label, no_label) -> bool` (await; Modal), signal `stack_changed(layer)`; holds `context: UIContext` |
| `UIContext` | `RefCounted` | `main: GameMain`, `run: RunController`, `ui: UIManager`, `state: PackedStringArray` (current tags); `on_run(signal_name, callable)` connects to the current run's signal and reconnects when the run changes; `has_state(tag)` |
| `UIState` | `RefCounted` | `compute(main) -> Array[StringName]` (2.2), pure; `UIManager` calls it |
| `UILayout` | `Control` (your layout's root script) | finds `UILayerStack` children; nothing else |
| `UILayerStack` | `Control` | `@export layer: StringName` (`gas::tag`), `@export blocks_below: bool` (Modal, Menu: dim and block input to lower layers) |
| `UIScreen` | `Control` (base for every screen and panel root) | virtuals `bind(ctx)` (once), `on_pushed(payload)` (once), `on_activated()` (each time it is shown on top; default calls `refresh()`), `on_deactivated()`, `handles_back() -> bool`, `refresh()`; `@export focus_on_activate: NodePath`; `static context_of(node)` |
| `UIConfirm` | `UIScreen` | the confirm dialog: fills `%Text`, `%Yes`, `%No` from the payload, signal `decided(yes)`; Back answers no |
| `UIExtensionPoint` | `Container` | `@export slot: StringName` (`gas::tag`); hosts extension scenes, sorted by `order` |
| `UIPolicy` | `Resource` | `layout: PackedScene`, `theme: Theme`, `screens: Array[UIScreenRule]`, `extensions: Array[UIExtension]`, `back_screens: Array[UIScreenRule]` (Esc with nothing to close), `confirm_scene: PackedScene` |
| `UIScreenRule` | `Resource` | `scene: PackedScene`, `layer: StringName`, `active_when: GameplayTagQuery`, `clears_layer: StringName` |
| `UIExtension` | `Resource` | `slot: StringName`, `scene: PackedScene`, `order: int`, `active_when: GameplayTagQuery` |
| `UIList` | `Container` | `@export entry_scene: PackedScene`, `set_items(items: Array) -> Array[Node]` (reuses entries); entries implement `set_item(item, ctx)`; signal `entry_filled(entry, item)` for wiring entry signals |
| `UIPushButton` | `Button` | `@export screen: PackedScene`, `@export layer: StringName = &"UI.Layer.Menu"`, `@export payload: Dictionary` |
| `UIBackButton` | `Button` | calls `ctx.ui.back()` |

Rules: the framework never reads game content or run rules; screens read the run only through `ctx.run` and change
it only through `RunController`'s public methods, as today. Presentation never changes combat state (unchanged).

### 3.2 `GameMain` (system; edit shown `old → new`)
| Old | New |
|---|---|
| Ten exports `menu_view … sound_board` + `_view()` fallback to `presentation/demo/<name>.tscn` | `@export var ui_policy: UIPolicy` (fallback `res://presentation/demo/ui/ui_policy.tres`), `room_view`, `unit_view`, `sound_board` kept (not UI); `var ui: UIManager`; `var gate: ViewGate` (a battle panel made after `battle_prepared` reads it); `static load_setting / save_setting(section, key, …)` for `user://game_main.cfg` |
| `show_message(text)` writes its own bottom `Label` | emits `message_shown(text)`; the policy's `message_line` panel shows it (headless: still printed by the console). Superseded by `specs/gameplay-messages.md` (D3): it broadcasts `Message.Notification` and `message_shown` is gone |
| `mode` strings `menu` / `run` / `end` | kept (the console and tests use them); `UIState` derives tags from them |

### 3.3 Tags (your registry, added through `sync_tags --add-missing` after you approve)
`UI.Layer.Game`, `UI.Layer.GameMenu`, `UI.Layer.Menu`, `UI.Layer.Modal`; `UI.Slot.Hud.Left`, `.Right`, `.Center`,
`.Bottom`, `.Overlay`, `.Footer`; the `UI.State.*` tags of 2.2. Slots are yours to add: a new `UI.Slot.*` tag plus a
`UIExtensionPoint` in any scene.

### 3.4 Your files (`presentation/demo/ui/`, new; U4)
| File | What |
|---|---|
| `ui_policy.tres`, `ui_theme.tres` | the policy (2.3 table) and the theme (type variations `HeaderLarge`, `Title`, `Caption`, `Muted`, `RarityCommon/Rare/Epic/Legendary`, `Warning`) |
| `layout.tscn` | `UILayout` with the four `UILayerStack`s |
| `title_menu.tscn`, `class_card.tscn`, `class_details.tscn` | the menu (today's `menu`), split into a card entry and a details sub-screen (U3) |
| `hud.tscn` | the Game-layer screen with the six `UIExtensionPoint` slots |
| `action_button`, `map_panel`, `stairs_panel`, `floor_card`, `party_panel`, `member_card`, `field_panel`, `armor_row`, `pickup_panel`, `pickup_row`, `event_panel`, `battle_panel`, `message_line`, `run_end`, `run_menu`, `settings` (`.tscn` + `.gd`), `confirm_dialog.tscn` | today's screens ported onto `UIScreen` / entries; behaviour unchanged except visibility now comes from the policy |

Every behaviour from step D carries over (run picker, remembered party, kit lines, title card, route buttons, rest
title, level and XP, armor bag, rarity and Void Scar prices, end summary and buttons, speed toggle). The old
`presentation/demo/*.tscn` screens are deleted only after you confirm (U4); `room_view_3d`, `unit_view`, `cues/`,
`animation_sets/` and `sound_board` stay as they are.

### 3.5 Validator (`game/dev/ui_policy_check.gd`, run by `validate_content.tscn` on the game's policy)
All errors: `ui_layout_root` (no layout, or its root isn't a `UILayout`), `ui_scene_missing` (a rule or extension
without a scene), `ui_layer_unknown` (a rule's layer has no `UILayerStack` in the layout), `ui_slot_unknown` (an
extension's slot has no `UIExtensionPoint` in the layout or in any scene of the policy), `ui_screen_not_uiscreen` (a
screen's root doesn't extend `UIScreen`; the confirm scene's must extend `UIConfirm`). Dropped while building: a
warning for an extension without `active_when` (that means "always", which the message line wants).
The tag checkpoint (`sync_tags.tscn`) now also scans `res://presentation/` and knows the `UI.State.*` tags.

## 4. Failure modes
Server failure scenarios (root `CLAUDE.md` 1–7): **none apply** (no server, no wire change). What this slice
protects: **presentation can never change a run or a battle**, so replays and run hashes are byte-identical with or
without the UI (scenario 5 relies on it).
| Failure | Behaviour | Test |
|---|---|---|
| Policy missing or a scene fails to load | `GameMain` shows a plain error label naming the file; the game stays playable from the console | `test_ui_policy_missing` |
| A rule's layer or slot doesn't exist | Validator error before play; at runtime a warning and the entry is skipped | `test_ui_policy_check` (broken policies built in code) |
| Back on an empty stack / on the Game layer | `back()` returns false, nothing changes | `test_ui_stack` |
| Pushing the same screen twice | the existing instance moves to the top (no duplicates) unless the rule says `allow_multiple` | `test_ui_stack` |
| A state flips quickly (battle starts the frame a pickup shows) | rules apply to the latest tag set only, once per frame (deferred) | `test_ui_rules_coalesce` |
| A screen awaits something while it's removed | removal frees it after `on_deactivated`; signals connected through `ctx.on_run` disconnect with it | `test_ui_context_rebinds` |
| UI changes a run | Can't through the framework (it has no run API); screens use `RunController` methods as today; a headless run and a window run of the same script give the same run hash | `test_ui_run_hash_unchanged` (fixtures, scripted run with and without a UI policy) |
| Speed toggle leaks `Engine.time_scale` after a battle | the battle panel resets it on battle end and on deactivation | manual (window run; presentation code) |
| A presentation script stops compiling | caught by `test_presentation_scripts_compile` (step D) | existing |

## 5. Observability
N/A: client-only, no service. Local signals: the `ui` console command's dump, validator output, window shots.

## 6. Test plan
System tests in `tests/game/test_ui.gd` on layouts, screens and policies **built in code** from two probes
(`tests/game/ui_probe_screen.gd`, `ui_probe_entry.gd`; never `presentation/`), so your restyling can't fail them:
- `test_ui_stack`: push/back/remove/clear per layer; activation order (`on_deactivated` before the next
  `on_activated`); the screen below keeps its state; no duplicates; Back order Modal → Menu → GameMenu; Game never pops;
  `handles_back` consumes Back.
- `test_ui_rules` (also covers `clears_layer` and `back_screens`): a policy and a scripted fixture run (`TestCase.start_run`): the right screens and
  extensions exist for Menu, Map, Battle, Event, Pickup, Stairs (and Choice), End Won/Lost; ordering by `order`.
- `test_ui_rules_coalesce`, `test_ui_context_rebinds` (a new run reconnects `on_run` signals; the old run's are gone).
- `test_ui_state_tags`: `UIState.compute` for each row of 2.2 (fixtures; pure function).
- `test_ui_list`: `UIList.set_items` reuses entries, keeps order, frees extras, passes `ctx`.
- `test_ui_push_and_back_buttons`: a `UIPushButton` in a screen pushes its scene with its payload; `UIBackButton` pops.
- `test_ui_confirm`: Modal confirm resolves true/false and pops.
- `test_ui_policy_check`: broken policies built in code (no layout, unknown layer, unknown slot, non-UIScreen and
  non-UIConfirm roots); `test_ui_policy_missing`: a broken policy leaves no UI, an error label, and runs still start.
- `test_ui_run_hash_unchanged`: the fixture scripted run's hash and log are identical with and without a policy.
- `test_tool_parity`: the `ui` command (`ui`, `ui push`, `ui back`, `ui press`).
- Content/presentation (reads your files, direction only): `test_demo_ui_policy` (the demo policy validates with 0
  errors and every demo screen root extends `UIScreen`), plus the existing compile test.

Golden vectors: none (no combat or run rule changes); `run_scripted.json` stays byte-identical.

Manual and window checks: the step D screenshot set retaken through `ui press` scripts (title → details → back →
start, map, pickup, Waystation, route choice, battle 2×, run menu → resume, won and lost end, play again), saved to
`H:\claudeOutShots\<date> ui-framework\`.

Implementation order: (1) framework types and fixture tests; (2) `GameMain` switch behind `ui_policy` (old exports
kept until 4 so the game always runs); (3) your new `presentation/demo/ui/` files, ported screen by screen, the theme;
(4) after your confirmation, delete the old screens and the old exports; (5) the `ui` command, validator rules, shots.

## 7. Decisions (approved as recommended by the user, 2026-10-26)
- **U1 tags for layers, slots and states: GodotGAS tags** (recommended: the project's one naming system, inspector
  pickers via `gas::tag`, queries via `GameplayTagQuery` like abilities). Alternative: plain `StringName`s (no
  registry entries, but typos fail silently).
- **U2 visibility from the policy's state rules** (recommended: one place says what is shown when; screens stop
  checking `mode`). Alternative: keep each screen deciding for itself and only add the stacks and slots.
- **U3 two example nested menus** to prove "menus in menus": the class **Details** sub-screen from the party select,
  and an **Esc run menu** (Resume, Settings → battle speed and skip-animation defaults, Abandon run → confirm modal;
  built without a separate Main menu button, which Abandon covers). Recommended both; or only Details.
- **U4 migration:** new files in `presentation/demo/ui/`, the game switched over, then the old ten screen files
  deleted after you confirm (recommended: one reviewable change, no half-edited old files). Alternative: rework the
  old files in place, each shown `old → new` (many large edits).
- **U5 placement:** inside 1d as step D2, before the export (E), so the exported demo ships the new shell
  (recommended). Alternative: its own slice after 1d.
