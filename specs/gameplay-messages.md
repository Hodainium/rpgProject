# Spec: gameplay-messages (slice 1d, step D3)

Status: 🔨 Implemented, awaiting your review (M1–M5 approved as recommended, 2026-10-26) · Roadmap: inside 1d
`playable-demo`, after D2 `ui-framework`, before E (M5) ·
Date: 2026-10-26
Model: Lyra's **Gameplay Message Subsystem** (the `GameplayMessageRouter` plugin): typed payloads broadcast on
gameplay-tag channels; listeners register for a channel with an exact or partial (child channels) match and never
know who sent the message. Builds on `specs/ui-framework.md` (screens listen instead of being called),
`specs/dev-tools.md` (console parity), `specs/combat-replay-core.md` (determinism).

## 1. Purpose & enterprise mapping
Before this step, game events reached the screens through a tangle of direct links: `RunController.message` and
`GameMain.show_message` carried plain strings ("Warrior reaches level 3"), the battle panel turned a dozen `Battle`
signals into message lines itself, the sound board hooked run and battle signals one by one, and nothing else (dev
tools, a future analytics feed, a kill feed, achievements) could hear "a level was gained" or "an enemy was broken"
without another hand-wired signal.

This step adds one **message bus** in the Lyra mould:
- **Senders broadcast** a typed message on a channel tag (`Message.Run.LevelUp`) and move on; they don't know who
  listens.
- **Listeners register** for a channel, exact or partial (`Message.Battle` hears every battle message), from anywhere:
  a screen, the sound board, the dev console. A listener tied to a node goes away with it.
- **Two general payloads**, as Lyra ships: a **verb message** (who did what to whom, how much, with which tags) and a
  **notification** (a line for the player). New payload types are small scripts.
- **The existing string messages moved onto it:** the message line, the battle call-outs (BROKEN!, ONE MORE!),
  level-ups, drops and refusals are messages, so a new screen (a kill feed, a toast stack) is a listener plus a
  policy entry.

**Enterprise mapping: none at runtime** (client-only, local mode; no service, queue, broker or cache). Indirect: the
verb messages are the client-side shape of the **player-behaviour events** of slice 4b (most used moves, items picked
up, event decisions). Those events stay **server-derived from the verified run log** (the authority model); the bus
is presentation and dev tooling only, never a source of truth, never uploaded in this step.

Out of scope: network replication of messages, a persistent message log, analytics upload, async/deferred delivery,
Unreal's struct reflection (GDScript scripts stand in for USTRUCTs).

## 2. Sequence flow
Client only; no server.

### 2.1 Broadcast and delivery (Lyra semantics)
```
sender: GameplayMessages.broadcast(&"Message.Battle.Broken", VerbMessage.make(&"Verb.Break", "P1", "E2", 0, tags))
  router (autoload GameplayMessages, script class GameplayMessageRouter, M1):
    channel = Message.Battle.Broken; who hears it is fixed when the broadcast starts:
    1. EXACT listeners of Message.Battle.Broken, in registration order
    2. PARTIAL listeners of Message.Battle.Broken, then of Message.Battle, then of Message (child first, up the tree)
    each listener: payload type check (M2): a listener that asked for VerbMessage and gets another type is skipped with
                   a warning naming the channel and both types (Lyra logs the same mismatch)
                   callback(channel, message)
    listeners added during a broadcast hear the next broadcast, not this one; removed ones stop at once
    a listener whose owner node was freed (or queued for deletion), or whose callable is no longer valid, is
    dropped silently
  returns how many listeners heard it
```

