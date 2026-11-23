# Spec: second-pack (before 5c `card-balance`, after `level-cap`)

Status: **spec written 2026-11-22, awaiting the user's review.** The last of four slices the user asked for on
2026-11-22: `bot-play`, `item-power`, `level-cap`, `second-pack` (this). A second card pack, **Blood Moon**, with three
new characters that bring a new playstyle and still fit existing teams, and a small set of items built around them.
Builds on `specs/card-collection.md`, `specs/pack-shop.md` and `specs/card-ui.md` (sets, packs, odds, pity, the
catalog, the Shop and pack reveal), `specs/class-pick.md` (the class pick, presets, portraits),
`specs/cube-style.md` (looks), `specs/item-power.md` (hooks K1-K8), `specs/level-cap.md` (the level rhythm),
`specs/bot-play.md` (role and fit tags).

## 1. Purpose & enterprise mapping

**Purpose.** A second pack the player buys and opens beside the Descent Pack, whose cards are three characters and
21 items (24 cards, D5):
1. **The Vampire** (user, 2026-11-22): every hit it deals heals it, and its moves cost **HP**, not SP. A damage dealer that
   lives on the edge: strong while it keeps hitting, in danger when it can't.
2. **The Lifebinder**, a new support (user, 2026-11-22): heals the party, and **every time a set amount of healing has
   been done, it makes a follow-up attack** (Honkai: Star Rail style). Its meter fills with **all healing the party
   receives**, so the Vampire's lifesteal and the Cleric's heals feed it.
3. **A third character**, still open (2.4, D3): the first draft, a counter-attacking Duelist, was turned down.
4. **21 Blood Moon items** for lifesteal, HP costs and healing meters, plus the third character's theme (2.5).

Each character has the full level rhythm of `level-cap` (2.3 there: similar, not identical, with passives).

**Enterprise mapping.** The card system end to end, on the real backend:
- **Catalog:** `build_card_catalog.tscn` adds 24 rows (set `bloodmoon`) to `infra/economy/card_catalog.json`; the
  server's `CardSeeder` adds them (it only refuses a file that takes a core card away).
- **Pack type:** a second entry in `infra/economy/card_economy.json` (`bloodmoon-pack`), seeded only where no row exists
  (an admin's edit is never overwritten); every pack-type rule of spec `pack-shop` applies, including the openability
  check (every rarity the pack can give by odds, pity or a first-pack guarantee must have an eligible card and a rate).
- **Postgres:** catalog and pack-type rows through the seeders; buys, opens, dust and craft as today
  (`pack_inventory`, `pack_ledger`, `card_ledger`, the outbox events `PackPurchased`, `PackOpened`, ...).
- **Redis:** `catalog:cards` and `catalog:packs` refresh by their TTL (1 h); the deploy notes say to delete both keys
  after seeding so the new pack shows at once.
- **Redpanda / RabbitMQ:** the existing card events, now also with the new pack id; no new topic.
- **Prometheus:** existing pack metrics carry `{pack}` (a bounded label: one per pack type, two now); no new metric.
- **Verification:** the new characters' moves and the new hooks are combat code and content in the ruleset; runs with
  them are verified by replay like any other.

**Acceptance scenarios covered:** 1 (a duplicate pack open with the same request key opens once: the existing test runs
for both pack types), 5 (a tampered battle with a Vampire HP cost or a Lifebinder meter follow-up is rejected 2002: new
tampered goldens).

## 2. Sequence flow

### 2.1 New kernel hooks (system code in `combat/`; all off unless content uses them)

| # | Hook | What it does |
|---|---|---|
| B1 | **HP costs** | An ability's cost effect may lower `hp` (a cost modifier or cost ExecCalc on `hp`, read by `CostReader.cost_of` as `{hp: n}` beside SP). `CombatASC.can_activate_ability` refuses an HP-cost ability when the cost is **at or above the caster's current HP** (a move never kills its user). `AbilityHint` shows "HP" and the cost; the battle HUD's command window previews it on the HP bar like the SP bar's preview. |
| B2 | **Heal events** | Whenever a unit's HP rises from an effect (instant heals, HoT ticks, lifesteal, revives' HP), the battle sends `Event.Heal.Given` to the source and `Event.Heal.Received` to the target, payload `{source, target, amount}` where `amount` is the HP actually restored (overheal excluded), and, through item-power's K1, `Event.Ally.Heal.Received` to the target's living allies. HoT stacks send one event per stack tick. New tags; nothing listens today. |
| B3 | **Meters** | A triggered ability may name a meter: `BattleAbility.meter_attribute` (an attribute name) and `meter_threshold` (×100; or `meter_threshold_of`, an attribute of the owner and a percent, e.g. 50% of its max HP). After each trigger drain the battle checks every living unit's meter abilities in unit order: while the attribute is at or above the threshold, it subtracts the threshold and queues the ability once (at most 3 fires per check, so a huge heal cannot fire forever). Meters fill through ordinary effects (e.g. a passive on `Event.Ally.Heal.Received` adding `Data.Event.Amount` to the meter through K6). Heals made by a meter-fired ability carry `Hit.Meter` and **never fill meters**, so a meter heal cannot feed itself. |
| B4 | **Meter attribute** | One new attribute in the generated `Unit` AttributeSet: `meter` (snake_case, starts at 0 each battle, never negative, never carried between battles). It is a `godot_gas/attributes_draft.cfg` edit (prompts), then `generate_attributes.tscn`. Shown on the battle HUD's party window as a thin bar under SP for units with a meter ability. |

