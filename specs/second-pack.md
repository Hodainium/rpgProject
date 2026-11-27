# Spec: second-pack (before 5c `card-balance`, after `level-cap`)

Status: **spec written 2026-11-22; design finished 2026-11-26 (the third character, the Vampire Hunter, and the 9
further items, user's answers in D8-D14); ready for `/implement`.** The last of four slices the user asked for on
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
3. **The Vampire Hunter** (user, 2026-11-26; 2.4): the first crit-focused class. Hits that don't crit build **Focus**
   (crit rate and crit damage), a crit spends it, and its crits **Silver** enemies (half healing received), which counters
   the lifesteal, regen and drained hits the pack's own theme brings. Physical bolts and a Fire flask.
4. **21 Blood Moon items** for lifesteal, HP costs, healing meters, follow-ups and crits (2.5).

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

Focus and Silvered (2.4) need no new hook either: `Battle._send_damage_events` sends `Event.Damage.Dealt` before
`Event.Damage.Dealt.Critical` for the same hit, and the triggers run in that order, so "add a stack on every hit" then
"clear the stacks on a crit" nets to "a hit that doesn't crit adds one, a crit spends them". The crit's damage is computed
in `exec_calc_standard_damage.gd` before either event, so the crit itself gets the full bonus. DoT ticks send only
`Event.Damage.Dealt.Dot` (K2, checked 2026-11-26), never `Event.Damage.Dealt`, so they never build Focus. Silvered is a
`heal_taken` modifier, which every heal ExecCalc and the drained hit already read.

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

### 2.4 The Vampire Hunter (`demo.character.vampire_hunter`)

The first crit-focused class (user, 2026-11-26; D8). Today every class starts at 5% crit rate / 50% crit damage and the
Ranger at 20% (its Steady Aim, Eagle Eye and Deadeye rows add more), but the Ranger is about weakness marks and
follow-ups; no class is built on crits. The Hunter's crits come on a rhythm (Focus), not on luck alone, and its theme is
the pack's counterweight: it Silvers what heals. (The Duelist draft of 2026-11-22 was turned down, D3; its counter
playstyle stays an idea for a later pack, with the Gambler, Hexblade and Chronomancer.)

Roles `Unit.Role.Damage`. Growth: `growth_damage` bands. Uses SP. Starting crit: 10% rate, 60% damage (placeholders).
Damage: Physical crossbow bolts and one Fire skill (the holy water flask), so it can hit either weakness (D10); no class
mixes damage types this way yet.

| Move | Kind | Effect (first proposals) |
|---|---|---|
| Silver Bolt | basic | 100% ATK Physical on one enemy. |
| Holy Water | skill | A flask: 90% ATK Fire on the target and 45% on its neighbours. |
| Stake | skill | 220% ATK Physical on one enemy; this hit has +25% crit rate. |
| Dawnbreak | ult | 320% ATK Physical on one enemy, always a crit; Focus counts double on this hit. |
| Focus | passive | Every hit that does not crit gives 1 Focus (max 5; each stack +8% crit rate, +12% crit damage); a crit spends them all (2.1: one listener on `Event.Damage.Dealt` adds, one on `Event.Damage.Dealt.Critical` clears). Focus is a stacking status that is **not** dispellable (no `Status.Buff` tag) and shows in the status list (D11). |
| Silver | passive | Its crits apply **Silvered** to the target: −50% `heal_taken` for 2 turns (D12). That also halves a drained hit's heal, so it weakens the drain mirror, regen enemies, the Leech and the Hearts. Enemies only. |

At 5 stacks it crits about 50% of the time for about +120% crit damage; "always a crit" on Dawnbreak is a crit-rate
modifier of +100% for that hit (crit rate above 100% is wasted today, `exec_calc_standard_damage.gd`).