### 2.2 Who sends (M3, M4)
```
RunController (game/)        → Message.Run.* verbs (start, floors, level-ups, takes and buys, drops, event choices, end)
                                and Message.Notification for the lines it used to emit as `message` (level-ups, drops,
                                warnings tagged Notification.Warning, runner errors tagged Notification.Error).
                                `RunController.message` is gone; a runner error also emits the new
                                `stopped(error)` signal, which GameMain uses to show the end screen.
GameMain.show_message(text)  → broadcasts Message.Notification ("" clears the line); `message_shown` and
                                `last_message` are gone
BattleMessages (game/, M3)   → a client-only bridge GameMain creates on each `run.battle_started` and drops on
                                `battle_finished`: Battle signals → Message.Battle.* verbs, with the units' display
                                names in `data`. Never created by the replay runner, trace runner or verifier, and
                                combat/ is unchanged, so the battle kernel never broadcasts
GameMain.refuse(text, who, data) → a refused player action (2026-10-26 follow-up): the line on Message.Notification
                                and Message.Ui.Refused (Verb.Refuse, data + "text"). The battle, pickup and field
                                panels refuse only through it; no screen plays the Refused sound itself
```

### 2.3 Who listens
```
message_line (UI footer)     → Message.Notification (exact, NotificationMessage): shows the text; and
                                Message.Battle.Ended (exact): "Battle: Victory" (`battle_end_format`)
floor_card (HUD overlay)     → Message.Run.FloorEntered: the floor's title card
battle_callouts (new panel,  → Message.Battle (partial, VerbMessage): BROKEN!, ONE MORE!, phases, resisted, knocked
  UI.Slot.Hud.Overlay,          down, turn lost, ult unleashed, as exported formats; each line shows for `seconds`
  order 10, while Battle)       (2, real time), at most `max_lines` (3) at once
sound_board                  → Message.Battle.Started → BattleStart, Message.Battle.UnitDied → Death,
                                Message.Run.ItemTaken → Item, Message.Ui.Refused → Refused (its battle_started,
                                unit_died and action_rejected hooks are gone; Move stays on room_entered, deferred,
                                because a room that starts a battle plays BattleStart instead)
dev console `messages`       → any channel (partial), printed and collected for script runs (2.4)
```
The battle panel keeps its stats line, the `%Turn` hit marks, its buttons and its "ult at the next chance" line.
**Rule of thumb (2026-10-26 review):** messages are for things that *happen* (call-outs, lines, sounds, title cards);
panels that redraw *state* (party, map, pickups, events, the room view, the stats line) stay on the run's and battle's
signals and read the state, as Lyra's widgets do. Messages carry no run id: fine with one run per client; a second
live `RunController` beside the shown game would need one in `data`.

