# Spec: boss-drops (what a battle gives lands on the room's floor, and the player picks who takes it)

Status: reviewed 2026-11-21 (the user answered Q1-Q5, section 7); ready for `/implement`. Origin: `specs/playtest-fixes.md` B33 (reported
2026-11-21). It needed its own spec because it changes a run rule, the run log and the hash. Slice: playtest-fixes
follow-up, after 5b3 `floor-rooms` (PR #79) and the B27-B34 fixes (PR #80).

## 1. Purpose & enterprise mapping

**Today** a won battle hands out items in two ways, and neither puts anything in the room:

- **Enemy drops** (`EnemyDefinition.drop_item` / `drop_chance_x100`, `RunController._roll_drops`, stream
  `floor/<n>/item_drop/<cell>`; spec `playable-demo` 3.11, `route-enemies` 3.6, `food-items` D4). Each hit is a
  `GiveItem.Recipient.CHOOSE` gift. With more than one possible holder it waits in `RunState.pending_gifts` and the Give-to
  panel (`UI.State.Run.Gift`) blocks every other action until the logged `give_to(slot)`. With exactly one holder it is given
  at once, and with none it is lost. Bosses that drop: the Golem, the Rat King and the Mother Heart. Regular enemies and elites
  drop too (the Bat, the Toad, the 25% elite drops, and others).
- **Encounter rewards** (`EncounterDefinition.rewards`, `_grant_rewards`; spec `playable-demo` 3.7). Every boss of floors
  1-8 gives one `Pool.Boss` item through a `GiveItem` with the default recipient FIRST, so it **goes straight to the first
  member** (the player never chooses). A CHOOSE reward waits like a drop. A `GiveEquipment` reward (the Knight duel's Warden
  Helm) goes straight to the armor inventory.

**The user wants** (B33) a boss's drop to fall onto the room's floor as a pickup, like a chest's items (spec
`floor-chests` D2-D4), and be taken with the usual member choice (the pickup row's Take / give-to picker, the existing
`take(placement, slot)`).

Proposed decisions (the open questions are in section 7):

