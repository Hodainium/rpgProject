# Spec: playtest-fixes (the living log of small UI and game adjustments from playtesting)

Status: 🔨 Ongoing (stays open; every small playtest fix is added here) · Started: 2026-10-27
Renamed from `ui-fixes` on 2026-10-27: code comments and commits that cite "ui-fixes Bn" refer to this file.

**What goes here:** any small change found while playtesting, UI or game: a layout bug, a toast, a panel, a value
tweak in content. Each entry is numbered (B1, B2, …) with the date, what was seen, the cause, the change as
`old → new` per file, and the test or screenshot that proves it. Value tweaks in `content/` are the user's (asked first,
`old → new`); one that may move the balance gate gets a smart 4-member report before it is committed.

**What gets its own spec instead:** a change to the run rules, the run's action log or hash, a server contract, or a new
system (e.g. `event-items`, which added the logged `give_to`). If a "small" fix turns out to be one of these, say so
before building it.

**Workflow:** reproduce (a window run: `dev_run --window --shots`, `ui press`, `shot`; or the live playtest window),
propose `old → new` for the user's files, fix, test, add the entry here, then commit as a `design:` + `fix:` pair when
asked.

The first entries (B1–B3) fixed `specs/ff7-ui.md` 2.9 (Use Item and Use Ability) and 2.12 (the shared `menu_frame` and
`description_window`); later ones cover the battle HUD, the run toasts and the battle feed.

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
- **B4. The run toasts jump, show one at a time and are too tall** (reported 2026-10-27). The set was a QUEUE with
  `max_visible = 1`: a leaving toast kept its place in the `VBoxContainer` while it faded, so the next one appeared
  below it and snapped up when it was freed. Each toast had two lines (title, then subtitle) and was 65–95 px tall.
  Wanted: oldest on top, one line each, thinner. **Four is a soft cap (user, 2026-10-27):** more may show; being over
  it only makes the oldest toasts expire faster (2–3×), never removes them at once.
- **B5. Battle feed text hugs the left edge** (reported 2026-10-27). `feed_line.gd`'s slide-in tweened the label to
  x 0, over the line's 12 px content margin, so the text sat at the left edge with twice the space on the right.
- **B6. The Tab floor banner appears in place while only its text slides down** (reported 2026-10-27). `toast.gd`
  slid `%Lines` inside the window; the window itself was placed at once by the stack layout.
- **B7. Entering an event room logs an engine error** (found 2026-10-27 while building `event-items`). `party_strip.gd`
  binds one handler with one optional argument to six run signals; `event_page_shown` sends two, and it fires while
  the strip is still up (the room is entered from the map). Fix: the handler takes a second optional argument.
  Test: `test_explore_hud::test_party_strip_takes_event_pages` (any engine error fails it).