Level rows (`level-cap` 2.3 rhythm, passives at 3 and 7, the innate skill's ranks at 5 and 9):

| Level | Row | Kind | Effect |
|---|---|---|---|
| 3 | Keen Senses | passive | Crits on a Silvered target +20% crit damage. |
| 5 | Holy Water II | rank | |
| 7 | Patient Hunter | passive | Start every battle with 2 Focus. |
| 9 | Holy Water III | rank | |
| 12 | Chain Shot | skill | 3 hits of 60% ATK Physical on one enemy; each hit builds or spends Focus. |
| 15 | Dawnbreak II | rank | |
| 20 | Relentless | passive | A crit keeps 1 Focus. |
| 25 | Stake II | rank | |
| 30 | Purge the Night | signature | 150% ATK Fire on every enemy; Silvers them all. |
| 35 | Keen Senses II | rank | |
| 40 | Final Verdict | passive | A kill by a crit advances its next action by 25% (`ExecutionRow.delay`). |
| 45 | Purge the Night II | rank | |
| 50 | Dawnbreak III | rank | |

Synergy with today's classes: the Ranger's weakness marks and the Hunter's Fire flask cover both weakness kinds; the
Bard's ATK buffs and the crit items of item-power (Lucky Coin, Focus Stone, Glass Lens, Keen Rapier, Opportunist,
Executioner's Seal) find a real owner; against drain mirrors and healing bosses Silvered is the party's answer. With the
Vampire: the pack's two sides of the same night (theme), no mechanical tie (D9: Silvered never touches party units).

Look (presentation, the user's gate, spec `cube-style` round 4 process): a crossbow on the Right socket, silver, a holy
water flask and **a cross: religious symbols are allowed for this character only** (user, 2026-11-26, D13; the rule of
cube-style Set 4b stays for every other unit).

### 2.5 The Blood Moon items (21, set `Card.Set.Bloodmoon`)

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
| Sanguine Pact | Epic | Your HP costs are 30% lower. | Treasure |
| Verdant Heart | Epic | Your meter fills 30% faster. | Treasure |
| Heartseeker Fang (weapon) | Epic | Heal 20% of the damage you deal; +15% crit rate. | Boss |
| Crimson Thirst | Legendary | +2% damage for every 5% of max HP missing (no cap). | Boss |
| Lifebloom Crown | Legendary | The party: every 100% of your max HP healed, heal the party 15% and strike every enemy for 100% ATK (a meter, B3). | Boss |
| Twin Blades | Legendary | Your follow-ups hit twice. | Treasure |
| Silver Tip | Common | +8% crit rate. | Treasure, Shop, Chest |
| Whetstone | Common | +15% crit damage. | Treasure, Shop, Chest |
| Hunter's Focus | Rare | Gives its holder the Focus passive (2.4) with at most 3 stacks. | Treasure, Shop |
| Holy Water Vial | Rare | Your crits have a 25% chance to Silver the target; +15% damage against Silvered enemies. | Treasure, Shop |
| Garlic Wreath | Rare | An enemy that hits you gets −25% healing received for 2 turns (a weaker Silvered). | Treasure, Chest |
| Hunter's Crossbow (weapon) | Epic | +30 ATK, +10% crit rate; your crits Silver the target. | Treasure |
| Hunter's Longcoat (armor, body) | Epic | +60 max HP, +8% crit rate; a crit cleanses one debuff from you. | Treasure |
| Rosary of Vigil | Epic | Your crits have a 35% chance to Silver the target; the party: +5% crit rate for each Silvered enemy (up to +15%). | Treasure |
| Stake of Dawn | Legendary | Your crits have a 50% chance to Silver the target (K3 `trigger_chance`); +60% crit damage against Silvered targets; a crit that kills gives a One More (at most once per turn). | Boss |

The counter items of the Duelist draft (Riposte Ring, Duelist's Cloak) are dropped with it; Fencer's Glove and Twin
Blades stay for the follow-ups the Lifebinder (Verdant Lash), the Ranger and item-power's procs already make (D14). The
last nine are the Hunter's: crit stats, Focus for any holder, Silvered sources and payoffs. Silvered sources besides
the Hunter: Hunter's Crossbow (every crit), and each payoff item carries its own chance on its holder's crits (K3
`trigger_chance`), higher with rarity: Holy Water Vial 25%, Rosary of Vigil 35%, Stake of Dawn 50% (user, 2026-11-26:
a Silvered payoff must work without the character). Garlic Wreath applies its own weaker status, which does not count as Silvered. Rarities of the 21: Common 6,
Rare 5, Epic 6, Legendary 4. Stake of Dawn's One More is guarded "once per turn" (a flag status cleared at turn end) on
top of the chain cap, so a crit kill chain cannot make endless turns; confirm in the build that One More from a trigger
works like Persona's (logged `"extra": true`), else it is an action advance of 100% instead (the user's call then).

### 2.6 The pack

`infra/economy/card_economy.json` gains `bloodmoon-pack` ("Blood Moon Pack"), `setIds` ["bloodmoon"], the Descent
Pack's price, card count (5), odds, pity and first-pack guarantees as placeholders (5c tunes both packs). The set holds
every rarity the pack can give (Common 6, Rare 5, Epic 6, Legendary 4, Mythic 3: the three characters are Mythic like
every character card), so the openability rule passes. 24 cards (D5); dust values are the shared rates.

Presentation (the user's folders; new files only, on the user's go-ahead):
- `CardPackLook` for the pack in `card_style.tres`'s pack list (a crimson foil, a game-icons glyph) — an edit to an
  existing file, shown `old → new`.
- Cube looks for the three characters: a design round with a live preview and the user's gate (spec `cube-style`
  round 4 process: faces, one combined detail each, a floor effect), then 4K portraits by `build_card_portraits.tscn`.
- Animations from the default set; sounds from the bank by the audio pass's rules (new ult sounds picked by the user).
- Class pick: the three join the turntable when owned; one new preset per character in `party_presets.tres` (an edit).

### 2.7 Bots

- Role tags as in 2.2-2.4; fit and grant tags on the 21 items (`bot-play` 2.3; HP-cost items as `Item.Fit.Survival` +
  a new `Item.Fit.HpCost`, meter items as `Item.Fit.Healing` + `Item.Fit.FollowUp`, crit items as `Item.Fit.Damage` + a
  new `Item.Fit.Crit`, which `LootScorer` weighs up for a unit whose base crit rate is above the default 5% (the Hunter,
  the Ranger) or that holds Focus; Silvered sources and payoffs as `Item.Fit.Damage`). Hunter's Focus grants
  `Item.Grants.Damage`.
- Silvered and Focus need nothing from `AutoPolicy` beyond today's damage scoring; Stake is scored as a damage skill.
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
- **Crit loops:** Stake of Dawn's One More fires at most once per turn per holder; Focus is capped at 5 stacks (3 from
  Hunter's Focus), and a crit rate above 100% is wasted, never an error.
- **Pack rules:** the seeder refuses a pack type that fails openability; the e2e card scenario buys and opens a Blood
  Moon pack on the real stack; a duplicate open by request key opens once (scenario 1).
- **Run lock and pools:** Blood Moon items enter a run's pool only when owned, like every card (spec `card-collection`).

## 5. Observability

Existing metrics, no new names: `rpg_packs_bought_total{pack}`, `rpg_packs_opened_total{pack}`,
`rpg_pack_cards_total{pack,rarity}`, `rpg_pack_pity_triggers_total`, `rpg_packs_owned`; the Grafana card panels gain the
second pack's series automatically. The play report adds per-class rows for the three, `hpCostSpent`, `meterFires`,
and for crits `critRate` per class (crits ÷ damaging hits), `focusAtCrit` (the mean stacks a crit spent) and
`silveredHealCut` (healing Silvered took away).

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
- Hunter (content tests): a hit that does not crit adds 1 Focus, a crit spends all and gets their bonus on that hit,
  DoT ticks add none, the cap holds, Focus survives a dispel; a crit Silvers the target and halves a heal and a drained
  hit's heal on it; Silvered never lands on a party unit; Dawnbreak always crits; Holy Water Vial, Rosary of Vigil and Stake of
  Dawn Silver on a crit at their chances; Stake of Dawn gives at most one One More a turn. A golden `crit-seed-*` with Focus and Silvered (trace + tampered copy).

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
- D3. A third character; **the Duelist is not approved** (user, 2026-11-22). Decided 2026-11-26: the Vampire Hunter (D8).
- D4. Three characters in the new pack; each fits a new playstyle and today's teams.
- D5. The set holds **24 cards**: 3 characters and 21 items (the final list in 2.5, D14).
- D6. The Lifebinder's meter fills from **all healing the party receives**.
- D7. Names kept: Vampire, Lifebinder, Blood Moon.

**Decisions (user, 2026-11-26; closes Q1 and Q2):**
- D8. The third character is a crit-focused **Vampire Hunter** (no class is built on crits yet).
- D9. Its loop is **Focus build-up**: hits that don't crit build Focus, a crit spends it. Its tie to the pack is
  **Silvered** anti-heal on its crits (enemies only); no mechanical tie to the Vampire.
- D10. Damage: Physical bolts plus a Fire flask (Holy Water).
- D11. Focus is a stacking status (pure GAS stacking effects, no new hook), not dispellable; not the B4 meter.
- D12. Silvered: −50% healing received (`heal_taken`) for 2 turns.
- D13. Holy water and a cross are fine on the Vampire Hunter's look (an exception to cube-style's no-religious-symbols
  rule, for this character only).
- D14. Riposte Ring and Duelist's Cloak are dropped; Fencer's Glove and Twin Blades stay; 9 new crit and Silvered items
  (2.5). Every Silvered payoff item also Silvers on its holder's crits (Holy Water Vial 25%, Rosary of Vigil 35%,
  Stake of Dawn 50%), so it works without the Hunter (user, 2026-11-26).

**Open questions:** none for the design. Numbers are first proposals, tuned in the build's playtest and 5c.

**Stays out:** pack odds and prices (5c), more packs, analytics, new events for the new characters (class choices in
events can come with 5c or a later event pass).

## 8. Measurements

To be filled by the build: per-class win rates for the three, `hpCostSpent`, `meterFires`, pairs with lift.
