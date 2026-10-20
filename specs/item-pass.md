# Spec: item-pass (slice 1c2)

Status: 📝 Spec written, item list reviewed (rev 4) · Roadmap: slice 1c2 · Date: 2026-10-20
Design intent: `specs/design/game-design.md` section 3 ("How items work in combat"), `specs/design/combat-design.md`
(damage formula, toughness). Item mechanics: `specs/game-skeleton.md` ("Items", 3.4 triggers). Turn order and replay:
`specs/combat-replay-core.md` ("Turn order", whose log schema already leaves room for extra turns). Tools:
`specs/dev-tools.md` (`give`, `equip`, `spawn item`, sandbox, script runner, validator).
Item, armor, enemy and ability values in 3.6–3.9 come from the user's reviewed list (2026-10-20, approved as written).

## 1. Purpose & enterprise mapping
Grow the demo's 8 items into a real set, add **armor**, and add the combat hooks that make interesting items
possible: **crits, weakness hits, toughness breaks (with a Persona-style "One More"), follow-up attacks and kills**
become gameplay events a passive can listen to. Every item and armor piece is tested at once with the console
(`give`, `equip`, then a sandbox battle) instead of waiting for a treasure or shop roll.

**Built the GAS way, so the next hook needs no code.** The battle already turns a row's `Damage.Type.<X>` tag into
`Event.Damage.Dealt.<X>` / `Event.Damage.Taken.<X>`. This slice generalises that into **hit tags**: anything that
describes a hit (`Hit.Critical`, `Hit.Weakness`, `Hit.Break`, `Hit.FollowUp`, later `Hit.Resisted`…) is a tag on the
hit's `GameplayEffectSpec` (GodotGAS `spec.inject_tag`), and the battle forwards **every** `Hit.<X>` tag as
`Event.Damage.Dealt.<X>` / `Event.Damage.Taken.<X>`. The ExecCalc decides what a hit is; the battle never keeps the
list. Weaknesses are plain tags on the target's ASC, toughness and weakness damage are attributes, so a definition,
a variant, an item or a debuff can change any of them with no code.

| Area | What | Owner |
|---|---|---|
| Hit tags | The battle forwards every `Hit.<X>` spec tag as Dealt/Taken events; the payload carries them | system (`combat/`) |
| Crits | Your ExecCalc injects `Hit.Critical` when the crit roll succeeds | your ExecCalc (edit approved) |
| Weakness | `Weakness.<Type>` tags on a unit; damage of that type × the target's **`weakness_dmg`** attribute, set per enemy asset; `Hit.Weakness` | your ExecCalc + attribute + tags |
| Toughness and break (HSR) | Weakness hits deplete the target's `toughness`; at 0 the unit is **Broken**: `Hit.Break`, its action is delayed, it recovers at its next turn | system rules + your ExecCalc (toughness damage) |
| One More (Persona) | The party member whose action breaks an enemy acts again at once | system (`combat/`) |
| Follow-ups | A triggered ability tagged `Ability.Type.FollowUp` is a follow-up attack: its hits carry `Hit.FollowUp`; the battle sends `Event.Attack.FollowUp` | system |
| Kills | `Event.Unit.Killed` to the unit that landed the killing hit | system |
| Armor | Head, Body, Arms, Legs, Accessory beside Weapon. Armor found in a run always goes into the party's **armor inventory**; it is equipped and unequipped from there on the map, and never dropped or put back | system (`game/`) |
| Descriptions | `description` on items and equipment | system |
| UI | Toughness bar, weakness icons, Broken and One More indicators, tooltips, equipment slots and armor inventory | your `presentation/` (edits approved) |
| Tags, attributes | New tags in the registry; `weakness_dmg`, `toughness_dmg`, `broken_dmg` in the demo AttributeSet | your `godot_gas/` and `content/` (approved) |
| Content | ~35 items, 10 armor pieces, weaknesses, toughness and weakness damage per demo enemy, toughness damage per ability | yours (list reviewed, 3.6–3.9) |

**Approvals given (2026-10-20):** Claude edits your ExecCalc, the tag registry, the UI panels in `presentation/demo/`,
and adds the `weakness_dmg`, `toughness_dmg` and `broken_dmg` attributes. Each edit is still shown as a diff when
made, and the rest of `client-godot/CLAUDE.md` section 0 applies (minimal edits, no other tweaks). Changes to the
existing demo enemies and abilities (weaknesses, toughness values) follow 3.8 and 3.9. All numbers here are
**starting values** in designer units; once the files exist, they are the source of truth.

