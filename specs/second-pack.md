# Spec: second-pack (before 5c `card-balance`, after `level-cap`)

Status: **spec written 2026-11-22; the Vampire Hunter and its items 2026-11-26 (D8-D14); the roster changed the same
day (D15-D23): the Lifebinder moves to the Descent Pack in its own slice after this one, the Bloodbinder, the Werewolf and
the Bloodletter join (kits approved); all five looks approved (2.6). Ready for `/implement`.** The last of four slices the user asked for on
2026-11-22: `bot-play`, `item-power`, `level-cap`, `second-pack` (this). A second card pack, **Blood Moon**, with five
new characters that bring a new playstyle and still fit existing teams, and a set of items built around them.
Builds on `specs/card-collection.md`, `specs/pack-shop.md` and `specs/card-ui.md` (sets, packs, odds, pity, the
catalog, the Shop and pack reveal), `specs/class-pick.md` (the class pick, presets, portraits),
`specs/cube-style.md` (looks), `specs/item-power.md` (hooks K1-K8), `specs/level-cap.md` (the level rhythm),
`specs/bot-play.md` (role and fit tags).

## 1. Purpose & enterprise mapping

**Purpose.** A second pack the player buys and opens beside the Descent Pack, whose cards are five characters and
23 items (28 cards, D20):
1. **The Vampire, Vlad** (user, 2026-11-22; shown as "Vlad", D23): every hit it deals heals it, and its moves cost **HP**, not SP. A damage dealer that
   lives on the edge: strong while it keeps hitting, in danger when it can't.
2. **The Bloodbinder** (user, 2026-11-26; 2.3): a blood support that pays **HP** to heal and buff others, gives the party
   lifesteal, heals harder the lower it is, and keeps a **Blood Pool** that fills with the HP the party loses and bursts as a
   party heal. (The Lifebinder, the first support drafted here, moves to the Descent Pack as it is, 2.3b, D15.)
3. **The Vampire Hunter** (user, 2026-11-26; 2.4): the first crit-focused class. Hits that don't crit build **Focus**
   (crit rate and crit damage), a crit spends it, and its crits **Silver** enemies (half healing received), which counters
   the lifesteal, regen and drained hits the pack's own theme brings. Physical bolts and a Fire flask.
4. **The Werewolf** (user, 2026-11-26; 2.4b): break and follow-ups, stronger when low: under half HP, or after its Howl or
   ult, it takes **Wolf Form** and every action ends with a free claw.
5. **The Bloodletter** (user, 2026-11-26; 2.4c): a DoT and support hybrid whose Bleeds heal the party.
6. **23 Blood Moon items** for lifesteal, HP costs, follow-ups, crits and Wolf Form (2.5).

Each character has the full level rhythm of `level-cap` (2.3 there: similar, not identical, with passives).

**Enterprise mapping.** The card system end to end, on the real backend:
- **Catalog:** `build_card_catalog.tscn` adds 28 rows (set `bloodmoon`) to `infra/economy/card_catalog.json`; the
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
for both pack types), 5 (a tampered battle with a Vampire HP cost, a Blood Pool burst or a Wolf Form claw is rejected 2002: new
tampered goldens).

## 2. Sequence flow

### 2.1 New kernel hooks (system code in `combat/`; all off unless content uses them)

