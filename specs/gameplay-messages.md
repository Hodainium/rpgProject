# Spec: gameplay-messages (slice 1d, step D3)

Status: 📝 Spec written, awaiting review · Roadmap: inside 1d `playable-demo`, after D2 `ui-framework`, before E (M5) ·
Date: 2026-10-26
Model: Lyra's **Gameplay Message Subsystem** (the `GameplayMessageRouter` plugin): typed payloads broadcast on
gameplay-tag channels; listeners register for a channel with an exact or partial (child channels) match and never
know who sent the message. Builds on `specs/ui-framework.md` (screens listen instead of being called),
`specs/dev-tools.md` (console parity), `specs/combat-replay-core.md` (determinism).

## 1. Purpose & enterprise mapping
Today game events reach the screens through a tangle of direct links: `RunController.message` and
`GameMain.show_message` carry plain strings ("Warrior reaches level 3"), the battle panel turns a dozen `Battle`
signals into message lines itself, the sound board hooks run and battle signals one by one, and nothing else (dev
tools, a future analytics feed, a kill feed, achievements) can hear "a level was gained" or "an enemy was broken"
without another hand-wired signal.

This slice adds one **message bus** in the Lyra mould:
- **Senders broadcast** a typed message on a channel tag (`Message.Run.LevelUp`) and move on; they don't know who
  listens.
- **Listeners register** for a channel, exact or partial (`Message.Battle` hears every battle message), from anywhere:
  a screen, the sound board, the dev console. A listener tied to a node goes away with it.
- **Two general payloads**, as Lyra ships: a **verb message** (who did what to whom, how much, with which tags) and a
  **notification** (a line for the player). New payload types are small scripts.
- **The existing string messages move onto it:** the message line, the battle call-outs (BROKEN!, ONE MORE!), level-ups,
  drops and refusals become messages, so a new screen (a kill feed, a toast stack) is a listener plus a policy entry.

**Enterprise mapping: none at runtime** (client-only, local mode; no service, queue, broker or cache). Indirect: the
verb messages are the client-side shape of the **player-behaviour events** of slice 4b (most used moves, items picked
up, event decisions). Those events stay **server-derived from the verified run log** (the authority model); the bus
is presentation and dev tooling only, never a source of truth, never uploaded in this slice.

Out of scope: network replication of messages, a persistent message log, analytics upload, async/deferred delivery,
Unreal's struct reflection (GDScript scripts stand in for USTRUCTs).

## 2. Sequence flow
Client only; no server.

### 2.1 Broadcast and delivery (Lyra semantics)
```
sender: GameplayMessages.broadcast(&"Message.Battle.Broken", VerbMessage.make(&"Verb.Break", "P1", "E2", 0, tags))
  router (autoload GameplayMessages, M1):
    channel = Message.Battle.Broken
    1. EXACT listeners of Message.Battle.Broken, in registration order
    2. PARTIAL listeners of Message.Battle.Broken, then of Message.Battle, then of Message (child first, up the tree)
    each listener: payload type check (M2): a listener that asked for VerbMessage and gets another type is skipped with
                   a warning naming both (Lyra logs the same mismatch)
                   callback(channel, message)
    listeners added during a broadcast hear the next broadcast, not this one; removed ones stop at once
    a listener whose owner node was freed is dropped silently
```

### 2.2 Who sends (M3, M4)
```
RunController (game/)       → Message.Run.* verbs and Message.Notification lines it emits today as strings
                               (level-ups, drops, refusals); RunController.message stays as a thin alias for one slice
GameMain.show_message(text)  → broadcasts Message.Notification (the UI's message line listens; no more message_shown)
BattleMessages (game/, M3)   → a client-only bridge GameMain attaches to each battle it shows: Battle signals →
                               Message.Battle.* verbs. Never attached in the replay runner, trace runner or
                               verifier, and combat/ is not changed, so the battle kernel never broadcasts
presentation                 → may broadcast its own channels (Message.Ui.*), e.g. a sound cue request
```

### 2.3 Who listens (this slice)
```
message_line (UI footer)     → Message.Notification (exact): shows the text
battle_callouts (new panel,  → Message.Battle (partial): BROKEN!, ONE MORE!, phases, resisted, knocked down, ult
  Hud.Center or Overlay)        unleashed: the strings the battle panel builds today move here as exported formats
sound_board                  → Message.Battle.UnitDied → Death, Message.Run.ItemTaken → Item, Message.Ui.Refused →
                               Refused (its signal hooks for these go away)
dev console `messages`       → any channel (partial), printed or collected for script runs (2.4)
```

