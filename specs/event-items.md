# Spec: event-items (who gets an item from an event or a chest, and its toast)

Status: 🔨 Implemented 2026-10-27, awaiting playtest · Date: 2026-10-27
Builds on `specs/game-skeleton.md` (events, outcomes, the run log), `specs/keys-and-gear.md` (chests),
`specs/ff7-ui.md` 2.2 (run toasts) and `specs/server-authority.md` (run actions). D1, D2 and D5 are the user's
(2026-10-27).

## 1. Purpose & enterprise mapping
Today an item from an event or a chest goes to the first living party member who can hold it. An event item shows no
toast. A chest's toast lists what came out but not who holds it. This spec adds:
- **A recipient on `GiveItem`:** `FIRST` (today, the default), `RANDOM` (a seeded pick among the living members who can
  hold it) or `CHOOSE` (the player picks the member; a new logged run action `give_to`). **Items from a chest are
  always `CHOOSE`** (D5).
- **One "Give to" panel** for both: it names the item and has one button per party member.
- **The item toast for gifts:** once an item has its holder, it shows the same toast as an item-room pickup ("Cleric
  got **Hourglass**! …"). For a chest this comes after the chest's own toast, which still lists everything inside.

Enterprise mapping: `give_to` is a new **in-floor run action**, the same kind as `choose`, `take` and `open_chest`. It
is uploaded as an async quick message in the run's ordered, idempotent action log and checked when the server replays
the run in headless Godot (`server-authority.md` section 0). No server code exists yet (slice 2b). This spec only adds
the action type to the documented list, so the backend picks it up when runs are built. No C# DTO changes: there are
no run DTOs yet.

### Decisions
- **D1 (user): the existing events.** Librarian (both books) and Shady merchant (the trinket): `CHOOSE`. Cursed chest
  event (the one where everyone loses 20% max HP): `RANDOM`.
- **D2 (user): which gifts toast.** Every item given by an outcome: events, encounter rewards (bosses, elites) and
  chests. The toast shows once the item has its holder: at once for `FIRST` and `RANDOM`, after `give_to` for `CHOOSE`.
- **D5 (user): chests always let the player pick.** While a chest opens, every `GiveItem` acts as `CHOOSE`, whatever
  its `recipient`. The chest's toast ("Gilded chest · Hourglass, 3 coins") shows when it opens, as today. Each item's
  toast follows when it gets its holder.
- **D3:** `CHOOSE` is valid in an event choice and in a chest. The validator flags it in encounter rewards and item
  hooks (`give_choose_outside_event`), where no picker can show. `FIRST` stays the default, so existing content and
  run hashes do not change unless content opts in (or a chest gives an item, D5).
- **D4:** `CHOOSE` with exactly one living member who can hold the item gives it at once, with no prompt and no
  `give_to` entry (it still toasts). With none, the item is lost with a warning (as today).

## 2. Sequence flow
All client-side (local mode), in `RunController`:
1. An event choice (`choose(i)`) or a chest (`open_chest(i)`) runs its outcomes, logged as today.
2. `GiveItem` resolves the item as today (fixed, or from the pool: the floor's gift stream, or the chest's own stream),
   then the recipient:
   - `FIRST`: the first living member who can hold it (today).
   - `RANDOM`: the living members who can hold it, by slot, picked with `RunSeeds.rng(run_seed,
     "floor/<n>/recipient/<cell>/<k>")`, where `k` counts the gifts in this choice (0, 1, …). The stream depends only on
     the floor, the cell and the order of outcomes, so a replay draws the same member and no hashed counter is added.
   - `CHOOSE` (and every item in a chest, D5): the item id goes onto the run's pending gifts
     (`state.pending_gifts`, in order), unless D4 applies. The remaining outcomes still run.
3. An item given at once (`FIRST`, `RANDOM`, D4) goes through `_receive_item` and sends `Message.Run.ItemTaken`
   (`Verb.Take`, data `"source": "gift"`) with the holder's name, rarity and description, like a pickup.
4. A chest then sends `Message.Run.ChestOpened` with everything inside, as today. Its pending items are named in that
   list ("Hourglass, 3 coins"); they have no holder yet.
5. If gifts are pending at the end of an event choice, the event stays open. What the choice would have done next (go
   to a page, start an encounter, end the event) is kept in `state.event["after"]` instead of happening.
6. While gifts are pending, the UI state has `UI.State.Run.Gift`. The **Give to** panel shows "Give **<item>** to:",
   the item's description (its name in its rarity colour), and one button per party member (greyed when dead or
   unable to hold it, the reason as a tooltip). It is a screen on the Modal layer (a policy rule on
   `UI.State.Run.Gift`), so it shows over the event panel, the map, or the Use Item menu a chest was opened from.
7. `give_to(slot)`: refused unless a gift is pending and the member can hold it. Otherwise it is logged
   `{"type": "give_to", "floor", "cell", "item", "slot"}`, gives the item, sends its toast (step 3) and pops the gift.
   The next pending gift follows. When none remain, the event's kept step from 5 runs; after a chest the map is free.

While a gift is pending, every other run action (`choose`, travel, `take`, `open_chest`, field actions, `next_floor`,
gear moves) is refused with "choose who gets <item> first".

