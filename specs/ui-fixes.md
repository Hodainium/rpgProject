# Spec: ui-fixes (bug fixes on the ff7-ui menu screens)

Status: 🔨 In progress (an ongoing bug-fix spec: later UI fixes are added here) · Date: 2026-10-27
Fixes bugs in `specs/ff7-ui.md` 2.9 (Use Item and Use Ability) and 2.12 (the shared `menu_frame` and
`description_window`). There are no new features and no new screens. Every file it touches is in `presentation/demo/ui/`,
the user's folder, so each edit is made with a minimal `Edit` and with the user's OK.

## 1. Purpose & enterprise mapping
Two layout bugs, reproduced in a window run (`dev_run --window`: `new` a four-member party, `give` items,
`ui press "Use Item"` / `"Use Ability"`, `shot`):

- **B1. The description window is covered by the content below it.** `menu_frame.tscn` gives the description window
  a fixed slot (`Top`, y 16–108, so 92 px), and `Content` starts at y 124. A description with three lines (the
  name, the text and the gold `extra` line: "Held by: Warrior" in Use Item, "Equipped by: …" in Equipment and Armor) is
  113 px tall (measured; the theme's window margins included). The window grows past its slot, `Content` is drawn over it, and its bottom border is hidden. Use
  Ability looks right because its descriptions usually have two lines. Seen with the Potion and the Phoenix Feather.
- **B2. The Use Item and Use Ability list fills the whole upper screen.** In `use_screen.tscn`, `ListWindow` expands
  (`size_flags_vertical = 3`) and takes all of the space above the party window, even with two entries.

- **B3. The battle HUD is empty when a battle starts from a clicked room** (reported 2026-10-27, seen in the editor
  playtest, seed 30445776023: big map → boss room). The party window and command window show with nothing inside, and
  the turn order has no cards. Cause: a click is handled at the start of a frame, `GameMain` waits for
  `process_frame` (in that same frame) and then the battle starts, but the battle panels are created by the UI
  state's deferred apply at the end of the frame. `UIBattlePanel` takes the battle only from `battle_started`, so
  panels made after it never get it (they catch up the recorder, not the battle). Console runs fire from inside
  `process_frame` and wait a whole frame, so they never showed it.

Enterprise mapping: N/A: these are client-only presentation fixes. No backend component, run log, hash or replay is
involved.

## 2. Sequence flow
N/A: no client↔server traffic. Within the client nothing changes except layout: screens still call `describe()`, and
`description_window.gd` shows the same parts.

## 3. Data contracts
N/A: no DTOs, queues, topics or Redis keys.

## 4. Failure modes
N/A: no idempotency, retries or queues apply, and none of the acceptance scenarios is touched. The behaviour to fix:

### Fix for B1 (every screen built on the menu frame: Equipment, Armor, Use Item, Use Ability, Status, the big map)
| File | Change |
|---|---|
| `description_window.tscn` | `custom_minimum_size` `(800, 92)` → `(800, 113)`: three lines always fit, and the window keeps the same height while the player hovers between entries with and without an `extra` line. |
| `menu_frame.tscn` | `Top.offset_bottom` `108` → `129`; `Content.offset_top` `124` → `145` (a 16 px gap). |
| `menu_frame.gd` | When the description window resizes (`resized`, `item_rect_changed`; `Top`'s own `resized` did not fire when it grew), `Content.offset_top` is set to at least the window's bottom + `content_gap` (16, an `@export`). A description that wraps to a fourth line then moves the content down instead of being covered. |
| `gear_screen.tscn` | `Dim.offset_top` and `MenuCenter.offset_top` `124` → `145`, so the gear pop-up still lines up with the content. |

### Fix for B2 (Use Item and Use Ability)
| File | Change |
|---|---|
| `use_screen.tscn` | A new empty `Spacer` (`Control`, `size_flags_vertical = 3`, mouse ignored) between `ListWindow` and `PartyWindow`. The list keeps its scroll, the party window stays at the bottom, and the space between them is shared by stretch ratio. |

**Decided (user, 2026-10-27): half.** The Spacer keeps the default `size_flags_stretch_ratio = 1`, so the list gets
half of the space above the party window (about 9 rows or 18 entries before it scrolls). Setting the Spacer's ratio
to `2` gives the list a third. It is one inspector value.

### Fix for B3 (system code)
| File | Change |
|---|---|
| `game/run_controller.gd` | `current_battle`: the battle `fight()` is playing, set just before `battle_started` and cleared when `battle.run()` returns; null otherwise. |
| `game/ui/ui_battle_panel.gd` | `bind()` also takes `ctx.run.current_battle` when a battle is already running, the same way it already takes the recorder and gate. |

## 5. Observability
N/A: no server metrics.

## 6. Test plan
- **`tests/game/test_menu_frame_layout.gd`** (new, headless; layout runs without a window). It pushes `use_screen` on a
  run with held items and checks:
  - the description window's rect ends above `Content`'s rect when the description has three lines (name, text, `extra`)
    and when it has four (a long text that wraps);
  - in item mode and in ability mode, `ListWindow`'s height is at most the chosen share of `Stack`'s height (plus the
    separation), and `PartyWindow` stays at the bottom of `Stack`.
- **B3:** `test_battle_hud::test_panels_made_after_battle_started` binds a party window and a turn order after the battle
  started and checks they draw it (2 rows, 7+ cards), and that `current_battle` is null after the battle. It fails
  without the fix (0 rows).
- **Unchanged:** `test_demo_ui_policy`, the existing explore HUD and gear tests, and `validate_content.tscn`
  (`UIPolicyCheck`) still pass.
- **Visual check:** the window run from section 1 again, with new screenshots of Use Item (Potion hovered), Use Ability,
  Equipment and Status in `H:\claudeOutShots\2026-10-27 ui-fixes\`.
- Both suites (`tools/godot_tests.sh`, `tools/dotnet_test.sh`) pass.
