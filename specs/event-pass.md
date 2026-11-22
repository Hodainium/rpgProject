# Spec: event-pass (slice 5d, part 1 of 2)

Status: **draft 2026-11-21, awaiting the user's review.** Written together with the revision of `specs/unique-events.md`
(part 2: once per run, the normal-room fallback). Both land in slice 5d, before 5c `card-balance`. Builds on
`specs/game-skeleton.md` (events, pages, choices), `specs/event-items.md` (gift recipients), `specs/playable-demo.md`
(encounter grants and rewards, field effects), `specs/boss-drops.md` (rewards land on the floor) and `specs/food-items.md`
(holder effects).

## 1. Purpose & enterprise mapping

**Purpose.** The demo has 8 events shared by every chapter. On today's floors (spec `floor-rooms`) a Descent run places
about 40–50 event rooms (measured 2026-11-21 over 200 seeds: ~1.2 on floor 1, ~4.4 on floor 5, ~7.2 on floor 10), so the
same few events keep coming back. This slice:
1. **Adds 42 events**, for 50 in all: 18 general ones (`Event.Demo`, any chapter), 8 simple "found" ones (`Event.Demo`:
   keys by a skeleton, a chest sitting in the room, an item on the floor) and 3 per chapter (`Event.<Chapter>`).
   A run then draws from about 44 events (26 general + 3 × the 6 chapters it visits).
2. **Makes events rarer:** about **10–20 event rooms per run** (target 15) instead of 40–50 (section 2.5).
3. **Adds the few missing data building blocks** so events can name party members (the 1st, the 3rd...), kill or hurt
   them, hand out items and armor to them, gamble, take items away and start fights where either side starts with statuses.
   Everything else events need already exists as data (coins, keys, golden key, chests, XP, levels, reveals, encounters
   with rewards).
4. **Curses and boons as event-only items:** a passive item with `grants` (an `AbilitySet`: a new ability, a lasting
   debuff or buff) that only an event gives, e.g. *Curse of the Vampire* (a new drain move and a lasting debuff) or
   *Leech* (a buff and a debuff).

**Enterprise mapping.** Client content and run rules only. The server stores nothing new and runs no new code: event
choices are already logged run actions (`choose`, `give_to`), and the verifier replays them through headless Godot like
any other action. A client that fakes an event outcome gets a different state hash, and the step is rejected (2002) and
rolled back. Postgres, Redis, RabbitMQ and Redpanda are not touched. Analytics: event decisions already travel in the run
log through the outbox (game-design section 10). Nothing changes there.

**Acceptance scenarios covered:** 5 (a tampered event outcome is rejected by replay). The others are not this slice.

## 2. Sequence flow

All of it runs in Godot (`game/`, plus one small change in `combat/`). Server path: unchanged (client → `POST /runs/{id}/actions` → steps
→ verifier → verdict).

### 2.1 Naming party members: the `SLOT` and `LOWEST_HP` recipients

`GiveItem.Recipient` gains two values (existing values and their behaviour are unchanged):
```
FIRST | RANDOM | CHOOSE                  (today)
SLOT       the member at party position `slot` (1–4, as the party strip shows them)
LOWEST_HP  the living member with the lowest HP share who can hold it (ties: the lowest slot; the rule food uses for the bots)
FLOOR      the item lands on the event room's floor as a free pickup (below)
GiveItem.slot: int = 1                   read only by SLOT
GiveEquipment.on_floor: bool = false     the same for an armor piece
```
**FLOOR** reuses the boss-drops path (`RunController._drop_pickup(thing, cell, 0)`). The item or piece becomes a free
pickup in the event's cell, numbered from `DROP_PLACEMENT` and taken with the ordinary `take` and the member picker. It
can be left behind, in which case it counts in `dropsLeftBehind` and the map shows its leftover tile. Its source name
(the pickup row, `Message.Run.ItemDropped`) is the event's display name. It is counted as seen when it lands, like every
drop. The room view draws it on the free tiles like a drop. Outside a room (an item hook, the rest stop) FLOOR falls back
to FIRST, and the validator flags it (`give_floor_outside_room`). A chest needs nothing new: `GiveChest` already lands a
closed chest in the event's room (spec `floor-chests`), opened as any chest (a Gilded one takes a key).
**SLOT fallback:** when that position is empty, dead, or cannot hold the item, the item goes to the **first** member who
can (as FIRST), and the run warns in the dev log. An event whose text promises a member a gift should guard the choice
with `MemberAt(slot)` (2.3), so the text stays true. `GiveEquipment` needs no recipient: armor goes to the armor inventory.

### 2.2 New outcomes