### 2.4 Dev tools (console parity)
`messages on [channel]` logs every message under a channel (default `Message`; it must start with `Message`) to the
console overlay and stdout (so the script runner's output) as
`[msg] Message.Battle.Broken Verb.Break P1→E2 0 [Hit.Weakness]`; `messages off`; `messages last [n]` (default 10)
prints the last n; `messages` alone says whether it is on and how many lines are kept (at most 1000). The script
runner's JSON gets `"messages"` (the kept lines) whenever any were logged. Tab completion offers `on/off/last` and
every channel and parent channel.

## 3. Data contracts
**No wire contracts change**: no `Rpg.Contracts` record, RabbitMQ queue, Redpanda topic or Redis key (N/A,
client-only). The contracts are Godot types (system, `game/messages/`) and channel tags.

### 3.1 Types (system, `game/messages/`)
| Type | Kind | API |
|---|---|---|
| `GameplayMessageRouter` | the autoload script (`game/messages/gameplay_messages.gd`), autoload name `GameplayMessages` (M1) | `broadcast(channel: StringName, message: GameplayMessage) -> int` (listeners reached); `listen(channel, callback: Callable, mode: Match = EXACT, payload_type: Script = null, owner: Object = null) -> GameplayMessageHandle` (`mode`, since `match` is a GDScript keyword; with no `owner`, the callback's object is the owner when it is a Node, so a screen's lambdas go away with the screen); `enum Match { EXACT, PARTIAL }`; `listener_count(channel) -> int` (tests, dev); `unregister(entry)` (used by the handle); channel constants (`NOTIFICATION`, `RUN_*`, `BATTLE_*`, `UI_REFUSED`) and the lists `CHANNELS`, `VERBS`, `NOTIFICATION_TAGS` (read by the tag checkpoint) |
| `GameplayMessageHandle` | `RefCounted` | `unregister()` (twice is harmless); `is_valid() -> bool` |
| `GameplayMessage` | `RefCounted` (base of every payload) | `describe() -> String` (one line for the dev log) |
| `VerbMessage` | `GameplayMessage` (Lyra's `FLyraVerbMessage`) | `verb: StringName` (`Verb.*`), `instigator: StringName`, `target: StringName` (unit ids `P1`/`E2`, member slots `slot:2`, or content ids), `magnitude: int` (×100 when a number of the game), `tags: Array[StringName]`, `data: Dictionary` (small extras, read-only by convention); `static make(verb, instigator, target, magnitude = 0, tags = [], data = {})`; `describe()` = `Verb.Break P1→E2 0 [Hit.Weakness]` |
| `NotificationMessage` | `GameplayMessage` (Lyra's `FLyraNotificationMessage`) | `text: String`, `tags: Array[StringName]` (`Notification.Warning`, `Notification.Error`), `seconds: float` (how long a toast may show; 0 = until replaced); `static make(text, tags = [], seconds = 0.0)` |
| `BattleMessages` | `RefCounted` (`game/messages/battle_messages.gd`) | `attach(battle, encounter_id, router)`: connects to the battle's signals and broadcasts `Message.Battle.Started` |

Rules (checked by tests where they can be):
- **Messages are presentation and tooling.** No rule of the game (combat, run, content) ever listens; a listener never
  changes run or battle state. Payloads are built from state, never handed back into it.
- **The battle kernel never broadcasts** (M3): combat/ is unchanged; the bridge reads `Battle` signals the client
  already gets.
- Delivery is synchronous and ordered (2.1), so dev logs and tests are deterministic.
- Payloads are fresh objects per broadcast; listeners must not keep and mutate them for others.

### 3.2 Channels and verbs (your tag registry; added through `sync_tags --add-missing`, 46 tags)
| Channel | Payload | Sent when |
|---|---|---|
| `Message.Notification` | Notification | any line for the player (`GameMain.show_message`, run level-ups, drops, warnings, runner errors) |
| `Message.Run.Started` | Verb (`Verb.Start`, target run structure id; data `sandbox` for a sandbox) | run start |
| `Message.Run.Ended` | Verb (`Verb.Win` / `Verb.Lose`, target run structure id, data `status`; `Verb.Stop` with data `error` on a runner error) | run end |
| `Message.Run.FloorEntered` | Verb (`Verb.Enter`, target chapter id, magnitude the floor number from 1) | a floor starts |
| `Message.Run.LevelUp` | Verb (`Verb.LevelUp`, target `slot:N`, magnitude new level, data `targetName`) | each level gained |
| `Message.Run.ItemTaken` | Verb (`Verb.Take` / `Verb.Buy`, instigator `slot:N`, target item or equipment id, magnitude price in coins, tags its tags, data `targetName` and `priceItem` for a curse price) | pickup or purchase |
| `Message.Run.ItemDropped` | Verb (`Verb.Drop`, instigator enemy id, target item id, tags item tags, data names) | an enemy drop |
| `Message.Run.Choice` | Verb (`Verb.Choose`, target event id, magnitude choice index, data `page`) | an event choice |
| `Message.Battle.Started`, `Message.Battle.Ended` | Verb (`Verb.Start`, `Verb.Win` / `Verb.Lose`, target encounter id; Ended data `outcome`) | battle start, end |
| `Message.Battle.Damage` | Verb (`Verb.Damage`, instigator → target unit ids, magnitude ×100, tags hit tags) | each hit |
| `Message.Battle.Broken` (`Verb.Break`, breaker → broken), `.Recovered` (`Verb.Recover`), `.Downed` (`Verb.Down`), `.OneMore` (`Verb.OneMore`), `.Interrupt` (`Verb.Interrupt`, tags the ult's ability tag, data `abilityName` from `AbilityName`), `.Phase` (`Verb.Phase`, magnitude the phase entered from 1), `.Resisted` (`Verb.Resist`, data `status`), `.Drained` (`Verb.Drain`, magnitude ×100), `.TurnSkipped` (`Verb.Skip`), `.UnitDied` (`Verb.Die`) | Verb; every battle verb carries `data.instigatorName` / `data.targetName` (display names) for the unit ids it names | the matching `Battle` signal |
| `Message.Ui.Refused` | Verb (`Verb.Refuse`, data `reason`, plus `detail` from the battle panel) | a screen's action was refused (sound) |

Verbs (`Verb.*`): Start, Win, Lose, Stop, Enter, LevelUp, Take, Buy, Drop, Choose, Damage, Break, Recover, Down,
OneMore, Interrupt, Phase, Resist, Drain, Skip, Die, Refuse. Notification tags: `Notification.Warning`,
`Notification.Error`.

### 3.3 Edits as made
| File | Change |
|---|---|
| `project.godot` (system) | autoload `GameplayMessages` |
| `game/messages/*` (system, new) | the router, handle, payloads and `BattleMessages` |
| `game/run_controller.gd` (system) | `message` signal removed, `stopped(error)` added; `_send` / `_notify` / `_send_taken` broadcast the 3.2 run channels |
| `game/game_main.gd` (system) | `message_shown` and `last_message` removed; `show_message` broadcasts; `stopped` → end screen; `battle_messages` bridge per battle |
| `game/dev/dev_console.gd`, `dev.gd`, `commands/messages.gd`, `game/tools/dev_run.gd` (system) | the `messages` command, its log, overlay printing and the runner's `"messages"` |
| `game/tools/sync_tags.gd` (system) | also checks the message channels, verbs and notification tags |
| `presentation/demo/ui/message_line.gd` (yours) | listens to `Message.Notification` instead of `main.message_shown` |
| `presentation/demo/ui/battle_panel.gd` (yours) | the call-outs left (to `battle_callouts`); a refused pick broadcasts `Message.Ui.Refused` |
| `presentation/demo/ui/pickup_panel.gd`, `field_panel.gd` (yours) | refusals through `GameMain.refuse` (the field panel's failed field spell now plays Refused too); no own Refused sound; the field panel keeps Item for wearing and taking off armor |
| `presentation/demo/ui/floor_card.gd` (yours) | shows on `Message.Run.FloorEntered` instead of the run's `floor_entered` |
| `game/game_main.gd` (system, follow-up) | `refuse(text, instigator, data)` |
| `presentation/demo/sound_board.gd` (yours) | Death, Item, Refused from messages instead of signal hooks |
| `presentation/demo/ui/battle_callouts.tscn/.gd` (yours, new) + one `ui_policy.tres` entry | the call-out panel |
| `godot_gas/tag_registry.tres`, `gameplay_tags.gd` (yours, through `sync_tags --add-missing`) | the 46 tags of 3.2 |

## 4. Failure modes
Server failure scenarios (root `CLAUDE.md` 1–7): **none apply** (no server, no wire change). What this step
protects: **replays and run hashes never depend on messages.**
| Failure | Behaviour | Test |
|---|---|---|
| A listener changes battle or run state | Forbidden by rule; the battle kernel never broadcasts, so replay can't be affected; run hashes are compared with and without listeners | `test_messages_run_hash_unchanged`, `test_messages_battle_bridge` (same final hash with and without the bridge) |
| The verifier or replay runner broadcasts | Can't: the bridge is attached only by `GameMain`; `replay_main` / `trace_main` never create it | `test_replay_sends_no_messages` (a recorded and replayed fixture battle; a partial `Message` listener hears nothing) |
| Listener's owner freed without unregistering | Dropped at the next broadcast or count; no error | `test_messages_owner_freed`, `test_messages_ui_panel_listens` |
| Payload type mismatch | Listener skipped, warning names channel and both types | `test_messages_payload_type` |
| Listener registers or unregisters during a broadcast | New ones from the next broadcast; removed ones at once | `test_messages_reentrant` |
| Broadcast on an unregistered channel tag | Delivered anyway (tags are names); the tag checkpoint reports the code's channels missing | `sync_tags` system tags |
| No listeners (headless reports, verifier) | One dictionary check per broadcast | — |

## 5. Observability
N/A: client-only, no service. Local signals: the `messages` console command and the script runner's `"messages"`
output. Later (slice 4b) server-side analytics come from the verified run log, not from this bus.

## 6. Test plan (as built: 11 tests; the suite was 326, 330 with the runner fix below)
System tests in `tests/game/test_gameplay_messages.gd` (fixtures and code-built listeners only):
- `test_messages_exact_and_partial`: exact hears only its channel; partial hears children; delivery order exact →
  partial child-first up the tree; registration order inside a level.
- `test_messages_payload_type`, `test_messages_owner_freed` (explicit owner, and a node's method as callback),
  `test_messages_unregister`, `test_messages_reentrant`.
- `test_messages_run_flow`: the fixture scripted run (seed 7, `RunPlayer`, the bridge on each battle) with a partial
  `Message` listener: Run.Started, Run.FloorEntered first, Run.Ended last with the outcome verb; a battle is
  Started → Damage → Ended; counts match the run log (battles, takes and buys, choices, floors); LevelUp when the
  run has an XP curve.
- `test_messages_battle_bridge`: the item-pass break fixture: the opening breaks `P1→E2`, `P1→E1` with names, one
  Broken / OneMore message per signal, hit tags on damage, Started first and a won Ended last, same final hash.
- `test_messages_run_hash_unchanged`, `test_replay_sends_no_messages`, `test_messages_refuse` (the line, then
  `Message.Ui.Refused` with who, why and the text).
- `test_messages_ui_panel_listens`: a probe panel (`tests/game/ui_probe_message.gd`) in a code-built policy shows
  `show_message` text; its listener leaves with the game.
- `tests/game/test_dev_console.gd`: `test_tool_parity` (the `messages` command) and `test_console_messages` (on,
  run and battle lines logged, `last`, `off`, a non-`Message` channel refused).
Golden vectors: none; `run_scripted.json` and the combat goldens are byte-identical.
Mutation check (2026-10-26): with the router's "removed during a broadcast" guard disabled,
`test_messages_reentrant` fails (`expected ["first"], got ["first", "removed"]`); restored, it passes.
Test runner gap found here and fixed (2026-10-26, `specs/combat-replay-core.md` "Test runner"): a runtime script
error inside a test aborted it without a failure, so it reported `ok`. The runner now fails a test on any script or
engine error; the bug that slipped through while writing these tests (`result["status"]` on a replay result) now
fails `test_replay_sends_no_messages` with the error and its line.

Window check (2026-10-26, `H:\claudeOutShots\2026-10-26 gameplay-messages\`): menu, floor card, battle start, the
footer line after a battle (level-ups), "Pyromancer unleashes Supernova!", then stacked with "Lich enters phase 2!",
after the lich; driven by `dev_run --window --manual` with `messages on` and a throwaway `stepuntil <channel>`
command. A BROKEN! shot wasn't reached with Auto's first-ability picks; breaks are covered by
`test_messages_battle_bridge`.

Implementation order (followed): (1) router, payloads, handle, tests; (2) RunController and GameMain broadcasts, the
battle bridge, the `messages` command; (3) your screens move to listening (shown `old → new`), the call-out panel,
the policy entry; (4) `message_shown` / `RunController.message` removed; (5) tags via `sync_tags`, shots.

## 7. Decisions (approved as recommended by the user, 2026-10-26)
- **M1 a global autoload `GameplayMessages`** (recommended: like Lyra's game-instance subsystem, reachable from the
  run, the UI, the sound board and the console without wiring). Alternative: a node owned by `GameMain` (listeners
  need a path to it; dev tools without a game can't listen).
- **M2 typed payloads** (`GameplayMessage` scripts, listener type check; recommended, Lyra's typed structs).
  Alternative: plain `Dictionary` payloads (no check, typos found late).
- **M3 battle messages through a client-only bridge** (recommended: `combat/` unchanged, the verifier never
  broadcasts, replay can't be touched). Alternative: `Battle` broadcasts itself (simpler wiring, but the kernel and
  the verifier would carry the bus).
- **M4 migrate the existing string messages and call-outs in this step** (recommended: one way to tell the player
  something). Alternative: add the bus only and migrate later.
- **M5 placement: 1d step D3, before the export (E)** (recommended). Alternative: its own slice after 1d.
