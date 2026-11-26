# Spec: item-power (before 5c `card-balance`, after `bot-play`)

Status: **built 2026-11-23 on `feat/item-power`, measured (section 8), awaiting the user's review and playtest** (spec written
2026-11-22; decisions confirmed by the user the same day, K5 approved; the build's additions are D11-D17). The second of four slices the user asked for on 2026-11-22:
`bot-play`, `item-power` (this), `level-99`, `second-pack`. Builds on `specs/item-pass.md` (hit tags, follow-ups,
toughness and break, `per_item_effect`), `specs/content-pass.md` (statuses, DoT stacks, the trigger queue),
`specs/playable-demo.md` 3.7-3.8 (rarity weights, the Void altars), `specs/food-items.md` (stacking bonuses),
`specs/card-collection.md` (card sets, the catalog), `specs/unique-events.md` (`seen` and drained pools),
`specs/bot-play.md` (fit and grant tags).

## 1. Purpose & enterprise mapping

**Purpose.** Items barely make the party stronger (user, 2026-11-22). Of the 122 demo items most are flat numbers
(+20% ATK, +40 DEF) or narrow conditions (+25% damage to Broken enemies); the follow-ups are small (30-90% ATK) and wait
on a crit or a weakness; nothing fires when an ally is hit, when a DoT ticks, or chains on a kill; nothing wins a run.
This slice **adds** about 40 new items and gear (the weak ones stay as they are; user: "focus on just adding stronger
ones now"):
1. **Run-winning Legendaries**, Risk of Rain 2 and Isaac style: procs on hits, kills, allies being hit and DoT ticks,
   procs that feed procs, and items that change how a character plays (2.3).
2. **Stronger base Rares and Epics** so an ordinary pick matters (user: "we need better base items in the game").
3. **Void trades** with a big upside and a real cost.
4. **Weapons and armor** worth wearing.
5. **Copies stack, always in full** (user, 2026-11-22): a second copy applies its whole effect again (two Chain Bells
   roll twice). Pools never offer a copy; only something that names the item does (2.2).
6. **Card sets:** the new Rares, Epics and most Legendaries go in **Core**; some of the strongest go in **Descent**, the
   existing pack (user, 2026-11-22). Legendaries can be in the boss pool, but **no boss guarantees one** (user).

A few new kernel hooks make the procs possible (2.1); everything else is data on GodotGAS (abilities, effects, tags)
plus the bots' fit and grant tags (`bot-play` 2.3).

**Enterprise mapping.** The kernel hooks are combat code, so the verifier (headless Godot) replays them like any other
mechanic; the ruleset version changes, and the server only ever verifies a build whose ruleset is its own. New cards:
the catalog (`game/tools/build_card_catalog.tscn` → `infra/economy/card_catalog.json`) gains the new items, and the
server's `CardSeeder` adds them (it refuses only a file that takes a core card away). No wire record changes. Postgres
gains catalog rows through the seeder; Redis's `catalog:cards` is refreshed by its TTL. No new metrics.

**Acceptance scenarios covered:** 5 (a tampered log is rejected 2002): each hook gets a tampered golden (6).

## 2. Sequence flow

### 2.1 Kernel hooks (system code in `combat/`)

Each hook is off unless content uses it, so **no committed golden changes** (every combat and run golden replays to its
recorded hash; the tests say so).

| # | Hook | What it does |
|---|---|---|
| K1 | **Ally events** | After the battle sends `Event.Damage.Taken` to a unit, it sends `Event.Ally.Damage.Taken` (same payload) to every other living unit on that unit's side, in slot order. After `Event.Ability.Used.Ultimate`, `Event.Ally.Ability.Used.Ultimate` the same way. New tags; nothing listens today. |
| K2 | **DoT tick events** | A periodic damage tick (one per stack, spec content-pass H3) sends `Event.Damage.Dealt.Dot` to the unit that applied the effect (its instigator, while alive) and `Event.Damage.Taken.Dot` to the ticked unit, payload `{source, target, amount, effect}`. Only the `.Dot` events, never the generic `Event.Damage.*`, so Thorn Mail and the other existing listeners do not start firing on ticks. |
| K3 | **Trigger chance** | `BattleAbility.trigger_chance` (typed as a percent, stored ×100; unset = always): when a queued trigger is about to activate, the battle rolls `rng.randi_range(0, 9999) < chance` once. A failed roll is a skipped trigger (no activation, no cost, no event). One roll per queued trigger, in queue order. |
| K4 | **Random enemy targeting** | `Targeting.RANDOM_ENEMY`: one living opposing unit drawn on the battle RNG when the ability activates (one draw per activation; per execution row with `Targets.PRIMARY`, a new draw per row is not made: one target per activation). A follow-up with N strikes is N rows on one target or an ability that re-queues itself (data). |
| K5 | **Dying** | Today a unit at 0 HP is *down* (later hits and follow-ups skip it) and dies at the next death check (`Battle._check_deaths`, step 7, after the action and its triggers). New, at the start of that check: each unit at or below 0 HP that **has an ability listening to `Event.Unit.Dying`** is sent it, in unit order, and only those triggers run (a drain of what this queued); a unit whose HP is then above 0 is not marked dead. Everyone else dies exactly as today, so a battle without such an ability is unchanged. A saved unit gave no kill (no `Event.Unit.Died` / `Killed`, so on-kill items do not fire). Once per battle is content (the save grants `State.DeathSaved`, which its activation query blocks). |
| K6 | **Event amount** | `ExecutionRow.DamageMode.EVENT_AMOUNT`: damage = the triggering event's `amount` × `multiplier` (×100 math, `Fixed`). A heal effect may read it too through the SetByCaller tag `Data.Event.Amount`. For reflect (Thornheart Plate) and percent lifesteal (Bloodthirst Blade). Outside a trigger the amount is 0. |
| K7 | **Echo cast** | A triggered ability with asset tag `Ability.Type.Echo` and `echo_scale` (percent ×100) re-runs the triggering ability's execution rows (from `Event.Ability.Used.*`'s payload) on the same target at that scale: no cost, no ult charge, no `Event.Ability.Used` of its own (so an echo never echoes), its hits tagged `Hit.Echo` and `Hit.FollowUp`. |
| K8 | **Copies** | A unit built with two copies of an item (snapshot: the item id twice in held items) grants the item's AbilitySet twice: effects applied twice (they stack per their own stacking policy; a non-stacking effect is two active effects), abilities granted once per copy (`_grant_ability` keys by ability tag + copy index, so the "duplicate ability tag skipped" warning no longer drops an item copy; it still drops a true duplicate from two different sources, as today). Each copy's trigger rolls and fires separately. |

