# Spec: food-items (food becomes passive: eat it on pickup, keep a lasting bonus)

Status: built 2026-11-13, awaiting playtest (decisions in section 7; synced with the build 2026-11-13). Slice: a small content-and-rules slice after `route-enemies` (before its cube looks,
Sets 4b and 5b). The four new Food items of slice 5c `card-balance` follow this pattern.

## 1. Purpose & enterprise mapping

Today the four `Pool.Food` items (`rations`, `honey_cake`, `roast_haunch`, `hearty_feast`, all `Card.Set.Core`) are **usable,
consumable** items: each sits in one of the holder's use slots until it is used once in battle or on the map (Rations: one
ally heals 15%; Roast Haunch: 30%; Honey Cake: one ally regains 40% SP; Hearty Feast: the party heals 25%). The only way to get
one is an enemy drop (`EnemyDefinition.drop_item`) and, since spec `route-enemies` 3.6, the food fallback of a drop outside the
run's card pool. Neither the smart nor the auto policy ever spends a consumable (spec `auto-battle`), so in the balance gate
food has done nothing at all.

The user decided (2026-11-13) to make food work like Isaac's food:

- **D1. Food is passive.** No use slot: a food item is eaten when it is picked up and then stays in the holder's items.
- **D2. On pickup the holder heals** (the Hearty Feast heals the whole party), through a new outcome that targets the item's
  holder; `ApplyPartyEffect` heals everyone.
- **D3. Then a lasting bonus**, flat or percent chosen per item: max HP for the three HP foods, **max SP** for the Honey Cake
  (which also refills SP on pickup, D2).
- **D4. The player chooses who gets every dropped item** (the event-items CHOOSE flow; for food, who eats it; review Q2: all
  drops, not only food); the bots give food to the party member with the lowest HP share, any other drop as today.
- **D5. The Collector never copies food** (its mirror skips it) but still counts it as a piece held for its +2% per piece.
- **D6. Copies stack**: every copy grants its bonus again (like `void_scar`).

**Enterprise mapping: none new.** Content and run rules only. The ruleset version changes (content and code hash); a run that
eats food logs one more `give_to` action per dropped food (an existing action type, spec `event-items`), uploaded and verified
like every other run action (any drop, not only food: Q2). No endpoint, contract, queue, topic, cache key or metric changes. Analytics see the existing
`ItemTaken` / `give_to` entries.

## 2. Sequence flow

N/A for the backend: nothing new travels. In the game:

1. A battle is won; `RunController._roll_drops` rolls each beaten enemy's drop on `floor/<n>/item_drop/<cell>` as today
   (and `_pooled_drop` applies the card pool, spec `route-enemies` 3.6).
2. Every dropped item is given with the recipient CHOOSE (Q2): when more than one living member could hold it (always, for a
   passive item), the item waits in `RunState.pending_gifts` and every other run action is refused until the logged
   `give_to(slot)` (spec `event-items`; `UI.State.Run.Gift` shows the choice). One possible holder: it goes straight to them.
   Several drops after one battle wait one after another, in the order they were rolled. **The battle that wins the run**
   (the last floor's boss room, `RunController._wins_run`) **drops nothing** (Q4): no pick can follow the win. Drops are
   rolled before the room is cleared but given after it, so a dropped item counts from the next room on (its
   `on_room_cleared`, a Twin Fob's key doubling; Q6).
3. `give_to` → `_receive_item(slot, item)` → `_place_item` adds it to the member's `items` (a passive item; no use slot), then
   the item's `on_pickup` outcomes run with `hook_item` and the new **`hook_slot`** (the receiving member) set.
4. The food's outcome **`ApplyHolderEffect`** (new) applies its effect to the holder only (`RunController.apply_member_effect`
   with `[hook_slot]`, the field context): the HP foods heal a percent of max HP (`exec_calc_percent_of_max`, as today's food
   effects), the Honey Cake restores a percent of max SP (`food_mp_40`, which holds 33% despite its name). The Hearty Feast uses the existing `ApplyPartyEffect`.
   Because the item is placed first, the bonus already counts, so a percent heal reads the new maximum.
5. The lasting bonus is the item's `grants`: an `AbilitySet` with one INFINITE effect (max HP flat or percent; max SP), applied
   in every later battle and field context like any passive item's grants (`applies_to` HOLDER, PARTY for the Hearty Feast).
6. The bots (`RunPlayer`, dev `autorun`, the play report, e2e scripts) resolve a waiting gift by giving food to the living member
   with the lowest HP share (`hp × 100 / max_hp`, ties to the lowest slot); any other gift as today (the first member who can
   hold it).
7. Server mode: unchanged flow. The `give_to` entry is uploaded in order, the verifier replays it (`RunWire`), the run hash
   already covers `pending_gifts` and each member's items (`run-v2`).

## 3. Data contracts

**No C# DTOs, queues, topics or Redis keys.** The contracts are Godot types and content. Numbers are written as a designer types
them (stored ×100, root `CLAUDE.md`); the `.tres` files are the source of truth once built.

### 3.1 System code (`game/`)

- `_roll_drops` gives every drop with `GiveItem.Recipient.CHOOSE` (was FIRST), except in the battle that wins the run, which
  rolls no drops (Q4; `_wins_run(cell)` is the one win rule, also used by `_clear_room`). Chests (already CHOOSE), events,
  pickups and shops keep their own rules. No new field: the rule is the same for every drop (Q2).
- Encounter rewards may be CHOOSE (Q5): such a reward waits for `give_to` like a drop (rewards come before the drops); in the
  battle that wins the run it goes to the first member who can hold it (the transient `_choose_off`, set only while those
  rewards are granted). The validator's `give_choose_outside_event` now covers item hooks only (spec `event-items` D3).
- `_pooled_drop` (spec `route-enemies` 3.6) checks who can hold only its possible picks (card-pool items tagged
  `Pool.Treasure` or `Pool.Food`); the picks are the same as checking the whole content.
- `ApplyHolderEffect` (new `RunOutcome`, `game/defs/outcomes/apply_holder_effect.gd`): `effect: GameplayEffect`; `apply(run)`
  calls `run.apply_holder_effect(effect)`, which applies it to `hook_slot` through `apply_member_effect`. Outside an item hook
  (no holder) it does nothing and pushes a content warning. The content validator reports `holder_effect_outside_item` when
  the outcome sits anywhere but an item's `on_pickup` / `on_floor_start` / `on_room_cleared`, and `dangling_ref` when it has
  no effect.
- `RunController.hook_slot: int` (transient, like `hook_item`): set around an item's hooks in `_receive_item` (and the floor /
  room hooks, which already know the holder), the outer value restored after (a hook may run inside another); never logged,
  hashed or snapshotted.
