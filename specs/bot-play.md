# Spec: bot-play (before 5c `card-balance`)

Status: **spec written 2026-11-22, awaiting the user's review.** The first of four slices the user asked for on 2026-11-22
before 5c: `bot-play` (this), `item-power` (run-winning items, weapons and armor; copies stack), `level-99` (the level
cap, growth and high-level moves) and `second-pack` (a second card pack with three new characters). Bots come first:
balancing items while the bots play badly would measure the bots, not the items. Builds on `specs/game-skeleton.md`
section 6 (`RunPlayer`), `specs/playable-demo.md` 2.3 and 3.9 (the play report, the smart policy),
`specs/keys-and-gear.md` 3.5 (keys, chests, gear on the map), `specs/event-pass.md` 2.8 (`EventScorer`),
`specs/floor-rooms.md` (challenge rooms, armories), `specs/auto-battle.md` (`Ability.Role.*`, `build_role_pass`).

## 1. Purpose & enterprise mapping

**Purpose.** The run bots (`game/dev/run_player.gd`) make poor run decisions, and the smart 4-member gate (11.8% after
5d) measures those decisions as much as the game. Today the bots:
- **explore by accident:** they enter the unvisited room with the lowest index next to a visited one, so the boss is
  fought whenever its index comes up (after any locked or challenge room they can take), not by a plan;
- **place items blindly:** a passive item goes to the first member who can hold it (food to the lowest HP share), and
  passives never move again (`move_item` moves use items only), so the first pick is final;
- **wear gear blindly:** a piece goes on the first living member with that slot empty; nothing is compared, upgraded or
  swapped;
- **shop blindly:** they buy whatever is affordable, in shelf order, for the first member who can hold it;
- **use field actions blindly:** the first field option, once per floor, whatever the party needs.

This slice makes the **smart** run bot play the run well, with every judgement read from **tags and a data profile**,
so later slices (and, later still, analytics) improve it by data, not code:
1. **Exploration by what a floor can hold** (2.2): explore a floor fully when its floor rules can place rooms worth
   having (item rooms, shops, armories, altars), otherwise go to the boss. With today's content that is the user's rule:
   floors 1-6 (Cellar, Crypt, Forge) and the Vault and Void explored fully; the Hollow, Cathedral and Coven go straight
   to the boss.
2. **Role tags on characters and fit tags on items and gear** (2.3): `Unit.Role.*` says what a character does,
   `Item.Fit.*` what an item or piece rewards, `Item.Grants.*` which role holding it adds. Roles are **live**: a member
   who picks up an item that grants follow-ups is a follow-up character from then on.
3. **Party-aware placement** (2.4): each item, piece and purchase is scored for every member who could take it, against
   what the whole party already holds. Survival spreads (worth less where there is already plenty); damage and procs
   may stack on a carry (worth more where the same kind already sits). **Copies of an item stack** (user, 2026-11-22):
   a copy scores like any other item of its kinds; pools never offer copies, only named items do (`item-power` 2.2).
4. **Gear upgrades and swaps** (2.5) through the existing logged `equip`, `unequip` and `swap_gear`, and use items
   moved with `move_item` where that raises the party's score.
5. **Smarter shops and field actions** (2.6).
6. **Measured, not guessed** (2.7): the report runs the same seeds under different profiles (spread vs carry, full vs
   boss-rush exploration) and prints the difference; the best becomes the smart default. The bots decide by
   conditionals on tags; the profile only holds their numbers. Analytics-driven bots wait for the analytics pipeline
   (user, 2026-11-22).

**Enterprise mapping.** None at runtime: the bots are dev and test tools (local mode, `seed_report --play`, `autorun`,
`dev_run`). Every bot decision is an ordinary logged run action (`take`, `buy`, `equip`, `swap_gear`, `move_item`,
`enter_room`, `use_field`), so a bot-played server run uploads and verifies exactly like a player's; nothing on the wire
changes. No analytics component is built or designed for here. Postgres, Redis, RabbitMQ, Redpanda: not touched.