| Outcome | Fields | Behaviour |
|---|---|---|
| `ApplyMemberEffect` | `effect`, `target` (FIRST, SLOT, RANDOM, LOWEST_HP, CHARACTER, ALL), `slot`, `character`, `include_dead` | `effect` on the chosen member(s) through the existing field context (`RunController.apply_member_effect`). Killing is an effect too: a member brought to 0 HP is dead, and a party wipe ends the run as Lost (both already happen in `apply_member_effect`). SLOT on an empty or dead position (without `include_dead`) applies nothing. |
| `RemoveItem` (extended) | + `item_query`, + `from` (ANY, SLOT, RANDOM), + `slot` | Today: one item by id from everyone. Added: one held item matching `item_query`, from the member `from` names (RANDOM: a seeded pick among the matching held items). Nothing matches: nothing happens. |
| `GoToRandomPage` | `pages: Array[int]`, `weights: Array[float]` (×100 when stored) | Weighted pick of the next page. It is a gamble (*bet 15 coins*), and it can point back to the page it is on, so a choice can be taken again (*throw another coin*). |

**Every seeded draw inside an event** (RANDOM recipients and targets, RANDOM removals, random pages) uses the stream
`floor/<n>/event_roll/<cell>/<k>`. The counter `k` lives in `state.event["draws"]` (hashed and saved with the open event),
not in a `RunController` field. This fixes a latent problem: today's `_recipient_draws` lives on the controller and
restarts at 0 after a snapshot taken in the middle of an event, so a resumed or verified run could draw differently from
the client. The existing `recipient/<cell>/<k>` stream stays for runs that never use the new outcomes, so the goldens hold
(section 4, F9).

### 2.3 New conditions

| Condition | Fields | True when |
|---|---|---|
| `MemberAt` | `slot`, `alive_only` (true), `hp_at_least` (percent, 0 = any) | that party position holds a (living) member with at least that HP share |
| `FloorAtLeast` | `floor` (1-based, as the player counts) | the run is on that floor or deeper |
| `HoldsItemTag` | `query` (tag query), `slot` (0 = anyone) | a member (or that member) holds an item matching `query` |
| `AnyOf` / `NotCondition` | `conditions` / `condition` | any of them holds / it does not hold |

`HasCharacter`, `HasItem`, `CoinsAtLeast`, `KeysAtLeast` and `PartyHpAtLeast` are unchanged.

### 2.4 Fights that start with statuses

- **Enemies:** `EncounterDefinition.grants` / `EncounterSlot.grants` already apply an `AbilitySet` (effects, abilities, tags) to
  enemies at battle start, rebuilt from content by encounter id.