**Added by the build (user's OK, 2026-11-23, D11-D16):**
- `Targeting.RANDOM_OTHER_ENEMY` and `OTHER_ENEMIES` beside `RANDOM_ENEMY`: the same draw, or every opposing unit that is up, without
  the unit the triggering event is about (what an ability was aimed at, else the hit or hitting unit). With nobody to aim at the
  trigger is skipped before its roll and its draw.
- The `Event.Ability.Used*` payload carries `primary` and `targets`, and `Event.Ability.Used.Skill` follows it for a **skill**: an
  action with a cost that is neither a basic attack, an ult nor an item's use ability (no demo move has a Skill tag).
- `GiveItem.Recipient.HOLDER`: in an item's run hook, the member whose item it is, dead or alive (Philosopher's Coin).
- `ExecutionRow.event_effect`: the row applies the triggering event's own effect with its damage values and types (Plague Crown's
  spread; the K2 payload carries the tick's `spec`).
- K1 and K2 only speak of the other side: HP a unit's own side or own effect costs it sends neither an ally event nor a tick event.
- **Proc chains:** every "hit → extra attack" item and every counter is a follow-up (`Ability.Type.FollowUp`), so the HSR rule (a
  follow-up never fires from a follow-up's hit) bounds them. Feast Knife's strikes and the Sun Heart's splash are not
  (`Ability.Type.Strike`: they only *play* like one), so they do feed the follow-ups; Hollow Crown alone chains follow-ups, through
  `Event.Attack.FollowUp`.
- **Ult cap:** a unit casts at most `Battle.ULTS_PER_TURN` (3) ults until the next turn (anyone's, or a One More) starts, refused by
  `CombatASC.can_activate_ability` (brains, Auto, the party window and the verifier alike; a log claiming a fourth is 2002). Ults use
  no turn, so charge refunds adding up to a full bar cast for ever: 3 of 600 runs hung on Echo of Nothing + Corrupted Coil.
- A trigger that costs something never pays for a target already at 0 HP (Void Tether). An echo also scales buffs, debuffs and
  ticks (their added amounts; effects that only grant tags land whole) and restores (`Data.Echo.Scale`).
- **Pacing (presentation):** the first triggered attack of a drain keeps the normal pacing, the rest of the chain at most 0.45 s on
  screen and a 0.15 s pause, in game time, so the play speed scales both (the normal pacing already did).

Every hook runs inside the existing trigger queue (FIFO, chain cap `TriggerQueue.MAX_DEPTH` 10), so proc chains (a
follow-up kill firing Feast Knife, whose strikes fire Chain Bell, ...) are deterministic and bounded. The play report's
`hashTiming`-style budget gains a battle-time line: the 600-seed smart report must not take more than 1.5× today's wall
time (measured, section 8).

### 2.2 Where copies come from (run layer: unchanged)

**Pools never offer a copy** (user, 2026-11-22): every pool pick keeps skipping `held` and `seen` items, as today. A copy
reaches the party only when something **names** the item (spec `unique-events` 1.2: a fixed placement, an outcome by id
in an event, a chest or an encounter reward, an enemy's `drop_item`), which always gives that item even when the run
already has one. Food keeps its own stacking bonuses (spec `food-items`). So the run layer, the pools and the run hash do
not change; K8 makes such a named copy count in full in battle.

### 2.3 The new items (content, new files only)

Numbers are first proposals for the user to tune. "Hook" names the kernel hook a design needs; "data" needs none. All
items get `Item.Fit.*` / `Item.Grants.*` tags (`bot-play` 2.3), an `Item.Rarity.*`, a `Card.Set.*` and pool tags. Only
three damage types exist (Physical, Fire, Ice).

**Legendary (10)**

| Item | Effect | Pools | Set | Hook |
|---|---|---|---|---|
| Chain Bell | Every hit: 30% chance to ring across every enemy for 60% ATK Physical. | Treasure | Core | K3 |
| Feast Knife | On a kill: 3 strikes of 120% ATK Physical at random enemies. | Boss | Core | K4 |
| Vengeful Aegis | Whenever an ally is hit, strike the attacker for 100% ATK Physical. | Boss | Core | K1 |
| Sun Heart | Your basic attacks also hit every other enemy for 60% ATK and give +100% SP. | Treasure | Core | data |
| Undying Ember | Once per battle, a killing blow leaves you at 50% HP with +50% ATK for 3 turns. | Boss | Core | K5 |
| Shatter Covenant | Triple toughness damage; Broken enemies take +60% damage from you. | Treasure | Core | data |
| Philosopher's Coin | At each floor's start: +5% ATK, DEF and max HP, for the rest of the run (stacks). | Treasure, Shop | Core | data |
| Twin Soul | Your skills cast again at 60%. | Boss | Descent | K7 |
| Plague Crown | Each tick of your DoTs: a 50% ATK follow-up on that enemy and one stack spread to another enemy. | Treasure | Descent | K2, K4 |
| Echo Crown | The party: after any ally's ult, every ally makes a 100% ATK follow-up. | Boss | Descent | K1 |

**Void trades (6)** (Pool.Void, `Item.Corrupted`, the altars' Void Scar prices; all Core, like the 15 corrupted items)

| Item | Rarity | Upside | Cost | Hook |
|---|---|---|---|---|
| Void Heart | Legendary | Double damage dealt. | You can't be healed (heal_taken −1000%; every party heal reads it, D19). Revives still work, and so do the two heals that also revive (the waystation's rest, the Wandering Medic). | data |
| Hollow Crown | Legendary | Each of your follow-ups triggers another (60% ATK), up to the chain cap. | −20% max HP. | data |
| Void Tether | Epic | Whenever an ally is hit, strike the attacker for 150% ATK. | Lose 5% max HP each time. | K1 |
| Null Lens | Epic | +200% crit damage. | −50% crit rate. | data |
| Starving Maw | Epic | On a kill: heal 30% max HP, +10% ATK for the battle (stacks). | Lose 5% max HP each turn (stops below 5%, never kills). | data |
| Echo of Nothing | Epic | After your ult, +60 ult charge (D12). | −30% max HP. | data |

**Epic (8)** (all Core)

| Item | Effect | Pools | Hook |
|---|---|---|---|
| Chain Hook | Every hit: 25% chance of a 60% ATK follow-up on a random other enemy. | Treasure, Shop | K3, K4 |
| Reaper's Mark | On a kill: +25% ATK for 2 turns (up to 3 stacks) and a 30% action advance. | Treasure, Shop | data |
| Guardian's Vow | When an ally is hit, counter for 80% ATK and heal them 10% of their max HP. | Treasure | K1 |
| Venom Spur | Every hit adds 1 Poison stack. | Treasure, Shop | data |
| Second Wind | Heal 15% max HP at battle start and on every kill. | Treasure, Shop | data |
| Lifebloom Seed | The party: +10% max HP and Regen (8% max HP, 3 turns) at battle start. | Boss | data |
| Battle Hymn | The party: +15% ATK, +10 SPD. | Boss | data |
| Bulwark Sigil | +30% max HP, +30% DEF. | Treasure, Shop | data |

**Rare (8)** (all Core)

| Item | Effect | Pools | Hook |
|---|---|---|---|
| Static Ring | Every hit: 20% chance of a 50% ATK follow-up on the same target. | Treasure, Shop, Chest | K3 |
| Hunter's Snare | Weakness hits: a 50% ATK follow-up. | Treasure, Shop | data |
| Blood Charm | On a kill: heal 8% max HP and +15 ult charge. | Treasure, Shop, Chest | data |
| Thick Hide | +20% max HP, +15% DEF. | Treasure, Shop, Chest | data |
| Kindling | Fire hits: 40% chance to add a Burn stack. | Treasure, Shop | data |
| Quick Draw | 40% action advance at battle start. | Treasure, Shop, Chest | data |
| Focus Stone | +25% ATK, +10% crit rate. | Treasure, Shop | data |
| Mender's Bell | +40% healing given, +15% SP gain. | Treasure, Shop, Chest | data |

**Weapons (4) and armor (4)** (the run's equipment pools; existing slot tags)

| Piece | Slot | Rarity | Effect | Set | Hook |
|---|---|---|---|---|---|
| Executioner's Greatsword | Weapon | Legendary | +50% ATK; a hit that leaves a non-boss below 25% HP finishes it. | Core | data (an ExecCalc in content) |
| Storm Spear | Weapon | Epic | Basic attacks: a 60% ATK follow-up on 2 random other enemies. | Core | K4 |
| Bloodthirst Blade | Weapon | Epic | Heal 25% of the damage you deal. | Descent | K6 |
| Runebound Staff | Weapon | Legendary | +40% ATK; abilities cost 25% less SP. | Descent | data |
| Thornheart Plate | Armor | Legendary | +30% max HP; reflect 50% of the damage you take to the attacker. | Core | K6 |
| Sentinel Plate | Armor | Epic | −30% damage taken; Taunt for 2 turns at battle start. | Core | data |
| Mantle of Haste | Armor | Epic | +25 SPD; 50% action advance at battle start. | Descent | data |
| Warlord's Crown | Armor | Legendary | The party: +25% ATK, +15% DEF. | Descent | data |

**Pools are mixes of rarities, and the item-room and boss pools barely overlap** (user, 2026-11-22): every new item is
in `Pool.Treasure` (item rooms) **or** `Pool.Boss`, never both; `Pool.Shop` and `Pool.Chest` may share with Treasure as
before. Which rarity a pick lands on is decided by the run's `rarity_weights` (spec `playable-demo` 3.7) over whatever
rarities the pool holds, so an item room can roll a Common or a Legendary. New Legendaries per pool: Treasure 5 (Chain
Bell, Sun Heart, Shatter Covenant, Philosopher's Coin, Plague Crown), Boss 5 (Feast Knife, Vengeful Aegis, Undying
Ember, Twin Soul, Echo Crown), Shop 1 (Philosopher's Coin), Void 2; new Epics in Boss: Lifebloom Seed and Battle Hymn.
Today 15 of the 28 boss-pool items are also in Treasure; this slice adds no overlap and leaves those as they are (changing
them edits existing files; a question for 5c). The build prints each pool's rarity counts and the overlap before and
after. Legendary weapons and armor sit in the normal
equipment pools (armories, pedestals, shelves) like the other pieces. Pools get no rarity weights of their own (D10).

Totals: 40 (10 Legendary, 6 Void, 8 Epic, 8 Rare, 8 gear); Core 33, Descent 7 (what the tables say; the first draft's 30 / 10 was a
miscount). Slots: Thornheart Plate, Sentinel Plate and Mantle of Haste are Body, the Warlord's Crown is Head. A named copy stacks in full (K8): two
Bulwark Sigils are +60% max HP.

### 2.4 Building the set

- A builder `game/tools/build_item_power.tscn` writes the new item, equipment, ability, effect and ExecCalc files into
  `content/demo/` (new files only, never overwrites), and lists every
  path and value it wrote. Run with the user's go-ahead (the `build_demo` exception pattern).
- Each new move gets an animation with `execute` keys from the default set (the existing passive and follow-up
  animations are reused), and a sound from the bank through the audio pass's rules (follow-ups by damage type). Visual
  effects reuse the library's cues by damage type; new signature looks are a later presentation task.
- New tags (`Event.Ally.*`, `Event.Damage.*.Dot`, `Event.Unit.Dying`, `Hit.Echo`, `Ability.Type.Echo`,
  `State.DeathSaved`, `Data.Event.Amount`) through `sync_tags -- --add-missing` (registry edits prompt).
- Card catalog rebuilt (`build_card_catalog.tscn`), `tools/check_card_catalog.sh` clean, `card_economy.json` unchanged.

## 3. Data contracts

No C# record changes. The catalog file `infra/economy/card_catalog.json` gains 40 rows (same schema). Battle snapshot
v2 already lists held items as an array, so two copies are the id twice (no version change). New Godot fields:
`BattleAbility.trigger_chance` (`trigger_chance_x100` storage), `Targeting.RANDOM_ENEMY` / `RANDOM_OTHER_ENEMY` / `OTHER_ENEMIES`,
`ExecutionRow.DamageMode.EVENT_AMOUNT`, `ExecutionRow.event_effect`, `BattleAbility.echo_scale`, `GiveItem.Recipient.HOLDER`.

## 4. Failure modes

- **Determinism:** every new roll (K3, K4) is on the battle's one RNG, in an order that depends only on combat state;
  each hook's golden is recorded on Windows and replayed in the Linux verifier image (`tools/verifier_image_check.sh`).
- **Runaway chains:** the chain cap (10) stops a proc loop the same way every time and records a content warning; a
  test builds a self-feeding pair (Hollow Crown + Chain Hook) and checks the cap and the hash.
- **Old content unchanged:** K2 sends only new `.Dot` events, K1 only new `Event.Ally.*` events, K3-K7 are off unless a
  field is set, K8 changes nothing for single copies; every committed golden replays to its hash.
- **Tampering:** a battle whose log claims a proc that did not roll is rejected 2002 like any other (the procs are
  re-simulated, never logged). Tampered goldens per hook (6).
- **Copies:** only named items make copies (2.2); the pools, the card pool on the run and the run hash are unchanged.

## 5. Observability

N/A for Prometheus (no server code). The play report adds `procs` (fires per hook and per item per battle, chain-cap
hits) and the existing `itemLift` (`bot-play` 2.7) for the new items; the verifier's existing `rpg_step_duration`
histograms show any replay-time growth on the server.

## 6. Test plan

On fixtures only (new fixtures in `tests/fixtures/`, built by `tests/tools/build_fixtures.tscn`, never `content/`):
- K1: an ally hit fires the holder's counter at the attacker, in slot order; the hit unit gets no `Ally` event.
- K2: a 3-stack DoT fires 3 `Dealt.Dot` to its applier; a dead applier gets none; Thorn-Mail-like listeners on the
  generic event do not fire on ticks.
- K3: trigger chance 0 / 100 / 30 over seeds; one roll per queued trigger; a failed roll costs nothing.
- K4: random enemy draws on the battle RNG, skips dead units, replays identically.
- K5: a dying unit saved by its trigger lives; once per battle; no save at 0 → dies as today.
- K6: reflect deals the event's amount × multiplier; outside a trigger 0.
- K7: an echo re-runs the rows at scale, costs nothing, never echoes itself.
- K8: two copies apply effects twice and fire triggers twice; a true duplicate from two sources still warns.
- Chain cap with a self-feeding pair; the content warning.
- New goldens: `proc-seed-*` (K1-K4), `dying-seed-*` (K5), `echo-seed-*` (K6-K7), `copies-seed-*` (K8), each with a
  `.trace.json` and a tampered copy; all replayed in reversed and jsonb key order like the others.
- Every existing golden replays unchanged.
- Copies: a named item given twice (an event outcome by id on a fixture) is held twice and fights with both copies;
  pool picks still never repeat (run goldens unchanged).
- K5: a unit at 0 HP without a save dies at the same check as before (every golden); with one it is saved once, gives
  no kill, and a second lethal hit in the same battle kills it.
- Validator: `trigger_chance_on_action` (a chance on a non-triggered ability), `random_target_on_ally`, `echo_without_trigger`,
  `event_amount_outside_trigger`.
- Content (`test_content_valid`): the new items validate, fit tags present, the card catalog in sync.
- Measurement (section 8): the smart 4-member gate with `bot-play` in, before and after this set.

## 7. Decisions, open questions, what stays out

**Decisions (user, 2026-11-22):**
- D1. Add strong items; leave the weak ones as they are for now.
- D2. About 40 new items: Legendaries, Void trades, Epics, Rares, weapons and armor.
- D3. New Rares, Epics and Legendaries in Core; some of the strongest in Descent.
- D4. Legendaries may be in the boss pool; no boss guarantees one.
- D5. Copies stack in full (every copy applies its whole effect again).
- D6. Pools never offer copies; a copy comes only from something that names the item (an event outcome, a fixed
  placement, a chest or reward by id).
- D7. K5 works at the death check, only for units holding a save; everything else dies as today. Approved by the
  user, 2026-11-22.
- D8. Names and numbers are first proposals; the user tunes them after playtest.
- D9. Legendaries are in the normal pools too; pools hold a mix of rarities; the item-room and boss pools barely
  overlap (no new item is in both).
- D10. No per-pool rarity weights: the run-wide `rarity_weights` keeps weighing every pool alike.

**Decisions (user, 2026-11-23, during the build):**
- D11. The additions under 2.1 (targetings, the Used payload and Skill event, HOLDER, `event_effect`, other-side events, the echo scale in the
  restore ExecCalc, one edit to an existing content file: `exec_calc_restore.gd`).
- D12. Echo of Nothing gives +60, not +100.
- D13. The follow-up rule for proc chains (2.1).
- D14. Lower on-screen time for chained attacks, with a small delay that scales with the play speed.
- D15. At most 3 ults per unit between two turns.
- D16. Every new card has its own game-icons glyph (40 SVGs, 40 rows appended to `card_icons.tres`).
- D17. Content bugs found in review, fixed: the Maw's cost outlives a revive; the Greatsword never finishes party members (the Collector
  mirrors gear); Kindling's 40% is a trigger chance, not a status roll.

**Decisions (user, 2026-11-24, after the build):**
- D18. The Collector and the Reflection skip Philosopher's Gold like food: its set carries `Item.Gold` (new tag, in their `mirror_skip_tags`),
  so its +5% is not copied; each piece still counts for the Collector's per-piece bonus.
- D19. Void Heart blocks every heal: 18 older heals that ignored `heal_taken` now read it (7 in battle: Corrupted Vampire Fang, Corrupted
  Bounty Mark, Mirror Ward, Mimic Tooth, Heartstring, Holy Water, Shield Wall; 11 outside: food, event heals, the healing spring, the
  chests' heal). Amounts unchanged; Blessed Amulet now raises them and the Bounty Mark's −15% lowers its own heal. Revives do not read it.
- D20. A follow-up never fires when every enemy it aims at is at 0 HP: no attack, no chance roll, no `Event.Attack.FollowUp`. The one exception
  to "no committed golden changes": `break-seed-11` was regenerated (10 ult charge from such a follow-up), and this spec's `copies-seed-29`.
- D21. A counter (a trigger on `Event.Damage.Taken*` or `Event.Ally.Damage.Taken`) answers its attacker past any taunt. Taunt still draws the
  attacks an enemy chooses and the aimed triggers of its own hits; a random draw (K4) ignores it, like taunt's own rule (single-target and
  blast only). A taunter at 0 HP taunts no more. Before, every enemy trigger was redirected (since `content-pass`).
- D22. Findings of the last review, fixed: what a kill or death sets off plays at once, before the next actor is chosen (`Battle._play_aftermath`;
  it waited for the next turn's start, so Reaper's Mark's advance could be lost; no golden moved); an echo of a damage row without an override
  deals the echo's share of 100% ATK; `GiveItem` HOLDER gives a drawn item only to a holder who can take it, warns on its fallback, and the
  validator warns on a named character (`holder_ignores_character`); the older builders make heals that read `heal_taken`;
  `build_item_power` has no `--force` any more; the ult cap is recorded as a safety limit in `client-godot/CLAUDE.md`.

**Open questions:** none.

**Stays out:** reworking or retiring the weak items (later, 5c), level changes (`level-99`), new characters
(`second-pack`), signature VFX for the new items, pack odds and prices (5c).

## 8. Measurements

2026-11-23/24: The Descent, the 600 balance seeds (`game/dev/balance_seeds.json`), smart policy, 4 members, `--check` (every battle
replayed), 12 shards. Wins compared seed by seed, p from the two-sided sign test.

| Run | Won | Win rate | Battles | Reached floor 10 | Wall time |
|---|---|---|---|---|---|
| before (`main`, bot-play's `smart`, reproduced the same evening) | 101 | 16.83% | 54,054 | 365 | 672 s |
| **after** | **128** | **21.33%** | 58,393 | 430 | 690 s (1.03×, the budget is 1.5×) |

- +91 −64 seeds, p 0.036: a small, probably real gain. No run stopped, no script error, no replay mismatch; the violations are 2 turn-limit
  battles of the Reflection events (1 before).
- Without the ult cap 3 of the 600 runs never ended (Echo of Nothing + Corrupted Coil).
- Procs over 58,393 battles: K6 amount 10,009, K4 random 8,800, K1 ally 8,143, K3 chance 5,603, K8 copy 1,910 (54 runs: named drops
  like Halo do give copies), K2 DoT 492, K7 echo 330, K5 dying 94; the chain cap was hit 580 times (Hollow Crown).
- Win rate of the runs that held it, against 21.33% (a lift also measures how late an item comes: Void trades are only found on floor 10):
  Void trades 47-77% (Hollow Crown 77%, Void Heart 68%, Echo of Nothing 67%); Shatter Covenant 47%, Plague Crown 36%, Bloodthirst Blade
  36%, Mantle of Haste 34%, Undying Ember 33%, Echo Crown 33%, Venom Spur 31%, Lifebloom Seed and Sentinel Plate 29%; **below average:**
  Reaper's Mark 6.8% (59 runs), Twin Soul 15.1%, Chain Hook 16.0%, Philosopher's Coin 18.8%, Focus Stone 18.8%. Treasure Legendaries
  are rare (11-16 runs each: 3% rarity weight), so their rows are noise.

- **After D18 and D19 (2026-11-24, the same 600 seeds): 128 (21.33%) again**, +3 −3 seeds against the row above (526 runs unchanged), +90 −63
  against `main`, p 0.035, 58,313 battles, 762 s (1.13×), 2 turn-limit battles of the Reflection events. Void Heart 68% → 61% (21 → 19 of 31).
- The other figures above are from the run before D18 and D19. Besides floor 10's altars, two Coven events (floor 9) can give Void items.

- **After D20 and D21 (2026-11-24, a quick check on the first 100 seeds): 22 won** (21 of the same 100 before them, +7 −6; 14 on `main`), 149 s,
  no violation. Too few seeds to move the 600-seed figure, which stays 128 (21.33%), measured before D20 and D21.

- **After D22 (the first 100 seeds): 19 won** (22 before it, +1 −4: well within noise), no stopped run, error or violation. The 600-seed gate has
  not been rerun since D20.

- **The baseline level-cap (5i) is compared with (user, 2026-11-24):** 128 of 600 (21.33%, the last full run, before D20-D22) and 19 of the first 100
  seeds (the merged code). `main` was measured again on those 100 on 2026-11-24 with level-cap's system code and the content unchanged: 19 won, and
  all 100 run hashes equal the ones above. The 600 was not rerun on `main` (the user's choice): level-cap is tuned on the first 100 and runs the
  600 once, at its end.