## 3. Data contracts
- `GiveItem.recipient`: `enum Recipient { FIRST, RANDOM, CHOOSE }`, default `FIRST`. The existing `character` field
  still wins when it is set, except in a chest (D5).
- Run log entry (new type): `{"type": "give_to", "floor": int, "cell": int, "item": String, "slot": int}`.
  `server-authority.md` gains `give_to` in its list of in-floor action types (next to `choose`).
- `RunState.pending_gifts: Array[StringName]` (item ids) and `RunState.event["after"]` (`{"kind": "page" |
  "encounter" | "end", "page": int, "encounter": id}`) hold a decision that is still open. They are not in the run
  hash: the hash is taken between actions, and the items' final holders are hashed through the party lines.
- `UI.State.Run.Gift`: a new UI state tag (tag registry, `sync_tags`).
- No queues, topics or Redis keys.

## 4. Failure modes
- **Illegal `give_to`** (no gift pending, a dead member, a member who can't hold it, an unknown slot) is refused with a
  reason and nothing is logged, like a refused `take`.
- **Replay:** `RANDOM` draws from its own stream, and `CHOOSE` is decided by the logged `give_to`, so replaying the log
  gives the same holders and hash. A tampered `give_to` (an illegal slot) fails like any illegal run action.
- **No holder:** lost with a warning (D4), as today.
- The acceptance scenarios in the root `CLAUDE.md` are server-side and unchanged.

## 5. Observability
N/A: no server yet. `run_summary` counts `give_to` and adds `"giftsGiven"` only when it is above 0, so older
summaries and goldens are unchanged.

## 6. Test plan
System tests on fixtures (events and chests built in memory over fixture items; `tests/fixtures/` gains nothing):
- `RANDOM`: same seed, same member; different cells can pick different members; only members who can hold it.
- `CHOOSE` in an event: the event waits, other actions are refused, an illegal `give_to` is refused and not logged, a
  legal one is logged and gives the item, then the kept step runs (page, encounter and end, each).
- A chest with two items: the chest toast lists both, then two `give_to` steps, each followed by its item toast; a
  `GiveItem` with `FIRST` in a chest still asks (D5).
- D4: one possible holder gives at once, with no `give_to` entry, and toasts.
- The toast: a gift sends `Message.Run.ItemTaken` with the holder's name, rarity and description.
- `UIState` has `UI.State.Run.Gift` while gifts are pending.
- The validator flags `CHOOSE` in an encounter reward (`give_choose_outside_event`) and accepts it in a chest and an
  event (built in memory, like the keys-and-gear validator checks).
- The bots (`RunPlayer`: auto, smart and chaos) give a pending gift to the first member who can hold it, and go back to
  the top of their loop after opening chests when one waits; chaos also tries an illegal `give_to` (`give_nothing`).
- Console command `giveto <slot>` (dev-tools parity), with a test.

Presentation (demo UI policy on fixture content): the Give to panel shows for an event gift and for a chest gift, its
buttons call `give_to`, and the event panel comes back for the kept page. Content tests on `content/`: the three events
have the recipients of D1. A window run takes screenshots of the Librarian's and the Gilded chest's Give to steps and
their toasts.

Goldens: fixture goldens change only if a golden run opens a chest that gives an item (`run_keyed.json`, which opens
fixture chests). If so, it is re-recorded on purpose with the `give_to` entries. Content play reports change wherever
demo events or chests give items, which is expected.

## 7. Files
- System: `game/defs/outcomes/give_item.gd`, `game/run_state.gd`, `game/run_controller.gd`, `game/ui/ui_state.gd`,
  `game/dev/run_player.gd`, `game/dev/content_validator.gd`, `game/dev/commands/giveto.gd` (new), tests.
- Yours (asked before each edit, new files listed):
  - New: `presentation/demo/ui/gift_panel.tscn` and `gift_panel.gd`, built from the shared parts (`action_button`
    entries and the theme).
  - Edited: `presentation/demo/ui/ui_policy.tres` (the gift panel's screen rule), `godot_gas/` tag registry
    (`UI.State.Run.Gift`, added by `sync_tags --add-missing`), and `content/demo/events/librarian.tres`,
    `merchant.tres` and `cursed_chest.tres` (`recipient` only).
- Specs: `server-authority.md` (the new action type), roadmap note.

## 8. As built (2026-10-27)
- Tests: `tests/game/test_event_items.gd` (RANDOM, CHOOSE with page, encounter and end, D4, FIRST toasts, chests D5 and
  the toast order, the validator, the bot), `test_explore_hud::test_gift_panel`, `test_demo_run::
  test_demo_event_recipients`; `test_demo_run::test_demo_events` gives the Librarian's Hourglass with `give_to`;
  `giveto` in the tool parity and autocomplete tests. No golden changed.
- The bot fix above came from the content play test: seed 9 opened a Gilded chest on its map step and then tried to
  walk on in the same step.
- Window run screenshots: the Librarian's Give to panel, and a Gilded chest's toast followed by "Cleric got Last
  Rites!" (`H:\claudeOutShots\2026-10-27 ui-fixes\gift_*.png`).
- Found on the way, fixed under `ui-fixes` B7: the party strip's run-signal handler took one argument, but
  `event_page_shown` sends two, so every event room entered from the map logged an engine error.
