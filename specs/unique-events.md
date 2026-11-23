# Spec: unique-events (slice 5d, part 2 of 2)

Status: **spec written 2026-11-09, decisions confirmed by the user the same day; revised 2026-11-21 against the build
after `floor-rooms` (5b3), `boss-drops` (B33) and the playtest fixes, with the normal-room fallback (user, 2026-11-21). Built 2026-11-22 (PR #84, merged) and playtested 2026-11-22: done.**
Part 2 of slice 5d. Part 1 is `specs/event-pass.md` (the new events, fewer event rooms, the new outcomes and conditions).
Both land before 5c `card-balance`, which re-measures the win-rate gate with them in place. Builds on
`specs/game-skeleton.md` (the floor generator and pools), `specs/playable-demo.md` (events, `rest_event`),
`specs/route-enemies.md` (`_pooled_drop`), `specs/boss-drops.md` and `specs/floor-chests.md` (what lands on the floor),
`specs/food-items.md` and `specs/run-verify.md` (the run hash covers what decides play).

## 1. Purpose & enterprise mapping

**Purpose.** Make a run feel unrepeated, as in Isaac:
1. **An event picked from a chapter's event query appears at most once per run.** Today the pick is a weighted draw from
   every matching event with no memory (`FloorGenerator._resolve_content`), so the same event can open twice on a floor
   and again on later floors. When no unseen event is left, **the room becomes an ordinary room of the same type** (a
   battle room), never an empty room and never a repeat (2.2).
2. **A drained item pool gives a food item.** Pool picks are already once per run (`pick_item`, `pick_pickup`,
   `pick_equipment` skip `held` and `seen`). When a pool has nothing left, the pick now gives a food item instead of
   the run's `fallback_item` (Stale Bread), like Isaac's hearts and coins (2.4). **Named items are not affected** (user,
   2026-11-21): a fixed placement, an outcome by id (events, chests, encounter rewards) or an enemy's `drop_item` always
   gives that item, even when the run already has one.

**Enterprise mapping.** Client rules only. The server stores nothing new and runs no new code. The run hash covers every
cell of the map (`run-v2`), and the verifier regenerates every floor from the server's seeds, so a client that ignored
the rule would generate different floors and fail verification (2002) like any other cheated pick. Redis, RabbitMQ,
Redpanda and Postgres are not touched. Metrics: none (play-report lines, section 5).

**Acceptance scenarios covered:** 5 (a tampered run, here one that repeats an event, is rejected by replay). The others
are not this slice.

## 2. Sequence flow

### 2.1 Events: the new state

```
RunState.seen_events: Array[StringName]      event ids placed from a query on any floor so far, in placement order
pools["seen_events"]                          beside the existing pools["seen"] (items); built in all three places that
                                              build pools: RunController._pools(), seed_report.gd (floor_of / many),
                                              content_validator.gd (the generation check)
FloorGenerator._resolve_content (EVENT_QUERY):
    candidates = matching(content.events, query) minus pools["seen_events"]
    event      = RunSeeds.pick_weighted(content stream, candidates)
    pools["seen_events"].append(event.id)      (so two event rooms of one floor never match either)
    candidates empty  →  the normal-room fallback (2.2)
RunController._install_floor: state.seen_events.assign(pools["seen_events"])     (like seen_items)
```
**What counts as seen:** placed, not entered. A floor is generated whole, so events can only be unique within it if
placing marks them, the rule items already follow. An event room the player never opens still spends its event.

**Exempt (fixed by id, on purpose):** `room.event` and a layout cell's `event` (authored scripted rooms) and
`RunStructure.rest_event` (the rest stop between floors repeats by design). They are not drawn from a query, so they are
neither filtered nor recorded.

### 2.2 The normal-room fallback

When an `EVENT_QUERY` room finds no unseen event, `FloorGenerator._resolve` **swaps the cell's room** before resolving its
content:
```
replacement candidates: rooms with the cell's type tag (normally Room.Type.Normal), in the chapter (_in_chapter),
                        fitting the cell's doors (room.fits), whose content_mode is neither EVENT nor EVENT_QUERY
replacement = RunSeeds.pick_weighted(floor/<n>/room_swap/<cell>, candidates)     (its own stream)
data["room"] = replacement.id, then its content resolves as usual (an encounter from the chapter's query)
```
The swap happens in step 6 (content), before step 7 (pickups), so the replacement's own placements apply. The swap
stream is its own, so the content stream draws exactly as before until a swap happens: floors that never run out stay
byte-identical. In the rare case that no replacement fits, the room's content is `none` (an empty room, as an empty
query gives today), and the validator warns in advance (`event_fallback_room_missing`: a chapter whose event room fits
doors no non-event Normal room of that chapter fits).

