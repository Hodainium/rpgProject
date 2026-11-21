# Spec: floor-rooms (slice 5b3)

Status: **draft, awaiting review** (2026-11-21). Roadmap: `specs/roadmap.md` section 5b3. Builds on `game-skeleton` (floor
generator, rooms), `item-pass` (pedestals offering items and equipment from one pool), `keys-and-gear` (locked special rooms),
`playable-demo` 3.7 / 3.11 (rarity weights, XP, enemy drops), `card-collection` 2.5 (the run's card pool), `item-cards` (floor
items as cards) and `cube-style` (looks).

## 0. Decisions

| # | Decision | Source |
|---|---|---|
| D1 | **A challenge room on every floor except the last two, guaranteed.** It is a special room like the shop: one per floor, always placed, on The Descent's floors 1-9 (Cellar, Crypt, Forge, Hollow, and the Cathedral or the Coven); the final floors, the **Vault and the Void, have none**. The roadmap's "has a chance to spawn" is settled as *no chance per floor*. | User, 2026-11-21 |
| D2 | A challenge room is **three waves**: three battles in the same room, one after another, the party carrying HP, SP and ult charge across them (the run's usual carry-over). Clearing the third wave clears the room and shows its reward. | Roadmap 5b3 |
| D3 | The challenge reward is **one item or one piece of equipment** (armor or a weapon), drawn from the shared pool (`offers = ANY`), on a pedestal that shows when the room is cleared, as every pedestal does today. | User, 2026-11-21 (was "rewards an item") |
| D4 | **An armory wherever the item room or the shop spawns, and nowhere else** (today the Cellar, Crypt, Forge and Vault rules; not the Hollow, Cathedral, Coven or Void, which have neither): a special room whose pedestal offers **equipment only**, any slot (accessories too). It is **key-locked like the shop and the item room**: wherever a chapter's rules lock `Room.Type.Treasure` / `Room.Type.Shop`, they lock `Room.Type.Armory` too (from `RunStructure.unlocked_floors` on). | Roadmap 5b3; user, 2026-11-21 |
| D5 | **Item rooms give items only**: the treasure room's and the Vault hoard's pedestals stop offering equipment. Shops and boss rewards are unchanged (they keep the shared pool). | Roadmap 5b3 |
| D6 | **Bigger floors**: more rooms per floor in every chapter's `FloorGenRules`, enough for the two new dead ends plus extra normal rooms. The point is **keys**: every cleared battle room rolls for a key, so more normal rooms are how the player earns enough keys to open the shop, the item room and the armory. | Roadmap 5b3; user, 2026-11-21 |
| D7 | Every number in D2-D6 (room counts, how many waves, which encounters, what the pedestals draw from) is **content data**. The system adds the mechanisms only. | `CLAUDE.md` (data-driven) |
| D8 | A wave is an ordinary logged `battle`. No new run action, no new wire record except two `OfferSource` values (3.2). The run stays a seed plus an ordered log, so the verifier needs no change. | This spec |
| D9 | **The challenge room is not locked.** **Entering it starts the sequence**: no confirm, no break between waves (the next wave starts as soon as one is won). | User, 2026-11-21 |
| D10 | **Rewards only at the end**: a won wave gives nothing (no XP, no enemy drops, no encounter rewards, no coin, key or chest roll). Clearing the last wave gives, once: XP for every enemy of every wave, the room's drop rolls (coins, key, chest) **once, as one room** (three battles are not three room-drop chances), and the reward pedestal. **The waves' encounters never drop anything themselves**: no enemy drops (`EnemyDefinition.drop_item`) and no encounter rewards (`EncounterDefinition.rewards`) in a challenge room, in any wave; only the room gives loot. Item cooldowns still count down per won battle (that is not a reward). | User, 2026-11-21 |

All open questions of the first draft are settled (D3, D4, D9, D10).

## 1. Purpose & enterprise mapping

Playtests found the floors too small and items too rare. This slice changes the floor's room set: bigger floors, a guaranteed
challenge room (three waves for an item or a piece of equipment), a guaranteed armory (equipment), and item rooms that hold items only. It is a **rule
change** on the client: the floor generator, the run hash and the run goldens change, the bots learn the new rooms, and the
balance gate is measured again in 5c.

Backend components it actually uses (all unchanged in shape):
- **GameServerApi**: waves arrive as ordinary `battle` actions in `POST /api/v1/runs/{id}/actions`; a pickup from the new rooms
  carries `OfferSource.Armory` / `OfferSource.Challenge` in its `ItemOffer` (analytics: where players find gear and items).
- **Postgres**: `run_actions` and `battle_sessions` hold the waves like any battle (one session per wave).
- **RabbitMQ + VerifierWorker (headless Godot)**: the step that contains the waves replays them like any battle; a step
  checkpoint can fall between two waves (a battle left pending).
- **Redpanda via the outbox**: no new event. The offers' new `source` values flow into the existing run action payloads.
- **Redis, SignalR, Prometheus**: nothing new (section 5).

Enterprise angle (internal): a schema-evolution exercise on a live contract. The server stores and verifies runs whose floors
changed shape without a code change on the server; only an enum grows, additively, under the golden-contract tests.

## 2. Sequence flow

### 2.1 Floor generation (client, also the verifier)

1. At `next_floor`, `FloorGenerator.generate` reads the chapter's `FloorGenRules`. `special_room_tags` now lists
   `Room.Type.Challenge` (all but the Vault and the Void) and `Room.Type.Armory` (only beside a treasure room or shop) (content,
   4.1). The generator already places one dead end per listed tag, so **no generator code changes for D1 and D4**; the dead ends
   needed grow from 3 to 5 (Cellar, Crypt, Forge), 1 to 2 (Hollow, Cathedral, Coven) and 6 to 7 (Vault), and the bigger room
   counts (D6) make such layouts likely. The validator checks the pairing (`armory_without_item_room`: an armory listed in rules
   with no `Room.Type.Treasure` or `Room.Type.Shop`), so the rule holds for future chapters too.
2. Step 5 picks a room tagged `Room.Type.Challenge` / `Room.Type.Armory` for those cells, as for any special tag.
3. Step 6 (content) resolves a challenge room's **waves** (new, 3.1): for each `RoomWave` of the room, in order, an encounter
   is picked from the wave's query (empty = the chapter's `encounter_query`) on the floor's `content` stream, **without
   repeating an encounter already picked for this room** while another candidate remains; its enemies are resolved with
   `resolve_enemies` (elite rolls included). The cell's `content` becomes
   `{"kind": "waves", "encounter": <wave 1's>, "event": &"", "enemies": <wave 1's>, "waves": [{"encounter", "enemies"}, ...]}`.