**Enterprise mapping:** none at runtime; client-only, local mode. It touches the backend design in four ways, none
built here:
- The content hash changes, so `ruleset_version` changes (expected; no server yet).
- Item and equipment ids flow later through `ItemOffer` and run actions (`specs/server-authority.md` Part B) into the
  analytics projections (slice 4b). Ids are stable and namespaced (`demo.item.<name>`, `demo.equipment.<name>`), never
  Prometheus labels. Pickups can now be equipment, and equipping is a new run action (3.5), so the server-authority
  spec text is updated in this slice for Part B.
- The verifier replays battles with breaks and extra actions; both are deterministic and the extra action is an
  ordinary party decision in the action log (section 4).
- "Most used moves" analytics will see One More actions as actions; the action log entry says it was one (3.2).

Out of scope: **ults usable at any time** (HSR-style, out of turn; roadmap slice 1c4 `ult-interrupts`; a One More
is a normal action, so it can be an ult), resist/null/repel/drain (`Hit.Resisted` is the hook), HSR's type-specific break effects (burn, freeze,
entanglement…) beyond what content builds with the break event, break damage, party toughness in the demo,
"reveal map" / "shop discount" items, armor set bonuses.

## 2. Sequence flow
No server. Flows inside a battle (system code), on the map, and the authoring loop.

**A hit** (`combat/battle.gd`, `_apply_row`):
```
spec := GameplayEffectSpec(row.effect, context(unit → target), level)
row.apply_override(spec)                     row's damage types and toughness damage go on the spec (set-by-caller Data.Toughness)
if ability has Ability.Type.FollowUp: spec.inject_tag(Hit.FollowUp)
toughness_before := target.toughness
unit.asc.apply_effect_spec_to_target(spec, target.asc)
  └─ your ExecCalc:
       damage as today (BaseDmg × DefMultiplier)
       if the row has Damage.Type.<X> and target has Weakness.<X>:
            damage × target.weakness_dmg;  spec.inject_tag(Hit.Weakness)
            if target not State.Broken and target.max_toughness > 0:
                 toughness −= Data.Toughness                               (returned like hp: {"toughness": −t})
       crit roll (unchanged, one roll per hit) → × (100% + crit_dmg);  spec.inject_tag(Hit.Critical)
battle: toughness_before > 0 and toughness now 0  → BREAK (below);  spec gets Hit.Break
damage > 0 → target.last_hit_by = unit; _send_damage_events(unit, target, damage, row, spec)
     payload {source, target, amount, row, tags: row.tags, hit_tags}       (hit_tags NEW)
     Dealt/Taken; Dealt/Taken.<DamageType> (unchanged); Dealt/Taken.<Hit.X> for each hit tag, sorted (NEW)
```

**Break** (system rules, `combat/battle.gd` + `turn_manager.gd`, HSR behaviour):
```
target gains State.Broken (a GAS tag, so content can query it: "deal more to Broken enemies")
target's action is delayed by BREAK_DELAY (25% of its full action value; a battle rule constant)
breaker's action is marked "broke a unit" → One More after it (below)
target's next turn start: toughness := max_toughness, State.Broken removed, then it acts normally
while Broken: weakness hits still do weakness damage but no toughness damage
```
Any unit with `max_toughness > 0` and a weakness can be broken, so the rule is generic; in the demo only enemies
have weaknesses, so only enemies break.