- **B8. Some battle feed lines still hug the left edge** (reported 2026-11-01: "only sometimes"; B5 fixed most of them).
  B5's slide read the label's laid-out x on the slide tween's first step. Most lines are pushed from a tween step,
  and that worked. A line pushed from a **timer** (the battle's presentation pauses) had its new tween stepped in that
  same frame, before the container's deferred sort, so the slide read x 0 and ended there: 0 px left, 24 px right.
  Reproduced by `test_battle_hud::test_feed_line_centred_from_any_step` (`left 0.0, right 24.0` before the fix).
- **B9. A connecting pop-up while the game waits on the server** (asked 2026-11-01). A reusable spinner and a
  pop-up show whenever the player can't go on until the server answers: a server run starting or resuming, a floor
  seed at the stairs (the wait begins when the rest stop ends and the floor really has no seed, `RunController.floor_waiting`,
  not when the seed is first requested behind the rest stop; fixed 2026-11-01), a won run's verification, a run rebuilt after a 1103 conflict. Background work (the action
  queue's uploads, the heartbeat) never shows it. It appears only after the wait has lasted 0.3 s, so a quick answer
  never flashes it, and it blocks clicks while shown.
- **B10. Server status in the bottom left corner** (asked 2026-11-01; a debug aid for now). In server mode, a bright
  green line "Connected: <player> (<player id>)" sits just above the footer's message line. It turns yellow
  ("Offline: <player> (no answer from the server)") while the server isn't answering, and is hidden in local mode.
- **B11. "Connected" in green, but the message line still says "Server: no connection: HttpRequestException"**
  (reported 2026-11-01, in the user's first try of B10). Server mode was set while the server was off, so the resume at
  app start (or Start run) failed and put that line in the footer. The footer keeps its last message until another one
  replaces it, and nothing did once the server came up (or the console's `server <url>` linked again). Fix: after
  `GameMain` shows a server problem, or a link stops answering, the next answer shows "Connected to the server as
  <player>". Test: `test_server_ui::test_server_error_cleared_when_connected`.
- **B12. The resume at app start is retried when the server comes back** (asked 2026-11-01). With the server off at app
  start, the run the server holds only continued after a restart or the console's `server resume`. Now a start-up
  resume that got no answer (or a 5xx) is tried again at the server's first answer, if the player is still on the
  title with no run playing; starting a new run, or local mode, drops the retry. While the server isn't answering, the
  heartbeat runs every 5 s (`offline_heartbeat_seconds`) instead of 30, so its return is seen soon.

Enterprise mapping: N/A: these are client-only presentation fixes. No backend component, run log, hash or replay is
involved. B9 and B10 only show the state of the client's existing calls (no new request, field or header); they are the
player-facing side of the offline-first retries in `server-authority` 2.1–2.4.

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

### Fix for B4 (run toasts; the battle feed keeps its own line scene)
| File | Change |
|---|---|
| `game/ui/ui_toast_set.gd` (system) | `overflow_seconds` (STACK only): `0` keeps `max_visible` a hard cap (the battle feed); above `0` it is a soft cap. |
| `game/ui/ui_toast_host.gd` (system) | Hard cap: a toast pushed out leaves at once. Soft cap: each toast over the cap gets an early expiry, the oldest first, chained one `overflow_seconds` after the other (a burst keeps the pace). Either way it leaves through its entry's `leave_fast()` when it has one (else `leave()`). |
| `run_toasts.tres` | `stack` QUEUE → STACK, `max_visible` `1` → `4`, `overflow_seconds` `0.25`. |
| `run_toasts.tscn` / `run_toasts.gd` | `Toasts` `VBoxContainer` → `Control`; the host lays the toasts out top-down, centred, `separation` 6, and each glides to its place at `glide_speed` 600 px/s, so the ones below a leaving toast wait for its fade and then glide up (no snap). A new toast starts at its place. |
| `toast.tscn` | `Lines` `VBoxContainer` → `HBoxContainer` (kicker, title and subtitle on one line, separation 12, centred vertically); the subtitle no longer wraps (its 520 px minimum width removed). |
| `toast.gd` | `leave_fast()`: the fade at `pushed_fade_speed` (3×) speed; the slide-in ends where the layout put the line (it used to end at y 0, top-aligning the text). |
| `ui_theme.tres` | `toast` window `padding` `10` → `4`; `ToastTitle` font size `28` → `22`. A toast is about 44 px tall. |

### Fix for B5
| File | Change |
|---|---|
| `feed_line.gd` | The slide-in starts on the tween's first step (the line laid out) and ends at the label's laid-out x, not 0 (as `toast.gd` in B4). |
| `feed_line.tscn` | `Text.horizontal_alignment` left → centre. |

### Fix for B6 (every run toast, not only the floor one)
| File | Change |
|---|---|
| `toast.gd` | A `drop` offset tweened from −`slide_distance` (40) to 0 over `slide_seconds` replaces the `%Lines` slide. |
| `run_toasts.gd` | The layout keeps each toast's glided place in a meta and sets `position.y` = place + `drop`, so the window and its text come down together. |

### Fix for B8
| File | Change |
|---|---|
| `feed_line.gd` | The slide is an offset (`_slide`, tweened −`slide_distance` → 0 with `tween_method`) added to the label's x on the line's `sort_children` signal, after every layout pass; each step calls `queue_sort()`. The slide no longer reads a laid-out x once, so it can't end at a place read before layout. |

### Fix for B9 and B10
| File | Change |
|---|---|
| `game/ui/ui_spinner.gd` (system, new) | `UISpinner`: a spinning arc drawn in code (`color`, `track_color`, `thickness`, `arc_degrees`, `speed` turns/s, real time), reusable in any screen that waits. |
| `game/server_link.gd` (system) | B12: the heartbeat timer's period is `offline_heartbeat_seconds` (5) while requests get no answer, `heartbeat_seconds` (30) again after one. `begin_wait(key, text)` / `end_wait(key)` / `waiting_text()` (the newest wait shows) and `waiting_changed(text)`. Keys with a `/` belong to the linked run and end when another run is linked, so an abandoned run's retries never keep the pop-up up. Waits: `floor/<run>/<n>` around `_fetch_floor`, `end/<run>` around the win's drain, end and poll, `rebuild/<run>` around a conflict's rebuild. Texts `wait_floor_text`, `wait_end_text`, `wait_rebuild_text`. `connected()` (signed in and the last request got an answer, any HTTP status), `player_id` (from `DevTokenResponse.playerId`), `connection_changed`. |
| `game/game_main.gd` (system) | B12: `_resume_pending` (the start-up resume's `GET /runs/current` failed and is retryable); at the current link's next answer, on the title with no active run, `resume_server_run()` again (once); cleared by `start_run` in server mode and by local mode. B11: `_server_problem_shown` (set by a failed start or resume, or a link that stops answering); the current link's next answer shows `reconnected_text` "Connected to the server as %s" (`@export`) on the message line. `server_changed(link)` from `use_server`; waits `start` around `POST /runs` and `resume` around the resume at app start (`wait_start_text`, `wait_resume_text`, `@export`). |
| `godot_gas/tag_registry.tres` | New tag `UI.Slot.Overlay` (`sync_tags` regenerated `gameplay_tags.gd`). |
| `layout.tscn` | New last child `Overlay` (`MarginContainer`, full rect, mouse ignored, `UIExtensionPoint` slot `UI.Slot.Overlay`): above every layer stack and the footer. |
| `ui_policy.tres` | Two always-on extensions in `UI.Slot.Overlay`: `server_status.tscn` (order 0) and `connecting_popup.tscn` (order 1, on top). |
| `connecting_popup.tscn` / `.gd` (new) | `Popup` (hidden): a 50% black dim that stops clicks, and a centred theme window (360 px min) with a 36 px `UISpinner` and the wait's text. It follows `GameMain.server_changed` and `ServerLink.waiting_changed`, and shows after `show_after_seconds` (0.3, real time). |
| `server_status.tscn` / `.gd` (new) | A 16 px label with a black outline, bottom left (x 8, y −54 to −32, above the footer). `connected_format` "Connected: %s (%s)" in `connected_color` (0.25, 1, 0.35); before the first answer `waiting_format`, after a lost answer `offline_format`, both in `offline_color` (1, 0.8, 0.25). Hidden with no link. |

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
- **B4:** `test_ff7_ui::test_toast_stack_soft_cap` (system, on the test clock): 8 at once over a soft cap of 4 all
  show, then one leaves every `overflow_seconds`, oldest first, down to the newest 4. `test_explore_hud::
  test_run_toasts_stack_four`: four toasts at once, one thin line each (< 50 px), each below the one before; a fifth
  shows too, the oldest stays until `overflow_seconds`, then fades in under 200 ms (a normal fade is 300) and four
  remain; the next one glides up (not a snap) and reaches the top.
- **B4, filmed** (window run, a throwaway command logging each toast's y and alpha every 50 ms): 7 toasts 100 ms apart
  expire early at 0.70, 0.95 and 1.20 s; 8 in one frame leave at 0.38, 0.62, 0.88 and 1.13 s, down to 4; each fast
  fade takes about 0.1 s and the glide up about 0.1 s, before the next fade starts. `test_run_toasts_cover_keys_and_chests` now expects the key and
  chest toasts together.
- **B5:** `test_battle_hud::test_feed_line_centred`: after the slide-in, a feed line's text has equal space left and
  right (more than 4 px each).
- **B6:** `test_explore_hud::test_floor_toast_slides_as_one`: holding Tab, the floor banner starts above its place and
  comes down to it while its text keeps the same y inside it. Filmed: the banner goes −36.8 → 0 over 0.3 s with alpha
  0 → 1, its text at y 8 throughout.
- **B8:** `test_battle_hud::test_feed_line_centred_from_any_step` pushes lines from a tween step, a timer and a process
  step; each one's text has equal space left and right after the slide-in.
- **B9:** `test_server_mode::test_server_link_waits` (newest wait shows, run waits end on a new link, each change
  once) and `test_stairs_wait_shows_while_offline` (the stairs wait while the seed has no answer, then stop).
  `test_server_ui::test_connecting_popup` (demo policy, fake bridge): hidden in local mode, not shown at once, shown
  after 0.45 s with the wait's text, a spinner, and clicks stopped; gone when the wait ends.
- **B10:** `test_server_mode::test_server_link_connection` (connected after an answer, with the player id; not
  connected with no answer; again after one) and `test_server_ui::test_server_status_line` ("Connected: tester (p)" in
  the green, bottom left; "Offline: …" with no answer; hidden again in local mode).
- **B11:** `test_server_ui::test_server_error_cleared_when_connected`: a failed resume puts "Server: no connection…"
  on the message line, and a new link's first answer replaces it with "Connected to the server as tester".
- **B12:** `test_server_ui::test_resume_retried_when_connected`: offline at start (no resume reaches the server, the
  heartbeat at 5 s), then the server answers: the resume is tried once (`GET /runs/current`), the heartbeat is back at
  30 s, and a later drop and return doesn't retry again (the server had no run).
- **B9, B10 visual check:** a window run with a throwaway command linking the fake bridge; screenshots in
  `H:\claudeOutShots\2026-11-01 server-overlay\` (title with the green line; the pop-up over the title menu).
- **Unchanged:** `test_demo_ui_policy`, the existing explore HUD and gear tests, and `validate_content.tscn`
  (`UIPolicyCheck`) still pass.
- **Visual check:** the window run from section 1 again, with new screenshots of Use Item (Potion hovered), Use Ability,
  Equipment and Status in `H:\claudeOutShots\2026-10-27 ui-fixes\`.
- Both suites (`tools/godot_tests.sh`, `tools/dotnet_test.sh`) pass.
