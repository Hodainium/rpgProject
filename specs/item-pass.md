# Spec: item-pass (slice 1c2)

Status: ✅ Implemented, synced with the code (2026-10-20) · Roadmap: slice 1c2 · Date: 2026-10-20
Design intent: `specs/design/game-design.md` section 3 ("How items work in combat"), `specs/design/combat-design.md`
(damage formula, toughness). Item mechanics: `specs/game-skeleton.md` ("Items", 3.4 triggers). Turn order and replay:
`specs/combat-replay-core.md` ("Turn order", whose log schema already leaves room for extra turns). Tools:
`specs/dev-tools.md` (`give`, `equip`, `spawn item`, sandbox, script runner, validator).
The item, armor, enemy and ability lists in 3.6–3.9 come from the user's reviewed list (2026-10-20). Their numbers
now live in the content files (pointers in each section), which are the source of truth.

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
| Follow-ups | A triggered ability with `Ability.Type.FollowUp` in its `asset_tags` is a follow-up attack: its hits carry `Hit.FollowUp`; the battle sends `Event.Attack.FollowUp`; a follow-up never fires from a follow-up's hit | system |
| Kills | `Event.Unit.Killed` to the unit that landed the killing hit | system |
| Armor | Head, Body, Arms, Legs, Accessory beside Weapon. Armor found in a run always goes into the party's **armor inventory**; it is equipped and unequipped from there on the map, and never dropped or put back | system (`game/`) |
| Descriptions | `description` on items and equipment | system |
| UI | Toughness bar, weakness list, Broken and One More indicators, tooltips, equipment slots and armor inventory (text placeholders) | your `presentation/` (edits approved) |
| Tags, attributes | New tags in the registry; `weakness_dmg`, `toughness_dmg`, `broken_dmg` in the demo AttributeSet | your `godot_gas/` and `content/` (approved) |
| Content | 35 items, 10 armor pieces, weaknesses, toughness and weakness damage per demo enemy, toughness damage per ability; new files made by `game/tools/build_item_pass.tscn` | yours (list reviewed, 3.6–3.9) |

**Approvals given (2026-10-20):** Claude edits your ExecCalc, the tag registry, the UI panels in `presentation/demo/`,
and adds the `weakness_dmg`, `toughness_dmg` and `broken_dmg` attributes. Each edit is still shown as a diff when
made, and the rest of `client-godot/CLAUDE.md` section 0 applies (minimal edits, no other tweaks). Changes to the
existing demo enemies and abilities (weaknesses, toughness values) follow 3.8 and 3.9. The files are the source of
truth for every number.

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
row.apply_override(spec)                     set-by-caller Data.Toughness; the row's tags become spec dynamic tags
if ability.is_follow_up(): spec.inject_tag(Hit.FollowUp)
toughness_before := target.toughness
unit.asc.apply_effect_spec_to_target(spec, target.asc)
  └─ your ExecCalc (GodotGAS passes this same spec object, so its inject_tag is visible to the battle):
       damage as today (BaseDmg × DefMultiplier)
       if the row has Damage.Type.<X> and target has Weakness.<X>:
            damage × target.weakness_dmg;  spec.inject_tag(weakness_hit_tag = Hit.Weakness)
            if target not State.Broken and target.max_toughness > 0:
                 toughness −= Data.Toughness                               (returned like hp: {"toughness": −t})
       crit roll (unchanged, one roll per hit) → × (100% + crit_dmg);  spec.inject_tag(critical_hit_tag = Hit.Critical)
battle: toughness_before > 0, toughness now 0, target still alive, not field mode → BREAK (below); spec gets Hit.Break
any HP drop (attribute_changed, hits and DoT ticks) → target.last_hit_by = spec instigator (self-inflicted drops credit nobody)
damage > 0 → _send_damage_events(unit, target, damage, row, spec)
     payload {source, target, amount, row, tags: row.tags, hit_tags}       (hit_tags NEW)
     Dealt/Taken; Dealt/Taken.<DamageType> (unchanged); Dealt/Taken.<Hit.X> for each hit tag, sorted (NEW)
     Battle signal damage_dealt(source, target, amount, hit_tags) for the UI and the battle log