- `RunPlayer` gift resolution (D4): food (an item tagged `Pool.Food`) to the lowest HP share, else today's rule.
- Validator (new codes): `food_usable` (a `Pool.Food` item that is USABLE: food is passive, D1), `food_no_pickup` (a `Pool.Food`
  item whose `on_pickup` is empty).

### 3.2 Content (`content/demo/`, the user's folder; existing files changed with the user's OK, shown as old → new)

The numbers live in the effect files (the source of truth); the starting values were kept after the gate (Q1, section 6).

| Item | On pickup (D2) | Lasting bonus (D3) | `applies_to` |
|---|---|---|---|
| Rations | holder heals a percent of max HP (`effects/food_heal_15.tres`) | flat max HP (`effects/food_rations_bonus.tres`) | HOLDER |
| Roast Haunch | holder heals a percent of max HP (`effects/food_heal_30.tres`) | percent max HP (`effects/food_roast_haunch_bonus.tres`) | HOLDER |
| Honey Cake | holder regains a percent of max SP (`effects/food_mp_40.tres`; the name is historic) | percent max SP (`effects/food_honey_cake_bonus.tres`) | HOLDER |
| Hearty Feast | the party heals a percent of max HP (`ApplyPartyEffect`, `effects/food_heal_25.tres`) | percent max HP (`effects/food_hearty_feast_bonus.tres`) | PARTY |

Each item file: `kind` USABLE → PASSIVE, `use_ability` cleared, `on_pickup` = the heal outcome on the existing effect
(`food_heal_15`, `food_heal_30`, `food_mp_40`, `food_heal_25`), `grants` = a new `AbilitySet` (`loadouts/food_<name>.tres`, its set
tag `Item.Food`) with a new INFINITE effect (`effects/food_<name>_bonus.tres`), and a new `description`
("On pickup: heal 15% of max HP. +40 max HP."). The prices stay (food is never sold today). The four use abilities and their
animations (`abilities/rations.tscn`, `honey_cake`, `roast_haunch`, `hearty_feast` and `animations/` of the same names) are
deleted (Q3), with their `Ability.Item.*` tags once `sync_tags` reports them unused.

- **D5:** `enemies/collector.tres` `mirror_skip_tags` gains `Item.Food` (the set tag, which the mirror's skip check already reads:
  spec `skill-points` D14). The piece still counts for `per_item_effect`.
