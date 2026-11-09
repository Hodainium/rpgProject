# Spec: unique-events (slice 5d)

Status: **spec written 2026-11-09, decisions confirmed by the user the same day (section 7); implemented together with 5c.** A small client-side slice, next to 5c `card-balance` (it moves the
win-rate gate, so the two retunes are measured together). Found while reviewing slice 5: "items and events should be
obtainable once per run, like Isaac". Builds on `specs/game-skeleton.md` (the floor generator and pools),
`specs/playable-demo.md` (events, `rest_event`) and `specs/run-verify.md` (the run hash covers what decides play).

## 1. Purpose & enterprise mapping

**Purpose.** Make a run feel unrepeated:
1. **An event picked from a chapter's event query appears at most once per run.** Today the pick is a weighted draw from every
   event matching the query, with no memory (`FloorGenerator._resolve_content`), so the same event can open twice on a floor
   and again on later floors.
2. **An item is obtainable once per run on every route.** Pool picks already are (`FloorGenerator.pick_*` skip `held` and
   `seen_items`). The routes that name an item (a fixed placement, an event outcome by id, a chest or a shop slot by id, an
   enemy `drop_item`) do not check, so a second copy can arrive. They now fall back (section 2.3).

**Enterprise mapping.** Client rules only. The server stores nothing new and runs no new code: the run hash already covers what
decides play, and the verifier regenerates every floor from the server's seeds, so a client that ignored the rule would
generate different floors and fail verification (2002) exactly like any other cheated pick. Redis, RabbitMQ, Redpanda and
Postgres are not touched. Metrics: none (a play report line, section 5).

**Acceptance scenarios covered:** 5 (a tampered run, here one that repeats an event, is rejected by replay). The others are
not this slice.

## 2. Sequence flow

### 2.1 Events (the new state)

```
RunState.seen_events: Array[StringName]          event ids placed on any floor so far, in placement order
FloorGenerator._resolve_content (EVENT_QUERY mode):
    candidates = matching(content.events, query) minus pools["seen_events"]
    event      = RunSeeds.pick_weighted(stream, candidates)
    pools["seen_events"].append(event.id)          (so two event rooms of one floor never match either)
    candidates empty  →  the room's content is "none" (an empty room), never an error and never a repeat
RunController._install_floor: state.seen_events.assign(pools["seen_events"])     (like seen_items)
RunController._pools(): "seen_events": state.seen_events.duplicate()
```
**What counts as seen:** placed, not entered. A floor is generated whole, so events can only be unique inside it if placing
marks them (the same rule items follow). An event room the player never opens still spends its event.

**Exempt (fixed by id, on purpose):** `room.event` and a layout cell's `event` (authored scripted rooms) and
`RunStructure.rest_event` (the rest stop between floors repeats by design). They are not drawn from a query, so they are
neither filtered nor recorded. An authored room that names an event is the designer's choice to repeat it.

### 2.2 Hash and compatibility

`events_seen=<ids joined by ,>` joins `RunState.canonical_lines()` **only when not empty** (the same rule as `seen=`/`keys=`),
and `RunSnapshot` gains `seenEvents`. A run with no event rooms hashes exactly as before. Runs that do place query events change
(the later ones draw from a smaller list), so **the committed run goldens may change** (scripted run, keyed run, floor
goldens with several event rooms) and the **balance gate is re-measured**. Per the ownership rules the goldens are re-recorded
only after the user confirms the change is intended, never by editing content. Snapshot version stays 1: `seenEvents` is read
with a default of `[]`, so older saves and server checkpoints still restore.

### 2.3 Items on routes that name them