Lifesteal needs no new hook: a passive on `Event.Damage.Dealt` heals the dealer by `Data.Event.Amount` × a percent
(item-power K6).

### 2.2 The Vampire (`demo.character.vampire`)

Roles `Unit.Role.Damage`, `Unit.Role.Tank` (it survives by hitting). Growth: `growth_damage` bands. No SP: its
skills cost HP (B1), its basic gives no SP (`sp_basic` 0), so SP items fit it as `Item.Fit.Sp` with weight 0.

| Move | Kind | Effect (first proposals) |
|---|---|---|
| Bite | basic | 100% ATK Physical; heals 30% of the damage. |
| Blood Lance | skill | Costs 12% max HP. 220% ATK Physical on one enemy; heals 40% of the damage. |
| Crimson Sweep | skill | Costs 18% max HP. 120% ATK Physical on every enemy; heals 25% of the damage. |
| Night Feast | ult | 300% ATK on one enemy and 100% on its neighbours; heals 60% of the damage; cleanses itself. |
| Thirst | passive | +1% damage for every 2% of max HP missing (up to +40%). |
| Lifesteal | passive | The innate heal of every hit (the percents above), through K6. |

Level rows (`level-cap` 2.3 rhythm, its own mix): 12 Hemorrhage (skill: Bleed on hit), 15 Night Feast II, 20 Blood
Frenzy (passive: a kill refunds the last HP cost), 25 Blood Lance II, 30 Sanguine Tide (signature: every enemy, heals
the party a share of the damage), 35 Thirst II, 40 Undying Hunger (passive: below 25% HP, lifesteal doubles), 45
Sanguine Tide II, 50 Night Feast III.

Synergy with today's classes: the Cleric and Bulwark keep it above its HP costs; the Lifebinder's meter fills from its
lifesteal; item-power's on-hit items (Chain Bell, Static Ring) add hits that each heal it.

### 2.3 The Lifebinder (`demo.character.lifebinder`)

Roles `Unit.Role.Healer`, `Unit.Role.Support`, `Unit.Role.FollowUp`. Growth: `growth_support` bands. Uses SP.

| Move | Kind | Effect (first proposals) |
|---|---|---|
| Mending Strike | basic | 80% ATK Physical; heals the lowest-HP ally 5% of their max HP. |
| Wellspring | skill | Heals every ally 12% of the Lifebinder's max HP and gives Regen for 2 turns. |
| Lifeline | skill | One ally: heals 25% of their max HP and cleanses one debuff. |
| Bloom | ult | Heals every ally 25%; the party +20% ATK for 2 turns; adds 50% of the threshold to the meter. |
| Overflowing Grace | passive (meter) | The meter fills with every heal any ally receives (B2: `Event.Ally.Heal.Received` and its own `Received`). At 50% of the Lifebinder's max HP (B3), **Verdant Lash**: a follow-up of 120% ATK on a random enemy (K4) that also heals the lowest-HP ally 8% (a meter heal: it does not refill the meter). |

Level rows: 12 Seedburst (skill: heal and Regen on two allies), 15 Bloom II, 20 Deep Roots (passive: the threshold
falls to 40%), 25 Wellspring II, 30 World Tree (signature: a big party heal and a free Verdant Lash), 35 Deep Roots II
(35%), 40 Evergreen (passive: Verdant Lash hits every enemy at 60%), 45 World Tree II, 50 Bloom III.

### 2.4 The third character: open (the Duelist draft below was turned down, D3)

**Not approved (user, 2026-11-22).** Kept only as a record of the first brainstorm; the third character is designed in
this slice's own chat.