**One More** (Persona-style, on top of the HSR break):
```
a party action ends (its rows, the triggers it queued, deaths, end check)
if that action broke ≥ 1 unit and the battle isn't over:
    the same actor takes an extra action immediately, before the turn queue moves on
    its action value is unchanged (the extra action is free); it can be any action it could normally take
    (attack, skill, ult, usable item; decided 2026-10-20)
    the extra action can break another unit → another One More (bounded: each unit breaks once until it recovers)
breaks caused by a follow-up or a triggered passive count for the unit that owns it, if it is a party member
    and alive, and are granted after its current action
enemies never get One More in the demo (no party weaknesses); the rule is the same for both sides
```
The extra action is a party decision, so it goes in the action log like any action, with `"extra": true`; replay
re-simulates the break and expects the extra action at that point (combat-replay-core: "the log schema leaves room for
extra turns"). `Event.Battle.OneMore` `{source: actor}` is sent to the actor when it starts, so items can react.

**A follow-up** (`_drain_triggers`): a triggered ability tagged `Ability.Type.FollowUp` sends `Event.Attack.FollowUp`
`{source, target, ability}` to its unit after it finishes. Queued like every trigger (FIFO, `TriggerQueue.MAX_DEPTH`),
never an action, never in the log.

**A death** (`_check_deaths`): Died to every living unit, payload gains `instigator`; then each living killer gets
`Event.Unit.Killed {source: killer, target: dead}`, in unit order. Killer = `last_hit_by`; a periodic tick's
instigator; dev `kill` → none.

**Armor on the map** (`RunController`):
```
pedestal / shop slot offers an item or a piece of armor (one pool, matched by tags, no repeats per run)
take / buy armor → always succeeds (no character choice, no slot needed) → state.armor (the run's armor inventory)
    log {take|buy, placement, kind: "equipment", id}
party panel: equip(character, piece from inventory) → into piece.slot; the piece that was there returns to inventory
             unequip(character, slot) → back to inventory
    log {equip, character, id} / {unequip, character, slot}; map only (refused during a battle); free
armor is never dropped, sold or put back on a pedestal; it stays in the inventory for the rest of the run
GiveEquipment (events) and loadouts: the piece is equipped directly, as today; a replaced piece goes to the inventory
```

**Authoring loop** (unchanged tools): create files → `validate` (0 errors) → script runner: `new <seed>`,
`give`/`equip <id> 1`, `room <room>`, `auto`, `state json` → assert the JSON → you play and tune → `design:`.

## 3. Data contracts
**C# contracts: none in this slice.** `Rpg.Contracts` has no run DTOs yet; battle snapshot v2 already carries
`Items`, `UseSlots` and `EquipmentIds` (equipped pieces only; the inventory never enters a battle) and is unchanged.
The action log gains an optional `extra` flag (3.2), which lives in the Godot-side log and the existing
`ActionLog` JSON; if the C# `ActionLog` record models entries strictly, it gains `bool? Extra = null` (golden
cross-check in `Rpg.Contracts.Tests`). No queue, topic or Redis key. `ReplayResult`, `MismatchReason` unchanged.

### 3.1 Hit tags, follow-ups, kills (system)
| Where | Change |
|---|---|
| `combat/battle.gd` | `HIT_TAG_PREFIX := "Hit."`; forwards every `Hit.<X>` spec tag (sorted, after damage-type events); `hit_tags` in the payload. `EVENT_ATTACK_FOLLOW_UP`, `EVENT_UNIT_KILLED`, `EVENT_ONE_MORE`. `last_hit_by` set per damaging hit, cleared on revive. |
| `combat/battle_ability.gd` | `FOLLOW_UP_TAG := &"Ability.Type.FollowUp"`, `is_follow_up()`. Still a triggered passive. |
| `combat/battle_unit.gd` | `last_hit_by` (not hashed; replay recomputes it). |
| `combat/execution_row.gd` | `toughness: int` (×100, designer units: "30"), written to the spec as set-by-caller `Data.Toughness`; the row's tags are on the spec so the ExecCalc sees damage types. |
| `game/tools/sync_tags.gd` | Checks the new system tags (3.4). |
| Recorder / `state json` | Battle log lists triggered activations `{unit, ability, event}`, each hit's `hit_tags`, breaks, recoveries and One More actions. |

First implementation step: check that GodotGAS hands the ExecCalc the same spec object the battle holds (so
`inject_tag` is visible). If it copies, the ExecCalc writes hit tags through `BattleContext` (a per-hit scratch on the
battle) instead; the events are the same.

### 3.2 Toughness, break, One More (system)
| Where | Change |
|---|---|
| `combat/battle.gd` | Break detection after each hit (toughness crossed to 0) → `State.Broken`, delay, `Hit.Break`, breaker marked. After each party action: One More if marked. At a Broken unit's turn start: refill toughness, remove `State.Broken`. Constant `BREAK_DELAY := 2500` (25.00%). |
| `combat/turn_manager.gd` | `delay(unit, percent)`: adds `percent` of the unit's full action value to its remaining action value (HSR action delay). `insert_extra(unit)`: the unit acts next without changing its action value. |
| Action log | Entry gains `"extra": true` for a One More action. The replay runner checks it: an extra action where none is due, or a missing one, is a 2002 rejection (`MismatchReason` `IllegalAction`, existing; no new reason). |
| State hash | Toughness is an attribute and `State.Broken` a tag, both already hashed. A pending One More at a checkpoint is hashed as `extra=<unit id>` **only when one is pending**, so every existing golden is unchanged (hash stays v1; spec combat-replay-core updated). |
| AI (enemy brains) | Unchanged; a Broken enemy simply acts later. |