| # | Hook | What it does |
|---|---|---|
| B1 | **HP costs** | An ability's cost effect may lower `hp` (a cost modifier or cost ExecCalc on `hp`, read by `CostReader.cost_of` as `{hp: n}` beside SP). `CombatASC.can_activate_ability` refuses an HP-cost ability when the cost is **at or above the caster's current HP** (a move never kills its user). `AbilityHint` shows "HP" and the cost; the battle HUD's command window previews it on the HP bar like the SP bar's preview. Paying an HP cost sends `Event.Cost.Hp` to the caster and `Event.Ally.Cost.Hp` to its living allies, payload `{source, amount}` (the HP paid), so the Bloodbinder's Blood Pool and Bloodstone see it (an HP cost sends no `Damage.Taken`, K1). |
| B2 | **Heal events** | Whenever a unit's HP rises from an effect (instant heals, HoT ticks, lifesteal, revives' HP), the battle sends `Event.Heal.Given` to the source and `Event.Heal.Received` to the target, payload `{source, target, amount}` where `amount` is the HP actually restored (overheal excluded), and, through item-power's K1, `Event.Ally.Heal.Received` to the target's living allies. HoT stacks send one event per stack tick. New tags; Thorned Rose listens (2.5). |
| B3 | **Meters** | A triggered ability may name a meter: `BattleAbility.meter_attribute` (an attribute name) and `meter_threshold` (×100; or `meter_threshold_of`, an attribute of the owner and a percent, e.g. 50% of its max HP). After each trigger drain the battle checks every living unit's meter abilities in unit order: while the attribute is at or above the threshold, it subtracts the threshold and queues the ability once (at most 3 fires per check, so a huge heal cannot fire forever). Meters fill through ordinary effects (the Bloodbinder's Blood Pool: passives on `Event.Damage.Taken`, `Event.Ally.Damage.Taken`, `Event.Cost.Hp` and `Event.Ally.Cost.Hp` adding `Data.Event.Amount` to the meter through K6). Heals made by a meter-fired ability carry `Hit.Meter` and **never fill meters**, so a meter heal cannot feed itself. |
| B5 | **HP threshold states** | A unit whose definition sets `UnitDefinition.health_states` (off by default, so no existing unit, hash or golden changes) carries `State.Health.Low` while its HP is under 50% of max and `State.Health.Critical` while under 25%, set after every HP change (settled with the death check); crossing into one sends `Event.Health.Low` / `Event.Health.Critical` to it once per crossing. Passives gate on the tags with their activation query (the Werewolf's Wolf Form, the Vampire's Undying Hunger); the tags are hashed like any tag. |
| B4 | **Meter attribute** | One new attribute in the generated `Unit` AttributeSet: `meter` (snake_case, starts at 0 each battle, never negative, never carried between battles). It is a `godot_gas/attributes_draft.cfg` edit (prompts), then `generate_attributes.tscn`. Shown on the battle HUD's party window as a thin bar under SP for units with a meter ability. |

Lifesteal needs no new hook: a passive on `Event.Damage.Dealt` heals the dealer by `Data.Event.Amount` × a percent
(item-power K6).

Focus and Silvered (2.4) need no new hook either: `Battle._send_damage_events` sends `Event.Damage.Dealt` before
`Event.Damage.Dealt.Critical` for the same hit, and the triggers run in that order, so "add a stack on every hit" then
"clear the stacks on a crit" nets to "a hit that doesn't crit adds one, a crit spends them". The crit's damage is computed
in `exec_calc_standard_damage.gd` before either event, so the crit itself gets the full bonus. DoT ticks send only
`Event.Damage.Dealt.Dot` (K2, checked 2026-11-26), never `Event.Damage.Dealt`, so they never build Focus. Silvered is a
`heal_taken` modifier, which every heal ExecCalc and the drained hit already read.

### 2.2 The Vampire, Vlad (`demo.character.vampire`)

Display name **Vlad** (the id and the spec's name stay "Vampire", D23). Roles `Unit.Role.Damage`, `Unit.Role.Tank` (it survives by hitting). Growth: `growth_damage` bands. No SP: its
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
the party a share of the damage), 35 Thirst II, 40 Undying Hunger (passive: below 25% HP, lifesteal doubles; B5 `State.Health.Critical`, so the Vampire sets `health_states`), 45
Sanguine Tide II, 50 Night Feast III.

Synergy with today's classes: the Cleric and Bulwark keep it above its HP costs; the Bloodbinder's Blood Pool fills from its
HP costs and its Blood Rite gives the whole party lifesteal; item-power's on-hit items (Chain Bell, Static Ring) add hits that each heal it.

### 2.3 The Bloodbinder (`demo.character.bloodbinder`)

First drafted as the Hemomancer (renamed by the user 2026-11-26, D23: a name about blood magic).

The pack's support (user, 2026-11-26, D16): the Vampire's mirror. The Vampire spends HP to deal damage; the Bloodbinder
spends HP to heal others, heals harder the lower it is, and lives on lifesteal (its own, the party's, the Vampire's).

Roles `Unit.Role.Healer`, `Unit.Role.Support`. Growth: `growth_support` bands. No SP: its skills cost HP (B1), its basic
gives no SP (`sp_basic` 0).