A named item the run already holds or has seen (`held` or `seen_items`) is **replaced by a food item, as Isaac drops a heart or a
coin instead of a repeated pickup** (decided 2026-11-09): one pick from the `Pool.Food` items, on a stream of its own
(`floor/<n>/repeat/<k>`), **ignoring held and seen** (food is a consumable and may repeat; the pool is all core, so it is never
empty). If the content has no food item at all the run's `fallback_item` is used. A fixed placement can therefore never hand a
second copy. The three sites:
- generation: a placement's fixed `item` / `equipment` (`pick_item` / `pick_pickup` with `fixed`);
- outcomes: `GiveItem` by id, `GiveEquipment` by id (and a chest's by-id rewards);
- enemy drops: `EnemyDefinition.drop_item` (the roll is unchanged; the dropped item is the food item when already seen).
`seen_items` already marks every placed or given item, so no new state. The validator warns (`named_item_repeats`) when two
fixed placements in one run structure name the same item, because only one can ever be the real one.

## 3. Data contracts

N/A on the wire: no `Rpg.Contracts` record changes, no queue, no topic, no Redis key. Godot only:
- `RunState.seen_events: Array[StringName]`, hashed as `events_seen=` when not empty;
- `RunSnapshot` `run.seenEvents` (array of strings), default `[]` on restore;
- `FloorGenerator` pools dictionary gains `"seen_events"` (the `FloorGenerator` signature is unchanged: it is a key of the
  existing `pools` argument);
- `ContentValidator`: `event_pool_short` (warning: a chapter whose event query matches fewer events than the rooms of its
  floors could ask for, counting the floors that use that chapter), `named_item_repeats` (warning, 2.3).

## 4. Failure modes

| # | Failure | Behaviour | Test |
|---|---|---|---|
| F1 | Every matching event is already seen | The room becomes an empty room (no error, no repeat); the validator warns in advance | `test_exhausted_event_pool_gives_empty_room` |
| F2 | Two event rooms on one floor | Different events | `test_events_unique_within_a_floor` |
| F3 | The same event on floor 3 as on floor 1 | Never, while an unseen one matches | `test_events_unique_across_floors` |
| F4 | A fixed room event / rest stop | Unchanged, repeats, not recorded | `test_fixed_and_rest_events_repeat` |
| F5 | A named item already held or seen | A food item instead (the fallback item only if the content has none); never a second copy | `test_named_item_already_seen_becomes_food` |
| F6 | A drop of an item already seen | A food item | `test_drop_of_a_seen_item_becomes_food`; `test_food_replacement_may_repeat` |
| F7 | Resume or replay from a snapshot | `seenEvents` restores; the replayed floors and hashes match | `test_resume_keeps_seen_events`, `test_step_runner` (the committed runs) |
| F8 | A client that repeats an event | Its floors/hash differ from the verifier's regeneration: rejected 2002, rollback | the existing tamper cases (`test_step_runner`), plus `test_repeated_event_hash_mismatch` |
| F9 | An old save with no `seenEvents` | Restores with `[]` | `test_old_snapshot_restores` |

Replay mismatches follow the root error contract: a verdict with `errorCode` 2002, never an HTTP 422.

## 5. Observability

No Prometheus change (the server sees only hashes). The play report (`seed_report --play`) gains `eventsSeen` and
`eventPoolExhausted` per run so the balance pass sees how often a chapter runs out of events, and the death map is unchanged.
Console: `status`/`state` list the run's seen events.

## 6. Test plan

Godot, fixtures only (the fixtures have event rooms and several events matching `fixture` event queries; extra events are built
in memory like `card_world.gd`):
- the table in section 4;
- hash: `events_seen=` absent while empty, present after, order-sensitive (placement order), and covered by
  `test_snapshot_fields_are_covered`;
- determinism: the same seed generates the same floors twice; a run's events are all distinct;
- goldens: floors with no query events are byte-identical; any golden that changes is listed and re-recorded only on confirmation;
- the play report on the 600 balance seeds before and after (reported, not asserted).

## 7. Decisions, open questions, what stays out

**Decided by the user, 2026-11-09:**
1. Seen = placed, not entered (needed for uniqueness inside a floor).
2. An exhausted event pool gives an empty room, not a repeat and not an error. To make that rare, **slice 5c adds more events**
   to the demo content (each chapter's event query should match well more events than the rooms its floors can ask for;
   the `event_pool_short` validator warning is how 5c finds the chapters that need them).
3. Fixed events and the rest stop stay repeatable.
4. A named item already seen is replaced by **a food item, like Isaac's drops** (section 2.3), not by the fallback item.
5. It lands together with 5c: the gate moves, and the balance pass is the place to re-measure it.

**Open:** should an *entered* event that the player flees (if an event can be left) count as seen? Today events cannot be left
mid-choice, so no.

**Stays out:** per-save/meta uniqueness (events a player has seen in earlier runs), weighting unseen events higher, a
"repeatable" flag on events (add when a designer needs one), and any server change.