```
The ExecCalc's hit tag names are exported `gas::tag` fields (`weakness_hit_tag`, `critical_hit_tag`), so
`sync_tags` registers them like any other tag in content.

**Break** (system rules, `combat/battle.gd` + `turn_manager.gd`, HSR behaviour):
```
only if the target survives the hit (a killing blow is a kill, not a break)
target gains State.Broken (a GAS tag, so content can query it: "deal more to Broken enemies")
target's action is delayed by BREAK_DELAY (25% of its full action value; a battle rule constant)
breaker is queued for a One More (below); signal unit_broken
target's next turn start: toughness := max_toughness (an instant set-by-caller effect), State.Broken removed,
    signal unit_recovered, then it acts normally
while Broken: weakness hits still do weakness damage but no toughness damage
a unit laid down (death) loses State.Broken
```
Any unit with `max_toughness > 0` and a weakness can be broken, so the rule is generic; in the demo only enemies
have weaknesses, so only enemies break. Toughness starts full **after bonuses** (`BattleUnit._apply_carry` sets
`toughness := max_toughness`), so an elite's +100% max toughness counts.

**One More** (Persona-style, on top of the HSR break):
```
a party action ends (its rows, the triggers it queued, deaths, end check)
if that action broke ≥ 1 unit and the battle isn't over:
    the same actor takes an extra action immediately, before the turn queue moves on
    its action value is unchanged (the extra action is free); it can be any action it could normally take
    (attack, skill, ult, usable item; decided 2026-10-20)
    the extra action can break another unit → another One More (bounded: each unit breaks once until it recovers)
breaks caused by a follow-up or a triggered passive count for the unit that owns it, and are granted after the
    current action; a queued unit that has died by then is skipped
the rule is generic for both sides; enemies never get One More in the demo (no party weaknesses)
```
Built as `Battle.one_more_queue`, run at the top of the turn loop (`_extra_action()`), not inside the turn manager:
a One More has its own turn number, no turn-start or turn-end ticks and no action-value change.
`CombatASC.begin_extra_action` / `end_extra_action` keep the self-buff countdown rule (a buff the actor gives itself
doesn't lose a turn to the extra action). The extra action is a party decision, so it goes in the action log like any
action, with `"extra": true`; replay re-simulates the break and expects the extra action at that point.
`Event.Battle.OneMore` `{source: actor}` is sent to the actor when it starts (signal `one_more_started`), so items can
react.

**A follow-up** (`_drain_triggers`): a triggered ability with `Ability.Type.FollowUp` in `BattleAbility.asset_tags`
(UE's AbilityTags; GodotGAS has none) sends `Event.Attack.FollowUp` `{source, target, ability}` to its unit after it
finishes. Queued like every trigger (FIFO, `TriggerQueue.MAX_DEPTH`), never an action, never in the log. HSR rule: a
follow-up never fires from an event whose `hit_tags` contain `Hit.FollowUp`, so two follow-up items can't ping-pong;
other trigger chains still stop at the depth cap. Every activation emits the Battle signal `trigger_activated`.

**A death** (`_check_deaths`): Died to every living unit, payload gains `instigator`; then each living killer gets
`Event.Unit.Killed {source: killer, target: dead}`, in unit order. Killer = `last_hit_by` (any HP drop, including a
periodic tick, credits its instigator); a unit never kills itself; dev `kill` → none; revive clears `last_hit_by`.

**Armor on the map** (`RunController`):
```
pedestal / shop slot offers an item or a piece of armor (FloorGenerator.pick_pickup: one pool, matched by tags,
    no repeats per run; equipment with no pool tags is never offered)