**Acceptance scenarios covered:** none directly (no server path changes). Bot runs on the e2e stack keep exercising 1-5
as before.

## 2. Sequence flow

### 2.1 Where it runs

```
seed_report --play --policy smart [--bot-profile res://...] [--explore smart|full|boss]
  -> PlayReport -> RunPlayer.play(run, ..., events = smart, bot = BotProfile)
       per map step: gifts -> events -> chests -> pickups (2.4) -> gear (2.5) -> shop (2.6) -> field (2.6)
                     -> stairs (route: unchanged, random on dev/route/<n>) -> next room (2.2)
```

- `RunPlayer.play` gains `bot: BotProfile = null`. **`null` is today's behaviour, unchanged**: the `auto` and `chaos`
  policies, `test_run_scripted` and every committed run golden keep playing (and hashing) exactly as now. The `smart`
  policy passes the smart profile. `chaos` passes it too (chaos is "smart plus bad moves") from this slice on; the
  chaos report's numbers move, its invariants do not.
- Every decision is deterministic from the run state and the profile: integer scores (×100), ties to the lowest slot,
  then the lowest cell index, then the item id **compared as `String`** (root `CLAUDE.md` / `client-godot/CLAUDE.md`
  3: never order `StringName`s by pointer). Anything random stays on the bots' own streams (`dev/...`), never a run stream.
- The bots see what a player could know: the map through `MapCells` visibility and `RunController.room_type_known`, the
  chapter's floor rules (an experienced player knows what a chapter can hold), held items and stats through
  `party_stats()`. They never read unrevealed cells' content or the floor seed's future.

### 2.2 Exploration

`ExplorePlan` (`game/auto/explore_plan.gd`, pure) decides each floor's mode when the floor starts:

```
loot value = sum over the floor rules' special_room_tags of profile.room_values[tag]   (a tag listed 4 times counts 4 times)
mode       = FULL if loot value >= profile.explore_threshold else BOSS      (--explore full|boss forces one for a report)
```

Default room values (profile data, 2.7): `Room.Type.Treasure` 100, `Room.Type.Shop` 60, `Room.Type.Armory` 60,
`Room.Type.Altar` 100, `Room.Type.Challenge` 20; threshold 50. With today's floor rules that gives FULL on `small`
(Cellar), Crypt, Forge, Vault and Void, and BOSS on Hollow, Cathedral and Coven (one challenge room, 20). The rule reads
data, so a new chapter or a changed floor rule needs no bot change.

- **FULL:** visit every reachable room before the boss: the nearest unvisited enterable room by steps through visited
  rooms (BFS on the map, ties by cell index), locked rooms the party can open taken as today (item rooms before shops),
  the boss last. Today's "lowest index next to a visited room" is replaced by "nearest", so the party does not cross
  the floor back and forth.
- **BOSS:** the shortest known path to the boss. While the boss room is not known, explore the nearest unvisited room
  (as a player must). Rooms on the way are fought as they come. A challenge room **found on the way** (known and
  enterable from a room the party has visited) is fought before the boss (user, 2026-11-22); the bot makes no detour
  to look for one. A locked loot room next to the path is opened when the party has a key to spare.
- **Both:** pickups left in a room the party passes are still taken (2.4); a cleared room is never re-entered just to
  walk unless it is on the path.
- The run report adds, per floor, the mode, rooms visited of rooms generated, and items left behind (2.7).

### 2.3 Tags

**Character roles** (`UnitDefinition.tags` on each `CharacterDefinition`; the display string `role` stays as it is):