### 2.4 Dev tools (console parity)
`messages on [channel]` logs every message under a channel (default `Message`) to the console and the script
runner's output as `[msg] Message.Battle.Broken Verb.Break P1→E2 0 [Hit.Weakness]`; `messages off`; `messages last
[n]` prints the last n. Window and headless scripts can assert on them (`dev_run` JSON gains `"messages"` when on).

## 3. Data contracts
**No wire contracts change**: no `Rpg.Contracts` record, RabbitMQ queue, Redpanda topic or Redis key (N/A,
client-only). The contracts are Godot types (system, `game/messages/`) and channel tags.

### 3.1 Types (system, `game/messages/`)
| Type | Kind | API |
|---|---|---|
| `GameplayMessages` | autoload (`game/messages/gameplay_messages.gd`), M1 | `broadcast(channel: StringName, message: GameplayMessage)`; `listen(channel, callback: Callable, match: Match = EXACT, payload_type: Script = null, owner: Object = null) -> GameplayMessageHandle`; `enum Match { EXACT, PARTIAL }`; `listener_count(channel) -> int` (tests, dev) |
| `GameplayMessageHandle` | `RefCounted` | `unregister()`; `is_valid() -> bool` |
| `GameplayMessage` | `RefCounted` (base of every payload) | `describe() -> String` (one line for the dev log) |
| `VerbMessage` | `GameplayMessage` (Lyra's `FLyraVerbMessage`) | `verb: StringName` (`Verb.*`), `instigator: StringName`, `target: StringName` (unit ids `P1`/`E2`, member slots `slot:2`, or content ids), `magnitude: int` (×100 when a number of the game), `tags: Array[StringName]` (context: hit tags, rarity…), `data: Dictionary` (small extras, read-only by convention); `static make(verb, instigator, target, magnitude = 0, tags = [], data = {})` |
| `NotificationMessage` | `GameplayMessage` (Lyra's `FLyraNotificationMessage`) | `text: String`, `tags: Array[StringName]` (`Notification.Warning`…), `seconds: float` (how long a toast may show; 0 = until replaced) |

Rules (checked by tests where they can be):
- **Messages are presentation and tooling.** No rule of the game (combat, run, content) ever listens; a listener never
  changes run or battle state. Payloads are built from state, never handed back into it.
- **The battle kernel never broadcasts** (M3): combat/ is unchanged; the bridge reads `Battle` signals the client
  already gets.
- Delivery is synchronous and ordered (2.1), so dev logs and tests are deterministic.
- Payloads are fresh objects per broadcast; listeners must not keep and mutate them for others.

### 3.2 Channels and verbs (your tag registry, added through `sync_tags --add-missing` after approval)
| Channel | Payload | Sent when |
|---|---|---|
| `Message.Notification` | Notification | any line for the player (`GameMain.show_message`, run messages) |
| `Message.Run.Started`, `Message.Run.Ended` | Verb (`Verb.Start`, `Verb.Win` / `Verb.Lose` / `Verb.Stop`) | run start, end |
| `Message.Run.FloorEntered` | Verb (`Verb.Enter`, target chapter id, magnitude floor number) | a floor starts |
| `Message.Run.LevelUp` | Verb (`Verb.LevelUp`, target member, magnitude new level) | each level gained |
| `Message.Run.ItemTaken` | Verb (`Verb.Take` / `Verb.Buy`, target item id, magnitude price, tags item tags) | pickup or purchase |
| `Message.Run.ItemDropped` | Verb (`Verb.Drop`, instigator enemy id, target item id) | an enemy drop |
| `Message.Run.Choice` | Verb (`Verb.Choose`, target event id, magnitude choice index) | an event choice |
| `Message.Battle.Started`, `Message.Battle.Ended` | Verb (`Verb.Start`, `Verb.Win` / `Verb.Lose`, target encounter id) | battle start, end |
| `Message.Battle.Damage` | Verb (`Verb.Damage`, instigator → target unit ids, magnitude ×100, tags hit tags) | each hit |
| `Message.Battle.Broken`, `.Recovered`, `.Downed`, `.OneMore`, `.Interrupt`, `.Phase`, `.Resisted`, `.Drained`, `.TurnSkipped`, `.UnitDied` | Verb (matching `Verb.*`) | the matching `Battle` signal |
| `Message.Ui.Refused` | Verb (`Verb.Refuse`, data `reason`) | a screen's action was refused (sound, shake) |

Verbs (`Verb.*`): Start, Win, Lose, Stop, Enter, LevelUp, Take, Buy, Drop, Choose, Damage, Break, Recover, Down,
OneMore, Interrupt, Phase, Resist, Drain, Skip, Die, Refuse.

### 3.3 Edits (each shown `old → new` when made)
| File | Change |
|---|---|
| `game/game_main.gd` (system) | `show_message` broadcasts `Message.Notification`; `message_shown` and `last_message` removed after the message line listens; attaches/detaches `BattleMessages` per battle |
| `game/run_controller.gd` (system) | the `message.emit` sites broadcast Notification plus the Verb of 3.2; `run_started` / floor / take / drop / choose / level / end broadcasts |
| `project.godot` (system) | autoload `GameplayMessages` |
| `presentation/demo/ui/message_line.gd` (yours) | listens to `Message.Notification` instead of `main.message_shown` |
| `presentation/demo/ui/battle_panel.gd` (yours) | its `show_message` call-outs move to the new `battle_callouts` panel (it keeps the stats line and buttons) |
| `presentation/demo/sound_board.gd` (yours) | Death, Item, Refused from messages instead of signal hooks |
| `presentation/demo/ui/battle_callouts.tscn/.gd`, a `ui_policy.tres` entry (yours, new + one edit) | the call-out panel |

## 4. Failure modes
Server failure scenarios (root `CLAUDE.md` 1–7): **none apply** (no server, no wire change). What this slice
protects: **replays and run hashes never depend on messages.**
| Failure | Behaviour | Test |
|---|---|---|
| A listener changes battle or run state | Forbidden by rule; the battle kernel never broadcasts, so replay can't be affected; run hashes are compared with and without listeners | `test_messages_run_hash_unchanged` (fixture scripted run, with a listener on `Message` vs none) |
| The verifier or replay runner broadcasts | Can't: the bridge is attached only by `GameMain`; `replay_main` / `trace_main` never create it | `test_replay_sends_no_messages` (a fixture replay with a partial `Message` listener hears nothing) |
| Listener's owner freed without unregistering | Dropped at the next broadcast; no error | `test_messages_owner_freed` |
| Payload type mismatch | Listener skipped, warning names channel and both types | `test_messages_payload_type` |
| Listener registers or unregisters during a broadcast | New ones from the next broadcast; removed ones at once | `test_messages_reentrant` |
| Broadcast on an unregistered channel tag | Delivered anyway (tags are names); the tag checkpoint reports it missing | `sync_tags` system tags |
| No listeners (headless reports, verifier) | A dictionary lookup per broadcast, nothing else | — |

## 5. Observability
N/A: client-only, no service. Local signals: the `messages` console command and the script runner's `"messages"`
output. Later (slice 4b) server-side analytics come from the verified run log, not from this bus.

## 6. Test plan
System tests in `tests/game/test_gameplay_messages.gd` (fixtures and code-built listeners only):
- `test_messages_exact_and_partial`: exact hears only its channel; partial hears children; delivery order exact →
  partial child-first up the tree; registration order inside a level.
- `test_messages_payload_type`, `test_messages_owner_freed`, `test_messages_unregister`, `test_messages_reentrant`.
- `test_messages_run_flow`: a fixture scripted run (`TestCase.start_run` + scripted battle) with a partial `Message`
  listener records the expected channels in order (Run.Started, Run.FloorEntered, Battle.Started, Battle.Damage…,
  Battle.Ended, Run.LevelUp when the fixture run has an XP curve, Run.ItemTaken, Run.Ended).
- `test_messages_run_hash_unchanged`, `test_replay_sends_no_messages`.
- `test_tool_parity`: `messages` command.
- UI (fixture screens, as `test_ui`): a probe panel listening to `Message.Notification` shows `show_message` text.
Golden vectors: none; `run_scripted.json` and the combat goldens stay byte-identical.
Window check: the step D/D2 screenshot script plus `messages on`, shots of the call-outs, saved to
`H:\claudeOutShots\<date> gameplay-messages\`.

Implementation order: (1) router, payloads, handle, tests; (2) RunController and GameMain broadcasts, the battle
bridge, the `messages` command; (3) your screens move to listening (shown `old → new`), the call-out panel, the policy
entry; (4) remove `message_shown` / `RunController.message` once nothing uses them; (5) tags via `sync_tags`, shots.

## 7. Decisions (to review)
- **M1 a global autoload `GameplayMessages`** (recommended: like Lyra's game-instance subsystem, reachable from the
  run, the UI, the sound board and the console without wiring). Alternative: a node owned by `GameMain` (listeners
  need a path to it; dev tools without a game can't listen).
- **M2 typed payloads** (`GameplayMessage` scripts, listener type check; recommended, Lyra's typed structs).
  Alternative: plain `Dictionary` payloads (no check, typos found late).
- **M3 battle messages through a client-only bridge** (recommended: `combat/` unchanged, the verifier never
  broadcasts, replay can't be touched). Alternative: `Battle` broadcasts itself (simpler wiring, but the kernel and
  the verifier would carry the bus).
- **M4 migrate the existing string messages and call-outs in this slice** (recommended: one way to tell the player
  something). Alternative: add the bus only and migrate later.
- **M5 placement: 1d step D3, before the export (E)** (recommended). Alternative: its own slice after 1d.