The swapped cell carries `"fallback": true`, which is hashed with the cell like every field. `run_summary` and the play
report count `eventFallbacks`. With the event pass's numbers (~15 event rooms per run, about 44 events to draw from), a
fallback should be rare. It is reported, never asserted.

### 2.3 Hash and compatibility

`events_seen=<ids joined by ,>` joins `RunState.canonical_lines()` **only when not empty** (as `keys=` does; `seen=` is
always present). `RunSnapshot` gains `run.seenEvents`, read with a default of `[]`, so the snapshot version stays 1 and
older saves and server checkpoints still restore. `test_snapshot_fields_are_covered` covers the new field. A repeated
event inside one floor is already caught by the map's hash (`run-v2` hashes every cell field). The `events_seen=` line is
what keeps later floors identical on a replay.

A run with no query events hashes exactly as before. Runs that place query events change (later ones draw from a
smaller list), so **the committed goldens may change**: `floor_7.txt`, `floor_123456789.txt`, `run_scripted.json`,
`run_keyed.json`, `seed_report.json`, `seed_report_play.json`. The event pass's random bot choices move the bot-played
ones anyway. Per the ownership rules they are re-recorded only after the user confirms the diff, never by editing
content.

### 2.4 A drained pool gives food

Today a pool pick with no candidate left (everything matching is held, seen or outside the card pool) gives the run's
`fallback_item`, Stale Bread. It now gives **a food item**:
- one pick from the `Pool.Food` items that some living member can hold, **ignoring held and seen** (food may repeat:
  it is eaten on pickup and its bonus stacks, spec `food-items`), and inside the card pool (the four demo food items are
  `Card.Set.Core`, so it never removes them);
- on the same stream as the pick that came up empty (an empty pick draws nothing, so the food pick is that stream's
  first draw), so no new stream or counter is needed;
- no food item can be held → the `fallback_item`, as today; that neither → nothing, with a warning.

The sites, all already falling back to `fallback_item` today:
- `FloorGenerator.pick_item` and `pick_pickup` (pedestals, shop slots, item rooms), when `use_fallback` is true;
- **the armory** (`offers` EQUIPMENT) too (user, 2026-11-21): when no piece is left it gives a food item instead of no
  pickup. It never gives the `fallback_item` (no food can be held → no pickup, as today). This amends spec `floor-rooms`
  3.1, which `/sync-spec floor-rooms` records after the build;
- outcomes by query: `GiveItem` with an `item_query` (events, chests, encounter rewards) through `pick_item`, and
  `GiveEquipment` by query, whose empty pick gives the fallback item today (`give_equipment_from`);
- enemy drops already do this: `_pooled_drop` (spec `route-enemies`) gives food when the Treasure pool is drained.

**Named items are unchanged** (user, 2026-11-21): a fixed placement's `item` / `equipment`, `GiveItem` / `GiveEquipment`
with an `item` / `equipment`, a chest's by-id reward and an enemy's `drop_item` give exactly that item, even when it is
held or seen. They still mark it seen (as today), so pools never offer it afterwards.

A food item replacing a drained pick is marked seen like any pick. That keeps the record honest, and since food ignores
seen, it does not stop food repeating. `run_summary` and the play report count `poolsDrained`.

## 3. Data contracts