- **New tag:** `Item.Food` (registry, the user's file).
- **Card collection:** the four stay `Card.Set.Core` and `Pool.Food`; the card catalog records only id, rarity, set, core flag
  and pools, so `card_catalog.json` and its hash do not change (`tools/check_card_catalog.sh` stays clean).
- **Slice 5c:** its four new Food items are built the same way (passive, an `on_pickup` heal or restore, a lasting bonus, CHOOSE).
- **Slice 5d `unique-events`:** its "a repeated named item becomes a food item" rule still holds: food repeats, and a repeat now
  also stacks its bonus (D6).

## 4. Failure modes

Content and run rules only; no backend failure path changes.

| Risk | Guard |
|---|---|
| A dropped food waits forever (a headless run, a bot, an e2e script) | `RunPlayer` resolves every waiting gift (D4); `autorun` and the play report use it; a test plays a run with food drops to its end. |
| The heal targets the wrong member, or the bonus is not yet counted when it heals | Test: the receiving slot alone heals, and a percent heal reads the raised maximum. |
| A food copy stacks wrongly or not at all | Test: two Rations on one member give +80 max HP. |
| The Collector copies food | Test: the mirror skips a held food and still counts it. |
| `can_hold` refuses food | Passive items have no use-slot check: food is always holdable (also what `_pooled_drop`'s food fallback relies on). Test. |
| A client and the verifier disagree on a food run (2002) | `give_to` and the item lists are already in the log and the run hash; a test replays a food run step by step (`StepRunner`) to Verified. A mismatch stays a verdict with `errorCode` 2002 (root error contract). |
| Goldens move | No committed golden uses demo food (fixtures have none; seed and run goldens use the fixtures). If one moves it is investigated and regenerated on purpose, never worked around. |

Root acceptance scenarios 1-7: N/A (no settlement, queue, outbox, cache or verifier change).

## 5. Observability

N/A: no new metric. The play report already counts items taken; food appears in its item lists and in `run_summary`.

## 6. Test plan

**Godot (`tools/godot_tests.sh`), on fixtures for the system parts:**
- `ApplyHolderEffect`: heals only `hook_slot`; outside an item hook it does nothing (and warns); the validator flags it outside
  an item hook (content built in memory, as `test_event_items` does; no broken fixture file).
- The battle that wins the run drops nothing; a CHOOSE encounter reward waits, except in that battle (first holder).
- Drops: a drop waits in `pending_gifts` and refuses other actions until `give_to`; with one possible holder it goes straight to
  them; two drops after one battle wait in roll order. No fixture enemy has a drop, so no golden changes.
- `RunPlayer`: a waiting food goes to the lowest HP share (ties: lowest slot); any other gift to the first member who can hold it.
- A fixture food item (passive, holder heal, +max HP): the heal reads the raised maximum; two copies stack; `can_hold` is "".
- The mirror: a held food (set tag `Item.Food`) is skipped by a mirror boss that lists the tag, and still counts for its
  per-item effect.

**Godot, content (`tests/game/`, skipped without the demo content):**
- `test_food_items`: each of the four demo foods is passive, has an `on_pickup` and a `grants` bonus; picked up it heals its
  holder (the Hearty Feast the party) and adds its bonus; the Honey Cake restores and raises SP; the Collector skips food.
- A run with food drops (a fixture food dropped by every fixture enemy) played by the bots to its end, then replayed step
  by step (`StepRunner`) to Verified. A demo-content step replay is optional, on demand: `tools/e2e.sh verify_demo_content`.
- The content validator stays clean (`food_usable`, `food_no_pickup` silent); `sync_tags` reports no missing tag.

**Balance gate** (spec `skill-points` D16): the smart four-member report on the 600 balance seeds before and after, compared
with `--compare` (win rate, per route, deaths by floor). Claude tunes the starting values on the gate (Q1) and reports the before and after numbers.
Result (2026-11-13): 29.3% → 31.0% won, sound parties 37.4% → 38.9%, 0 violations; the starting values were kept.

**.NET:** no change; `dotnet test` must still pass. Optional on demand: `tools/e2e.sh verify_demo_content` with the rebuilt export.

## 7. Decisions (user, 2026-11-13)

- **Q1. Values:** Claude balances them on the gate (section 6); the table's values are the starting point.
- **Q2. Other drops:** the player always chooses who gets a dropped item, every drop, not only food (section 2 step 2). The
  bots give food to the lowest HP share and any other drop to the first member who can hold it.
- **Q3. Old use abilities:** deleted, with their animations (section 3.2).
- **Q4. The last boss drops nothing** (after the build): the battle that wins the run rolls no drops, so no gift waits in a
  won run.
- **Q5. CHOOSE encounter rewards** (after the build): allowed, waiting like a drop; in the battle that wins the run they go to
  the first member who can hold them.
- **Q6. A dropped item counts from the next room** (accepted): it is given after the room's clear, so its `on_room_cleared`
  and run modifiers miss that room.
- Old saves with food in a use slot: no migration (none existed when this was built).

## 8. Out of scope

The four new Food items (slice 5c), food in shops or events, a cap on food copies, and any change to the rest event.