The third character (the user asked for a brainstorm). Picked from four ideas: a **Duelist** (counters), a Gambler
(crit and chance procs), a Hexblade (damage per debuff on the target), a Chronomancer (action advance and extra turns).
The Duelist is proposed because it is the playstyle the game lacks entirely (acting on the enemy's turn), it uses the
item-power ally-hit hook (K1) and pairs with existing tanks and with Vengeful Aegis and Guardian's Vow. The other three
stay as ideas for a later pack.

Roles `Unit.Role.FollowUp`, `Unit.Role.Damage`. Growth: `growth_damage` bands. Uses SP.

| Move | Kind | Effect (first proposals) |
|---|---|---|
| Thrust | basic | 100% ATK Physical. |
| En Garde | skill | For 2 turns, Riposte: whenever an ally is hit, a 90% ATK follow-up on the attacker (K1). |
| Flurry | skill | 3 strikes of 60% ATK Physical at random enemies (K4). |
| Grand Riposte | ult | 250% ATK on one enemy; for 2 turns every counter hits twice. |
| Parry | passive | When the Duelist is hit, a 70% ATK follow-up on the attacker. |

Level rows: 12 Feint (skill: Vulnerable on the target, a One More on a crit), 15 Grand Riposte II, 20 Blade Dance
(passive: each counter gives +10 ult charge), 25 En Garde II (3 turns), 30 Thousand Cuts (signature: 6 strikes at
random enemies), 35 Blade Dance II, 40 Perfect Guard (passive: a counter heals the protected ally 5%), 45 Thousand Cuts
II, 50 Grand Riposte III.

### 2.5 The Blood Moon items (21 planned, set `Card.Set.Bloodmoon`; 14 drafted below, 7 to come with the third character)

Pools follow item-power's rule (an item is in `Pool.Treasure` or `Pool.Boss`, never both; Shop and Chest may share with
Treasure). They appear in a run only when the player owns them (the card pool, as for Descent cards).

| Item | Rarity | Effect | Pools |
|---|---|---|---|
| Blood Vial | Common | On a kill: heal 15% max HP. | Treasure, Shop, Chest |
| Fencer's Glove | Common | Follow-ups deal +15% damage. | Treasure, Shop |
| Seedling Charm | Common | +15% healing given. | Treasure, Shop, Chest |
| Leech Tooth | Common | Heal 8% of the damage you deal. | Treasure, Chest |
| Blood Chalice | Rare | Heal 15% of the damage you deal; +10% ATK. | Treasure, Shop |
| Thorned Rose | Rare | When you are healed, a 40% ATK follow-up on a random enemy. | Treasure |
| Riposte Ring | Rare | When an ally is hit, 25% chance of a 70% ATK follow-up on the attacker. | Treasure, Shop |
| Sanguine Pact | Epic | Your HP costs are 30% lower. | Treasure |
| Verdant Heart | Epic | Your meter fills 30% faster. | Treasure |
| Duelist's Cloak (armor) | Epic | When an ally is hit, 30% chance to counter for 100% ATK. | Treasure |
| Heartseeker Fang (weapon) | Epic | Heal 20% of the damage you deal; +15% crit rate. | Boss |
| Crimson Thirst | Legendary | +2% damage for every 5% of max HP missing (no cap). | Boss |
| Lifebloom Crown | Legendary | The party: every 100% of your max HP healed, heal the party 15% and strike every enemy for 100% ATK (a meter, B3). | Boss |
| Twin Blades | Legendary | Your follow-ups hit twice. | Treasure |

### 2.6 The pack

`infra/economy/card_economy.json` gains `bloodmoon-pack` ("Blood Moon Pack"), `setIds` ["bloodmoon"], the Descent
Pack's price, card count (5), odds, pity and first-pack guarantees as placeholders (5c tunes both packs). The set holds
every rarity the pack can give (Common 4, Rare 3, Epic 4, Legendary 3, Mythic 3: the three characters are Mythic like
every character card), so the openability rule passes. With 24 cards (D5) the rarity counts are set when the
item list is final; dust values are the shared rates.

Presentation (the user's folders; new files only, on the user's go-ahead):
- `CardPackLook` for the pack in `card_style.tres`'s pack list (a crimson foil, a game-icons glyph) — an edit to an
  existing file, shown `old → new`.
- Cube looks for the three characters: a design round with a live preview and the user's gate (spec `cube-style`
  round 4 process: faces, one combined detail each, a floor effect), then 4K portraits by `build_card_portraits.tscn`.
- Animations from the default set; sounds from the bank by the audio pass's rules (new ult sounds picked by the user).
- Class pick: the three join the turntable when owned; one new preset per character in `party_presets.tres` (an edit).

### 2.7 Bots

- Role tags as in 2.2-2.4; fit and grant tags on the 21 items (`bot-play` 2.3; HP-cost items as `Item.Fit.Survival` +
  a new `Item.Fit.HpCost`, meter items as `Item.Fit.Healing` + `Item.Fit.FollowUp`).