N/A on the wire: no `Rpg.Contracts` record changes, no queue, no topic, no Redis key. Godot only:
- `RunState.seen_events: Array[StringName]`, hashed as `events_seen=` when not empty;
- `RunSnapshot` `run.seenEvents` (array of strings), default `[]` on restore;
- `pools["seen_events"]` (the `FloorGenerator` signature is unchanged: it is a key of the existing `pools` argument);
- a cell's `"fallback": true` when its room was swapped (2.2);
- stream `floor/<n>/room_swap/<cell>`;
- `ContentValidator`:
  - `event_pool_short` (warning): a chapter whose event query matches fewer events than its floors' event rooms are
    expected to ask for (from the floor rules and the nook's weight, counting every floor that uses the chapter). With
    the fallback this is about variety, not failure;
  - `event_fallback_room_missing` (warning, 2.2);
  - the existing `empty_item_pool` message names food first, then the `fallback_item` (2.4).

## 4. Failure modes

| # | Failure | Behaviour | Test |
|---|---|---|---|
| F1 | Every matching event is already seen | The room becomes another Normal room of the chapter that fits its doors (a battle room), `fallback` set | `test_exhausted_event_pool_falls_back_to_a_normal_room` |
| F1b | ... and no such room fits | An empty room (no error, no repeat), warned in advance | `test_fallback_without_a_room_is_empty` |
| F2 | Two event rooms on one floor | Different events | `test_events_unique_within_a_floor` |
| F3 | The same event on floor 3 as on floor 1 | Never, while an unseen one matches | `test_events_unique_across_floors` |
| F4 | A fixed room event / rest stop | Unchanged: repeats, not recorded | `test_fixed_and_rest_events_repeat` |
| F5 | A pool pick with nothing left (pedestal, shop, GiveItem / GiveEquipment by query) | A food item some member can hold; the `fallback_item` only if none can (the armory: no pickup then) | `test_drained_pool_gives_food`, `test_drained_pool_without_food_gives_fallback`, `test_drained_armory_gives_food` |
| F6 | A named item already held or seen (placement, event, chest, reward, drop) | Given again, unchanged | `test_named_items_repeat` |
| F6b | Food replacing drained picks, several times | Food repeats freely | `test_food_replacement_may_repeat` |
| F7 | Resume or replay from a snapshot | `seenEvents` restores, and the replayed floors and hashes match | `test_resume_keeps_seen_events`, `test_step_runner` (the committed runs) |
| F8 | A client that repeats an event | Its floors and hash differ from the verifier's regeneration: rejected 2002, rollback | the existing tamper cases (`test_step_runner`), plus `test_repeated_event_hash_mismatch` |
| F9 | An old save with no `seenEvents` | Restores with `[]` | `test_old_snapshot_restores` |
| F10 | The seed tools and the validator | Generate the same floors as the run (the same pools keys) | `test_seed_report_matches_the_run` |

Replay mismatches follow the root error contract: a verdict with `errorCode` 2002, never an HTTP 422.

## 5. Observability

No Prometheus change (the server sees only hashes). The play report (`seed_report --play`) gains `eventsSeen`,
`eventFallbacks` and `poolsDrained` per run, beside its `floorRooms` totals. `seed_report` (not playing) counts
fallbacks per floor. The death map is unchanged. Console: `status` / `state` list the run's seen events.

## 6. Test plan

Godot, fixtures only (an in-memory event world with several events matching a `fixture` query and two Normal rooms, one
of them an event room, like `card_world.gd` / `FloorRoomsWorld`):
- the table in section 4;
- hash: `events_seen=` absent while empty, present after, order-sensitive (placement order), covered by
  `test_snapshot_fields_are_covered`;
- determinism: the same seed generates the same floors twice; a run's query events are all distinct; a floor that
  never runs out is byte-identical to before (the swap stream is separate);
- goldens: floors with no query events are byte-identical; any golden that changes is listed and re-recorded only on
  confirmation;
- the play report on the 600 balance seeds before and after (reported, not asserted), together with event-pass.

## 7. Decisions, open questions, what stays out

**Decided by the user:**
1. Seen = placed, not entered (needed for uniqueness within a floor). 2026-11-09.
2. An exhausted event pool gives **a normal room of the same type**, not a repeat, an error or an empty room (user,
   2026-11-21; the first decision, 2026-11-09, was an empty room). The events come from `event-pass` (part 1: 50 events,
   about 15 event rooms per run).
3. Fixed events and the rest stop stay repeatable. 2026-11-09.
4. **Named items may repeat; a drained pool gives food** (user, 2026-11-21; replaces the 2026-11-09 decision that a
   named item already seen becomes food). The `fallback_item` remains only for content with no food a member can hold. A drained armory
   gives food too (user, 2026-11-21).
5. It lands before 5c, with event-pass (user, 2026-11-15 and 2026-11-21).

**Open:** should an *entered* event that the player flees (if an event can be left) count as seen? Today events cannot
be left mid-choice, so no.

**Stays out:** per-save or meta uniqueness (events a player has seen in earlier runs), weighting unseen events higher, a
"repeatable" flag on events (add when a designer needs one), and any server change.