| Move | Kind | Effect (first proposals) |
|---|---|---|
| Blood Bolt | basic | 80% ATK Physical; heals itself 20% of the damage. |
| Transfusion | skill | Costs 10% max HP. One ally heals 30% of the Bloodbinder's max HP. |
| Blood Rite | skill | Costs 15% max HP. The party gets **Lifesteal** for 2 turns: every hit heals its dealer 20% of the damage. |
| Crimson Communion | ult | Every ally heals 25% of their max HP and is cleansed of one debuff; the Blood Pool fills by half its threshold. |
| Martyr's Grace | passive | Its heals +1% for every 2% of its max HP missing (up to +40%). |
| Blood Pool | passive (meter, B3) | Fills with every HP the party loses: hits taken (`Event.Damage.Taken`, `Event.Ally.Damage.Taken`) and HP costs paid (`Event.Cost.Hp`, `Event.Ally.Cost.Hp`, B1). At 60% of the Bloodbinder's max HP, **Sanguine Surge**: every ally heals 10% of their max HP (a meter heal, `Hit.Meter`). |

Level rows (`level-cap` 2.3 rhythm):

| Level | Row | Kind | Effect |
|---|---|---|---|
| 3 | Thick Blood | passive | +10% max HP. |
| 5 | Transfusion II | rank | |
| 7 | Shared Vein | passive | Each HP cost it pays also heals the lowest-HP ally 50% of the cost. |
| 9 | Transfusion III | rank | |
| 12 | Coagulate | skill | Costs HP; a Ward on one ally. |
| 15 | Crimson Communion II | rank | |
| 20 | Deep Pool | passive | The Pool bursts at 50%. |
| 25 | Blood Rite II | rank | 3 turns. |
| 30 | Red Tide | signature | 140% ATK Physical on every enemy; the party heals 50% of the damage. |
| 35 | Deep Pool II | rank | 40%. |
| 40 | Last Drop | passive | Once per battle, when an ally would die (`Event.Unit.Dying`, K5), the Bloodbinder pays 20% max HP and the ally stays at 1 HP (not when the payment would kill it, B1). |
| 45 | Red Tide II | rank | |
| 50 | Crimson Communion III | rank | |

Synergy: with the Vampire, Blood Rite makes the whole party lifesteal and the Vampire's HP costs fill the Pool; with the
Hunter, no conflict (Silvered never lands on the party); with the Cleric, two healers from different resources.

### 2.3b The Lifebinder moves to the Descent Pack (D15)