| Tag | Meaning |
|---|---|
| `Unit.Role.Damage` | deals the party's damage with its own moves |
| `Unit.Role.FollowUp` | deals damage through follow-ups and extra attacks |
| `Unit.Role.Dot` | deals damage over time |
| `Unit.Role.Break` | breaks toughness |
| `Unit.Role.Healer` | heals and revives the party |
| `Unit.Role.Support` | buffs allies, debuffs enemies, cleanses |
| `Unit.Role.Tank` | takes hits for the party (taunt, high HP or DEF) |
| `Unit.Role.Control` | stuns, freezes, delays |

A character has one to three. Proposed for the eleven classes from their `role` strings and moves (applied only after
the user's OK, file by file, `old → new`): Warrior Damage + Tank, Cleric Healer + Support, Arcanist Damage, Bard
Support, Ranger FollowUp + Damage, Cryomancer Control + Damage, Pyromancer Dot + Damage, Bulwark Tank, Ember Knight
Break + Damage, Shatterweaver Break + Support, Plaguewright Dot + Support.

**Item and gear fit** (`ItemDefinition.tags`, `EquipmentDefinition.tags`): what it rewards, one or more of
`Item.Fit.Damage` (ATK, damage dealt, crit, weakness damage), `Item.Fit.FollowUp` (follow-ups, on-hit procs),
`Item.Fit.Dot`, `Item.Fit.Break`, `Item.Fit.Healing` (healing given), `Item.Fit.Survival` (HP, DEF, damage taken,
healing received, lifesteal, revives on self), `Item.Fit.Speed`, `Item.Fit.Sp` (SP gain and costs), `Item.Fit.Ult`
(ult charge), `Item.Fit.Control`, `Item.Fit.Party` (the effect covers the party: the holder matters only for staying
alive), `Item.Fit.Run` (coins, keys, chests, map: the holder does not matter).

**Granted roles** (`Item.Grants.FollowUp`, `Item.Grants.Dot`, `Item.Grants.Healer`, `Item.Grants.Tank`, ...: the same
suffixes as `Unit.Role.*`): holding the item adds that role to the holder's live roles. Kindled Edge, Hunter's Mark and
the Executioner's Seal grant FollowUp; Cinder Glove and Molten Core grant Dot; Thorn Mail grants Tank.

**Live roles** = the class's `Unit.Role.*` ∪ every `Item.Grants.*` of the member's held items and worn pieces,
recomputed after every pickup, equip, swap or move (`LootScorer.roles_of(run, slot)`).

**Proposal pass and checks**, the `build_role_pass` pattern (spec `auto-battle` A6):
- `game/tools/build_fit_pass.tscn` reads each item's and piece's GAS data and proposes its fit and grant tags:
  modifiers on `atk` / damage-dealt attributes → Damage, on `max_hp` / `def` / damage-taken → Survival, a granted
  ability with `Ability.Type.FollowUp` → Fit.FollowUp + Grants.FollowUp, a DoT status → Dot, `toughness_dmg` → Break,
  healing given → Healing, `spd` → Speed, SP attributes → Sp, ult charge → Ult, `applies_to` PARTY → Party, run hooks only
  (coins, keys, chests, reveal) → Run. Dry run by default, one line per file; `? none found` for a human to decide.
  `--write` adds the tags to the `tags` line as a text edit, nothing else in the file; **run with `--write` only with the
  user's one-off OK** (it edits existing design files in `content/`).
- Validator (`content_validator.gd`): `fit_missing` (an item or piece in a pool with no `Item.Fit.*`, an error once the
  pass has run on the demo), `fit_mismatch` (the pass would propose a kind the tags lack: a warning), `role_tag_missing`
  (a selectable character with no `Unit.Role.*`: an error), `grant_unknown` (an `Item.Grants.*` suffix with no
  `Unit.Role.*` twin).
- New tags in `godot_gas/tag_registry.tres` (prompts) through `sync_tags -- --add-missing`; the bot code's tag lists are
  system tags, so a typo in content or code fails `sync_tags` like `EventScorer.ALL_TAGS`.

### 2.4 Placement: who gets an item

`LootScorer` (`game/auto/loot_scorer.gd`, pure, static) scores a thing for a member:

```
value(thing, member) = sum over fit in thing's Item.Fit.* tags of
                         profile.fit_weight[fit][best live role of member for that fit]      (×100)
                         × stack_factor(fit, count of the member's held things with that fit)
                       + for each Item.Grants.* the thing adds that the member lacks: profile.new_role_value
stack_factor:  profile.stack[fit] = {mode: SPREAD | FLAT | CARRY, step_x100}
  SPREAD: 100 - step × held   (floor 25)   survival, healing received: worth less where there is already plenty
  FLAT:   100
  CARRY:  100 + step × held   (cap 200)    damage, follow-ups, dots: worth more where the same kind sits
survival extra:  Item.Fit.Survival × (party's highest max HP × 100 / member's max HP), capped at 200: the frailest first
Item.Fit.Party:  value only from staying alive: the member's Survival-fit count and Tank role rank it; never a dead member
Item.Fit.Run:    the same for every member (first living slot)
copies:          a copy of a held item is a thing with that item's fits; nothing special
```

- **Always used:** the bots take every free pickup and wear every piece they can, as today, except things marked bad
  (`Item.Curse`, 2.5); they only decide *who* gets it. A curse that comes as a price or an event outcome is unchanged
  (it is forced, not chosen).
- **Who:** each free pickup (pedestal, chest item, battle drop, event floor find) goes to the living member with the
  highest value who can hold it (`can_hold`). Food keeps its rule (lowest HP share, spec `food-items` D4) because its
  value is the heal now. A gift waiting for a holder (`give_to`) uses the same choice.
- **Carry:** with a CARRY stack mode, value naturally piles onto whoever already holds that kind. The profile's
  `carry_seed` (default on) gives the first damage-kind item to the member whose live roles score highest for it
  (Damage or FollowUp first), so the carry is a damage dealer, not slot 1.
- **Use items** (usable, limited use slots): the same score; when every slot is full, `move_item` with a swap is
  considered (2.5).
- **Never moves passives.** Passives stay with the holder (the game's rule, D8), so the pickup decision is final.

### 2.5 Gear and use items

After every pickup, battle, or member death or revive, the bot runs a bounded improvement pass:

1. **Equip:** for each piece in the armor inventory, the living member with the highest value for it whose slot is empty
   gets it (`equip`). **A piece is never left in the inventory while some living member has that slot empty** (user,
   2026-11-22): even a piece that scores 0 for everyone is worn (by the first living member with the slot free). The one
   exception is a piece marked bad, `Item.Curse` (pure downside); a trade-off piece (`Item.Corrupted`) is not bad and
   is scored like any other.
2. **Upgrade:** for each piece in the inventory and each living member wearing a piece in that slot: if the new piece's
   value on that member exceeds the worn one's by `profile.swap_margin` (default 15%), `unequip` the old piece and
   `equip` the new one; the old piece returns to the inventory and goes through step 1 again.
3. **Swap between wearers:** for each pair of members wearing the same slot: if `swap_gear` raises the sum of the two
   values by the margin, swap.
4. **Use items:** for each use item and each other member with a free slot (or a lower-valued use item to swap): move
   when it raises the sum by the margin.
5. **Dead members:** a dead member's worn pieces are taken off (`unequip`) and placed on the living by step 1 where the
   rules allow; its passives stay (D8).

Each step only makes moves that strictly raise the party's total score by the margin, and the pass stops after
`profile.max_moves` (default 6) moves per trigger, so it cannot oscillate or flood the log.

### 2.6 Shops and field actions

- **Shop:** items and pieces on the shelf are ranked by best value ÷ price; buy in that order while affordable, keeping
  `profile.key_reserve` (default 1) key's price when a locked loot room is still unopened on the floor and the shop
  sells keys. A thing whose best value is under `profile.buy_floor` is not bought.
- **Field actions** (`field_options()`), read through their abilities' `Ability.Role.*` tags (spec `auto-battle`):
  Revive when a member is dead; Heal when a living member is below `profile.field_heal_below` (default 50% HP) before
  entering a room with a battle, or always before the boss room; RestoreMP when a member is below 30% SP before the boss;
  otherwise nothing. Today's "first option once per floor" goes.

### 2.7 Profiles and measurement

`BotProfile` (`game/auto/bot_profile.gd`, a Resource; system files in `game/auto/profiles/`, bot code, not game balance):
`room_values`, `explore_threshold`, `fit_weight` (fit → role → weight), `stack` (fit → mode,
step), `new_role_value`, `carry_seed`, `swap_margin`, `max_moves`, `key_reserve`, `buy_floor`, `field_heal_below`.
All whole numbers, ×100 where a share. Shipped: `smart.tres` (the default, starts as `spread` or `carry`, whichever
measures better, decision D3), `spread.tres` (every damage kind FLAT), `carry.tres` (damage, follow-ups and dots CARRY).

Report options: `seed_report --play --policy smart --bot-profile res://game/auto/profiles/carry.tres`,
`--explore smart|full|boss`, both passed through `play_sharded.sh`. New report fields:
- `explore`: per chapter, the mode, rooms visited / generated, items and drops left behind, deaths on the floor;
- `placement`: per class, held items by fit kind (mean per run), carry share (the carry's share of the party's damage
  kinds), worn pieces per member, gear swaps and use-item moves per run;
- `itemLift`: per item, runs it was held in, win rate, and lift against the policy's overall rate (like `byPair`);
  **per fit kind on role** (e.g. FollowUp on a FollowUp member vs elsewhere), so the profile's weights are set from
  measurements;
- `shop`: coins spent per floor, things bought by fit kind.

The plan in the build: measure today's smart gate on `main` (600 balance seeds, 4 members) as the baseline, then each
change alone (exploration, placement, gear, shop, field), then the profiles side by side. Results go in section 8.

## 3. Data contracts

N/A: no wire change. Every bot decision is an existing logged run action; `RunAction`, `RunSnapshot` and the run hash are
unchanged. New Godot-side data only: `BotProfile` (2.7), the tags (2.3).

## 4. Failure modes

- **Determinism:** two runs of the same seed and profile make the same decisions (a test plays each profile twice and
  compares run hashes). Ties are broken by slot, cell index and `String` id, never by `StringName` order or dictionary
  order; `test_determinism_guard` covers the new files.
- **Refused actions:** every bot action is checked by the run like a player's. A refusal is a bot bug: the play report
  counts it (`botRefused`, by action and reason) and `--check` fails on any.
- **Oscillation:** the improvement pass only makes moves that raise the total by the margin and stops at `max_moves`
  (2.5); a test builds two pieces of equal value and checks no swap happens.
- **Missing tags:** an item with no `Item.Fit.*` scores 0 for everyone and goes to the first member who can hold it
  (today's rule), counted in the report as `untagged`; the validator flags it (2.3).
- **Unreachable boss in BOSS mode:** the plan falls back to FULL's nearest-room rule when no known path exists; a stuck
  bot still returns `"stuck"` as today.
- **Server runs:** unchanged. A bot on a server run waits at the stairs like today; its extra gear moves are ordinary
  uploads, verified by replay (acceptance scenario 5 still applies to any tampered one).

## 5. Observability

N/A for Prometheus: the bots never run on a server. Observability is the play report (2.7): the new `explore`,
`placement`, `itemLift`, `shop`, `botRefused` and `untagged` blocks in the JSON and the text summary.

## 6. Test plan

New `tests/game/test_bot_play.gd`, on fixtures only (`tests/fixtures/`, a small world built in memory like
`floor_rooms_world.gd`: a two-chapter run, one chapter's rules with a treasure room and one with only a challenge room,
tagged fixture items and pieces):
- `ExplorePlan`: the loot value and mode from floor rules (Treasure → FULL, Challenge only → BOSS, `--explore` forcing);
  FULL visits every reachable room before the boss; BOSS reaches the boss on the shortest known path, explores only to
  find it, takes a challenge room found next to its path and makes no detour for one elsewhere; nearest-room order.
- `LootScorer`: values by fit and role; live roles gain a granted role after a pickup; SPREAD sends a second survival
  item to the other member; CARRY sends a second damage item to the same member; a copy of a held item stacks like a
  same-fit item; Party items go to the sturdiest; Run items to the first living; ties by slot then `String` id.
- Gear: equip into empty slots by value; an upgrade over the margin unequips and re-places the old piece; no swap under
  the margin; no oscillation with equal values; a dead member's pieces move to the living.
- Shop: value ÷ price order, the key reserve, the buy floor.
- Field: revive a dead member, heal below the threshold before a battle room, nothing when healthy.
- `RunPlayer` with `bot = null` is unchanged: `test_run_scripted` and the committed run goldens pass untouched.
- Determinism: each shipped profile played twice on the same seeds gives the same run hashes; the same seeds windowed
  and headless decide the same (the B24 check, one seed).
- Validator: `fit_missing`, `fit_mismatch`, `role_tag_missing`, `grant_unknown` on new broken fixtures
  (`tests/broken_fixtures/`).
- `build_fit_pass`: proposals for fixture items of each kind; `--write` touches only the `tags` line (the file compared
  line by line before and after, on a `user://` copy).
- Play report: the new blocks are present and merge exactly across shards (`play_sharded.sh`), `--bot-profile` and
  `--explore` are honoured, `--check` fails on a refused bot action.

Gate (both suites pass; the balance is measured, not tuned to a number here): the smart 4-member report on the 600
balance seeds before and after, per change and per profile, written into section 8.

## 7. Decisions, open questions, what stays out

**Decisions (user, 2026-11-22):**
- D1. Explore low floors fully; go straight to the boss on high floors, except the Vault and Void (their special items).
  Built as a data rule on what a floor's rules can place (2.2), which gives exactly that on today's content.
- D2. Roles are tags and are live: an item that grants follow-ups makes its holder a follow-up character (2.3).
- D3. Placement weighs the whole party: survival spreads, damage may stack on a carry; which one wins is measured (spread
  vs carry profiles), and the better one becomes `smart.tres`.
- D4. Copies of an item stack; the scorer treats a copy like any same-fit item. Pools never offer copies; only a named
  item (an event outcome by id, a fixed placement) gives one (`item-power` 2.2).
- D5. The bots decide by conditionals on tags; their numbers live in a `BotProfile` data file. Analytics-driven bots
  are out of scope until the analytics pipeline exists.
- D7. The bots always use what they are given: every pickup is taken and every piece worn while a slot is free, unless
  it is marked bad (`Item.Curse`); scoring only picks the holder and the upgrades.
- D6. Stronger Epic and Rare items join the core card set too, not only new Legendaries (that is `item-power`).

- D8. Passive items never move after pickup (Isaac-style, the game's rule stays); the pickup decision is final.
- D9. The route at the floor-8 stairs stays random on the bots' stream `dev/route/<n>` (both endings covered).
- D10. On a BOSS floor a challenge room found on the way to the boss is fought; no detour to find one (2.2).

**Open questions:** none.

**Stays out:** the battle policy (`AutoPolicy` / smart battles), the player's Auto (no run decisions for players), new
items and gear (`item-power`), level changes (`level-99`), analytics projections
(slice 6 onwards), any server change.

## 8. Measurements

To be filled by the build: the baseline smart gate on `main`, each change alone, the profiles side by side.