- `AutoPolicy` and the smart controller learn HP costs: an HP-cost move is scored like an SP move, refused while it
  would leave the caster under `danger_hp_x100` (25% max HP by default, a policy option) unless the move's lifesteal on
  the expected damage would bring it back above; the Vampire then falls back to Bite. Meters need nothing from the
  bots (they fire on their own).

## 3. Data contracts

No new C# records: the catalog rows, the pack type and the card events use the existing shapes (`CardCatalogFile`,
`PackTypeRequest` / seed file, `PackPurchased`, `PackOpened`, ...). The new set id `bloodmoon` is data. Godot fields:
`BattleAbility.meter_attribute`, `meter_threshold`, `meter_threshold_of`; `CostReader` returns `hp`; `AbilityHint`
gains `hpCostX100`.

## 4. Failure modes

- **Old content and goldens:** B1-B4 are off unless content uses them; the new attribute starts at 0 and is hashed only
  when not 0 (as the state hasher does for optional values; to be confirmed in the build, else the combat goldens are
  re-recorded on purpose with the user's OK and `BattleGoldenTests` rerun).
- **HP cost loops:** a move that would kill its user is refused (B1), so an Auto or script cannot suicide; a refused
  HP move is an ordinary invalid choice (`on_invalid`).
- **Meter loops:** meter heals never fill meters, a check fires at most 3 times, the chain cap holds.
- **Pack rules:** the seeder refuses a pack type that fails openability; the e2e card scenario buys and opens a Blood
  Moon pack on the real stack; a duplicate open by request key opens once (scenario 1).
- **Run lock and pools:** Blood Moon items enter a run's pool only when owned, like every card (spec `card-collection`).

## 5. Observability

Existing metrics, no new names: `rpg_packs_bought_total{pack}`, `rpg_packs_opened_total{pack}`,
`rpg_pack_cards_total{pack,rarity}`, `rpg_pack_pity_triggers_total`, `rpg_packs_owned`; the Grafana card panels gain the
second pack's series automatically. The play report adds per-class rows for the three, `hpCostSpent` and `meterFires`.

## 6. Test plan

Godot (fixtures for the hooks; content tests for the characters):
- B1: an HP-cost ability lowers HP, is refused at cost ≥ HP, `CostReader` reports it, the hint shows it.
- B2: instant heals, HoT ticks and lifesteal send `Heal.Given` / `Received` / `Ally.Heal.Received` with the restored
  amount; overheal is excluded.
- B3: a meter fills, fires at the threshold, subtracts it, fires at most 3 times per check; meter heals never fill it.
- B4: the attribute starts at 0 each battle and is never carried.
- New goldens `hpcost-seed-*`, `meter-seed-*`, each with a trace and a tampered copy; every existing golden replays.
- Content: the three characters and 21 items validate; card faces render ("Unknown card" never shows); the catalog is in
  sync (`tools/check_card_catalog.sh`).
- Auto: the Vampire never casts a move it cannot survive; it uses Bite when low.

.NET (Testcontainers, real stack):
- The seeder adds the new catalog rows and pack type; a second seeding changes nothing.
- Buy and open a Blood Moon pack; pity and first-pack guarantees per pack type; openability holds for the new set.
- The existing duplicate-open test runs for both pack types (scenario 1).

e2e: `card_pack_bloodmoon` (`#! cards`): buy, open, own a Vampire, start a run with it, a battle verified by the real
worker.

## 7. Decisions, open questions, what stays out

**Decisions (user, 2026-11-22):**
- D1. The Vampire heals from the damage it deals and pays HP for its moves.
- D2. The new support makes follow-up attacks each time a set amount of healing has been done (Honkai style).
- D3. A third character; **the Duelist is not approved** (user, 2026-11-22). The third character is decided when this
  slice is discussed in its own chat (2.4 keeps the draft only as a record).
- D4. Three characters in the new pack; each fits a new playstyle and today's teams.
- D5. The set holds **24 cards**: 3 characters and 21 items (7 more than the draft list in 2.5, designed with the third
  character).
- D6. The Lifebinder's meter fills from **all healing the party receives**.
- D7. Names kept: Vampire, Lifebinder, Blood Moon.

**Open questions (for this slice's own chat):**
- Q1. The third character (ideas so far: Gambler, Hexblade, Chronomancer; the Duelist was turned down).
- Q2. The 7 further items, and whether the counter-themed draft items (Riposte Ring, Duelist's Cloak, Fencer's Glove,
  Twin Blades) stay once the third character is chosen.

**Stays out:** pack odds and prices (5c), more packs, analytics, new events for the new characters (class choices in
events can come with 5c or a later event pass).

## 8. Measurements

To be filled by the build: per-class win rates for the three, `hpCostSpent`, `meterFires`, pairs with lift.