- **Party (new):** `EncounterDefinition.party_grants: AbilitySet` is applied to every living party unit at battle start,
  after their own loadout and items, in `combat/battle.gd`, rebuilt from content by encounter id like `grants`. The battle
  snapshot does not change (the encounter id is already in the conditions), so no wire change and no golden moves (no
  existing content sets it). Effects in it must be turn-based (the validator's existing duration rules).
- **Event-only encounters** carry the new tag `Encounter.Event` and no `Chapter.*` tag, so no chapter query ever picks them.
  They are started by `StartEncounter`, and their `rewards` land on the room's floor when won (spec `boss-drops`).
- **Event bosses** (four, on later floors: Hollow, Cathedral, Coven, Void) are **elite enemies with `level_bonus`, not
  `Enemy.Boss` units**, and their reward is a `Pool.Boss` item. Because they are not bosses, a win pays no gems (settlement
  pays only `Enemy.Boss` in `Facts`) and boss rotation is unaffected (decision D3).

### 2.5 Fewer event rooms

Event rooms are the `nook` room, one of four equally weighted `Room.Type.Normal` rooms (a 25% share). Its weight goes
from **1 → 0.3** (a ~9% share), which predicts ~15 event rooms per run (~0.4 on floor 1, ~2.2 on floor 10). The number
is checked with `seed_report` over 200 seeds after the change. The target band is an average of 10–20 per run, and the
weight is re-tuned until it holds. Spec `unique-events` (part 2) handles the case where a chapter has no unseen event
left: the room becomes a normal battle room.

### 2.6 Curses and boons: event-only items

A **curse** (`Item.Curse`, the tag exists) or **boon** (new `Item.Boon`) is a passive `ItemDefinition` with **no `Pool.*`
tag**. So the item pools never offer it, and it is not a card (`CardCatalog`: only pooled items are cards). Everything it
does is in its `grants`: abilities the holder learns, effects that last as long as it is held, tags. It shows in the
party menu with its description like any item, and the Confessional event can remove a curse (`RemoveItem` by
`item_query`).

**Rejected: an outcome that grants an AbilitySet to a member directly.** It would need new per-member run state, a new
snapshot field and a new `PartyMemberSnapshot` field (a wire change) to carry the grant into battles. An item already does
all of this, and the player can see it.

The Collector (H9 mirror) copies held items' passives. Whether it copies curses is D4.

### 2.7 Event text names the members

Page text and choice labels may contain `{member:<n>}` (the display name of the character at party position n, or "an
empty place" when there is none) and `{party}` (the party's names). They are resolved by a pure `EventText.format(text,
state)` in `game/` that the event screen calls. Presentation only: never hashed, never logged.

### 2.8 How the bots play events

Choice order carries no meaning: authors order choices however reads best, and no bot takes "the first".

**Class choices first (user, 2026-11-21).** When a page has enabled class choices (2.9, tag `Choice.Class`), every
policy picks among them only: the smart policy the best-scoring one, the others a random one. The rest of this section
applies to pages without one.

**Choice tags.** `EventChoice.tags: Array[StringName]` (`gas::tag`) says what a choice gives and costs, the way
`Ability.Role.*` says what an ability does for Auto. A choice carries every tag that applies:
```
Choice.Gain.Item | .Armor | .BossItem | .Coins | .Keys | .Heal | .Xp | .Level | .Reveal | .Chest
Choice.Cost.Coins | .Keys | .Hp | .Item | .Life (a member is slain) | .Curse
Choice.Fight | Choice.Gamble (a random page follows) | Choice.Leave
Choice.Class (a class choice, 2.9)
```
Example: Blood Fountain's drink is `Gain.Item` + `Cost.Hp`, and Gambler's Table's bet is `Gamble` + `Cost.Coins` + `Gain.Coins`.
The tags are read only by the bots and analytics. The run never reads them, and they are never hashed.

**The smart policy scores the enabled choices** (`EventScorer` in `game/auto/`, beside `AutoPolicy`):
- gains add, costs subtract, and each term is weighed by the run's state:
  - `Cost.Hp` counts for little at a high party HP share and a lot when low;
  - `Cost.Life` is refused unless the choice also gives `Gain.BossItem` and three or more members are alive;
  - `Cost.Coins` / `Cost.Keys` count by what remains after paying;
  - `Fight` is avoided when the party's HP share is low;
  - `Gamble` halves its gains;
  - `Heal` is worth more the lower the HP;
  - `Leave` scores 0.
- It takes the highest score. Ties are broken on the policy's own stream (below).
- The weights are bot code, not game balance, and live as constants in `EventScorer`.

**The auto, scripted and chaos policies pick a random enabled choice**, so the reports also show what an event costs a
player who chooses blindly. The pick (and the smart policy's tie-break) comes from the policy's own stream, never the
run's, like today's route choice: `dev/event/<floor>/<cell>/<n>`, where `n` counts the bot's picks in this event. A
looping choice (Wishing Well) ends once Leave is drawn (random) or scores best (smart), and the step cap still guards. The
run itself is unchanged, since the pick is an ordinary logged `choose`.

**The validator checks the tags against the outcomes** (like `role_missing` / `role_mismatch` for abilities):
- `choice_tags_missing` (warning): a choice with outcomes and no tags;
- `choice_tag_mismatch` (warning): a tag the outcomes contradict, or an outcome with no matching tag, e.g.:
  - `GiveItem` without `Gain.Item` (or `Gain.BossItem` for a `Pool.Boss` query);
  - `GiveEquipment` → `Gain.Armor`; `GainCoins` / `LoseCoins` → `Gain.Coins` / `Cost.Coins`; `StartEncounter` → `Fight`;
    `GoToRandomPage` → `Gamble`; an `Item.Curse` given → `Cost.Curse`;
  - an `ApplyMemberEffect` / `ApplyPartyEffect` whose effect carries the slay or a damage tag without `Cost.Life` /
    `Cost.Hp`, a heal without `Gain.Heal`;
  - an outcome-less choice that ends the event without `Leave`.

  Outcomes behind a `GoToPage` / `GoToRandomPage` are counted for the choice that leads there (one level deep). So a
  gamble's tags cover what its pages can give.

### 2.9 Class choices (FTL's blue options)

A class choice is offered only when the party has a certain class. It is usually a better way through the event: it
skips the cost, skips the roll, or tilts the fight.
- **Condition:** the existing `HasCharacter` (alive), or `AnyOf` over several of them (Rat Nest: Pyromancer or Ember Knight).
- **`EventChoice.show`:** `ALWAYS` (today: a choice whose conditions fail is shown greyed out) or `WHEN_MET` (hidden unless its
  conditions hold). Class choices use `WHEN_MET`. This is display only: the event panel lists the visible choices, but each
  keeps its real index, so `choose(index)`, the log, the hash, the replay and `choice_enabled` are unchanged.
- **The look:** the event panel draws a class choice with the theme variation `EventChoiceClass` (a highlight colour), and its
  label starts with a badge: "[Cleric] Bless the dice". The badge is the display name of the character its `HasCharacter`
  condition names (several: "[Pyromancer / Ember Knight]"). `EventChoice.badge` overrides it when set.
- **Outcomes** can single out that member: `GiveItem` / `ApplyMemberEffect` with `character` (or target CHARACTER), so the
  Cleric receives the item or takes the hit.
- **Validator:** `class_choice_without_character` (error: a `Choice.Class` choice with no `HasCharacter` among its
  conditions), `when_met_without_conditions` (warning: a `WHEN_MET` choice that can never be hidden).

**Analytics bonus:** a logged `choose` already names the choice. Tags let the dashboard aggregate, for example, "risky
choices taken" without knowing any event.

This moves every committed bot-played run: the scripted and keyed run goldens (`run_scripted.json`, `run_keyed.json`) and
the play-report golden (`seed_report_play.json`). Per the ownership rules they are re-recorded only after the user
confirms the diff is this change. The balance gate is re-measured (5c re-tunes it).

## 3. Data contracts

**N/A on the wire:** no `Rpg.Contracts` record changes, no queue, no topic, no Redis key. Godot only:
- `GiveItem.Recipient` + `SLOT`, `LOWEST_HP`, `FLOOR`; `GiveItem.slot`; `GiveEquipment.on_floor`;
- outcomes `ApplyMemberEffect`, `GoToRandomPage`; `RemoveItem` + `item_query`, `from`, `slot`;
- conditions `MemberAt`, `FloorAtLeast`, `HoldsItemTag`, `AnyOf`, `NotCondition`;
- `EncounterDefinition.party_grants: AbilitySet`;
- `state.event["draws"]` (inside the open event, already hashed and in `RunSnapshot`);
- `EventText` (presentation helper);
- `EventChoice.tags` and the `Choice.*` tags (2.8); `EventScorer` in `game/auto/`;
- `EventChoice.show` (`ALWAYS` / `WHEN_MET`) and `EventChoice.badge` (2.9);
- tags: `Event.Cellar`, `Event.Crypt`, `Event.Forge`, `Event.Hollow`, `Event.Cathedral`, `Event.Vault`, `Event.Coven`,
  `Event.Void`, `Encounter.Event`, `Item.Boon` (through `sync_tags`; `godot_gas/` edits prompt);
- validator codes: `member_slot_out_of_range` (a slot outside 1..the run's party size, error), `event_encounter_in_pool`
  (an `Encounter.Event` encounter that a chapter query matches, error), `event_item_pooled` (an `Item.Curse` / `Item.Boon`
  with a `Pool.*` tag, warning), `random_page_invalid` (no pages, a page out of range or a weight ≤ 0, error),
  `party_grants_not_turn_based` (error), `event_text_token_unknown` (warning), `choice_tags_missing` and
  `choice_tag_mismatch` (warnings, 2.8), `give_floor_outside_room` (FLOOR / `on_floor` in an item hook or at the
  rest stop, warning), `class_choice_without_character` (error) and `when_met_without_conditions` (warning) (2.9).

### 3.1 Content changes to existing design files (shown as old → new before editing)

- The 8 chapters' `event_query`: `require_all_tags [Event.Demo]` → `require_any_tags [Event.Demo, Event.<Chapter>]`.
- `rooms/nook.tres` weight 1 → 0.3 (2.5).
- `Choice.*` tags added to every choice of the 8 existing events (each event's tags listed before editing).
- The new tags `Choice.Gain.*`, `Choice.Cost.*`, `Choice.Fight`, `Choice.Gamble`, `Choice.Leave` and `Choice.Class` in the
  registry (`sync_tags`).
- `presentation/demo/ui/event_panel.gd`: hide `WHEN_MET` choices that fail, keep each visible choice's real index, add
  the badge and the class look; `ui_theme.tres`: the `EventChoiceClass` variation (2.9). Both are presentation files, so
  the diff is shown before editing.

### 3.2 The new content (new files only)

Numbers below are **starting proposals for the user to tune**. Once built, the GodotGAS resources hold the numbers (root
rule 4). "% HP" means % of max HP, as an instant field effect (`effects/events/hurt_<n>.tres`, `heal_<n>.tres`,
`slay.tres`, made once and reused). Every event has a "Leave" (ends the event, nothing happens) unless its row says
otherwise. The tables list it last, but order has no meaning (2.8). Every choice
carries the `Choice.*` tags its outcomes call for (2.8), read off the event tables below.

**Event-only items (4):**
| Item | Tag | Grants (proposal) | Given by |
|---|---|---|---|
| Curse of the Vampire | `Item.Curse` | new ability **Blood Drain** (Physical damage, heals the user for part of it); −15% max HP while held | Vampire's Crypt |
| Leech | `Item.Curse` | +12% ATK; −10% DEF | Leech Pool |
| Smith's Brand | `Item.Boon` | new ability **Molten Strike** (Fire damage, breaks toughness well); takes +15% Ice damage | Smith's Brand |
| Void Mark | `Item.Curse` | new ability **Unmake** (dispels a buff, then damages); −10% max SP | Nameless Gift |

The new abilities reuse existing animations and carry the usual `Ability.Usage.*` / `Ability.Role.*` tags and SP costs
(`build_cost_pass` rules).

**Event-only encounters (11 here, plus 3 for class choices below, 14 in all)**, `Encounter.Event`, existing enemies: `event_ambush` (enemies start with Haste; party
starts Slowed), `event_sparring` (one Knight), `event_watchman` (a Knight; reward 2 keys), `event_vampire` (Bat swarm,
enemies Hasted; reward a Rare item), `event_furnace` (Forge line; party starts Burning; reward 3 keys),
`event_beast` / `event_beast_awake` (Hollow elites, `level_bonus` +2; the first with enemies Weakened, the second with the
party Slowed; reward a `Pool.Boss` item and 30 coins), `event_paladin` (Glass Saint + Penitent Knight, +2; party starts
Warded; a `Pool.Boss` item), `event_tax` (Tally Clerks; 50 coins), `event_hag` (Hag Sister + Familiars, +2; party starts
Weakened; a `Pool.Boss` item), `event_reflection` (a new event-only enemy, a Hollow Echo copy with
`mirror_party_items`, +2; a `Pool.Boss` item).

**General events (`Event.Demo`, 10 new + the 8 existing):**
| # | Event | Choices → outcomes |
|---|---|---|
| G1 | Gambler's Table | Bet 15 coins (`CoinsAtLeast` 15) → random page 50/50: +35 coins / lost · Leave |
| G2 | Wishing Well | Throw 5 coins → random: 25% a Treasure item (CHOOSE) / 75% "nothing"; both pages offer another throw · Leave |
| G3 | Blood Fountain | "{member:1} drinks" (`MemberAt` 1) → slot 1 hurt 30%, a Treasure item to SLOT 1 · Leave |
| G4 | Weapon Rack | Take a weapon → a pooled weapon (GiveEquipment query), then random 50%: the rack falls on {member:2} (hurt 25%) / fine · Leave |
| G5 | Keyhole Wall | Spend a key (`KeysAtLeast` 1) → GiveChest Wooden · Pick the lock (`HasCharacter` Ranger) → the same, free · Leave |
| G6 | Idol of the Last | Offer {member:4} (`MemberAt` 4) → slot 4 slain, the party gains 1 level · Leave |
| G7 | Ambush! | Fight (the only choice) → `event_ambush`; win: 25 coins and a Treasure item |
| G8 | Sparring Ring | Spar → `event_sparring`; win: XP of two battles · Leave |
| G9 | Fortune Teller | Pay 10 → reveal the floor · Pay 25 → reveal and a golden key · Leave |
| G10 | Lost Satchel | Open → random: 40% a food item to LOWEST_HP / 40% 15 coins / 20% a snake bites a RANDOM member (hurt 20%) · Leave |

**Found events (`Event.Demo`, 8 new): one short page, one take-it choice, and Leave.** Isaac-style things lying in the
room. Their prop is the room's existing event prop. A chest or item they give is drawn by the room view like any chest
or drop.
| # | Event | Text (proposal) → outcome of "Take" |
|---|---|---|
| F1 | Skeleton's Keys | "Two keys lie beside a skeleton." → +2 keys |
| F2 | Golden Chest | "A gilded chest sits in the middle of the room." → GiveChest Gilded (needs a key to open) |
| F3 | Wooden Chest | "A plain wooden chest, unlocked." → GiveChest Wooden |
| F4 | Abandoned Pack | "Someone left in a hurry." → a Treasure item, FLOOR |
| F5 | Armor Stand | "A dusty stand still holds its armor." → a pooled armor piece, `on_floor` |
| F6 | Picnic Remains | "Not everything has gone bad." → a food item, FLOOR |
| F7 | Coin Purse | "A torn purse, coins spilling out." → +25 coins |
| F8 | Scrawled Map | "A map scratched into the wall." → reveal the floor |

**Chapter events (`Event.<Chapter>`, 3 each):**
| # | Chapter | Event | Choices → outcomes |
|---|---|---|---|
| C1 | Cellar | Rat Nest | Reach in → {member:1} hurt 15%, +20 coins · Burn it (`AnyOf` Pyromancer, Ember Knight) → +20 coins · Leave |
| C2 | Cellar | Forgotten Pantry | Eat → a food item to LOWEST_HP · Search deeper → random 50%: a Treasure item (CHOOSE) / a Slime pair fight · Leave |
| C3 | Cellar | Drunk Watchman | Bribe 10 coins → 1 key · Steal his keys → `event_watchman` · Leave |
| C4 | Crypt | Open Grave | Dig ({member:2}) → slot 2 hurt 20%, a pooled armor piece (`prefer_open_slot`) · Leave |
| C5 | Crypt | Bone Dice | Roll → random 50%: the party heals 30% / the party is hurt 15% · Leave |
| C6 | Crypt | Vampire's Crypt | Stake it → `event_vampire` · Let it bite {member:1} → Curse of the Vampire to SLOT 1 · Leave |
| C7 | Forge | Smith's Brand | Take the brand ({member:3}) → Smith's Brand to SLOT 3 · Leave |
| C8 | Forge | Slag Pit | Throw in a treasure (`HoldsItemTag` Pool.Treasure) → RemoveItem RANDOM Pool.Treasure, a `Pool.Chest` item (CHOOSE) · Leave |
| C9 | Forge | Runaway Furnace | Shut it down → `event_furnace` · Run → the party is hurt 10% |
| C10 | Hollow | Heart Altar | Offer blood (`PartyHpAtLeast` 40) → the party is hurt 25%, a `Pool.Boss` item (CHOOSE) · Leave |
| C11 | Hollow | Leech Pool | Bathe ({member:4}) → Leech to SLOT 4, the party heals 20% · Leave |
| C12 | Hollow | Slumbering Beast (event boss) | Wake it → `event_beast` · Sneak past → random: 60% a Treasure item / 40% it wakes → `event_beast_awake` · Leave |
| C13 | Cathedral | Confessional | Confess (`HoldsItemTag` Item.Curse) → remove one curse, the party heals fully · Donate 30 coins → the party gains 1 level · Leave |
| C14 | Cathedral | Choir Loft | Sing along (`HasCharacter` Bard) → XP of two battles · Listen → the party heals 15% · Leave |
| C15 | Cathedral | Fallen Paladin (event boss) | Fight → `event_paladin` · Kneel ({member:1}) → slot 1 hurt 40%, a Rare item · Leave |
| C16 | Vault | Tax Collector | Pay 25 coins (`CoinsAtLeast` 25) · Refuse → `event_tax` (no Leave) |
| C17 | Vault | Golden Idol | Take it → a `Pool.Boss` item (CHOOSE), then random 50%: the party is hurt 30% / nothing · Leave |
| C18 | Vault | Appraiser | Sell {member:1}'s treasure (`HoldsItemTag` Pool.Treasure, slot 1) → RemoveItem SLOT 1, +40 coins · Leave |
| C19 | Coven | Witch's Brew | {member:1} drinks → random 50%: slot 1 heals fully / slot 1 hurt 40% · Leave |
| C20 | Coven | Blood Effigy | Burn {member:4}'s effigy (`MemberAt` 4) → slot 4 slain, a `Pool.Boss` item (CHOOSE) · Leave |
| C21 | Coven | Hag's Bargain (event boss) | Fight → `event_hag` · Pay 2 keys (`KeysAtLeast` 2) → a `Pool.Void` item (CHOOSE) · Leave |
| C22 | Void | Your Reflection (event boss) | Face it → `event_reflection` · Leave |
| C23 | Void | Void Rift | Step in → {member:1} hurt 25%, reveal the floor, a golden key · Leave |
| C24 | Void | Nameless Gift | Accept ({member:3}) → Void Mark to SLOT 3, lose 2 keys (`KeysAtLeast` 2) · Leave |

**Class choices (35, added to the events above; 2.9).** Each is `WHEN_MET`, tagged `Choice.Class` plus its gain and
cost tags. Every class appears at least twice.
| Event | Class | Choice → outcome |
|---|---|---|
| G1 Gambler's Table | Bard | Charm the dealer → +35 coins, no bet |
| G2 Wishing Well | Cryomancer | Freeze the water and climb down → a Treasure item (CHOOSE), the event ends |
| G3 Blood Fountain | Cleric | Purify it → a Treasure item to the Cleric, no HP lost |
| G4 Weapon Rack | Bulwark | Brace the rack → the weapon, no roll |
| G5 Keyhole Wall | Ranger | Pick the lock → the Wooden chest, free (already in the row) |
| G6 Idol of the Last | Ember Knight | Melt the idol down → +40 coins, nobody slain |
| G7 Ambush! | Ranger | Spot them first → `event_ambush_spotted` (the same enemies Slowed, the party Hasted) |
| G8 Sparring Ring | Warrior | Teach them a lesson → XP of two battles, no fight |
| G9 Fortune Teller | Shatterweaver | Gaze through your own crystal → reveal and a golden key, free |
| G10 Lost Satchel | Plaguewright | Check it for vermin → a food item to LOWEST_HP and 15 coins, no snake |
| F8 Scrawled Map | Arcanist | Decipher the margins → reveal and a golden key |
| C1 Rat Nest | Pyromancer / Ember Knight | Burn it → +20 coins (already in the row) |
| C2 Forgotten Pantry | Cryomancer | Keep it fresh → two food items, FLOOR |
| C3 Drunk Watchman | Bard | Drink with him → 2 keys, free |
| C4 Open Grave | Warrior | Dig it out yourself → the armor piece, the Warrior hurt 10% instead |
| C5 Bone Dice | Cleric | Bless the dice → the party heals 30%, no roll |
| C6 Vampire's Crypt | Ranger | Stake it in its sleep → a Rare item, no fight |
| C7 Smith's Brand | Ember Knight | Take the brand yourself → Smith's Brand to the Ember Knight |
| C8 Slag Pit | Pyromancer | Melt it out of the slag → a `Pool.Chest` item, the treasure kept |
| C9 Runaway Furnace | Cryomancer | Freeze the furnace → 3 keys, no fight |
| C10 Heart Altar | Plaguewright | Feed it poison instead → a `Pool.Boss` item, the party hurt only 10% |
| C11 Leech Pool | Bulwark | Wade in armoured → the party heals 20%, no Leech |
| C12 Slumbering Beast | Ember Knight | Smoke it out → the Treasure item, no roll |
| C13 Confessional | Cleric | Absolve (`HoldsItemTag` Item.Curse too) → remove a curse, the party heals fully and gains 1 level |
| C14 Choir Loft | Bard | Sing along → XP of two battles (already in the row) |
| C15 Fallen Paladin | Warrior | Fight shield to shield → `event_paladin_warrior` (the same fight, the party starts Warded and Hasted) |
| C16 Tax Collector | Arcanist | Forge the receipt → pay nothing |
| C17 Golden Idol | Ranger | Swap it for a sandbag → the `Pool.Boss` item, no trap roll |
| C18 Appraiser | Bard | Haggle → +60 coins instead of 40 |
| C19 Witch's Brew | Plaguewright | Drink it safely → the Plaguewright heals fully |
| C20 Blood Effigy | Shatterweaver | Shatter the effigy → a `Pool.Void` item, nobody slain |
| C21 Hag's Bargain | Arcanist | Out-hex the hag → a `Pool.Void` item, free |
| C22 Your Reflection | Shatterweaver | Break the mirror first → `event_reflection_broken` (the reflection starts Weakened) |
| C23 Void Rift | Cryomancer | Freeze the rift's edge → reveal and a golden key, no HP lost |
| C24 Nameless Gift | Bulwark | Take the mark yourself → Void Mark to the Bulwark, the keys kept |

Count per class: Warrior 3, Cleric 3, Arcanist 3, Bard 4, Ranger 4, Cryomancer 4, Pyromancer 2, Bulwark 3, Ember Knight 4,
Shatterweaver 3, Plaguewright 3. Three more event-only encounters: `event_ambush_spotted`, `event_paladin_warrior`,
`event_reflection_broken` (14 in all). The 8 existing events get no class choices in this pass. They can follow when the
user tunes them.

Per chapter, a run sees the 26 general and found events plus its 3. Vault and Void are the last floor (10), so their events matter
only for the final boss (D5).

## 4. Failure modes

| # | Failure | Behaviour | Test |
|---|---|---|---|
| F0 | A FLOOR item from an event, taken or left | A free pickup in the event's room: taken with `take`, or left (`dropsLeftBehind`). Its offer travels with the logged action, and the replay matches | `test_floor_recipient_lands_in_room` |
| F1 | SLOT names an empty, dead or full position | The gift goes to the first member who can hold it (warns), and an effect applies to nobody | `test_slot_recipient_falls_back` |
| F2 | An event kills the last living member | The run ends Lost, as any wipe does | `test_event_wipe_loses_the_run` |
| F3 | An event slays a member | The member is dead (revivable like any death), and their items stay held | `test_event_slay_marks_dead` |
| F4 | A random page or recipient after a snapshot taken mid-event | Same draw: `state.event["draws"]` restores with the event | `test_event_draws_survive_restore` |
| F5 | `party_grants` and replay | The verifier rebuilds them by encounter id, and the hash matches. An encounter id changed in the log gives ConditionsMismatch | `test_party_grants_replay`, `test_step_runner` |
| F6 | RemoveItem matches nothing | Nothing happens. The choice should be guarded by `HoldsItemTag` | `test_remove_by_query` |
| F7 | A client fakes an outcome (another member, another page) | The state hash differs: rejected 2002, rollback | `test_faked_event_outcome_rejected` (step tamper case) |
| F8 | An event-only encounter or item leaks into a pool | Validator errors/warnings (`event_encounter_in_pool`, `event_item_pooled`) | `test_event_pass_validator` |
| F9 | Runs that use none of the new outcomes | Hash, streams and goldens unchanged (the old `recipient/` stream stays for the existing RANDOM gift) | the existing goldens |
| F10 | An event boss win | No gems (not `Enemy.Boss`), and the item lands on the floor | `test_event_boss_pays_no_gems` (settlement facts) |

Replay mismatches follow the root error contract: a verdict with `errorCode` 2002, never an HTTP 422.

## 5. Observability

No Prometheus change. The play report (`seed_report --play`) gains `eventsEntered` per run, a per-event table (times
entered, choice picked, members slain, run lost in or right after it) and `eventMemberDeaths`. `seed_report` (not
playing) already counts events per floor and adds the run total, so the 10–20 band is visible. Console: `event <id>` opens
an event in the current room (dev, local mode, logged cheat) so every event can be played headless.

## 6. Test plan

Godot, on fixtures (an in-memory event world like `keys_world.gd`, with small events per new outcome and condition):
- each outcome and condition in sections 2.1–2.4, including F1–F6 and F9;
- determinism: the same seed and choices give the same hash twice; a snapshot mid-event restores to the same next draw;
- the bots: `test_bot_event_choice_random` (only enabled choices, drawn from `dev/event/...`, the same seed picks the same
  choices, the run's own streams untouched), and a looping event ends;
- class choices:
  - `test_class_choice_hidden_unless_met`: hidden without the class, shown with it, and a dead member hides it;
  - indices unchanged: the log and the hash are the same as with the choice shown;
  - the badge, including several characters and an override;
  - `test_bots_take_class_choices`: every policy, and smart among several;
  - the two validator codes;
- `test_event_scorer`:
  - takes a free item over Leave;
  - refuses `Cost.Life` except for a boss item with three or more alive;
  - avoids `Cost.Hp` and `Fight` at a low HP share but takes them at full HP;
  - prefers `Heal` when hurt;
  - ties broken on the bot's stream;
- `choice_tags_missing` / `choice_tag_mismatch` on broken fixtures (one per rule, including a tag behind a random page);
  every demo event's choices pass;
- `party_grants` on the fixtures' battle (applied after items, turn-based, replayed by `ReplayRunner` to the same hash);
- `EventText` tokens (present, empty position, unknown token);
- validator codes in section 3 (broken fixtures);
- content: `validate_content` clean; a `dev_run` script plays every new event once through the `event` command (each
  choice at least once across seeds) with no script errors;
- frequency: `seed_report` over 200 seeds, events per run averaged (reported, in the 10–20 band);
- balance: the smart 4-member play report on the 600 balance seeds before and after (reported, not asserted; the gate
  moves on purpose and 5c re-tunes it).

## 7. Decisions, open questions, what stays out

**Proposed (for the user to confirm):**
- D1. Recipients use party position (1–4) with a FIRST fallback. Guarded choices keep the text true.
- D2. Curses and boons are unpooled items (2.6), never a direct AbilitySet grant.
- D3. Event bosses are elites with `level_bonus`, not `Enemy.Boss` (no gems, no rotation effect). The alternative: real
  bosses, which pay their boss reward once per cycle.
- D4. The Collector's mirror skips `Item.Curse` (add it to its `mirror_skip_tags`), so it never copies a curse. Boons
  are copied.
- D5. Vault and Void (the last floor) keep events, though their rewards matter only for the final boss.
- D6. Frequency by the nook's weight alone (2.5). If floor 1 often has no event, a per-floor minimum could follow later.
- D7. Choice order is free (user, 2026-11-21). Choices carry `Choice.*` tags. The smart policy scores them, and the
  auto, scripted and chaos policies pick at random. Both use the bots' own stream, and the bot-played goldens are
  re-recorded on confirmation (2.8; user, 2026-11-21).
- D8. Class choices (2.9): `WHEN_MET` and badged, one in each new general and chapter event and in the Scrawled Map (the
  other found events stay simple), every class at least twice, and all bots pick them first (user, 2026-11-21).

**Open:** how a FLOOR item from an event is uploaded. The plan is the `choose` action carrying an `ItemOffer` with
source `Other`, the same way boss-drops put `Drop` offers on the `battle` action. If analytics needs a separate `Event`
source, that is a new `OfferSource` value, which is a contract change in `Rpg.Contracts`, so it would be raised before
building.

**Open:** can a member refuse a curse (an event that says "{member:1} is bitten" with no choice)? Proposed no: curses
always come from a choice.

**Stays out:** events that unlock across runs, statuses carried from the field into the next battle (would need the
battle snapshot to carry them), choosing which member a random outcome hits (CHOOSE for effects), events offered in
shops, and any server change.
