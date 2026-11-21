# Spec: ui-feedback: feedback on the thing involved, no white message line

Status: **spec written and reviewed 2026-11-19 (answers in section 7); slice 5b5, next after 5b4 `class-pick`.** Follows the class-pick playtest (user, 2026-11-19): "I don't want any of that
white text in the bottom left. The green and yellow server status text is all I need." Every message the white line showed was
reviewed one by one on https://claude.ai/artifact/8Fzn5KWjwUmnknGujVFC99 and **all 27 proposals were accepted** (section 2.4). Already
done before this spec (PR #71): the "Connected to the server as" and "Connecting…" lines are gone and the server status line sits alone
in the bottom-left corner (green connected, yellow offline).

Design rule this spec adds to `ff7-ui` 2.12: **a refusal shows on the widget it is about** (a red flash, a shake) with the refused
sound; a rare, important problem is a one-button dialog; nothing writes a line of text at the bottom of the screen.

## 1. Purpose & enterprise mapping

The player learns why an action was refused by looking at the thing involved (the SP bar, the equipment slot, the Gold counter, the room
on the map), the way a game shows it, instead of reading a debug-like line in the corner. Text that other UI already says (toasts, the
connecting pop-up, a screen's own line) is not repeated.

Backend components used: **none.** Presentation only (Godot `game/ui/`, `presentation/demo/ui/`): no endpoint, record, queue, topic,
Redis key or metric. Server refusals keep their codes; only where the client shows them changes (2.4, "Dialogs").

## 2. Sequence flow

### 2.1 A refusal, today and after

```
today:   a screen → GameMain.refuse(text, instigator, data)
            → show_message(text) → Message.Notification → the message line (white text, bottom left)
            → Message.Ui.Refused {Verb.Refuse, instigator, data + text} → the sound board plays "Refused"
after:   a screen → GameMain.refuse(text, instigator, data)       (data now names the widget: 2.2)
            → Message.Ui.Refused {..., data: {target, ...}, text} → the sound board plays "Refused" (unchanged)
                                                                → the screen that owns `target` flashes it (UIFlash, 2.3)
            → the text goes to the dev console in debug builds (`messages on` logs it), never on screen
```

`GameMain.show_message(text)` stops having an on-screen listener: the message line leaves the UI policy (2.5). `Message.Notification`
is still broadcast (the dev console's `messages` logs it; tests read it), so the run layer and its replays are unchanged.

### 2.2 What a refusal names (`data.target`)

| `target` | Extra data | Flashed by |
|---|---|---|
| `room` | `cell` | the big map's and the minimap's tile for that cell (`map_cell`) |
| `lock` | `cell` or `chest` serial | the lock on that tile, or the chest's Open row (pickup panel) |
| `keys` | | the Keys counter (explore menu) |
| `gold` | | the Gold counter (explore menu) |
| `gold` + `placement` | | the item's price on its pickup / shop row (built 2026-11-20: sent with `gold`, not as its own `price` target, so one refusal flashes both) |
| `member` | `slot` | that member's row (party strip, the open panel's member list) |
| `member_items` | `slot` | that member's item slots (party strip, gear and gift screens) |
| `gear_slot` | `slot`, `equipment_slot` | the equipment slot on the gear screen |
| `sp` | `slot` or `unit` | the member's SP bar (party strip outside battle, battle party window in battle) |
| `command` | `ability` | the skill's row in the battle command window |
| `target` | `unit` | the target cursor over that unit |
| `gift` | | the Give-to panel |
| (none) | | nothing flashes; the sound plays (internal guards, 2.4 row 5) |

The run layer's refusals stay plain text (`RunController` returns a String): the **screen** that called it knows which widget the
action was about and fills `target` itself (e.g. the gear screen knows the slot it tried). No refusal text is parsed.

### 2.3 The flash (`UIFlash`, system code in `game/ui/`)

```gdscript
## A refusal's feedback on a Control: a red pulse and a small shake, then back to how it was. Presentation only.
class_name UIFlash extends RefCounted
static func refuse(control: Control, shake: bool = true) -> void   ## the standard refusal
static func pulse(control: Control) -> void                       ## the red pulse only (counters, bars)
```

- The pulse tints `modulate` toward the theme's refusal colour and back, twice, over `flash_ms` (built 2026-11-20: `modulate`, not
  `self_modulate`, so a row or a bar box tints with its children; `self_modulate` only tints a control's own drawing, and the SP bar box
  draws nothing); the shake moves the control a few pixels left and right over the same time and puts it back exactly (the start position
  is read on the tween's first step, after a container placed the control, and restored at the end, and the parent container re-sorts,
  so a re-layout never keeps an offset). Values from the theme: a `UIFlash` type with constants `flash_ms` (default 350),
  `shake_px` (6) and colour `refuse` (the theme's Warning red); a new look goes into the theme, not overrides (ff7-ui 2.12).
- A flash on a control that is already flashing restarts it; a freed control ends it quietly.
- Screens listen with `GameplayMessages.listen(UI_REFUSED, callable, EXACT, VerbMessage, self)` and flash only the targets they own.

### 2.4 The 27 decisions (all accepted, user 2026-11-19)

**Already covered (the line just goes):**

| # | Said today | What already tells the player |
|---|---|---|
| 5 | already taken / already open / no such pickup / not now (internal guards) | the refused sound (no target) |
| 14 | `<item>` used on `<Member>` (field) | the item's effect and sound; the HP / SP bar moves |
| 17 | `<Member>`'s `<ult>` is queued | the ULT button's queued look |
| 18 | `<Member>` reaches level `<n>` | the run toast "Level up" |
| 19 | `<Member>` learned `<skill>` | the run toast "Skill learned" |
| 20 | `<Enemy>` dropped `<item>` | the Give-to panel naming the item (nothing more) |
| 21 | Verifying run… | the connecting pop-up |
| 25 | card screens: a refused buy, open, dust, craft | the screen's own line already shows the same text |

**New feedback (a flash on the widget, with the refused sound):**

| # | Said today | When | Feedback |
|---|---|---|---|
| 1 | can't enter that room now | the big map, a room not reachable | `room`: the tile flashes red and shakes |
| 2 | Locked: you need a key | a locked room or chest with no key | `lock` pulses red + `keys` |
| 3 | the next floor is not open | the stairs before the boss | none: the stairs panel only shows once the floor's boss is beaten (`UI.State.Run.Stairs` needs `boss_cleared`), so the control is never there to press; a refusal from elsewhere (the console) plays the refused sound only |
| 4 | clear the room first | a pickup or chest in a room still fighting | none: the pickup panel and its rows only show in a cleared room (`UI.State.Run.Pickup` needs `cleared`; user, 2026-11-20: "pickup rows shouldn't even be available until the room is cleared", "pickup rows don't need to flash as they won't be visible"); a refusal from elsewhere plays the refused sound only |
| 6 | not enough coins | a shop buy | `gold` + `price` |
| 7 | you can't carry more keys | a key bought at 99 | `keys` |
| 8 | `<Member>` has no free use slot / item slot | take, buy, gift or move to a full member | `member_items` |
| 9 | `<Member>` is dead | a gift or pickup for a dead member | `member` |
| 10 | choose who gets `<item>` first | any other action while a gift waits | `gift`: the Give-to panel shakes |
| 11 | `<Member>` already wears / has nothing in `<slot>` / not in the armor inventory | the gear screen | `gear_slot` (the user's example) |
| 12 | `<Member>` would hold more items than item slots | moving items | `member_items` (the receiver) |
| 13 | `<ability>`: cannot activate now (usually not enough SP) | Use Ability / Use Item outside battle | `sp` (the user's example); an invalid target: `member` |
| 15 | `<reason>`: cannot activate now (not enough SP) | a skill in battle | `sp` on the caster's bar + `command` shakes |
| 16 | `<reason>`: not a valid target | a target the skill can't take | `target`: the cursor shakes over that unit |

"Cannot activate now" covers more than SP (a control status, a cooldown): the screen checks the caster's SP against the ability's cost
(`CostReader`, already used by the SP bar's preview) and flashes `sp` only when SP is short; otherwise `command` (battle) or the
ability's row (field) shakes.

**Dialogs (one button, `UIManager.notify`):**

| # | Said today | Dialog |
|---|---|---|
| 22 | Server: `<error>` (a refused run start, resume or stairs; not 1409, which the class pick shows itself) | the error in plain words (`ServerLink.describe`). Built 2026-11-20: a run start (not 1409, nor 1412, which the connecting pop-up's own dialog shows); stairs refusals stop the run, so they are row 24; a resume or an offline Continue returns its error to the main menu, whose own `%Error` line shows it (no dialog, so it is not said twice) |
| 23 | leaving to the main menu while a won run waits for its verdict | "Your win is being verified. You can leave once it is." |
| 24 | a run stopped on a runner error | the error, before the run-end screen |

**Dev only (the dev console and the log, never on screen):**

| # | Said today |
|---|---|
| 26 | Content problems in `<root>` |
| 27 | unknown run / `RunController` warnings |

**Found at build time (2026-11-20, not in the 27):** the server link's "The server rolled your run back to its last verified checkpoint"
(a 1108) and "The run continues from the server's log" (a 1103 rebuild) are one-button dialogs (`ServerLink.notice` → `GameMain`):
rare, and the player would otherwise find the run moved back with no word.

In debug builds `GameMain.show_message` and `refuse` print their text to the dev console's log (`Dev`); in the player build nothing.

### 2.5 What goes away

- The message line: `panel_message` leaves `presentation/demo/ui/ui_policy.tres`, and `presentation/demo/ui/message_line.tscn/.gd`
  are deleted (the user's files; approved, Q1). The layout's `UI.Slot.Footer` held only the message line and is removed too (Q1).
- The class pick keeps its own message line (in its right column) for its own lines (a failed collection read, a 1409): that is a
  screen's own line, like the card screens', not the bottom-left one.

## 3. Data contracts

### 3.1 C# records, queues, topics, Redis

**N/A: no server change.** Server refusals keep their `ApiErrors` codes; only the client's display changes.

### 3.2 Godot

- `UIFlash` (`game/ui/ui_flash.gd`, 2.3); a `UIFlash` theme type in `presentation/demo/ui/ui_theme.tres` (constants `flash_ms`,
  `shake_px`, colour `refuse`).
- `GameMain.refuse(text, instigator, data)`: unchanged signature; `data.target` and its extras per 2.2; no `show_message` call.
- The `Message.Ui.Refused` payload: `VerbMessage` with `Verb.Refuse`, `instigator`, `extras` = `data` + `text` (unchanged shape; new
  keys only).
- Screens that flash: `big_map`, `map_cell` (minimap), `explore_menu` (Gold, Keys), `stairs` panel, `pickup_panel` (+ its rows),
  `gift_panel`, `gear_screen`, `use_screen`, `party strip`, `battle_party_panel` (SP bar), `command_panel` (rows), the battle target
  cursor.
- Console (tool parity): `ui refused [last]` prints the last refusal's text and target; `ui flash <node name>` plays a flash on a named
  control (to look at it in a window).

## 4. Failure modes

| Case | Behaviour | Test |
|---|---|---|
| A refusal with no `target` | The sound only; nothing flashes; nothing on screen. | `test_ui_feedback` |
| A refusal whose target is on a screen not open | The sound only. | `test_ui_feedback` |
| Two refusals on the same control quickly | The flash restarts; the control ends at its original position and colour. | `test_ui_feedback` |
| A control freed mid-flash | The tween ends; no error. | `test_ui_feedback` |
| Headless (tests, the verifier) | Flashes run on a scripted clock or not at all; nothing in combat, the run, a hash or a replay listens. | `test_ui_feedback` |

Idempotency, retries, dead letters: N/A. Acceptance scenarios of the root `CLAUDE.md`: none (presentation only). No replay, no 2002.

## 5. Observability

**N/A: no server change, no metric.** Debug builds log every refusal's text and target to the dev console.

## 6. Test plan

**`tests/game/test_ui_feedback.gd`** (fixtures, the real UI policy, headless):
- No on-screen listener of `Message.Notification`: the UI policy has no message line; `show_message` draws nothing.
- `UIFlash.refuse` and `pulse`: the control ends at its start position and colour; a restart mid-flash; a freed control.
- One test per row of 2.4 "New feedback": the action is refused, `Message.Ui.Refused` carries the right `target` and extras, and the
  owning screen flashes that control (rows 1, 2, 6, 7, 8, 9, 10, 11, 12, 13, 15, 16); row 4: an uncleared room has no pickup state,
  so no rows show.
- "Cannot activate now": SP short flashes `sp`; a controlled caster with enough SP flashes `command`, not `sp`.
- The three dialogs (rows 22–24) open through `UIManager.notify` with the plain-words text.
- Rows 26–27: the text reaches the dev console's log in a debug build and nothing on screen.
- The refused sound still plays for every refusal (the sound board listener is unchanged).
- Tests that read the message line today (`test_server_ui`, `test_main_menu`, the card UI tests) move to the dialog, the screen's own
  line or `Message.Ui.Refused`.

**Window checks:** a shot per flash (a refused buy, a bad equip, SP short in battle, a locked room) to
`H:\claudeOutShots\<date> ui feedback\`, and a live window for the user's playtest.

**No golden changes:** nothing here touches combat, the run, a hash, a snapshot or the verifier.

## 7. Review answers (user, 2026-11-19)

| # | Question | Answer |
|---|---|---|
| Q1 | Delete `message_line.tscn/.gd` and the layout's empty `UI.Slot.Footer` | Yes, in the build PR (2.5). |
| Q2 | The flash: red, two pulses over 0.35 s, a 6 px shake | Yes, as theme constants (2.3). |
| Q3 | Rows 3 and 4: disable the stairs control until the floor is open, grey the pickup rows in an uncleared room | Superseded at build time (user, 2026-11-20): the rows are not shown at all until the room is cleared, and neither panel flashes; both panels already show only when their action is possible (2.4). |
| Q4 | Roadmap place | 5b5 `ui-feedback`, after 5b4 `class-pick`, before 5b2 `item-cards`. |

Status after review: **ready for `/implement ui-feedback`.**