The user likes the Lifebinder's design and playstyle as they are, but its nature theme fits neither the Blood Moon pack
nor its playstyle (2026-11-26). It moves, unchanged, to the **Descent Pack** (which has no healer: its supports are the
Shatterweaver and the Plaguewright) in its own quick slice after this one (roadmap 5j2), with its three items (Seedling
Charm, Verdant Heart, Lifebloom Crown) and its approved look (the `bm_lifebinder_*` shapes of PR #95, renamed there). It
needs B2-B4, which this slice builds. Its kit, kept here as the record for that slice:

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

### 2.4b The Werewolf (`demo.character.werewolf`)

The Blood Moon creature itself (user, 2026-11-26, D17): break and follow-ups, stronger the lower it gets, like the
Vampire's Thirst. It owns the pack's follow-up items (Fencer's Glove, Twin Blades) and the two Wolf Form items.

Roles `Unit.Role.Break`, `Unit.Role.FollowUp`, `Unit.Role.Damage`. Growth: `growth_damage` bands. Uses SP (so the pack
has two HP and three SP characters). Physical, heavy toughness damage. Sets `health_states` (B5).

| Move | Kind | Effect (first proposals) |
|---|---|---|
| Rend | basic | 100% ATK Physical, heavy toughness damage. |
| Pounce | skill | 180% ATK Physical on one enemy; if it breaks the target, its next action comes 15% sooner. |
| Howl | skill | Wolf Form for 2 turns; the party +15% ATK for 2 turns. |
| Moonfall Frenzy | ult | 5 claws of 50% ATK Physical at random enemies (K4); then Wolf Form for 2 turns. |
| Wolf Form | passive | While under 50% HP (`State.Health.Low`, B5) or in the Wolf Form status (Howl, the ult): after each of its actions (`Event.Ability.Used.Basic` / `Skill` / `Ultimate`, never on a hit, so a claw cannot chain), **Claw**: a 40% ATK Physical follow-up on the action's primary target; its hits heal it 10% of the damage. |

Level rows:

| Level | Row | Kind | Effect |
|---|---|---|---|
| 3 | Thick Hide | passive | +15% DEF. |
| 5 | Pounce II | rank | |
| 7 | Pack Instinct | passive | Its follow-ups +20% damage against Broken enemies. |
| 9 | Pounce III | rank | |
| 12 | Savage Maul | skill | 150% ATK on the target and 60% on its neighbours, heavy toughness damage. |
| 15 | Moonfall Frenzy II | rank | |
| 20 | Blood Moon Hunger | passive | Wolf Form under 60% HP instead (B5's `health_low_at` raised for this unit by an effect; default 50). |
| 25 | Howl II | rank | |
| 30 | Lunar Rampage | signature | 8 claws at random enemies. |
| 35 | Alpha | passive | In Wolf Form, Claw hits twice. |
| 40 | Eternal Moon | passive | Always in Wolf Form, whatever its HP (user, 2026-11-26, D22): the Wolf Form status for the whole battle, from battle start. |
| 45 | Lunar Rampage II | rank | |
| 50 | Moonfall Frenzy III | rank | |

Look: a human form and a **wolf form** shown while Wolf Form is on (user, 2026-11-26, D21): presentation hook P1 (2.6).

### 2.4c The Bloodletter (`demo.character.bloodletter`)

A DoT and support hybrid (user, 2026-11-26, D18): its Bleeds hurt the enemy and heal the party. Roles `Unit.Role.Dot`,
`Unit.Role.Support`. Growth: `growth_support` bands. Uses SP. Physical.

| Move | Kind | Effect (first proposals) |
|---|---|---|
| Lancet | basic | 90% ATK Physical; 60% chance of 1 Bleed stack (2 turns). |
| Open Vein | skill | 60% ATK Physical and 3 Bleed stacks (3 turns) on one enemy. |
| Siphon | skill | Detonates every Bleed stack on one enemy (each stack's remaining ticks at once, like the Pyromancer's Detonate); the party heals 50% of that damage, split evenly. |
| Crimson Letting | ult | 2 Bleed stacks on every enemy; for 2 turns, allies' hits on a Bleeding enemy heal them 15% of the damage. |
| Leeching Wounds | passive | Each tick of a Bleed it applied (`Event.Damage.Dealt.Dot`, K2) heals the lowest-HP ally 30% of the tick (K6). |

Level rows: 3 Deep Cuts (passive: Bleed holds 2 more stacks), 5 Open Vein II, 7 Clotting (passive: the party +10% healing
received while any enemy Bleeds), 9 Open Vein III, 12 Bloodmist (skill: 1 Bleed on every enemy, each ally cleansed of one
debuff), 15 Crimson Letting II, 20 Exsanguinate (passive: a tick of its Bleed has 30% to spread one stack to another
enemy, `ExecutionRow.event_effect`), 25 Siphon II, 30 Red River (signature: detonates Bleed on every enemy; the party
heals the total), 35 Clotting II, 40 Lifeblood (passive: Leeching Wounds heals the whole party at 15% instead), 45 Red
River II, 50 Crimson Letting III.

Synergy: the Vampire's Hemorrhage row (Bleed on hit) and the Plaguewright's DoTs stack with it; the Bloodbinder heals the
damage its Bleeds don't cover.

### 2.5 The Blood Moon items (23, set `Card.Set.Bloodmoon`)

Pools follow item-power's rule (an item is in `Pool.Treasure` or `Pool.Boss`, never both; Shop and Chest may share with
Treasure). They appear in a run only when the player owns them (the card pool, as for Descent cards).

| Item | Rarity | Effect | Pools |
|---|---|---|---|
| Blood Vial | Common | On a kill: heal 15% max HP. | Treasure, Shop, Chest |
| Fencer's Glove | Common | Follow-ups deal +15% damage. | Treasure, Shop |
| Blood Bandage | Common | +15% healing received while under 50% HP. | Treasure, Shop, Chest |
| Leech Tooth | Common | Heal 8% of the damage you deal. | Treasure, Chest |
| Blood Chalice | Rare | Heal 15% of the damage you deal; +10% ATK. | Treasure, Shop |
| Thorned Rose | Rare | When you are healed, a 40% ATK follow-up on a random enemy. | Treasure |
| Sanguine Pact | Epic | Your HP costs are 30% lower. | Treasure |
| Bloodstone | Epic | Each time you pay HP: +10% ATK for 2 turns (stacks 3 times). | Treasure |
| Heartseeker Fang (weapon) | Epic | Heal 20% of the damage you deal; +15% crit rate. | Boss |
| Crimson Thirst | Legendary | +2% damage for every 5% of max HP missing (no cap). | Boss |
| Heart of the Red Moon | Legendary | The party: heal 10% of all damage dealt; your HP costs are 20% lower. | Boss |
| Twin Blades | Legendary | Your follow-ups hit twice. | Treasure |
| Silver Tip | Common | +8% crit rate. | Treasure, Shop, Chest |
| Whetstone | Common | +15% crit damage. | Treasure, Shop, Chest |
| Hunter's Focus | Rare | Gives its holder the Focus passive (2.4) with at most 3 stacks. | Treasure, Shop |
| Holy Water Vial | Rare | Your crits have a 25% chance to Silver the target; +15% damage against Silvered enemies. | Treasure, Shop |
| Garlic Wreath | Rare | An enemy that hits you gets −25% healing received for 2 turns (a weaker Silvered). | Treasure, Chest |
| Hunter's Crossbow (weapon) | Epic | +30 ATK, +10% crit rate; your crits Silver the target. | Treasure |
| Hunter's Longcoat (armor, body) | Epic | +60 max HP, +8% crit rate; a crit cleanses one debuff from you. | Treasure |
| Rosary of Vigil | Epic | Your crits have a 35% chance to Silver the target; the party: +5% crit rate for each Silvered enemy (up to +15%). | Treasure |
| Moonstone Pendant | Rare | Wolf Form starts 10% higher (under 60% HP; 70% with Blood Moon Hunger). | Treasure, Shop |
| Full Moon Charm | Epic | +15% crit rate while in Wolf Form. | Treasure |
| Stake of Dawn | Legendary | Your crits have a 50% chance to Silver the target (K3 `trigger_chance`); +60% crit damage against Silvered targets; a crit that kills gives a One More (at most once per turn). | Boss |

The counter items of the Duelist draft (Riposte Ring, Duelist's Cloak) are dropped with it; Fencer's Glove and Twin
Blades stay for the follow-ups the Werewolf (Claw), the Ranger and item-power's procs already make (D14). The
last nine are the Hunter's: crit stats, Focus for any holder, Silvered sources and payoffs. Silvered sources besides
the Hunter: Hunter's Crossbow (every crit), and each payoff item carries its own chance on its holder's crits (K3
`trigger_chance`), higher with rarity: Holy Water Vial 25%, Rosary of Vigil 35%, Stake of Dawn 50% (user, 2026-11-26:
a Silvered payoff must work without the character). Garlic Wreath applies its own weaker status, which does not count as Silvered. The Lifebinder's three items move with it
(D15) and three blood items replace them at the same rarities and pools (Blood Bandage, Bloodstone, Heart of the Red Moon;
the user's OK 2026-11-26); Moonstone Pendant and Full Moon Charm are the Werewolf's (D20). Rarities of the 23: Common 6,
Rare 6, Epic 7, Legendary 4. Stake of Dawn's One More is guarded "once per turn" (a flag status cleared at turn end) on
top of the chain cap, so a crit kill chain cannot make endless turns; confirm in the build that One More from a trigger
works like Persona's (logged `"extra": true`), else it is an action advance of 100% instead (the user's call then).

### 2.6 The pack

`infra/economy/card_economy.json` gains `bloodmoon-pack` ("Blood Moon Pack"), `setIds` ["bloodmoon"], the Descent
Pack's price, card count (5), odds, pity and first-pack guarantees as placeholders (5c tunes both packs). The set holds
every rarity the pack can give (Common 6, Rare 6, Epic 7, Legendary 4, Mythic 5: the five characters are Mythic like
every character card), so the openability rule passes. 28 cards (D20); dust values are the shared rates.

Presentation (the user's folders; new files only, on the user's go-ahead):
- `CardPackLook` for the pack in `card_style.tres`'s pack list (a crimson foil, a game-icons glyph) — an edit to an
  existing file, shown `old → new`.
- Cube looks for the five characters: a design round with a live preview and the user's gate (spec `cube-style`
  round 4 process: faces, one combined detail each, a floor effect), then 4K portraits by `build_card_portraits.tscn`.
  **Approved 2026-11-26 (the design round ran first, before the build; PR #95 and this one).** The shapes are committed as
  `presentation/demo/style/attachments/bm_*.tres` (36 files); the build adds each look to the main registry once its
  character exists (a look for a unit not in content fails the validator, `style_look_unknown_unit`), wired as below. Sockets:
  T = Top, F = Front, C = Center, L / R = Left / Right, B = Back. Effects were previewed with recoloured existing ones; each
  character gets its own (cube-style rule), keeping the previewed look.

  | Character | Body colour (`display_color`) | Attachments | Floor effect |
  |---|---|---|---|
  | Vlad (Vampire) | pale (0.93, 0.9, 0.9) | `bm_vampire_cloak` C, `bm_vampire_collar` T, `bm_vampire_hair` T, `bm_vampire_peak` F, `bm_face_vampire_a` F, `bm_vampire_cravat` F | a black cloud (previewed: `void_smoke`, colour (0.04, 0.02, 0.03), embers black) |
  | Vampire Hunter | slate (0.24, 0.27, 0.36) | `bm_hunter_coat` C, `bm_hunter_tricorne` T, `bm_face_hunter_d` F, `bm_hunter_bandolier` F, `bm_hunter_hip_flask` L, `bm_hunter_crossbow` R offset (-0.14, -0.04, 0) | none (user, 2026-11-26) |
  | Bloodbinder | pale grey (0.8, 0.79, 0.82) | `bm_bb_hood` C, `bm_bb_robe` C, `bm_face_bb_a` F, `bm_bb_crystal` L offset (0.24, 0.05, 0) and R offset (-0.24, 0.05, 0), both bobbing (BOB, 0.45 /s, 0.06) | dark red smoke (previewed: `void_smoke`, colour (0.45, 0, 0.05), embers black) |
  | Werewolf | grey (0.45, 0.43, 0.42) | `bm_ww_ears_grey` T, `bm_ww_mane_grey` C, `bm_ww_snout_grey` F, `bm_ww_eyes_gold` F, `bm_ww_tail_grey` B, `bm_ww_claws` C | none |
  | Werewolf, rage form (Wolf Form, P1) | black (0.12, 0.1, 0.1) by a colour override, **roughness 1** (a glossy black top reads pale under the top light) | `bm_ww_ears_black` T, `bm_ww_mane_black` C, `bm_ww_snout_black` F, `bm_ww_eyes_red` F, `bm_ww_tail_black` B, `bm_ww_claws` C | none |
  | Bloodletter | pale grey (0.68, 0.66, 0.66) | `bm_bl_scalp` T, `bm_bl_cage` T, `bm_bl_coat` C, `bm_bl_goggles` F, `bm_bl_vials` C, `bm_bl_mouth_stitched` F | one combined effect: a red floor glow and red orbs (previewed: `golden_glow` + `wisp_motes`, colour (0.85, 0.02, 0.06) / (0.9, 0.05, 0.1); a look holds one effect) |
  | Lifebinder (moves to Descent, 2.3b) | sage (0.45, 0.78, 0.58) | `bm_lifebinder_crown` T, `bm_face_lifebinder_a` F, `bm_lifebinder_staff` R offset (-0.14, -0.1, 0) | one combined effect: a green floor glow and green orbs |

  No effect may carry particles the effect's colour does not reach (the user turned down white motes from `holy_ground` and
  blue embers from `void_smoke`'s default `ember_color`).
- **P1, state looks (presentation hook, the Werewolf's wolf form, D21):** a look that replaces a unit's own look while the
  unit carries a tag (the Wolf Form status, or `State.Health.Low` for the Werewolf), swapped by `UnitAnimator.restyle()`
  when the tag comes or goes, with a short transform effect (approved 2026-11-26 in a live demo: the cube squashes to
  (1.1, 0.8, 1.1) over 0.16 s while a small burst plays, red going into rage and pale going back, its sparks kept close
  (previewed: `explosion` at size 0.7 on an anchor scaled 0.55), and a light screen shake; the look swaps while it is squashed,
  then it springs to (0.92, 1.18, 0.92) and settles with a back-ease over 0.22 s; no smoke; played once per change, never on
  a loop) (the field's shape is settled in the build: a
  `StyleRegistry.state_looks` list or a `UnitLook` field). Presentation only (cube-style's "state looks" item, never in
  a hash or upload); a replay or a headless run loads no look.
- Known bug found in the demo (fix in the build): an `FxShakeLayer` still running when the window closes raises "Trying
  to assign invalid previously freed instance" (`fx_shake_layer.gd` `ended` / `update`), so its target must be checked.
- Animations from the default set; sounds from the bank by the audio pass's rules (new ult sounds picked by the user).
- Class pick: the five join the turntable when owned; one new preset per character in `party_presets.tres` (an edit).

### 2.7 Bots

- Role tags as in 2.2-2.4c; fit and grant tags on the 23 items (`bot-play` 2.3; HP-cost items as `Item.Fit.Survival` +
  a new `Item.Fit.HpCost`, Wolf Form items as `Item.Fit.FollowUp`, crit items as `Item.Fit.Damage` + a
  new `Item.Fit.Crit`, which `LootScorer` weighs up for a unit whose base crit rate is above the default 5% (the Hunter,
  the Ranger) or that holds Focus; Silvered sources and payoffs as `Item.Fit.Damage`). Hunter's Focus grants
  `Item.Grants.Damage`.
- Silvered and Focus need nothing from `AutoPolicy` beyond today's damage scoring; Stake is scored as a damage skill.
- `AutoPolicy` and the smart controller learn HP costs: an HP-cost move is scored like an SP move, refused while it
  would leave the caster under `danger_hp_x100` (25% max HP by default, a policy option) unless the move's lifesteal on
  the expected damage would bring it back above; the Vampire then falls back to Bite, the Bloodbinder to Blood Bolt. The
  Bloodbinder's HP-cost heals go through `AutoPolicy._heal` with HP as the cost (spec `auto-support`), and Blood Rite counts
  as a party buff. Meters and Wolf Form need nothing from the bots (they fire on their own).

## 3. Data contracts

No new C# records: the catalog rows, the pack type and the card events use the existing shapes (`CardCatalogFile`,
`PackTypeRequest` / seed file, `PackPurchased`, `PackOpened`, ...). The new set id `bloodmoon` is data. Godot fields:
`BattleAbility.meter_attribute`, `meter_threshold`, `meter_threshold_of`; `CostReader` returns `hp`; `AbilityHint`
gains `hpCostX100`; `UnitDefinition.health_states`, `health_low_at` (B5); the presentation's state looks (P1).

## 4. Failure modes

- **Old content and goldens:** B1-B5 are off unless content uses them; the new attribute starts at 0 and is hashed only
  when not 0 (as the state hasher does for optional values; to be confirmed in the build, else the combat goldens are
  re-recorded on purpose with the user's OK and `BattleGoldenTests` rerun).
- **HP cost loops:** a move that would kill its user is refused (B1), so an Auto or script cannot suicide; a refused
  HP move is an ordinary invalid choice (`on_invalid`).
- **Meter loops:** meter heals never fill meters, a check fires at most 3 times, the chain cap holds.
- **Claw loops:** Claw answers actions, never hits, so a follow-up never sets off another Claw; Last Drop fires once per
  battle and never kills the Bloodbinder.
- **Crit loops:** Stake of Dawn's One More fires at most once per turn per holder; Focus is capped at 5 stacks (3 from
  Hunter's Focus), and a crit rate above 100% is wasted, never an error.
- **Pack rules:** the seeder refuses a pack type that fails openability; the e2e card scenario buys and opens a Blood
  Moon pack on the real stack; a duplicate open by request key opens once (scenario 1).
- **Run lock and pools:** Blood Moon items enter a run's pool only when owned, like every card (spec `card-collection`).

## 5. Observability

Existing metrics, no new names: `rpg_packs_bought_total{pack}`, `rpg_packs_opened_total{pack}`,
`rpg_pack_cards_total{pack,rarity}`, `rpg_pack_pity_triggers_total`, `rpg_packs_owned`; the Grafana card panels gain the
second pack's series automatically. The play report adds per-class rows for the five, `hpCostSpent`, `meterFires`,
and for crits `critRate` per class (crits ÷ damaging hits), `focusAtCrit` (the mean stacks a crit spent) and
`silveredHealCut` (healing Silvered took away), `wolfFormActions` and `bleedHealing`.

## 6. Test plan

Godot (fixtures for the hooks; content tests for the characters):
- B1: an HP-cost ability lowers HP, is refused at cost ≥ HP, `CostReader` reports it, the hint shows it.
- B2: instant heals, HoT ticks and lifesteal send `Heal.Given` / `Received` / `Ally.Heal.Received` with the restored
  amount; overheal is excluded.
- B3: a meter fills, fires at the threshold, subtracts it, fires at most 3 times per check; meter heals never fill it.
- B4: the attribute starts at 0 each battle and is never carried.
- B1 events: paying an HP cost sends `Cost.Hp` / `Ally.Cost.Hp` with the amount paid.
- B5: a unit with `health_states` gains and loses `State.Health.Low` / `Critical` as its HP crosses the lines and sends
  each event once per crossing; a unit without it never carries them; every existing golden replays unchanged.
- New goldens `hpcost-seed-*`, `meter-seed-*`, `health-seed-*`, each with a trace and a tampered copy; every existing golden replays.
- Content: the five characters and 23 items validate; card faces render ("Unknown card" never shows); the catalog is in
  sync (`tools/check_card_catalog.sh`).
- Auto: the Vampire and the Bloodbinder never cast a move they cannot survive; they use their basic when low.
- Bloodbinder: the Pool fills from hits and HP costs, bursts at its threshold, its burst never fills it; Martyr's Grace
  scales; Last Drop saves once. Werewolf: Wolf Form under 50% HP and after Howl, one Claw per action and never from a
  follow-up. Bloodletter: Bleed ticks heal the lowest-HP ally; Siphon detonates and heals.
- Presentation: the Werewolf's look swaps on Wolf Form and back (P1), nothing of it in a hash.
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
- D2. (Moved with the Lifebinder, D15.) The new support makes follow-up attacks each time a set amount of healing has been done (Honkai style).
- D3. A third character; **the Duelist is not approved** (user, 2026-11-22). Decided 2026-11-26: the Vampire Hunter (D8).
- D4. (Now five, D19.) Three characters in the new pack; each fits a new playstyle and today's teams.
- D5. (Now 28, D20.) The set holds **24 cards**: 3 characters and 21 items (the final list in 2.5, D14).
- D6. (Moved with the Lifebinder, D15.) The Lifebinder's meter fills from **all healing the party receives**.
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

**Decisions (user, 2026-11-26, the roster):**
- D15. The **Lifebinder moves to the Descent Pack** unchanged (design, playstyle, its three items, its approved look), in
  its own quick slice after this one (roadmap 5j2); its nature theme fits neither Blood Moon nor its playstyle.
- D16. The pack's support is the **Bloodbinder** (2.3): HP-cost heals and buffs, party lifesteal, the Blood Pool (B3/B4 stay
  in this slice for it; B1 sends cost events). Its three replacement items are approved.
- D17. A fourth character, the **Werewolf** (2.4b): break and follow-ups, Wolf Form under 50% HP; B5 is added for it and
  the Vampire's Undying Hunger. Kit approved as drafted.
- D18. A fifth character, the **Bloodletter**, a DoT and support hybrid (2.4c; kit approved 2026-11-26).
- D19. Five characters in the pack (the Descent Pack has five, six with the Lifebinder).
- D20. 28 cards: five characters and 23 items (the 21 with the Lifebinder's three swapped for blood items, plus Moonstone
  Pendant and Full Moon Charm for the Werewolf).
- D21. The Werewolf shows an **alternate form** while in Wolf Form (presentation hook P1, 2.6); visual demos for the
  Bloodbinder, the Werewolf and the Bloodletter run before the build, like the first three.
- D22. Leveling unlocks a passive that keeps the Werewolf in Wolf Form all the time (Eternal Moon, level 40; Alpha moves
  to 35 in place of Pack Instinct II). From then on Moonstone Pendant does nothing for it (Full Moon Charm still does).
- D23. Names: the Hemomancer is the **Bloodbinder** (`demo.character.bloodbinder`); the Vampire is shown as **Vlad** (its id
  stays `demo.character.vampire`). All five looks and the Werewolf's transform are approved (2.6).

**Open questions:** none for the design. Numbers are first proposals, tuned in the build's
playtest and 5c.

**Stays out:** pack odds and prices (5c), more packs, analytics, new events for the new characters (class choices in
events can come with 5c or a later event pass).

## 8. Measurements

To be filled by the build: per-class win rates for the five, `hpCostSpent`, `meterFires`, pairs with lift.