take / buy armor → always succeeds (no character choice, no slot needed) → state.armor (the run's armor inventory)
    log {take|buy, placement, kind: "equipment"} (no slot)
party panel / console: equip(slot, id) → into piece.slot; the piece that was there returns to inventory
                       unequip(slot, equipment_slot) → back to inventory
    log {"type":"equip","floor","slot","equipment"} / {"type":"unequip","floor","slot","equipment_slot"};
    map only (refused during a battle); free
armor is never dropped, sold or put back on a pedestal; it stays in the inventory for the rest of the run
GiveEquipment (events) and loadouts: the piece is equipped directly, as today; a replaced piece goes to the inventory
GiveItem stays items-only (pick_item); pedestals and the console's spawn pool use pick_pickup
```
**Mystery Box:** its pickup hook gives a random Treasure item to the first member who can hold it, then an empty
`RemoveItem` inside an item's own hook removes that item (`RunController.hook_item`).

**Authoring loop** (unchanged tools): create files → `validate` (0 errors) → script runner: `new <seed>`,
`give`/`equip <id> 1`, `room <room>`, `spawn <encounter>`, `state json` → read `lastBattle` in the JSON → you play
and tune → `design:`. `game/dev/scripts/item_pass.txt` is the smoke script for the whole set.

## 3. Data contracts
**C# contracts: none in this slice.** `Rpg.Contracts` has no run DTOs yet; battle snapshot v2 already carries
`Items`, `UseSlots` and `EquipmentIds` (equipped pieces only; the inventory never enters a battle) and is unchanged.
The action log gains an optional `extra` flag (3.2): `ActionEntry` gains `bool? Extra = null`, written only when set
(`JsonIgnore(WhenWritingNull)`), so existing logs serialize byte-identically (`ActionEntry_WritesExtraOnlyForOneMore`,
and the golden cross-check reads `break-seed-11`). No queue, topic or Redis key. `ReplayResult`, `MismatchReason`
unchanged.

### 3.1 Hit tags, follow-ups, kills (system)
| Where | Change |
|---|---|
| `combat/battle.gd` | `HIT_TAG_PREFIX := "Hit."`; forwards every `Hit.<X>` spec tag (sorted, after damage-type events); `hit_tags` in the payload; static `hit_tags_of(spec)`. `EVENT_ATTACK_FOLLOW_UP`, `EVENT_UNIT_KILLED`, `EVENT_ONE_MORE`. `last_hit_by` set in `_on_attribute_changed` from the spec instigator, cleared on revive. Died payload gains `instigator`. Signals `damage_dealt`, `trigger_activated`, `unit_broken`, `unit_recovered`, `one_more_started` (read-only, for UI and the battle log). |
| `combat/battle_ability.gd` | `asset_tags` export (UE AbilityTags), `FOLLOW_UP_TAG := &"Ability.Type.FollowUp"`, `is_follow_up()`. Still a triggered passive. |
| `combat/battle_unit.gd` | `last_hit_by` (not hashed; replay recomputes it). `_apply_carry` fills toughness to max after bonuses. |
| `combat/execution_row.gd` | `toughness` (designer units: "30"; stored `toughness_x100`), written to the spec as set-by-caller `Data.Toughness`; the row's tags are injected as spec dynamic tags so the ExecCalc sees damage types. |
| `game/tools/sync_tags.gd` | Checks the new system tags (3.4). |
| `RunController.battle_log` / `state json` | The last battle's hits with `hit_tags`, triggered activations `{unit, ability, event}`, breaks, recoveries and One More actions, reported as `lastBattle`; the report also gains `armor` and per-member `gear`. |

GodotGAS hands the ExecCalc the same spec object the battle holds, so `inject_tag` is visible to the battle; no
`BattleContext` fallback was needed.

### 3.2 Toughness, break, One More (system)
| Where | Change |
|---|---|
| `combat/battle.gd` | Break detection after each hit (toughness crossed to 0, target alive) → `State.Broken`, delay, `Hit.Break`, breaker queued in `one_more_queue`. The turn loop runs the queue first (`_extra_action()`). At a Broken unit's turn start: refill toughness, remove `State.Broken`. Constant `BREAK_DELAY := 2500` (25.00%). |
| `combat/turn_manager.gd` | `delay(unit, percent)`: adds `percent` of the unit's full action value to its remaining action value (HSR action delay). No `insert_extra`: extra actions bypass the turn manager. |
| `combat/combat_asc.gd` | `begin_extra_action()` / `end_extra_action()`. |
| Action log | Entry gains `"extra": true` for a One More action (`ActionRecorder.entry(..., extra)`). The replay runner checks it: an extra action where none is due, or a missing one, is a 2002 rejection with `MismatchReason` `TurnMismatch` (existing; no new reason). |
| State hash | Toughness is an attribute and `State.Broken` a tag, both already hashed. Owed One Mores at a checkpoint are hashed as `extra=<unit ids, comma-separated>` **only while the queue is non-empty**, so every existing golden is unchanged (hash stays v1). |
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
- **`weakness_dmg`** (new attribute in the demo AttributeSet; default in `godot_gas/attributes_draft.cfg`): set per
  enemy in its `stats` like any stat. Because it is an attribute, a debuff can raise it ("Exposed") or an elite
  variant can lower it.
- **`toughness_dmg`** (new attribute): the attacker's bonus on the toughness damage its hits deal (Shatter Hammer).
  **`broken_dmg`** (new attribute): the attacker's bonus damage against Broken targets (Predator's Fang). Both default
  to 0% and live on every unit, so items, armor and buffs raise them with ordinary modifiers.
- **`toughness` / `max_toughness`** already exist; set per enemy in its `stats`; `toughness` starts at max after
  bonuses (3.2). Party characters get `max_toughness` 0 in the demo (never broken).
- **Weakness tags** `Weakness.Physical`, `Weakness.Ice`, `Weakness.Fire` (one per `Damage.Type.<X>`; a new damage
  type adds its own). They reach the ASC by every existing GAS path: definition `tags`, a loadout or variant
  `AbilitySet.tags`, an effect's `granted_tags` (a timed "weak to Fire" debuff).
- **Toughness damage** is per execution row (`toughness`) on each ability: see 3.9 (existing abilities) and the
  usable items' abilities (a follow-up's row has none unless set).
- **Percent restores** (Hourglass, Hearty Stew, Smelling Salts) use a second content ExecCalc,
  `content/demo/exec_calcs/exec_calc_percent_of_max.gd`. Burn is a turn-based DoT that runs the damage ExecCalc.
  Exposed, Burn and the ATK buffs also grant their `Status.*` tags.

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
**Slots are tags, listed by the run.** `RunStructure.equipment_slots` lists the run's slot tags in display order
(the demo's `one_floor.tres`: Weapon, Head, Body, Arms, Legs, Accessory), so system tests don't depend on the
registry. A new slot is one tag plus one list entry, no code. `RunController.equipment_slots()` returns the list, or
the slots in use when the run has none.

**`EquipmentDefinition` gains pickup fields** (`combat/equipment_definition.gd`): `description`, `mesh`, `tags`
(pools, rarity), `weight`, `price`. Existing Iron Sword: no pools by default, so never offered, as today.

| Where | Change |
|---|---|
| `RunState` | `armor: Array[StringName]` (the run's armor inventory, pickup order), `held_equipment()`. In `canonical_lines()` as `armor=` only when non-empty, so existing run hashes are unchanged. Run snapshot/local save carry it (not built: no local save until slice 2b). |
| `RoomPlacement` | `equipment: EquipmentDefinition` beside `item`. `FloorGenerator.pick_pickup()` matches items **and** equipment by tag: one weighted pool, stable order (items, then equipment, by id), no repeats per run (held equipment counts as seen). Pools change only when content tags equipment, so fixture goldens stay the same. |
| Pickup offer | `{placement, item: <id>, price, taken}` as today, plus `kind: "equipment"` on armor only, so item pickups, hashes and goldens are unchanged. |
| `take` / `buy` | Equipment → `state.armor`; no character choice, never refused for lack of a slot. |
| `RunController.equip(slot, id)` / `unequip(slot, equipment_slot)` | New run actions, map only, logged (3.5 flow); a piece must be in the inventory to equip; the replaced or unequipped piece returns to the inventory. Any member can wear any slot; a dead character can be equipped (gear applies when revived). Refused during a battle, nothing logged. |
| `GiveEquipment`, loadouts | Equip directly (unchanged); a replaced piece goes to the inventory instead of being lost. |
| Validator | `bad_equipment` (no slot) and `bad_equipment_slot` (slot in no run structure's `equipment_slots`) errors; `placement_both` error (a placement with both `item` and `equipment`); `no_description` warning (items tagged `Dev` skipped); `trigger_unregistered` warning for a trigger in a battle event family the battle never sends. Equipment counts in pool checks. |
| Console | `equip <equipment> [slot]` (existing cheat) unchanged; new play commands `wear <equipment> <slot>` and `unwear <slot> <equipment slot>` (the party panel's buttons, Claude parity); `spawn` accepts equipment ids and pools; `items [tag]` lists items and equipment. |

**Server-authority spec follow-up (text only):** `ItemOffer` gains `ItemKind Kind` (`Item`, `Equipment`); new action
types `equip` and `unequip` (out-of-battle, async, server-verified like `field`); run snapshots carry the armor
inventory.

### 3.6 Items (content, `content/demo/items/`)
Existing 8 unchanged: Whetstone, War Banner, Oath Stone, Frost-Ember Charm, Potion, Phoenix Feather, Satchel, Stale
Bread. Ids are `demo.item.<id>`; each lives in `content/demo/items/<id>.tres`, its ability (if any) in
`content/demo/abilities/<id>.tscn`, its effects in `content/demo/effects/`. **Values, prices and descriptions are in
those files** (the reviewed list's numbers were the starting values). Pools: **T** = `Pool.Treasure`, **S** =
`Pool.Shop`, **B** = `Pool.Boss`; rarity **C**/**R** = `Item.Rarity.Common/Rare`. Events are shortened
(`Damage.Dealt.Critical` = `Event.Damage.Dealt.Critical`).

#### Stat (the holder)
| # | Name | id | Effect | Pools · rarity | Notes |
|---|---|---|---|---|---|
| 1 | Iron Ring | `iron_ring` | + DEF | T S · C | |
| 2 | Swift Charm | `swift_charm` | + SPD | T S · C | |
| 3 | Lucky Coin | `lucky_coin` | + Crit Rate | T · C | |
| 4 | Glass Lens | `glass_lens` | + Crit DMG, − Max HP | T · R | trade-off |
| 5 | Mana Crystal | `mana_crystal` | + Max MP | T S · C | |
| 6 | Heart Locket | `heart_locket` | + Max HP | T S · C | |

#### Party-wide
| # | Name | id | Effect | Pools · rarity | Notes |
|---|---|---|---|---|---|
| 7 | War Drum | `war_drum` | party + SPD | T B · R | |
| 8 | Guardian Totem | `guardian_totem` | party + DEF | B · R | |

#### Triggered
| # | Name | id | Trigger → effect | Pools · rarity | Notes |
|---|---|---|---|---|---|
| 9 | Thorn Mail | `thorn_mail` | `Damage.Taken` → flat Physical hit back at the attacker | T · R | |
| 10 | Vampire Fang | `vampire_fang` | `Damage.Dealt` → heal self | T · R | |
| 11 | Cinder Glove | `cinder_glove` | `Damage.Dealt.Fire` → Burn the target (Fire damage each turn, a few turns) | T · R | |
| 12 | Battle Horn | `battle_horn` | `Battle.Start` → + ult charge | T S · C | |
| 13 | Hourglass | `hourglass` | `Turn.Start` → heal self, % of Max HP | T · R | percent ExecCalc |
| 14 | Frost Needle | `frost_needle` | `Damage.Dealt.Physical` → flat Ice hit on the same target | T · C | chains into Frost-Ember Charm |
| 15 | Bounty Mark | `bounty_mark` | `Unit.Killed` → + ult charge, heal self | T B · R | |

#### Crit, weakness, break, follow-up, One More
| # | Name | id | Trigger → effect | Pools · rarity | Notes |
|---|---|---|---|---|---|
| 16 | Sharp Eye | `sharp_eye` | `Damage.Dealt.Critical` → + ult charge | T · C | |
| 17 | Executioner's Seal | `executioners_seal` | `Damage.Dealt.Critical` → follow-up, Physical, % ATK | T B · R | |
| 18 | Hunter's Mark | `hunters_mark` | `Damage.Dealt.Weakness` → follow-up, Physical, % ATK | T · R | |
| 19 | Scholar's Tome | `scholars_tome` | `Damage.Dealt.Weakness` → + ult charge, + MP | T S · C | |
| 20 | Momentum Charm | `momentum_charm` | `Attack.FollowUp` → + ult charge | T · C | |
| 21 | Glass Heart | `glass_heart` | `Damage.Taken.Critical` → heal self | T · C | |
| 22 | Shatter Hammer | `shatter_hammer` | holder's hits deal more toughness damage | T · R | `toughness_dmg` attribute |
| 23 | Breaker's Oath | `breakers_oath` | `Damage.Dealt.Break` → + ult charge, + ATK for a few turns | T B · R | |
| 24 | Encore Ribbon | `encore_ribbon` | `Battle.OneMore` → heal self | T · C | |
| 25 | Predator's Fang | `predators_fang` | holder deals more damage to Broken enemies | T · R | `broken_dmg` attribute |

#### Usable
| # | Name | id | Use | Mode | Pools · rarity | Notes |
|---|---|---|---|---|---|---|
| 26 | Fire Bomb | `fire_bomb` | blast, flat Fire damage, toughness damage | consumable | S · C | breaks Slimes |
| 27 | Frost Bomb | `frost_bomb` | blast, flat Ice damage, toughness damage | consumable | S · C | breaks Bats |
| 28 | Ether | `ether` | one ally, + MP | cooldown | S · C | |
| 29 | Rally Horn | `rally_horn` | all allies, + ATK for a few turns | cooldown | T S · R | |
| 30 | Smelling Salts | `smelling_salts` | revive one ally at % HP | cooldown | S · R | weaker, rechargeable Phoenix Feather; percent ExecCalc |
| 31 | Analyzer Lens | `analyzer_lens` | one enemy becomes weak to Physical for a few turns ("Exposed") | cooldown | T S · R | |

#### Run hooks
| # | Name | id | Hook → effect | Pools · rarity | Notes |
|---|---|---|---|---|---|
| 32 | Coin Purse | `coin_purse` | room cleared → + coins | T S · C | |
| 33 | Golden Idol | `golden_idol` | on pickup → + coins | T · C | |
| 34 | Hearty Stew | `hearty_stew` | floor start → heal living party, % Max HP | T S · C | percent ExecCalc |
| 35 | Mystery Box | `mystery_box` | on pickup → a random Treasure item, then the box is gone | S · R | empty `RemoveItem` (3.5 flow) |

### 3.7 Armor (content, `content/demo/equipment/`)
Ids are `demo.equipment.<id>`; each lives in `content/demo/equipment/<id>.tres` (values, price, description) with
its `AbilitySet`, like the Iron Sword.

| Slot | Name | id | Grants | Pools · rarity | Notes |
|---|---|---|---|---|---|
| Head | Leather Cap | `leather_cap` | + DEF, + Max HP | T S · C | |
| Head | Seer's Circlet | `seers_circlet` | + Crit Rate, + Max MP | T S · R | |
| Body | Chain Vest | `chain_vest` | + DEF | T S · C | |
| Body | Mage Robe | `mage_robe` | + Max MP, + ATK | T S · C | |
| Arms | Bracers | `bracers` | + ATK | T S · C | |
| Arms | Hunter's Gloves | `hunters_gloves` | `Damage.Dealt.Weakness` → + ult charge | T · R | |
| Legs | Swift Boots | `swift_boots` | + SPD | T S · C | |
| Legs | Greaves | `greaves` | + DEF, − SPD | T S · C | trade-off |
| Accessory | Duelist's Band | `duelists_band` | `Damage.Dealt.Critical` → follow-up, Physical, % ATK | T B · R | |
| Accessory | Ember Pendant | `ember_pendant` | `Damage.Dealt.Fire` → target becomes weak to Fire for 1 turn | T B · R | combo piece |

### 3.8 Demo enemies (edits to existing files in `content/demo/enemies/`, `variants/`)
Weakness = `Weakness.<Type>` in the definition's `tags` (the elite variant: its `AbilitySet.tags`); max toughness and
weakness damage taken (`weakness_dmg`) in `stats` of `content/demo/enemies/<id>.tres`.

| Enemy | Weakness | Notes |
|---|---|---|
| Slime | Fire | |
| Bat | Ice | fragile (lowest toughness), easy One More |
| Golem | Physical | toughest bar |
| Elite variant (`variants/elite.tres`) | adds Ice to whatever it's on (via the variant's tags) | `effects/elite.tres` raises max toughness; shows a second weakness without a new enemy |

Party characters: max toughness 0 (never broken).

### 3.9 Toughness damage per ability (edits to existing files in `content/demo/abilities/`)
Set on each execution row's `toughness` in the ability's `.tscn`.

| Ability | Who | Toughness damage | Notes |
|---|---|---|---|
| Strike | basic attack | yes | |
| Ice Blast | skill | on the main `blast` row | the `chill` splash row has none |
| Cleave | Warrior ult | per target, the largest | |
| Frost-Ember (charm passive) | triggered | small | |
| Heal, Sanctuary, Oath, Ult charge | support / passive | none | |
| Enemy abilities (Bite, Crush) | enemies | none | party has no toughness |

### 3.10 UI (your `presentation/demo/`; approved)
Text placeholders for now; icons and banners are later presentation work. Every panel reads `combat/` signals, GAS
and run state only, never changes combat state.

| Panel | Change |
|---|---|
| `battle_panel` | Per unit, after HP/MP/Ult: a toughness bar `[####--] 40/60` (hidden when `max_toughness` is 0), `BROKEN` while `State.Broken`, `weak Fire, Ice` read from the ASC's `Weakness.*` tags (so timed weaknesses appear and vanish). Messages "X is BROKEN!" and "ONE MORE! X acts again"; crit/weak/follow-up marks in the turn label (`damage_dealt`). `unit_view` unchanged. |
| `pickup_panel` | Item and armor description tooltip; armor shows its slot; taking armor doesn't ask for a character. |
| `party_panel` | Per member, every slot of `RunController.equipment_slots()` (filled or `-`, with tooltips); map only: "take off" per worn piece, and the armor inventory with a member picker (any member can wear any slot) and Equip. Same calls as `wear` / `unwear`. |
| `room_view_3d` | Armor pedestals show the piece's name (silver box). |

## 4. Failure modes
Server failure scenarios (root `CLAUDE.md` 1–7): **none apply** (no server, queue, broker or cache). What this slice
protects is **replay determinism**, which scenario 5 (tampered log → 2002) relies on later. A replay mismatch is a
verdict (`Rejected`, `errorCode` 2002, a `MismatchReason`), never an HTTP status; no new mismatch reason.

| Failure | Behaviour | Test |
|---|---|---|
| New rules change existing replays | They can't: fixtures have no weaknesses and no row toughness, the crit roll is unchanged, `extra=` is hashed only while owed | every existing golden passes un-re-recorded |
| Tampered log: One More claimed without a break, or a due One More skipped | 2002 (`TurnMismatch`) | `test_one_more_chain_records_and_replays` |
| Blast breaks three enemies in one action | One extra action, not three; all three Broken and delayed | `test_break_blast_one_more` |
| Extra action breaks another enemy | Another One More; bounded because a Broken unit can't break again until it recovers | `test_one_more_chain_records_and_replays` |
| Extra action and turn effects | No turn-start/turn-end ticks, no action value change, self-buffs don't count down | `test_extra_action_skips_turn_ticks` |
| Break by a follow-up or passive | One More for its owner after the current action; none for a dead owner | `test_break_by_follow_up` |
| Breaking hit also kills / ends the battle | A kill is not a break; death and end checks first; no One More after victory | `test_break_kill_and_victory` |
| Broken unit's turn | Toughness refilled, `State.Broken` removed, then it acts; delay applied exactly once | `test_break_delay_and_recovery`, `test_turn_manager_delay` |
| Hit tag order differs between client and verifier | Sorted, after damage-type events | `test_hit_tag_events` |
| Follow-up ping-pong (two follow-up items) | A follow-up never fires from a follow-up's hit; other chains stop at `TriggerQueue.MAX_DEPTH` | `test_follow_ups_never_feed_follow_ups` |
| Kill edge cases (blast, killer dies too, DoT, dev kill) | Died per dead unit, then Killed per living killer in unit order | `test_unit_killed_event`, `test_killer_dying_too_gets_no_event`, `test_unit_killed_by_dot` |
| Equip during a battle, equip a piece not in inventory, wrong slot | Refused, nothing logged | `test_armor_inventory` |
| Armor in pools with items | Stable order, weighted, no repeats across kinds | `test_equipment_pickups`, `test_armor_never_repeats` |
| Event gives a piece into a filled slot | The old piece goes to the inventory | `test_give_equipment_replaced_goes_to_inventory` |
| ExecCalc spec tags invisible to the battle | Ruled out: GodotGAS passes the same spec | `test_hit_tag_events` |
| No slot, unlisted slot, item+equipment placement, missing description, unregistered trigger | Validator error / error / error / warning / warning | `test_content_validator` (broken fixtures, plus `test_content_validator_equipment_slot`) |
| Replay of a demo battle with breaks, One More, new items and armor | Verified | `test_demo_items_replay` |

## 5. Observability
N/A: client-only slice, no service runs. (From slice 4b, pickups, equips and One More counts come from the event log
into Postgres projections, never Prometheus labels.) Local signals: validator report, script-runner JSON
(`lastBattle`, `armor`, `gear`).

## 6. Test plan
System tests use `tests/fixtures/` only (a fixture ExecCalc mirrors the crit/weakness/toughness/broken logic and
`fixture_break_attribute_set.gd` has the three new attributes; duelist, brittle enemies, armory room, helm/cap/mail),
except demo tests that read `content/demo/`. The fixture builders only add missing files unless run with `--rebuild`,
so adding fixtures keeps the existing ones (and their goldens) byte-identical.

**System (fixtures)**, `tests/combat/test_item_pass_combat.gd` and `tests/game/test_item_pass_run.gd`:
- Hit tags: `test_hit_tag_events`, `test_weakness_from_effect` (definition tag, timed effect),
  `test_weakness_from_ability_set` (a variant's `AbilitySet.tags`), `test_weakness_dmg_attribute`,
  `test_toughness_and_broken_dmg` (both bonuses, and that they do nothing at their 0% default).
- Break and One More: `test_break_delay_and_recovery`, `test_break_blast_one_more`, `test_break_kill_and_victory`,
  `test_one_more_chain_records_and_replays` (chain, record, replay, both tampers), `test_extra_action_skips_turn_ticks`,
  `test_break_by_follow_up`, `test_turn_manager_delay`.
- Follow-ups and kills: `test_follow_up_attack`, `test_follow_ups_never_feed_follow_ups`, `test_unit_killed_event`,
  `test_killer_dying_too_gets_no_event`, `test_unit_killed_by_dot`.
- Armor: `test_equipment_slots`, `test_equipment_pickups`, `test_armor_inventory` (pickup → inventory, equip, swap
  returns the old piece, unequip, refusals, logged, run hash unchanged without armor), `test_armor_never_repeats`,
  `test_give_equipment_replaced_goes_to_inventory`, `test_wear_commands_and_items`.
- Validator broken fixtures: `equipment/bad_equipment.tres`, `rooms/placement_both.tres`,
  `items/trigger_unregistered.tres` (+ `abilities/trigger_unregistered.tscn`), `no_description` on
  `items/fallback.tres`; `bad_equipment_slot` in `test_content_validator_equipment_slot`. Console parity adds
  `wear`/`unwear`.
- **Goldens:** no existing golden changes. One new combat golden `break-seed-11` (top level, 6 extra entries,
  Verified), which `Rpg.Contracts.Tests` cross-checks (5 battle goldens).

**Demo content (`tests/game/test_demo_items.gd`, reads `content/demo/`; skipped when the demo AttributeSet lacks the
new attributes)**: drives `Battle` / `RunController` directly, one group per section of 3.6–3.7
(`test_stat_items_and_armor`, `test_triggered_items`, `test_weakness_break_and_follow_up_items` (also Fire on a Slime
→ weakness, break, One More), `test_armor_passives`, `test_usable_items`, `test_run_hook_items`) and
`test_demo_items_replay` (a recorded battle with breaks, One More, new items and armor → `Verified`). Checks **that**
it happens and which way, never the tuned number. `test_content_valid` (existing): 0 errors.
`game/dev/scripts/item_pass.txt` is a manual smoke script for the script runner, not an automated test.

**Known gaps:** a replay of a run log with equip/unequip (no run-log replayer until slice 4a; the log entries and the
`armor=` hash line are tested); a dead character being equipped (allowed, untested); demo "Fire beats Physical on a
Slime" and demo recovery (recovery is tested on fixtures only).

`dotnet build` / `dotnet test` green. Both suites pass before the slice counts as done. Headless Godot always with
`--quit-after` and a timeout.

## 7. Implementation order
Built in this order (one uncommitted change set; `feat:` for the system, `design:` for content, `spec:` for this sync):
A. Hit tags, follow-ups, kills (fixtures + tests). The spec-object question was answered first: same object.
B. Toughness, break, delay, One More, replay/log/hash (fixtures + tests).
C. Armor: slots, pickup fields, pools, inventory, equip/unequip, validator, console (fixtures + tests).
D. Your files (approved): tags (`sync_tags --add-missing`), the three attributes (draft + your Generate), ExecCalc
   edit, UI panels.
E. Content from 3.6–3.9 (`game/tools/build_item_pass.tscn` for new files; approved edits for existing ones);
   `validate` 0 errors; demo tests.
F. `server-authority` text (`ItemKind`, `equip`/`unequip`), `combat-replay-core` (break, One More, `extra`, hash
   line), `combat-design` (toughness now designed), `game-skeleton`, `dev-tools`, `/sync-spec item-pass`, roadmap ✅,
   root `CLAUDE.md` table.

## 8. Later
- Resist / null / repel / drain via `Resist.<Type>` and `Hit.Resisted` (no battle code needed).
- HSR break effects per damage type (burn, freeze…) and break damage; buildable as content on `Event.Damage.Dealt.Break`.
- Party toughness (enemies breaking the party, and enemy One More): already supported by the generic rule; needs content.
- Follow-ups that copy the triggering hit's damage type; party-wide follow-up events.
- Reveal-map and shop-discount items; armor set bonuses; selling armor.

## 9. Decisions
None open. Decided 2026-10-20: the item, armor, enemy and ability lists (3.6–3.9) as reviewed; Shatter Hammer and
Predator's Fang stay (attributes `toughness_dmg`, `broken_dmg`); a One More can be any action; out-of-turn ults are
slice 1c4. Decided in implementation (synced 2026-10-20): slots listed on the `RunStructure`; One More outside the
turn manager, `TurnMismatch` on tamper; a kill is never a break; follow-ups never feed follow-ups; one combat golden
instead of five.