4. Step 7 (pickups) draws the pedestals. A placement's new `offers` field (3.1) filters the candidates: `ITEMS` (the treasure
   room, the hoard), `EQUIPMENT` (the armory), `ANY` (default: shops, boss rewards, the challenge reward, today's behaviour).

### 2.2 Playing a challenge room (client)

1. `enter_room(cell)` on a challenge room starts the sequence at once (no confirm; the room is never locked, D9). Logged as
   today: `{"type": "enter_room", ...}`.
2. `_enter_cell` sees `kind == "waves"` and the cell's `wave` index (absent = 0): `pending_battle = {cell, encounter, enemies,
   "label": "/w1"}`, `battle_requested`. The battle id is `<run>/f<n>/c<cell>/w1`, its seed `combat/<cell>/w1`.
3. `fight()` plays it and logs one `battle` entry as today (party state read back, used items applied). On a win:
   - If another wave remains: nothing is given (D10). `cell["wave"] += 1`, `Message.Run.WaveStarted` (`{wave, of}`; a toast
     "Wave 2 / 3"), and the next wave becomes `pending_battle` (`label "/w2"`) inside **the same action**, so a replay of the
     log produces it again. No gift can be waiting (a challenge never drops), so the next wave never waits.
   - After the last wave: XP for all the waves' enemies together (`_award_xp`), then `_clear_room(cell, true)`: the room's
     coin, key and chest rolls **once** on their usual per-cell streams (`drop/<cell>`, `floor/<n>/key/<cell>`), exactly as
     one cleared battle room, `on_room_cleared` hooks, the reward pedestal shows. `_grant_rewards` and `_roll_drops` are
     never called for a wave (D10); the coin roll's variant bonus counts the elites of every wave, as it counts a room's elites.
4. On a loss in any wave the run is Lost, as for any battle.
5. While a wave is pending every other run action is refused ("Finish the challenge first"), as while any battle is pending.

### 2.3 Upload, verify, resume (unchanged machinery)

1. `RunController.journal` turns each wave's `battle` entry into a `RunActionRequest` (state hash after it). A wave won with
   another still to come leaves a battle pending, so it carries a `RunSnapshot` (the rule "a battle left pending", spec
   `server-authority` Part B) with the cell's `wave` and the pending battle (label `/w2`).
2. `ServerLink` batches them to `POST /api/v1/runs/{id}/actions`; the server stores the actions and one `battle_sessions` row per
   wave, writes the step and its outbox job as today.
3. The worker's `StepRunner` restores the step's snapshot, plays the actions through `RunWire.apply` (a `battle` entry through the
   verifier's `ReplayController`); the controller sets up the next wave itself, so the next logged battle's conditions must match
   (`ConditionsMismatch` otherwise, a 2002 verdict).
4. Resume (from the save or `GET /resume`) restores the snapshot: a pending wave comes back as the pending battle.
5. Pickups from the new rooms upload with `OfferSource.Armory` / `OfferSource.Challenge` (`RunWire.offers`).

## 3. Data contracts

### 3.1 Godot content types (system code, `game/defs/`)

- **`RoomWave`** (new `Resource`): `encounter: EncounterDefinition` (fixed) or `content_query: GameplayTagQuery` (empty with no
  encounter = the chapter's `encounter_query`). Nothing else: a wave's difficulty comes from which encounters it draws (an
  elite-only query for wave 3, say), so no new enemy-level field reaches the battle snapshot.
- **`RoomDefinition`**: `ContentMode.WAVES` (appended to the enum, so saved rooms keep their values) and
  `waves: Array[RoomWave]` (used only in that mode; the validator requires at least two waves).
- **`RoomPlacement.offers`**: `enum Offers { ANY, ITEMS, EQUIPMENT }`, default `ANY` (today's shared pool, so every existing room
  draws as before). `pick_pickup` skips the other table; `EQUIPMENT` with nothing left gives **no pickup** (never the
  `fallback_item`, which is an item); `ITEMS` keeps the fallback.
- **Cell state** (`RunState.map` cells): optional `wave: int` on a challenge cell once its first wave is won, and the `waves`
  list in its `content`. Both are hashed through `StateHasher.canonical` and are new optional keys in `RunSnapshot` (only
  present on challenge cells, like `opened` and `chests`), covered by `test_snapshot_fields_are_covered`.
- **Tags** (registry, through `sync_tags`): `Room.Type.Armory`, `Room.Type.Challenge`, `Message.Run.WaveStarted`.

### 3.2 `Rpg.Contracts`

```csharp
// src/Rpg.Contracts/Runs/RunActions.cs: two values appended (additive; existing values keep their names and order).
public enum OfferSource { Treasure, Shop, BossReward, Other, Chest, Armory, Challenge }
```

No other record changes. A wave is a `RunAction` of type `battle` with its `BattleSubmission` as today; its `BattleId` ends in
`/w<k>`. `ReplayResult.Facts.EncounterId` names the wave's encounter.

### 3.3 Queues, topics, Redis

N/A: no new queue, topic, key or lock. Waves use the existing `verify.segment` step jobs; offers ride the existing run action
events.

## 4. Content (the user's folders: proposals, shown as `old → new` before any edit)

### 4.1 Proposed content (new files are listed with every value picked; existing files are changed only after the user's OK)

- New rooms in `content/demo/rooms/`: `challenge.tres` (`Room.Type.Challenge`, `Chapter.Demo`, `WAVES`, three `RoomWave`s with
  empty queries, so every chapter draws its own encounters; one `ITEM_PEDESTAL` with `item_query` `Pool.Treasure`,
  `offers = ANY` (items and equipment, D3); four enemy spawns like `arena.tres`) and `armory.tres` (`Room.Type.Armory`, `Chapter.Demo`, `NONE`, one
  `ITEM_PEDESTAL` with `item_query` `Pool.Treasure`, `offers = EQUIPMENT`). One door each (dead ends).
- Existing `treasure.tres` and `hoard.tres`: their pedestals get `offers = ITEMS` (D5).
- Existing `floor_rules/*.tres`: `special_room_tags` gains `Room.Type.Challenge` in `small`, `crypt`, `forge`, `hollow`,
  `cathedral`, `coven` (not `vault`, `void`), and `Room.Type.Armory` in `small`, `crypt`, `forge`, `vault` (the rules with a
  treasure room or shop); room counts grow in all eight. Starting proposal (to be measured, 6.3): `base_rooms` +3 and `max_rooms` +4 per chapter (`small` 5/8 → 8/12, `crypt`
  6/9 → 9/13, `forge` 7/10 → 10/14, ...), `grid_size` 11 × 10 for `small` and `crypt` (today 9 × 8), so five dead ends fit.
- Existing `floor_rules/small.tres`, `crypt.tres`, `forge.tres` (the rules that lock today): `locked_room_tags` gains
  `Room.Type.Armory` (D4). The other five lock nothing today and keep it that way, the armory included.
- The Vault (four treasure rooms and a shop) gets an armory and no challenge room; the Void (three altars) gets neither (D1, D4).

### 4.2 Looks (presentation, user gate)

- Map icons: `presentation/demo/ui/icons/map/` gains a crossed-swords icon (Challenge) and an anvil or shield (Armory) from
  game-icons.net (CC BY 3.0, credited in `CREDITS.md`), named in `map_icons.gd` (`NAMES` "TRIAL" / "ARMORY", the legend).
- In the room: the room view shows a look per room type (`StyleRegistry` gets an optional `room_looks` map by `Room.Type.*`
  tag: attachment-shape props on free tiles, as `PropView` draws pickups): proposal, weapon racks for the armory, four braziers
  in the corners for the challenge room that light one by one per wave won. Shown live before the user picks (memory: demo every
  new effect).
- No entry confirm (D9).
- The wave toast: one rule in `run_toasts.tres` on `Message.Run.WaveStarted` ("Wave 2 / 3"); the battle HUD shows the wave in
  its turn-order header while a challenge runs.

## 5. Failure modes

| Case | Behaviour | Test |
|---|---|---|
| A floor's rules cannot place their dead ends (up to seven, the Vault) | `generate` already fails after `max_attempts` with a named error (a runner error, not a silent floor). The content gate prevents it: the seed report over 1000 seeds per chapter must show 0 failures (6.3), and the validator warns when `max_rooms` is too small for `1 + special_room_tags.size()` dead ends. | `test_floor_rooms::test_every_chapter_places_its_rooms`, validator `floor_rules_too_small` |
| An app restart or a lost connection between waves | The won wave left a battle pending with a checkpoint snapshot; resume restores the cell's `wave` and the pending wave. | `test_floor_rooms::test_resume_between_waves` (save and server log paths) |
| Server conflict (1103) or rollback (1108) mid-challenge | The run rebuilds from the server's state, which is a checkpoint before, between or after waves; nothing new. | covered by the existing rebuild tests plus `test_resume_between_waves` |
| A tampered upload: a wave skipped, waves reordered, wave 2's enemies changed, a challenge cleared after one wave, rewards claimed after wave 1 | The replay builds the next wave itself, so the logged battle's conditions differ (`ConditionsMismatch`) or the claimed hash differs (`StateHashMismatch`): a **verdict with errorCode 2002**, never an HTTP error. | `test_step_runner`: one tampered copy per case; e2e `tamper-waves` (acceptance scenario 5) |
| A duplicate upload of a wave | Idempotent by seq as every action (scenario 1 already covers it). | existing |
| A locked armory and no key | Refused like any locked room ("Locked: you need a key"); the map flashes the lock (spec `ui-feedback`). | existing lock tests, plus an armory case |
| Armory with no equipment left in the pool (held, seen or outside the card pool) | No pickup on the pedestal; the room still clears. Never an item. | `test_floor_rooms::test_armory_empty_pool` |
| Item room's pool empty | The run's `fallback_item`, as today. | existing pick tests, plus an `ITEMS` case |
| Determinism | Waves are resolved in room order on the `content` stream; the no-repeat rule compares ids as `String`s; no new `StringName` sort (`test_no_pointer_ordered_sorts`). A windowed and a headless run of the same challenge produce the same hash. | `test_floor_rooms::test_waves_deterministic` |

Acceptance scenarios covered: **5** (tampered log, through the new tamper cases). Scenarios 1-4 and 6-7 are unchanged by this
slice (no new settlement, cache, queue or ruleset path).

## 6. Observability

No new Prometheus metric. Waves count in `rpg_battles_submitted_total` and the step metrics like any battle. Item and room ids
are never labels. The analytics value is in the event log: `ItemOffer.source = Armory | Challenge` lets the dashboard (slice 6)
say where gear and items were found. Dev side: `run_summary` adds `challengesCleared`, `challengesEntered` and `armoriesVisited`
(only when above 0, so older summaries are unchanged), and the play report (`seed_report --play`) gains the challenge win rate
per wave and the deaths inside challenge rooms in its death map.

## 7. Open questions

None. Settled by the user on 2026-11-21: the challenge room on every floor but the Vault and the Void (D1); the challenge reward draws items and
equipment (D3); the armory only beside an item room or shop, takes any slot and is key-locked like the shop and item room (D4); bigger floors exist for the keys (D6); the challenge room is
unlocked, starts on entry and has no break (D9); rewards only at the end (D10). Room counts and looks are measured and shown
before the user picks (4.1, 4.2).

## 8. Test plan

### 8.1 System tests (fixtures only, `tests/game/test_floor_rooms.gd`)
- New fixture content (built by `tests/tools/build_fixtures.tscn`, adding missing files only): a fixture challenge room with
  three waves (one fixed encounter, two queries), a fixture armory, fixture rules listing both.
- `test_special_rooms_placed`: over 200 seeds, every floor whose rules list them has exactly one challenge room and one armory,
  and a floor whose rules list neither has none; validator `armory_without_item_room` in `tests/broken_fixtures/`.
- `test_waves_resolved`: three waves in order, no repeated encounter while candidates remain, a repeat allowed when the query
  has one encounter, wave enemies with elite rolls.
- `test_waves_play_in_order`: entering starts wave 1 (no other action between); battle ids `/w1`, `/w2`, `/w3`; nothing given
  after waves 1 and 2 (XP, levels, coins, keys, drops, gifts, rewards unchanged); after wave 3 XP for every wave's enemies,
  coins, key and chest rolled once on the room's streams (the same draws as one cleared battle room), then the pedestal; no
  enemy drop and no encounter reward ever, even from an encounter with `drop_chance` 100% and rewards; a loss in wave 2 ends the run Lost; other
  actions refused while a wave is pending; item cooldowns count down per wave.
- `test_challenge_never_locked` and `test_armory_locked_like_shop`: on rules that lock the shop, the armory needs a key from
  `unlocked_floors` on; the challenge room never does.
- `test_offers_filter`: `ITEMS` never yields equipment, `EQUIPMENT` never an item, `ANY` picks exactly as before (an
  existing seed's pickups unchanged), the armory's empty pool; the challenge reward yields items and equipment over many seeds.
- `test_resume_between_waves`: snapshot round trip with `wave` and the pending wave; resume equivalence from that checkpoint.
- `test_waves_deterministic`: the same run twice gives the same hash; `test_snapshot_fields_are_covered` extended to `wave` and
  `waves`.
- `test_step_runner`: a run with a challenge room cut into steps like the server cuts them, verified; tampered copies (skipped
  wave, reordered waves, edited wave enemies, early clear) each rejected 2002 with its reason.
- Validator: `waves_too_few`, `waves_outside_mode`, `offers_equipment_no_pool`, `floor_rules_too_small`, in
  `tests/broken_fixtures/`.
- `RunWire.offers`: Armory and Challenge sources; `RunPlayer` enters the challenge room and the armory and wears found gear.

### 8.2 Goldens
- **Expected to change, re-recorded on purpose** (`-- --update-goldens`): the floor, seed, seed-code and sandbox goldens of
  `tests/fixtures/golden/game/` and the scripted runs `run.json` / `run_keyed.json` only where the fixture rules list the new
  rooms. Plan: the fixtures' existing rules stay as they are (their goldens unchanged), and new fixture rules carry the new rooms
  with a new golden `run_floor_rooms.json`. Combat goldens never change (no battle code changes).
- `.NET`: `RunAuthorityContractTests` golden JSON gains an `ItemOffer` with `Armory` and one with `Challenge`; Postgres jsonb
  key-order replays as today.

### 8.3 Content and balance (real `content/`, after the user's content OK)
- `validate_content.tscn` clean.
- `seed_report --count 1000` per chapter: 0 generation failures, room counts and generator attempts reported before and after.
- The gold-standard play report (`play_sharded.sh 12 ... --policy smart --party-size 4 --check`): runs finish, no violations, every
  battle replays; the win rate is reported against 31.8% but **not tuned here** (5c re-measures the gate).
- e2e `verify_demo_content` and a new `floor_rooms` scenario: a real-content run with a challenge room through the real worker,
  every wave Verified to the client's own hash; `tamper-waves` (scenario 5) rejected 2002 with nothing paid.
- Both suites pass: `tools/dotnet_test.sh` and `tools/godot_tests.sh`.