- **D1. One rule for every battle.** Every item a won battle gives (each enemy's drop and each item or armor piece of the
  encounter's rewards) lands as a **free pickup on the floor of the room the battle was fought in**. This applies to regular
  enemies, elites and bosses alike (Q1: yes) and to rewards whatever their `recipient` or `character` says (Q2: yes). It is the same
  rule a chest uses today (`give_item` ignores both while a chest opens; validator warning `chest_recipient_ignored`).
- **D2. Only items and armor land** (Q3: armor on the floor too). Every other reward outcome (coins, keys, XP, a heal, a chest, which already lands
  in the room per `floor-chests`) is given at once, as today.
- **D3. Nothing blocks.** No pending gift and no Give-to panel after a battle. The room clears as today, its pickups show,
  and the player may take them in any order, give each to any member who can hold it, or **leave them**. A drop left
  behind stays in its room (the map's leftover colour, `floor-chests` D5, already covers an untaken free pickup) and is
  lost at the stairs, like a chest's item. An item **nobody can hold right now** (every use slot full) is no longer lost:
  it waits on the floor until someone can hold it (a consumable used on the map frees its slot; a member with a free slot
  can take it, or `move_item` makes room on the one the player wants).
- **D4. The rolls stay the same.** The drop stream, the roll order, `_pooled_drop` (the card-pool substitute), the reward
  pick streams (`gift/<k>`) and the encounter's reward order are unchanged. Without a card pool (local mode, every golden) a
  battle gives exactly the same items as before; only where they go changes. Two small differences follow from nothing being
  held until a take (review 2026-11-21): with a card pool, `_pooled_drop`'s "who could hold it" check reads the party
  without the battle's earlier rewards and drops (they are still on the floor), so a substitute may differ from the old
  rule's; and a RANDOM reward no longer draws from the floor's recipient stream (`recipient/<cell>/<k>`), so a later RANDOM
  gift on that floor may go to another member. No demo encounter has a RANDOM reward.
- **D5. The battle that wins the run** (`_wins_run`) is unchanged: it drops nothing, and a reward item there still goes to
  the first member who can hold it (no take can follow; the route bosses give nothing anyway since B32). Challenge-room waves
  are unchanged too: no drop and no encounter reward in any wave (`floor-rooms` D10).
- **D6. Where it lands (presentation, Q4: in the middle).** Every drop and reward simply appears on the free tiles nearest the
  room's middle (in placement order) once the fight is over, whichever enemy dropped it, drawn as an item card (`item-cards`)
  or an armor prop (Set K). No pop-out animation and no toast (user, 2026-11-21, playtest).
- **D7. Food is eaten on the take** (spec `food-items`): `take` already runs `_receive_item` and its `on_pickup` hooks on
  the taker, so a food drop heals the member the player picks. Nothing new is needed.
- **D8. `give_to` stays** for event gifts (the Librarian, the Shady merchant: `GiveItem` CHOOSE inside an event choice,
  spec `event-items`). It is no longer used after a battle. A CHOOSE reward on an encounter now only draws the validator
  warning `reward_recipient_ignored` (as a chest's does, `chest_recipient_ignored`); it raises no
  `give_choose_outside_event` error (decided when built, 2026-11-21: one finding, not two).

**Enterprise mapping: a run rule change with one small contract addition, no new infrastructure.** The ruleset version
changes (its content hash covers `game/`), so the run goldens are re-recorded. A battle's items become ordinary `take`
actions, uploaded through the existing action queue (`POST /api/v1/runs/{id}/actions`), checkpointed and replayed by the
step verifier (spec `run-verify`) like every other run action. They go into the existing `run_actions` JSONB and nothing
new reaches the event log. For player analytics (slice 4b / 7) the `battle` action carries what the battle put on the
floor as `ItemOffer`s (as `open_chest` does), with two new `OfferSource` values, `Drop` and `Reward`. "Drops left
behind" and "who takes the boss item" can then be measured from the log. No endpoint, migration, queue, topic, Redis key
or metric changes.

## 2. Sequence flow

### 2.1 A won battle (client, `RunController._do_fight`)

```
battle logged and hashed (unchanged)
won, not a wave:
  _grant_rewards(encounter, cell)         reward outcomes in order; the hook "_dropping" is set to "reward"
     GiveItem → give_item(...)            item picked as today (query on gift/<k>), then:
        _dropping set and not _choose_off → _drop_pickup(item, cell, 0)  instead of pending_gifts / _give_to
     GiveEquipment → give_equipment       while _dropping: → _drop_pickup(piece, cell, 0)  (beside the _opening_chest check;
                                           never in _receive_equipment, which take() also calls)
     anything else                         applied at once (coins, keys, chest in this room, ...)
  _award_xp(...)                           unchanged
  _roll_drops(enemies, cell)               same stream, same rolls, same _pooled_drop
     hit → Message.Run.ItemDropped (no toast listens to it: D6)
         → _drop_pickup(item, cell, enemy slot)   instead of give_item(CHOOSE)
  _clear_room(cell, true)                  unchanged: coins, key, chest rolls; room_cleared; pickups_shown(cell)
```

`_drop_pickup(thing, cell, from)` appends `FloorGenerator.pickup_entry(number, thing, 0)` to `cell["pickups"]`, with
`number = DROP_PLACEMENT (3000) + <drop pickups already in the cell>` (unique in the cell, so a dev battle fought again in
a cleared room adds more without a clash) and `entry["drop"] = from` (the dropping enemy's 1-based encounter slot, 0 for an
encounter reward). The item is marked seen (`seen_items`), as a chest pickup and a gift are. The `_choose_off` battle (D5)
skips the hook and gives FIRST as today.

### 2.2 Taking it (`take`, unchanged code path)

```
player: pickup panel row "Golem's Heart" → Take → member picker (as for a pedestal or chest item)
RunController.take(3000, slot)       refused while a battle is pending or an event gift waits (unchanged); room is cleared
   can_hold(slot, item) → _receive_item(slot, item) (on_pickup hooks: food eaten, D7) → Message.Run.ItemTaken (source take)
   armor: take(placement, any) → armor inventory, as an armor pedestal
run_log: {"type": "take", "floor", "cell", "placement": 3000, "slot"}     (armor: "kind": "equipment", no slot)
journal → RunActionRequest (take, itemId, kind, characterId, price 0, coinsAfter) → action queue → server
```

### 2.3 Server and verifier

Nothing new. `POST /runs/{id}/actions` stores the `battle` action (now with `offers`) and the later `take`s.
`StepRunner` replays the battle through `RunWire.apply` → `fight` (the drops land in the replay exactly as in play),
then each `take` → `run.take`. Each claimed `stateHash` must match, so a take of a pickup that never dropped, or a battle
whose drops differ, is a `Rejected` step (2002, `StateHashMismatch` / the battle's `ReplayMismatch`), followed by the
run-verify rollback.

## 3. Data contracts

### 3.1 `src/Rpg.Contracts/Runs/RunActions.cs` (append only)

```csharp
/// <summary>... Spec boss-drops: Drop (an enemy's drop) and Reward (an item or armor piece of the encounter's rewards),
/// on the floor of the room the battle was fought in, offered on the battle action. Values are only ever appended.</summary>
public enum OfferSource { Treasure, Shop, BossReward, Other, Chest, Armory, Challenge, Drop, Reward }
```

No new record. `RunAction.Offers` (already on the record, used by `enter_room` and `open_chest`) is filled on `battle`.

### 3.2 Wire (`game/run_wire.gd`)

- `offers(state, cell)`: a pickup with `"drop"` is `Drop` when `drop > 0`, else `Reward`. This is checked right after
  `chest`, before the `BossReward` room-role branch.
- `battle` action: `offers` = the offers of the pickups whose placement the battle added (left out when none), like
  `open_chest`.
- `take` / `buy` unchanged (`itemId`, `kind`, `characterId`, `price` 0).

### 3.3 Run state, hash, snapshot

- A drop pickup is an ordinary cell pickup `{placement, item, price: 0, taken, [kind], drop}`. The run hash covers it
  through the map's canonical form (every field of every cell). Rooms with no drop hash as before, so a run that wins a
  battle with a drop or a reward item hashes differently. (No committed golden moved: the fixtures have no drops and no
  item rewards.)
- `RunSnapshot._pickup` restores `drop` as an int (JSON gives a float). The committed runs hold no drop, so
  `test_boss_drops::test_the_run_hash_covers_the_drop_leaf` changes the leaf instead of `test_snapshot_fields_are_covered`.
- `RunController.DROP_PLACEMENT = 3000`. `dev_spawn_item`'s range (1000 to <2000) and chests' (2000 to <3000) are kept
  apart. A cell is unlikely to hold 1000 chest pickups; the validator does not check that.
- `run_summary`: `dropsLeftBehind` (untaken drop pickups on a floor when it is left, counted like `chestItemsLeft`; only
  present when above 0, so older summaries match). `giftsGiven` now counts event gifts only.
- An old local save or server checkpoint with a drop still in `pending_gifts` restores and plays as before (`give_to` is
  still there). No `OLD_SAVE_PROBLEM`.

### 3.4 Content and validator

- No content change is required. The demo's `GiveItem` rewards (FIRST) land on the floor under D1.
- Validator: `reward_recipient_ignored` (warning) for a `GiveItem` in `EncounterDefinition.rewards` with `recipient` ≠
  FIRST or a `character` set (D8: a warning only, no `give_choose_outside_event` error; its text now names event choices
  only). `holder_effect_outside_item` is unchanged.

### 3.5 Presentation (no hash, no wire)

- Pickup panel: every row names the item only, with no "from the X" (user, 2026-11-21, playtest; this also removed the
  chest item's "from the <chest>" of spec `floor-chests` 2.6 and `pickup_row.gd`'s `from_chest_format`). `RunController.drop_source_name` (the enemy in the drop's slot; for a reward the room's
  `Enemy.Boss` unit, else its first enemy) names the source of the `ItemDropped` message only.
- `RoomView3D`: drop pickups on the free tiles nearest the room's middle (D6), in placement order, with no animation.
- The Give-to panel remains for event gifts only.

Redis / RabbitMQ / Redpanda: N/A. The feature adds no key, queue or topic. The offers travel inside the stored action JSON.

## 4. Failure modes

- **Idempotency and order:** a `take` of a drop is an ordinary run action. The upload is idempotent by seq with a body
  comparison (1102 / 1103 unchanged). Taking the same drop twice is refused locally ("already taken"), and a replayed
  log refuses it the same way.
- **Retries / offline:** unchanged. The drops are part of the floor played offline. The queue drains at the stairs (1106 /
  1107 unchanged).
- **Dead letters:** N/A (no new queue; step jobs are unchanged).
- **Mixed rule versions:** a run started before this change carries the old ruleset version. The verifier replays only
  its own version, so such a run's later steps are verified (or not) as for any rule change. This is the known slice 9
  limitation (acceptance scenario 6, not covered here).
- **Card pool:** a drop still obeys the run's card pool (`_pooled_drop`, unchanged); a reward still picks from the pool.
- **Acceptance scenario 5 (tampered action log → 2002):** covered for this rule by two new `test_step_runner` cases. A
  claimed `take` of a drop placement the battle never put out is a `StepVerdict` Rejected with code 2002 (the client
  refuses it locally too). A claimed start state holding a drop the replay never rolled is Rejected 2002
  (`SnapshotHashMismatch`). Neither is an HTTP 4xx. The `offers` themselves are analytics claims the step verifier does not
  compare (as for `enter_room` and `open_chest` today); a projection that needs trusted offers must rebuild them from the
  verified replay (open, slice 4b).
- Scenarios 1-4 and 7: N/A (no settlement, outbox, cache or load path changes).

## 5. Observability

N/A: no new metric. The existing `rpg_run_actions_total` counts the extra `take`s. Item ids never become Prometheus labels.
Analytics read drops from the stored actions' `offers` (`Drop` / `Reward`) later (slice 4b / 7).

## 6. Test plan

New `tests/game/test_boss_drops.gd`, on the frozen fixtures (a fixture enemy with a `drop_item` at 100% and an encounter
with a `GiveItem` reward and a `GiveEquipment` reward; added by the fixture builder without `--rebuild` if missing):

1. A won battle puts each hit drop and each reward item / armor piece on the room's floor (`drop` = slot / 0, placements
   from 3000 in reward-then-roll order, price 0, not taken). `pending_gifts` stays empty and no action is refused
   afterwards.
2. The rolled items are the same as before the change: the drop stream, its roll order and `_pooled_drop` are untouched
   code (not pinned by a new golden: `test_food_items` and `test_route_enemies` keep testing the rolls).
3. `take(3000+k, slot)` gives the item to the chosen member, logs `take`, toasts `ItemTaken`. Food heals the taker (D7),
   and armor goes to the armor inventory.
4. A drop nobody can hold is not lost: `take` refuses with the use-slot reason, and once a slot frees (a consumable used
   on the map) the take works.
5. Leaving the room and going down the stairs with drops untaken: allowed, `dropsLeftBehind` counted, the map's
   `leftover` set on the room.
6. The run-winning battle drops nothing and gives its reward to the first holder (D5). A challenge room gives neither (D5).
7. A dev battle in a cleared room adds drops with fresh placement numbers.
8. CHOOSE / character on an encounter reward is ignored and the validator warns `reward_recipient_ignored`. CHOOSE inside an
   event still waits for `give_to` (the `test_event_items` cases keep passing unchanged).
9. Snapshot round trip with drop pickups (taken and untaken), resume equivalence from a checkpoint after the battle, and
   `test_snapshot_fields_are_covered` with the `drop` leaf.
10. Wire: the battle action's `offers` (`Drop` / `Reward`, absent when nothing dropped), `RunWire.apply` replays a
    battle and a drop `take` to the same hash. The two tampered `test_step_runner` cases (section 4) give Rejected 2002.
11. Bots: `RunPlayer` takes drop pickups with `gift_holder` (food to the lowest HP share), like chest pickups. Chaos adds
    `take_drop_twice` (refused). The play report stays error-free on the demo (`seed_report --play`, smart policy).
12. UI: no pickup row says "from the X" (`test_explore_hud::test_pickup_panel_opens_chests`); no gift waits after a battle
    (`pending_gifts` empty, test 1), so the Give-to panel never opens. View: checked by hand in a window (drops in the
    middle, a chest on the centre tile, its item under it, gone after re-entry; playtest-fixes B35).

.NET: `Rpg.Contracts.Tests` golden JSON for `OfferSource.Drop` / `Reward` on a `battle` action, and
`Rpg.GameServerApi.Tests` `Actions_BattleWithDropOffers_Stored` (the new enum values round-trip through the actions
endpoint).

Goldens: none moved (the fixtures have no drops and no item rewards; combat is unchanged). The tests that pinned the old
rule were updated: `test_food_items`, `test_progression`, `test_encounter_features`, `test_demo_run`, `test_keys_and_gear`,
`test_floor_rooms`, `test_explore_hud`. e2e: `verify_demo_content` and `full_run` pass on the real worker.

## 7. Decisions (the user's review, 2026-11-21)

- **Q1. All enemies or bosses only?** All enemies: every drop (regular, elite, boss) lands on the floor (D1).
- **Q2. The boss's reward item too?** Yes: the `Pool.Boss` item lands on the floor and the player picks who takes it (D1).
- **Q3. Armor rewards?** On the floor, like a chest's armor (D2).
- **Q4. Where they land?** In the room's middle, every drop and reward alike (D6). The pickup keeps `drop` (the enemy's
  slot) for analytics and the `ItemDropped` message's source; no pickup row says "from the X" (playtest, 2026-11-21).
- **Q5. Analytics names?** Yes: new `OfferSource.Drop` and `Reward`; `BossReward` kept as it is (3.1).