### 3.3 Crit, weakness damage and toughness damage (your ExecCalc and assets)
Edit to `content/demo/exec_calcs/exec_calc_standard_damage.gd` (approved; shown as a diff):
```
  RawDmg = BaseDmg × DefMultiplier%                                   (unchanged)
+ weak: row has Damage.Type.<X> and target has Weakness.<X>
+       → RawDmg × target.weakness_dmg;  inject Hit.Weakness
+       → if target lacks State.Broken: toughness damage = Data.Toughness × (100% + source.toughness_dmg)
+ broken: target has State.Broken → RawDmg × (100% + source.broken_dmg)
  crit: rng.randi_range(0, 9999) < crit_rate → × (100% + crit_dmg)    (unchanged roll, same RNG use)
+       and inject Hit.Critical
  return {"hp": −damage, "toughness": −toughness_damage}
```
- **No change to the RNG sequence:** one roll per hit, so existing replays are identical. Weakness and toughness use
  no RNG.
- **`weakness_dmg`** (new attribute in the demo AttributeSet, default **150%**): set per enemy in its `stats` like
  any stat (designer types `150`; stored ×100). Because it is an attribute, a debuff can raise it ("Exposed: +30%
  weakness damage") or an elite variant can lower it.
- **`toughness_dmg`** (new attribute, default **0%**): the attacker's bonus on the toughness damage its hits deal
  (Shatter Hammer). **`broken_dmg`** (new attribute, default **0%**): the attacker's bonus damage against Broken
  targets (Predator's Fang). Both live on every unit, so items, armor and buffs raise them with ordinary modifiers.
- **`toughness` / `max_toughness`** already exist (default 300); set per enemy in its `stats`. Party characters get
  `max_toughness` 0 in the demo (never broken).
- **Weakness tags** `Weakness.Physical`, `Weakness.Ice`, `Weakness.Fire` (one per `Damage.Type.<X>`; a new damage
  type adds its own). They reach the ASC by every existing GAS path: definition `tags`, a loadout or variant
  `AbilitySet.tags`, an effect's `granted_tags` (a timed "weak to Fire" debuff).
- **Toughness damage** is per execution row (`toughness`) on each ability: values in 3.9 (existing abilities) and
  3.6 (usable items; a follow-up's row has none unless listed).

### 3.4 Tags and attribute (your `godot_gas/` and demo AttributeSet; approved)
`Hit.Critical`, `Hit.Weakness`, `Hit.Break`, `Hit.FollowUp`; `Weakness.Physical/Ice/Fire`; `State.Broken`;
`Ability.Type.FollowUp`; `Data.Toughness`; `Event.Attack.FollowUp`, `Event.Unit.Killed`, `Event.Battle.OneMore`;
`Event.Damage.Dealt.Critical/Weakness/Break/FollowUp`, `Event.Damage.Taken.Critical/Weakness/Break/FollowUp`;
`Equipment.Slot.Head/Body/Arms/Legs/Accessory`; `Status.Debuff.Burn`, `Status.Debuff.Exposed`,
`Status.Buff.AttackUp`; one `Ability.Passive.<Name>` / `Ability.Item.<Name>` per new ability (after the list review).
Added through the registry, then `game/tools/sync_tags.tscn` regenerates `gameplay_tags.gd`. Attribute
`weakness_dmg`, `toughness_dmg` and `broken_dmg` added to the demo AttributeSet (and the dashboard draft, so a
regeneration keeps them).

### 3.5 Armor (system + content)
**Slots are tags.** A slot is any child of `Equipment.Slot` (registry order): Weapon (exists), Head, Body, Arms,
Legs, Accessory. A new slot is one tag, no code. `RunController.equipment_slots()` lists them.

**`EquipmentDefinition` gains pickup fields** (`combat/equipment_definition.gd`): `description`, `mesh`, `tags`
(pools, rarity), `weight`, `price`. Existing Iron Sword: no pools by default, so never offered, as today.

| Where | Change |
|---|---|
| `RunState` | `armor: Array[StringName]` (the run's armor inventory, pickup order). In `canonical_lines()` only when non-empty, so existing run hashes are unchanged. Run snapshot/local save carry it. |
| `RoomPlacement` | `equipment: EquipmentDefinition` beside `item`. `item_query` matches items **and** equipment by tag: one weighted pool, stable order (kind, then id), no repeats per run (`seen` holds both). Pools change only when content tags equipment, so fixture goldens stay the same. |
| Pickup offer | `{placement, kind: item \| equipment, id, price}` |
| `take` / `buy` | Equipment → `state.armor`; no character choice, never refused for lack of a slot. |
| `RunController.equip(character, id)` / `unequip(character, slot)` | New run actions, map only, logged; a piece must be in the inventory to equip; the replaced or unequipped piece returns to the inventory. A dead character can be equipped (gear applies when revived). Refused during a battle, nothing logged. |
| `GiveEquipment`, loadouts | Equip directly (unchanged); a replaced piece goes to the inventory instead of being lost. |
| Validator | `slot` must be a child of `Equipment.Slot` (error); a placement with both `item` and `equipment` (error); pickup fields as for items. |
| Console | `equip <equipment> [slot]` (existing cheat) unchanged; new play commands `wear <equipment> <slot>` and `unwear <slot> <equipment slot>` (the party panel's buttons, Claude parity); `spawn item`/`spawn pool` accept equipment; `items [tag]` lists items and equipment. |

**Server-authority spec follow-up (text only):** `ItemOffer` gains `ItemKind Kind` (`Item`, `Equipment`); new action
types `equip` and `unequip` (out-of-battle, async, server-verified like `field`); run snapshots carry the armor
inventory.

### 3.6 Items (content, `content/demo/items/`)
Existing 8 unchanged: Whetstone, War Banner, Oath Stone, Frost-Ember Charm, Potion, Phoenix Feather, Satchel, Stale
Bread. Ids are `demo.item.<id>`. Pools: **T** = `Pool.Treasure`, **S** = `Pool.Shop`, **B** = `Pool.Boss`; rarity
**C**/**R** = `Item.Rarity.Common/Rare`. Values are designer units; events are shortened (`Damage.Dealt.Critical` =
`Event.Damage.Dealt.Critical`). Each item also gets a one-line `description` drafted by Claude.

#### Stat (the holder)
| # | Name | id | Effect | Value | Pools · rarity · price | Notes |
|---|---|---|---|---|---|---|
| 1 | Iron Ring | `iron_ring` | + DEF | +40 | T S · C · 5 | |
| 2 | Swift Charm | `swift_charm` | + SPD | +12 | T S · C · 6 | |
| 3 | Lucky Coin | `lucky_coin` | + Crit Rate | +10% | T · C · 5 | |
| 4 | Glass Lens | `glass_lens` | + Crit DMG, − Max HP | +40% / −150 | T · R · 7 | trade-off |
| 5 | Mana Crystal | `mana_crystal` | + Max MP | +40 | T S · C · 5 | |
| 6 | Heart Locket | `heart_locket` | + Max HP | +250 | T S · C · 6 | |

#### Party-wide
| # | Name | id | Effect | Value | Pools · rarity · price | Notes |
|---|---|---|---|---|---|---|
| 7 | War Drum | `war_drum` | party + SPD | +6 | T B · R · 9 | |
| 8 | Guardian Totem | `guardian_totem` | party + DEF | +25 | B · R · 9 | |

#### Triggered
| # | Name | id | Trigger → effect | Value | Pools · rarity · price | Notes |
|---|---|---|---|---|---|---|
| 9 | Thorn Mail | `thorn_mail` | `Damage.Taken` → Physical hit back at the attacker | 60 flat | T · R · 8 | |
| 10 | Vampire Fang | `vampire_fang` | `Damage.Dealt` → heal self | 15 | T · R · 8 | |
| 11 | Cinder Glove | `cinder_glove` | `Damage.Dealt.Fire` → Burn the target (Fire damage each turn) | 40 / turn, 2 turns | T · R · 7 | |
| 12 | Battle Horn | `battle_horn` | `Battle.Start` → + ult charge | +30 | T S · C · 6 | |
| 13 | Hourglass | `hourglass` | `Turn.Start` → heal self, % of Max HP | 5% | T · R · 8 | |
| 14 | Frost Needle | `frost_needle` | `Damage.Dealt.Physical` → Ice hit on the same target | 30 flat | T · C · 6 | chains into Frost-Ember Charm |
| 15 | Bounty Mark | `bounty_mark` | `Unit.Killed` → + ult charge, heal self | +20 / 50 | T B · R · 9 | |

#### Crit, weakness, break, follow-up, One More
| # | Name | id | Trigger → effect | Value | Pools · rarity · price | Notes |
|---|---|---|---|---|---|---|
| 16 | Sharp Eye | `sharp_eye` | `Damage.Dealt.Critical` → + ult charge | +10 | T · C · 6 | |
| 17 | Executioner's Seal | `executioners_seal` | `Damage.Dealt.Critical` → follow-up, Physical, % ATK | 50% ATK | T B · R · 10 | |
| 18 | Hunter's Mark | `hunters_mark` | `Damage.Dealt.Weakness` → follow-up, Physical, % ATK | 40% ATK | T · R · 9 | |
| 19 | Scholar's Tome | `scholars_tome` | `Damage.Dealt.Weakness` → + ult charge, + MP | +15 / 5 | T S · C · 6 | |
| 20 | Momentum Charm | `momentum_charm` | `Attack.FollowUp` → + ult charge | +10 | T · C · 6 | |
| 21 | Glass Heart | `glass_heart` | `Damage.Taken.Critical` → heal self | 80 | T · C · 5 | |
| 22 | Shatter Hammer | `shatter_hammer` | holder's hits deal + toughness damage | +50% toughness dmg | T · R · 8 | `toughness_dmg` attribute |
| 23 | Breaker's Oath | `breakers_oath` | `Damage.Dealt.Break` → + ult charge, + ATK for 2 turns | +20 / +15% | T B · R · 9 | |
| 24 | Encore Ribbon | `encore_ribbon` | `Battle.OneMore` → heal self | 60 | T · C · 6 | |
| 25 | Predator's Fang | `predators_fang` | holder deals more damage to Broken enemies | +25% | T · R · 9 | `broken_dmg` attribute |

#### Usable
| # | Name | id | Use | Value | Mode | Pools · rarity · price | Notes |
|---|---|---|---|---|---|---|---|
| 26 | Fire Bomb | `fire_bomb` | blast, Fire damage, toughness 60 | 300 flat | consumable | S · C · 4 | breaks Slimes |
| 27 | Frost Bomb | `frost_bomb` | blast, Ice damage, toughness 60 | 250 flat | consumable | S · C · 4 | breaks Bats |
| 28 | Ether | `ether` | one ally, + MP | +60 | cooldown 3 | S · C · 5 | |
| 29 | Rally Horn | `rally_horn` | all allies, + ATK 2 turns | +20% | cooldown 2 | T S · R · 8 | |
| 30 | Smelling Salts | `smelling_salts` | revive one ally | 20% HP | cooldown 4 | S · R · 9 | weaker, rechargeable Phoenix Feather |
| 31 | Analyzer Lens | `analyzer_lens` | one enemy becomes weak to Physical for 2 turns ("Exposed") | 2 turns | cooldown 2 | T S · R · 8 | |

#### Run hooks
| # | Name | id | Hook → effect | Value | Pools · rarity · price | Notes |
|---|---|---|---|---|---|---|
| 32 | Coin Purse | `coin_purse` | room cleared → + coins | +1 | T S · C · 5 | |
| 33 | Golden Idol | `golden_idol` | on pickup → + coins | +10 | T · C · 3 | |
| 34 | Hearty Stew | `hearty_stew` | floor start → heal living party, % Max HP | 30% | T S · C · 6 | |
| 35 | Mystery Box | `mystery_box` | on pickup → a random Treasure item, then the box is gone | – | S · R · 7 | |

### 3.7 Armor (content, `content/demo/equipment/`)
Ids are `demo.equipment.<id>`. Stats and triggers through the piece's `AbilitySet`, like the Iron Sword.

| Slot | Name | id | Grants | Value | Pools · rarity · price | Notes |
|---|---|---|---|---|---|---|
| Head | Leather Cap | `leather_cap` | + DEF, + Max HP | +20 / +100 | T S · C · 5 | |
| Head | Seer's Circlet | `seers_circlet` | + Crit Rate, + Max MP | +5% / +20 | T S · R · 8 | |
| Body | Chain Vest | `chain_vest` | + DEF | +60 | T S · C · 6 | |
| Body | Mage Robe | `mage_robe` | + Max MP, + ATK | +50 / +5% | T S · C · 6 | |
| Arms | Bracers | `bracers` | + ATK | +8% | T S · C · 6 | |
| Arms | Hunter's Gloves | `hunters_gloves` | `Damage.Dealt.Weakness` → + ult charge | +10 | T · R · 8 | |
| Legs | Swift Boots | `swift_boots` | + SPD | +10 | T S · C · 6 | |
| Legs | Greaves | `greaves` | + DEF, − SPD | +50 / −4 | T S · C · 5 | trade-off |
| Accessory | Duelist's Band | `duelists_band` | `Damage.Dealt.Critical` → follow-up, Physical | 30% ATK | T B · R · 10 | |
| Accessory | Ember Pendant | `ember_pendant` | `Damage.Dealt.Fire` → target becomes weak to Fire for 1 turn | 1 turn | T B · R · 10 | combo piece |

### 3.8 Demo enemies (edits to existing files in `content/demo/enemies/`, `variants/`)
Weakness = `Weakness.<Type>` in the definition's `tags` (the elite variant: its `AbilitySet.tags`); max toughness and
weakness damage taken (`weakness_dmg`) in `stats`; `toughness` starts at max.

| Enemy | Weakness | Max toughness | Weakness damage taken | Notes |
|---|---|---|---|---|
| Slime | Fire | 60 | 150% | |
| Bat | Ice | 30 | 175% | fragile, easy One More |
| Golem | Physical | 120 | 125% | |
| Elite variant (`variants/elite.tres`) | adds Ice to whatever it's on (via the variant's tags) | +100% | – | shows a second weakness without a new enemy |

Party characters: max toughness 0 (never broken).

### 3.9 Toughness damage per ability (edits to existing files in `content/demo/abilities/`)
Set on each execution row's `toughness`.

| Ability | Who | Toughness damage | Notes |
|---|---|---|---|
| Strike | basic attack | 30 | |
| Ice Blast | skill | 60 | |
| Cleave | Warrior ult | 90 per target | |
| Frost-Ember (charm passive) | triggered | 15 | |
| Heal, Sanctuary, Oath, Ult charge | support / passive | 0 | |
| Enemy abilities (Bite, Crush) | enemies | 0 | party has no toughness |

### 3.10 UI (your `presentation/demo/`; approved)
| Panel | Change |
|---|---|
| `battle_panel` (+ `unit_view` if the bar lives on the unit) | Toughness bar under each enemy's HP (hidden when `max_toughness` is 0); weakness icons per enemy (one per `Weakness.<X>` tag, read from the ASC so timed weaknesses appear and vanish); "BROKEN" marker while `State.Broken`; "ONE MORE!" banner when an extra action starts; crit/weak/break hit text. Reads `combat/` signals and GAS only, never changes state. |
| `pickup_panel` | Item and armor description tooltip; armor shows its slot; taking armor doesn't ask for a character. |
| `party_panel` | Per character, the six equipment slots (empty or filled, with tooltip); an armor inventory list; equip (pick a piece, pick a slot-compatible character) and unequip buttons, map only. |

## 4. Failure modes
Server failure scenarios (root `CLAUDE.md` 1–7): **none apply** (no server, queue, broker or cache). What this slice
protects is **replay determinism**, which scenario 5 (tampered log → 2002) relies on later. A replay mismatch is a
verdict (`Rejected`, `errorCode` 2002, a `MismatchReason`), never an HTTP status; no new mismatch reason.

| Failure | Behaviour | Test |
|---|---|---|
| New rules change existing replays | They can't: fixtures have no weaknesses and no row toughness, the crit roll is unchanged, `extra=` is hashed only when pending | every existing golden passes un-re-recorded |
| Tampered log: One More claimed without a break, or a due One More skipped | 2002 (`IllegalAction`) | `test_one_more_tamper` |
| Blast breaks three enemies in one action | One extra action, not three; all three Broken and delayed | `test_break_blast_one_more` |
| Extra action breaks another enemy | Another One More; bounded because a Broken unit can't break again until it recovers | `test_one_more_chain` |
| Break by a follow-up or passive | One More for its party owner after the current action; none for a dead owner | `test_break_by_follow_up` |
| Breaking hit also kills / ends the battle | Death and end checks first; no One More after victory | `test_break_kill_and_victory` |
| Broken unit's turn | Toughness refilled, `State.Broken` removed, then it acts; delay applied exactly once | `test_break_delay_and_recovery` |
| Hit tag order differs between client and verifier | Sorted, after damage-type events | `test_hit_tag_events` |
| Follow-up chains | `TriggerQueue.MAX_DEPTH` cut, content warning, battle continues | `test_follow_up_chain_depth` |
| Kill edge cases (blast, killer dies too, DoT, dev kill) | Died per dead unit, then Killed per living killer in unit order | `test_unit_killed_event`, `test_unit_killed_by_dot` |
| Equip during a battle, equip a piece not in inventory, wrong slot | Refused, nothing logged | `test_armor_inventory` |
| Armor in pools with items | Stable order, weighted, no repeats across kinds | `test_equipment_pickups` |
| ExecCalc spec tags invisible to the battle | Caught by `test_hit_tag_events` first day; fallback 3.1 | `test_hit_tag_events` |
| Bad slot tag, item+equipment placement, missing description, unknown trigger tag | Validator error / error / warning / warning | `test_content_validator` + broken fixtures |
| Replay of a demo battle with breaks, One More, new items and armor | Verified | `test_demo_items_replay` |

## 5. Observability
N/A: client-only slice, no service runs. (From slice 4b, pickups, equips and One More counts come from the event log
into Postgres projections, never Prometheus labels.) Local signals: validator report, script-runner JSON.

## 6. Test plan
System tests use `tests/fixtures/` only (a fixture ExecCalc mirrors the crit/weakness/toughness logic and a fixture
AttributeSet gets the three new attributes), except demo tests that already read `content/demo/`.

**System (fixtures)**
- Hit tags: `test_hit_tag_events`, `test_weakness_from_effect` (definition tag, `AbilitySet` tag, timed effect),
  `test_weakness_dmg_attribute` (per-unit value and a modifier on it), `test_toughness_and_broken_dmg` (both
  bonuses, and that they do nothing at their 0% default).
- Break and One More: `test_break_delay_and_recovery`, `test_break_blast_one_more`, `test_one_more_chain`,
  `test_break_by_follow_up`, `test_break_kill_and_victory`, `test_one_more_tamper`, `test_turn_manager_delay_insert`.
- Follow-ups and kills: `test_follow_up_attack`, `test_follow_up_chain_depth`, `test_unit_killed_event`,
  `test_unit_killed_by_dot`.
- Armor: `test_equipment_slots`, `test_equipment_pickups`, `test_armor_inventory` (pickup → inventory, equip,
  swap returns the old piece, unequip, refusals, logged, run hash unchanged without armor, replay of the run log).
- `test_items_command`, `test_wear_commands`; validator broken fixtures (`equipment_bad_slot.tres`,
  `placement_item_and_equipment.tres`, `item_no_description.tres`, `ability_bad_trigger.tres`).
- **Goldens:** no existing golden changes. New combat goldens `golden/combat/hit_tags.json`, `break_one_more.json`,
  `follow_up.json`, `unit_killed.json`; new run golden `golden/game/armor_run.json`. If `ActionLog` gains `Extra`,
  `Rpg.Contracts.Tests` cross-checks `break_one_more.json` like the other battle goldens.

**Demo content (`tests/game/test_demo_items.gd`, reads `content/demo/`)**
- One case per new item and armor piece through the script runner: `give`/`equip`, a sandbox room, assert the effect
  from the state JSON. Checks **that** it happens and which way, never the tuned number.
- `test_demo_weakness_break`: Fire on the Slime → `Hit.Weakness`, more damage than Physical, toughness drops, break,
  One More, recovery.
- `test_demo_items_replay`: a recorded battle with breaks, One More, new items and armor replays → `Verified`.
- `test_content_valid` (existing): 0 errors.

`dotnet build` / `dotnet test` green. Both suites pass before the slice counts as done. Headless Godot always with
`--quit-after` and a timeout.

## 7. Implementation order
This slice is now large; it stays one slice (your call to split it), built in this order with a `feat:` commit per
system step:
A. Hit tags, follow-ups, kills (fixtures + tests). Check the spec-object question first.
B. Toughness, break, delay, One More, replay/log/hash (fixtures + tests).
C. Armor: slots, pickup fields, pools, inventory, equip/unequip, validator, console (fixtures + tests).
D. Your files (approved): tags + `sync_tags`, the three attributes, ExecCalc edit, UI panels.
E. Content from 3.6–3.9: items, armor, enemy weaknesses/toughness/`weakness_dmg`, ability toughness; every
   value listed; `validate` 0 errors; demo tests. Left uncommitted for you to playtest; `design:` when you say.
F. `server-authority` text (`ItemKind`, `equip`/`unequip`), `combat-replay-core` (break, One More, `extra`, hash
   line), `combat-design` (toughness now designed), `/sync-spec item-pass`, roadmap ✅, root `CLAUDE.md` table.
   Commit `spec:`.

## 8. Later
- Resist / null / repel / drain via `Resist.<Type>` and `Hit.Resisted` (no battle code needed).
- HSR break effects per damage type (burn, freeze…) and break damage; buildable as content on `Event.Damage.Dealt.Break`.
- Party toughness (enemies breaking the party, and enemy One More): already supported by the generic rule; needs content.
- Follow-ups that copy the triggering hit's damage type; party-wide follow-up events.
- Reveal-map and shop-discount items; armor set bonuses; selling armor.

## 9. Decisions
None open. Decided 2026-10-20: the item, armor, enemy and ability lists (3.6–3.9) as reviewed; Shatter Hammer and Predator's Fang stay (attributes `toughness_dmg`, `broken_dmg`); a One More
can be any action; out-of-turn ults are slice 1c4.
