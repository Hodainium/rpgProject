# Spec: game-skeleton (slice 1b)

Status: ✅ Done (synced with the implementation 2026-10-19) · Roadmap: slice 1b · Date: 2026-10-19
Design intent: `specs/design/game-design.md` (asset model in section 3, GAS mapping in section 2a, seeds and server in section 5).

## 1. Purpose & enterprise mapping
Lay out **every game mechanic as data** before any tooling exists, so making the game becomes filling in data files:

- **World and run:** rooms, chapters, floor-generation rules, run structure, hand-made floor layouts; an Isaac-style
  seeded floor generator; RNG streams; run state, run log and run hash.
- **Units:** characters and enemies, loadouts (with encounter and placement overrides), elite variants, floor scaling.
- **Items and economy:** items held by characters, passive or usable, with pools, rarity and character-specific items;
  usable items are GAS abilities (in battle and on the map, with a cooldown or single use); triggered passives;
  equipment; treasure rooms, shops and coin drops; events with conditions and outcomes.
- **Carry-over, death and revive:** HP, MP and ult charge always persist between battles. Dead party members stay dead
  until something revives them; the revive mechanic itself is built now (content that revives comes later).
  Spells and usable items work outside battle too.
- **Battle snapshot v2,** so a battle can carry all of the above and still replay deterministically.
- A minimal clickable flow on **placeholder (graybox) screens**. System tests use **test fixtures only**; a small
  **example set in your folders** (`content/demo/`, `presentation/demo/`, plus real tags and the AttributeSet in
  `godot_gas/`) shows how hand-made content and screens are structured, and is playable:

```
menu (pick 1–4 characters, optional seed) → floor map → click a room → battle / event / treasure / shop → back to the map
→ boss → next floor → … → last boss → run won        (whole party dead → run lost)        → menu
```

Built only for mechanics that exist: no hub, gacha, completion marks, in-room walking, dev tools or demo content
(dev tools are slice 1c, demo content slice 1d). There is never any walking: you see a screen and battle, pick the next
room on the map, or choose in an event.

| Component | Used in this slice | How |
|---|---|---|
| `client-godot/game/` | ✅ new | World, unit-extension, item and event asset classes; generator; run state/log/hash; run controller; field (out-of-battle) actions |
| `client-godot/game/tools/` | ✅ new | `build_demo.tscn`: one-time builder for the example set (3.8) |
| `client-godot/combat/` | ✅ changed | Snapshot v2 setup (loadouts, items, equipment, variants, scaling, carry-over), ability sets, deterministic trigger dispatch, field mode. Snapshot v1 still works unchanged. |
| `client-godot/tests/` | ✅ | `tests/game/` system tests; world, unit and item fixtures; new goldens |
| `Rpg.Contracts` | ✅ changed | `BattleSnapshot` v2 fields (all optional, so v1 JSON still binds) |
| `content/demo/` | ✅ new files only | Example content of every asset type (3.8). Yours to tune or delete. |
| `presentation/demo/` | ✅ new files only | The placeholder screens (3.7), as an example of how your screens hook into the game. |
| `godot_gas/` | ✅ additions only | Real tags appended to the registry; the shared `UnitAttributeSet` added to the draft and generated. Nothing removed. |
| Server, Postgres, Redis, RabbitMQ, Redpanda | ❌ | N/A: the run is local. The system-design pass after this slice plans the wire side (slice 2b `run-authority`). |

**Enterprise mapping:** the run is a *client-side workflow driven by a seeded, replayable event log*: the generator is
a pure function `(seed, content) → floor`, the run log is the event-sourced record of the player's decisions, and the
battle snapshot is the versioned input document to the calculation library. Snapshot v2 is a backward-compatible
schema evolution (optional fields, v1 documents still valid), the same discipline a service applies to a public API.

## 2. Sequence flow
No client → server traffic. Everything happens in one Godot process.

```
GameMain (game/game_main.tscn, project main scene)
 ├─ ContentIndex(content_root)                 every content folder (3.1), recursive, sorted by path, indexed by id
 ├─ menu ── start(party character ids, seed text) ─▶ RunController.start_run()
 │           RunState{seed, party (full HP/MP from a field context, starting items), coins 0, floor 0}, RunLog []
 │
 ├─ RunController.enter_floor(n)
 │    chapter ← RunStructure.floors[n].chapters (stream floor/<n>/chapter)
 │    FloorMap ← FloorLayout (hand-made) or FloorGenerator.generate(...)        rooms + resolved content per cell:
 │                encounter → enemies resolved (default loadout → encounter override → placement override, elite rolls)
 │                event, item pedestals, shop slots → resolved from their pools
 │    items' on_floor_start outcomes run
 │
 ├─ map ── enter_room(cell) ─▶ RunController           (cell must be adjacent to a visited cell)
 │    log {enter_room}; mark visited
 │    battle room  → room view (3D box, enemy cubes on spawn cells) → battle panel
 │                   snapshot v2 {battleId, seed (room's combat stream), encounterId, party (every member, dead ones
 │                   at 0 HP, with hp/mp/energy, loadout, equipment, held items + readiness), enemies, scalingId + depth}
 │                   Battle.setup() + run(); triggered passives fire through the trigger queue (3.4)
 │                   log {battle, battleId, outcome, finalHash, actionLog}; read back HP/MP/energy and alive/dead;
 │                   items used in the battle (from the action log) are consumed or start their cooldown
 │                   Victory → cleared: coin drop roll, items' on_room_cleared, pedestals unlock, item cooldowns tick
 │                   Defeat/TurnLimit → run lost
 │    event room   → event panel: choose(i) → log {choose}; outcomes run in order (coins, party effects, items, page, battle)
 │    treasure/shop/boss reward → pickup panel: take / buy (placement, receiving character) → log {take|buy}; on_pickup
 │    boss cleared → next floor (or run won after the last floor)
 │
 ├─ party panel, any time on the map: use(ability, actor, target): a character's spell or a held item's use ability
 │    FieldContext (Battle in field mode, party only, tag State.Infield) → effect → read back HP/MP/energy, revives
 │    log {field, actor, ability, target, item?, resultHash}
 └─ run end → menu
```

The screens only **call** `RunController` methods and **listen** to its signals (`floor_entered`, `room_entered`,
`battle_requested`, `event_page_shown`, `pickups_shown`, `party_changed`, `room_cleared`, `run_ended`).
`RunController` holds no UI. `GameMain` takes each screen as an exported scene, pointing at `presentation/demo/` by
default; your own `presentation/` scenes replace them one at a time.

## 3. Data contracts

### 3.1 Content asset classes
Conventions for every asset: `id: StringName` (unique per type), `display_name`, and `tags: Array[StringName]` where it
is pooled (GodotGAS tag picker). Weights and chances are typed as decimals and stored ×100 (`Fixed.from_typed`).
Counts, prices and grid cells are plain integers. **No tag the code depends on is a hard-coded content tag**; the few
system tags are listed in 3.6. "Asset or inline" means the field takes either a saved `.tres` (reusable) or a
sub-resource created in place in the inspector (one-off). Godot supports both on the same field.

**GAS building block (in `combat/`)**
| Class | Fields |
|---|---|
| `AbilitySet` | `abilities: Array[PackedScene]` (each a `BattleAbility`), `effects: Array[GameplayEffect]` (infinite effects applied at battle start; must be saved `.tres` files, as the state hash requires), `tags: Array[StringName]` (loose tags on the unit). Lyra's AbilitySet: granted together, gone together. |

**Units (subclasses of the existing `UnitDefinition`, so combat sees them as units)**
| Class | Fields |
|---|---|
| `UnitDefinition` (exists, extended) | add `display_name`, `display_color: Color` (graybox cube), `tags` (granted as loose tags in battle, e.g. `Enemy.Boss`), `default_loadout: Loadout` |
| `CharacterDefinition extends UnitDefinition` | `portrait: Texture2D`, `selectable: bool`, `tags` (inherited; include `Character.<Name>`), `learnable_skills: Array[PackedScene]` (skills this character may learn during a run; a battle only accepts learned skills from its base `abilities` or this list) |
| `EnemyDefinition extends UnitDefinition` | `variants: Array[EnemyVariant]` (which elite variants this enemy can roll) |
| `Loadout` | **A starting kit, never the current inventory.** `id`, `skills: Array[PackedScene]`, `items: Array[ItemDefinition]`, `equipment: Array[EquipmentDefinition]`, `stats` (typed overrides, ×100; **enemies only**: a character's stats live on its definition so they can always be re-derived) |
| `EnemyVariant` | `id`, `display_name`, `grants: AbilitySet`, `display_color`, `coin_bonus` |
| `EquipmentDefinition` | `id`, `display_name`, `icon`, `slot: StringName` (a tag such as `Equipment.Slot.Weapon`; one item per slot), `grants: AbilitySet` |
| `EncounterDefinition` (exists, changed) | add `display_name`, `tags`, `weight`; `enemies` becomes `slots: Array[EncounterSlot]` |
| `EncounterSlot` | `enemy: UnitDefinition`, `loadout: Loadout` (optional override, asset or inline), `variant: EnemyVariant` (optional: forces this variant) |

**Loadouts are starting kits** (like Isaac starting with a bomb):
- **Characters:** at run start, the character's `default_loadout` is copied into its run state (learned skills, items,
  equipment). From then on the run state is what counts; the loadout is never read again.
- **Enemies:** applied at each battle start. Precedence (resolved when the floor is generated, frozen in the snapshot as
  a `LoadoutRef`): enemy's `default_loadout` → encounter slot's `loadout` → room placement's `loadout`. The last
  non-empty one wins and replaces the others. The enemy's own `abilities` and `stats` always apply; the loadout adds to
  them (its stats override base stats, its items grant like any held item).

**Character run state (the inventory):** level, learned skills, passive items (unlimited), **use slots** (1, plus
`extra_use_slots` from held items, e.g. 2 with a Schoolbag-like item) holding usable items with their cooldowns,
equipment (one per slot tag), HP, MP, ult charge, alive/dead. A battle captures exactly this (3.5). Status effects never
carry over. Everything else (ATK, DEF, SPD…) is re-derived from the definition, level, items and equipment, so a
permanent stat change must be an item or equipment, never a raw number.

**World**
| Class | Fields |
|---|---|
| `RoomDefinition` | `id`, `display_name`, `tags` (room type + chapters), `doors` (flags N/E/S/W that *may* have a door), `min_doors` (1 = can be a dead end), `weight`, `content_mode` (`NONE`, `ENCOUNTER`, `ENCOUNTER_QUERY`, `EVENT`, `EVENT_QUERY`), `encounter`, `event`, `content_query` (empty = the chapter's query), `placements: Array[RoomPlacement]` |
| `RoomPlacement` | `cell: Vector2i` (13 × 7 room grid), `kind` (`PLAYER_SPAWN`, `ENEMY_SPAWN`, `EVENT_PROP`, `ITEM_PEDESTAL`, `SHOP_SLOT`), `slot` (party slot or encounter slot, 1-based), `loadout` (enemy spawns: optional override), `item` (fixed item) or `item_query` (pool), `price` (shop slots: optional override; −1 = the item's price) |
| `ChapterDefinition` | `id`, `display_name`, `tags`, `room_query`, `encounter_query`, `boss_encounter_query`, `event_query`, `floor_gen_rules`, `scaling: ScalingRules` |
| `ScalingRules` | `id`, `enemy_effects_by_depth: Array[GameplayEffect]` (index = depth; past the end the last one applies; empty = none), `elite_chance` (%), `coin_drop_chance` (%), `coin_drop_min`, `coin_drop_max` |
| `FloorGenRules` | `grid_size` (default 9×8), `base_rooms`, `rooms_per_depth`, `random_extra_rooms`, `max_rooms`, `branch_chance` (%, default 50), `max_attempts` (default 100), `start_room_tag`, `normal_room_tag`, `boss_room_tag`, `special_room_tags` (one dead end each: e.g. treasure, shop) |
| `RunStructure` | `id`, `display_name`, `floors: Array[FloorSlot]`, `fallback_item: ItemDefinition` (when a pool is empty) |
| `FloorSlot` | `chapters` (one picked per run), `rooms_from_any_chapter` (Delirium-style), `layout: FloorLayout` (optional hand-made floor) |
| `FloorLayout` / `FloorLayoutCell` | `id`, `display_name`, `grid_size`, `cells`: `{cell, room, role (NORMAL, START, BOSS, SPECIAL), encounter / event overrides}`; the start is the cell with role `START` |

**Items**
| Class | Fields |
|---|---|
| `ItemDefinition` | `id`, `display_name`, `icon: Texture2D`, `mesh: Mesh`, `tags` (pools such as `Pool.Treasure`, rarity such as `Item.Rarity.Rare`), `weight`, `price`, `kind` (`PASSIVE`, `USABLE`), `grants: AbilitySet` + `applies_to` (`HOLDER` or `PARTY`), `use_ability: PackedScene` (`USABLE` only: a `BattleAbility`, so its targeting decides one, several or blast), `use_mode` (`CONSUMABLE`: gone after one use; `COOLDOWN`: ready again after `cooldown_battles` won battles), `extra_use_slots` (e.g. 1 for a Schoolbag-like item), `on_pickup`, `on_floor_start`, `on_room_cleared: Array[RunOutcome]` |

**Holding items:** every item is held by one character. Passive items are unlimited; usable items need a free use
slot (one per character, plus any `extra_use_slots` from items they hold). Taking an item asks which character gets
it; any character can hold any item, and almost every item does the same for anyone. A rare Birthright-like item
(one or two in the game) is plain data, not an asset field: it grants one ability per character, each gated by an
activation query on that character's tag (`Character.<Name>`). A character's usable items are just more abilities on that character,
in battle and on the map. **Unlocks:** `Unlocks.is_unlocked(item)` is a stub that always says yes, until gacha exists.

**Events**
| Class | Fields |
|---|---|
| `EventDefinition` / `EventPage` / `EventChoice` | `id`, `display_name`, `tags`, `weight`, `pages` (page 0 first); page `text`, `choices`; choice `label`, `conditions`, `outcomes` |
| `RunCondition` (base, `holds(run)`) | `CoinsAtLeast(amount)`, `HasCharacter(character)`, `HasItem(item)`. Content can add subclasses, as with ExecCalcs. |
| `RunOutcome` (base, `apply(run)`) | `GainCoins`, `LoseCoins` (never below 0), `ApplyPartyEffect(effect, include_dead)` (a GameplayEffect on party members through the field context: heals, damage, MP, ult charge, revives), `GiveItem(item or item_query, character)`, `RemoveItem(item)`, `GiveEquipment(equipment, character)`, `GoToPage(index)`, `StartEncounter(encounter)`, `EndEvent`. Content can add subclasses. |

Content folders under the content root (subfolders allowed): `units/`, `characters/`, `enemies/`, `loadouts/`,
`variants/`, `equipment/`, `items/`, `encounters/`, `events/`, `rooms/`, `chapters/`, `scaling/`, `floor_rules/`,
`runs/`, `layouts/`. `ContentIndex` (exists) grows to index all of them, recursively. The run uses the single
`RunStructure` in `runs/` (the hub picks one later).

**Tag pools:** pools are GodotGAS `GameplayTagQuery` resources, the same as for abilities. The addon's `matches()` only
accepts an ASC, so `TagMatch.matches(query, tags)` evaluates the same five fields with the same rules (including parent
matching) against a plain tag list. A test runs every case through both, so they can't disagree.

### 3.2 Floor generation (Isaac-style, integers and seeded RNG only)
Cells are visited in **index order** (`y × width + x`) wherever order matters.

1. `target = min(max_rooms, base_rooms + rooms_per_depth × depth + layout_rng.randi_range(0, random_extra_rooms))`.
2. Start at the centre cell. Breadth-first queue; neighbours in the order N, E, S, W. Skip a neighbour if it is outside
   the grid, filled, the target is reached, it already has more than one filled neighbour (no loops), or the branch
   roll fails (`randi_range(0, 9999) >= branch_chance`). Otherwise fill and queue it.
3. Retry on the same RNG if the queue empties before `target` or there are fewer dead ends than `1 + special_room_tags.size()`.
   After `max_attempts`, fail with a content problem naming the rules.
4. Dead end: a filled cell other than the start with one filled neighbour. Boss: the farthest dead end (BFS distance;
   ties: lowest index). Special rooms: per tag in order, one remaining dead end picked with `layout_rng`.
5. **Room choice** per cell with `rooms_rng`: candidates have the role's type tag, match the chapter's `room_query`
   (any chapter's with `rooms_from_any_chapter`), have `doors` covering the cell's door mask and `min_doors` ≤ its door
   count. Sorted by id, picked by weight. No candidates → content problem naming the cell, role, mask and chapter.
6. **Content** per cell with `content_rng`: fixed content as is; queries pick by weight from sorted matches (boss room:
   `boss_encounter_query`). For each enemy slot of a non-boss encounter: elite roll (`elite_chance`), then a variant
   picked from the enemy's `variants` (a slot's fixed `variant` always applies). Loadouts resolved by precedence (3.1).
7. **Pickups** per cell with the room's loot stream: each `ITEM_PEDESTAL` / `SHOP_SLOT` resolves its item: fixed, or
   picked by weight from items matching `item_query` and unlocked, excluding items held or already placed this run.
   Empty pool → `fallback_item`.

A hand-made `FloorLayout` skips steps 1–5 (checked on load: connected, in the grid, one start, one boss).

### 3.3 Seeds and RNG streams
Seeds are decimal strings of non-negative int64. `RunSeeds.derive(parent, label)`:
`rng.seed = parent ^ label.hash(); return ((rng.randi() & 0x7FFFFFFF) << 32) | rng.randi()`. Godot's own code, the same
on every platform; pinned by a golden vector.

| Stream (label under the run seed) | Used for |
|---|---|
| `floor/<n>/chapter`, `/layout`, `/rooms`, `/content` | steps above |
| `floor/<n>/loot/<cell>` | pickups in that room (step 7) |
| `floor/<n>/combat/<cell>` | that room's battle seed |
| `floor/<n>/drop/<cell>` | the coin drop when that room is cleared |
| `floor/<n>/field/<k>` | the k-th out-of-battle action on floor n |
| `floor/<n>/event/<cell>` | a battle started by an event in that room (its battle id and combat stream get a `/event` suffix) |
| `floor/<n>/gift/<k>` | the k-th item picked from a pool by an outcome (`GiveItem` with a query) on floor n |

The order you explore in never changes another room or a later floor. The only non-seeded draw: the menu's **Random**
button fills the seed field with Godot's global RNG (the field starts at `1`; an empty or invalid seed is refused).

### 3.4 Battle changes (`combat/`)
**Snapshot v2 setup**, per unit, in unit-id order, each step in a fixed order:
1. Base stats, then (enemies only) the loadout's stat overrides (`initialize_attribute_overrides`, `max_*` first).
2. Grant abilities: unit's own; learned skills (party: `Skills` from the snapshot, each resolved in the character's
   base kit or `learnable_skills`; enemies: the loadout's skills); equipment's (by slot tag); items' (party-wide passives
   from every member in slot order, then the unit's own passives in pickup order, then its use slots' `use_ability`
   if ready; enemies: the loadout's items); variant's.
   An ability tag the unit already has is skipped (reported once as a content warning); effects stack.
3. Apply infinite effects in the same order, then the floor-scaling effect for `depth` (enemies only).
4. Add loose tags: unit's tags, then each ability set's tags.
5. Carry-over: set `hp`, `mp` and `energy` from the snapshot; clamps in the AttributeSet apply. A member at 0 HP starts dead.
A v1 snapshot runs exactly the old path, so every slice 1 golden still matches.

**Usable items in battle:** a held item's `use_ability` is an ordinary party action, so it goes in the action log like
any skill and replays the same way. After it runs once, the battle revokes it from the unit's ASC for the rest of the
battle and records the use (`Battle.used_items`). After the battle the run consumes the item or starts its cooldown.

**Death and revive (v2 snapshots):** a dead unit keeps its node and ASC, gets the loose tag `State.Dead`, leaves the
turn queue, and loses its temporary effects (buffs, debuffs, DoTs); infinite ability-set effects (items, equipment)
stay. New targeting modes `SINGLE_DEAD_ALLY` and `ALL_DEAD_ALLIES` reach only dead allies (other modes skip them). When
an effect lifts a dead unit's `HP` above 0, the battle revives it: `State.Dead` removed, back in the turn queue with a
fresh action value. Revives use only GAS effects, so a revive item, spell or (later) interactable is content.
v1 snapshots keep slice 1's death handling unchanged.

**Triggered passives (GAS-first, deterministic).** Designers use GodotGAS's own `trigger_event_tag` on a
`BattleAbility`. GodotGAS activates triggered abilities immediately without awaiting them, which breaks determinism
(`client-godot/CLAUDE.md` section 3), so `CombatASC` overrides `send_gameplay_event`: it still emits the signal, but
enqueues the matching abilities (grant order) on the battle's **trigger queue** instead of activating them. The battle
drains the queue in FIFO order, awaiting each activation, after battle start, turn start, each action and turn end
(never inside an ability's own executions). Triggers
caused by triggered abilities join the back of the queue; a chain deeper than 10 stops (deterministically) with a
content warning. Triggered activations aren't in the action log; they're re-simulated.
Events the battle sends (code-known tags, 3.6): `Event.Battle.Start` (all units, before turn 1), `Event.Turn.Start` /
`Event.Turn.End` (actor), `Event.Damage.Dealt` (source) and `Event.Damage.Taken` (target) after each damaging hit,
`Event.Unit.Died` (every living unit), `Event.Ability.Used` (the actor, after each battle action; not triggered
passives, not map actions). `ExecutionRow` gains `tags`; for a row tagged `Damage.Type.Ice` the battle also
sends `Event.Damage.Dealt.Ice` / `Event.Damage.Taken.Ice`, so "extra Fire damage when you deal Ice damage" is pure data.
GodotGAS's own effect `event_tags` still fire, through the same queue. Payload: `{source, target, amount, row, tags}`.
A triggered single-target ability aims at the event's other unit if it's a valid target, else the first valid one by slot.

**Field mode** (out-of-battle actions): `Battle.setup_field(party snapshot)` builds the party exactly as steps 1–5 with
no enemies and no turn loop, adds the loose tag `State.Infield` to every unit, and `perform(actor, ability, target)`
activates one ability. Abilities choose where they work with GodotGAS's `activation_query`: require `State.Infield`
for dungeon-only, ignore it for battle-only. Only ally targeting (`SELF`, `SINGLE_ALLY`, `ALL_ALLIES`,
`SINGLE_DEAD_ALLY`, `ALL_DEAD_ALLIES`) is usable in the field. Usable items work exactly as in battle (the holder is
the actor). Afterwards the game reads HP/MP/energy and revives back into run state.

### 3.5 Wire shapes (`Rpg.Contracts.Battle`, JSON camelCase)
All new fields are optional, so v1 JSON binds unchanged and every existing golden still passes.
```csharp
public sealed record BattleSnapshot(
    int SchemaVersion,                                   // 1 or 2
    string BattleId,
    string Seed,
    string EncounterId,
    IReadOnlyList<PartyMemberSnapshot> Party,
    IReadOnlyList<EnemySnapshot>? Enemies = null,        // v2: resolved slots; null = the encounter's own slots
    string? ScalingId = null,                            // v2
    int? Depth = null);                                  // v2: 0-based floor depth for scaling

public sealed record PartyMemberSnapshot(
    int Slot, string UnitDefId, int Level,
    int? Hp = null, int? Mp = null, int? Energy = null,  // v2: carried values, ×100 like the attributes; null = full/default
    IReadOnlyList<string>? Skills = null,                // v2: learned skills (ability tags) beyond the base kit
    IReadOnlyList<string>? EquipmentIds = null,          // v2
    IReadOnlyList<string>? Items = null,                 // v2: passive items held, in pickup order
    IReadOnlyList<UseSlotSnapshot>? UseSlots = null);    // v2: the member's use slots (1, or more with slot items)

public sealed record UseSlotSnapshot(string ItemId, bool Ready);   // Ready: off cooldown and not used up

public sealed record EnemySnapshot(int Slot, string UnitDefId, string? LoadoutRef, string? VariantId);
```
The party part is a **capture of each character's run state** when the battle starts (level, learned skills,
inventory, equipment, HP/MP/ult charge); there is no loadout on party members. Enemies keep a `LoadoutRef`: a loadout
id, or `<encounterId>#<slot>` / `<roomId>#<placement>` for one typed inline, which `ContentIndex` resolves. The server
stores ids only; Godot derives every other number from content. From slice 2b the server builds the party part
itself from the run state stored in Postgres, instead of trusting the client. Dead members are in the
snapshot with `Hp` 0, so they can be revived mid-battle. The run log and run state stay local in this slice; their C# records come from the
system-design pass (slice 2b).

### 3.6 Run state, run log, run hash, system tags
- `RunState`: `run_id`, `run_seed`, `run_structure_id`, `party` (slot → `{character id, level, hp, mp, energy, alive,
  skills, passive items, use slots with cooldowns, equipment by slot}`, seeded from the default loadout at run start),
  `coins`, `seen_items`,
  `floor_index`, `chapter_id`, `map` (cells with resolved content, `visited`, `cleared`, pickups taken),
  `field_actions_on_floor`, `gifts_on_floor`, `event` (the open event's cell and page), `status`.
- `RunLog` (`RunController.run_log`) entries in order: `start_run`, `enter_room`, `battle` (with the slice 1
  `ActionLog`), `choose`, `take`, `buy`, `field`, `next_floor`, `end`.
- Run hash: `RunState.run_hash()`, canonical `key=value` lines → SHA-256, like state hash v1. For determinism tests only;
  not a wire format yet.
- **System tags the code uses** (you add them to your registry when you want them in the picker; the code doesn't need
  the registry): `State.Infield`, `State.Dead`, `Event.Battle.Start`, `Event.Turn.Start`, `Event.Turn.End`, `Event.Damage.Dealt`,
  `Event.Damage.Taken`, `Event.Unit.Died`, `Event.Ability.Used` (added 2026-10-19, see decision 15), and the prefix `Damage.Type.`.

### 3.7 Placeholder screens (`presentation/demo/`)
Menu (character toggles, seed field, content-root switch), map (Isaac visibility: visited and adjacent cells, role
icons), 3D room (13 × 7 box, door gaps, units as cubes in `display_color` on their spawn cells, pedestals and shop slots
as small cubes with the item's mesh or icon), battle panel (HP/MP/energy, abilities and usable items disabled when
their cost or tags fail, targets including dead allies for revives, Skip toggle; ability animations play on the cube
when they animate `Body`, otherwise a default hop), event panel, pickup/shop panel (with a "give to" character picker),
party panel (HP/MP, dead marker, items, use slots with cooldowns, equipment, field abilities).
As built: each screen's layout lives in its `.tscn` (full-rect root that ignores the mouse, `MarginContainer`, a
corner-pinned `PanelContainer`, containers inside; scripts only fill `%Unique` nodes), checked at 16:9, 4:3 and 21:9.
The party panel shows current/max HP, MP and ult charge (`RunController.party_stats()`) and updates live in battle; the
battle panel has Auto (also for the unit already waiting) and Skip; the map is a `GridContainer`.
**Sound:** ability sounds are audio tracks (plus an `Audio:volume_db` key) on the ability's animation, played by the
cube's `Audio` node; the hit sound is the GameplayCue `Cue.Sfx.Hit` (`godot_gas/cue_registry.tres` ->
`presentation/demo/cues/hit_cue.tscn`) listed on the damage effect; UI, room, battle-start, death and item sounds come
from `presentation/demo/sound_board.tscn` (a `GameMain` slot). Sound files: `presentation/audio/rtp/`.

### 3.8 Example set (`content/demo/`, `presentation/demo/`, `godot_gas/`)
Its job is to show the hand-made structure, not to be balanced. Values are placeholders; every file and value is
listed in the implementation summary.
- **`godot_gas/`, real names:** the system tags (3.6), room types (`Room.Type.Start/Normal/Boss/Treasure/Shop`),
  `Chapter.Demo`, `Encounter.Boss`, `Enemy.Boss`, `Enemy.Type.Slime/Bat/Golem`, `Pool.Treasure/Shop/Boss`,
  `Item.Rarity.Common/Rare`, `Equipment.Slot.Weapon`, `Damage.Type.Physical/Ice/Fire`, `Event.Demo` and the demo
  abilities' tags are appended to `tag_registry.tres` (nothing removed). One shared `UnitAttributeSet` (hp, max_hp, mp,
  max_mp, atk, def, spd, crit_rate, crit_dmg, energy, max_energy, toughness, max_toughness; defaults and clamps from `combat-design.md`) is added to
  `attributes_draft.cfg`. `gameplay_tags.gd` and the AttributeSet script are produced by GodotGAS's own generators; if a
  generator can only run inside the editor, you click Generate once.
- **`content/demo/`**, using the folder layout from 3.1 under `demo/`: 2 characters and 3 enemies (one tagged
  `Enemy.Boss`) as coloured cubes; abilities whose animations jump, spin or flash the cube (Strike, Ice Blast with an MP
  cost, Bite, Crush, a field Heal spell); `ExecCalc_StandardDamage` (`combat-design.md`); a reusable loadout file plus
  one inline override on an encounter and one on a room placement; one elite variant; scaling for two depths; items (a
  holder passive, a party passive, an Ice → Fire triggered passive, a consumable revive, a cooldown blast heal, a
  Schoolbag-like slot item, one Birthright-like item with a different effect per character); one equipment piece; 3 encounters + 1 boss encounter; 2
  events; rooms for start, normal (several door masks), treasure, shop and boss; one chapter, floor rules, a one-floor
  run structure. Added later: Warrior **Cleave** and Cleric **Sanctuary** ults, ult charge listeners (+25 per action,
  +10 per hit), the RTP sound pack with levelled volumes, and the tag checkpoint `game/tools/sync_tags.tscn`.
- **How they're made:** `res://game/tools/build_demo.tscn`, run with your approval, creates the files through
  Godot's `ResourceSaver`, so they are exactly what the editor would save. Rerunning it only creates files that are
  missing (later additions: ults, ult charge listeners, ability sounds), so your edits survive. It writes only inside `content/demo/` and
  `presentation/demo/` and **refuses to overwrite any file that already exists**. Scripts (screens, ExecCalc) are
  written as files, one permission prompt each. Tag and draft additions are `Edit`s, one prompt each.
- Smoke test `test_demo_content`: the example set loads with no problems and generates its floor for 50 seeds. It never
  checks balance, so your tuning can't fail it, and it is skipped if `content/demo/` is deleted.

### RabbitMQ / Redpanda / Redis
N/A: no backend in this slice.

## 4. Failure modes
None of the root `CLAUDE.md` acceptance scenarios is in scope (no server). This slice prepares scenarios 5 and 6: a
v2 battle replays deterministically with all run modifiers, and its content is identified by ids. Local failure modes:

| Case | Behaviour | Test |
|---|---|---|
| Duplicate id or wrong class in a content folder | `ContentIndex.problems`; the menu shows them and won't start | `test_content_problems` |
| A required pool matches nothing | Generation fails naming chapter, role and query (item pools fall back to `fallback_item`) | `test_generation_failures_name_the_problem` |
| Rules can't be met in `max_attempts` | Generation fails naming the rules | `test_generation_failures_name_the_problem` |
| Invalid hand-made layout | Load fails naming the layout and cell | `test_layout_load_and_validation` |
| Unknown loadout, item, variant, equipment or scaling id in a v2 snapshot | Runner error (exit 1), as for an unknown unit today; not 2002 | `test_duplicate_grant_and_unknown_ids`, `test_unknown_variant_equipment_scaling` |
| Tampered v2 battle (action log edited) | `Rejected` 2002 with the usual `MismatchReason`, exactly as v1 | `test_record_replay_verifies_and_tamper_rejects` |
| Trigger chain deeper than 10 | Stops at the same point every time; content warning | `test_trigger_chain_cap` |
| Item grants an ability the unit already has | Skipped, warning, battle continues | `test_duplicate_grant_and_unknown_ids` |
| Field action that isn't allowed (battle-only ability, enemy targeting, cost unaffordable, item on cooldown, dead actor) | Refused, nothing logged | `test_field_actions_and_refusals`, `test_field_mode`, `test_battle_only_ability_refused_in_field`, `test_cooling_item_refused_on_map` |
| Buying without enough coins, taking a taken pickup, a usable item with no free use slot, clicking a non-adjacent cell | Refused, nothing logged | `test_run_navigation_and_refusals`, `test_shop_and_treasure`, `test_usable_items_and_slots` |
| Battle runner error | Run stops with the error shown; not a loss | `test_run_battle_runner_error` |
| Whole party dead (battle, or a field/event effect) | Run `LOST` | `test_run_lost` |

## 5. Observability
N/A: no server or metrics. The run-end screen shows the seed and run hash; the Godot log gets the seed, generation
attempt counts and content warnings.

## 6. Test plan
All tests run in `res://tests/run_tests.tscn` on **fixtures only**; `content/` can never fail them.

### Fixtures (generated by `tests/tools/build_fixtures.tscn`, frozen)
Existing fixture encounters move to `slots` (same units, so slice 1 goldens don't change). New: two chapters, rooms for
every role and door mask (dead ends, a multi-chapter room, a treasure room, a shop, a boss room with a reward
pedestal), three `CharacterDefinition`s and two `EnemyDefinition`s built from the existing fixture units, a loadout
(asset) plus inline overrides on an encounter and a placement, an elite variant, scaling rules for two depths, items
(a passive stat item for the holder, a party-wide passive, one Birthright-like item (an effect per character tag), a triggered passive on
`Event.Damage.Dealt.Ice`, a consumable revive item, a cooldown heal item with blast targeting, a Schoolbag-like
`extra_use_slots` item, an item with `on_room_cleared`), one equipment piece, two events, a 2-floor `RunStructure`, a hand-made layout.
A fixture field ability (heal, `SINGLE_ALLY`, costs MP, requires `State.Infield`). Fixture tags live under `Fixture.*`.

### Unit tests (`tests/game/` and `tests/combat/`)
| Test | Proves |
|---|---|
| `test_agrees_with_addon_on_every_field`, `test_parent_matching` | `TagMatch` agrees with `GameplayTagQuery.matches()` on every field, parent matching, the empty query |
| `test_seed_derive_golden`, `test_seed_parse` | golden vector; non-negative; labels independent; seed text parsing |
| `test_generation_deterministic_and_golden`, `_rules_over_many_seeds`, `_pools` | same map twice and against a golden; over 200 seeds every Isaac rule in 3.2 holds; pools respect chapters and Delirium mode |
| `test_streams_independent_of_exploration_order` | different exploration orders give the same battle seeds |
| `test_layout_load_and_validation`, `test_generation_failures_name_the_problem` | hand-made floors; failures name the problem |
| `test_loadout_precedence`, `test_run_start_from_loadout`, `test_inventory_capture_and_enemy_kit` | enemies: default, then encounter, then placement, asset and inline; characters: the default loadout seeds the run state once; the battle sees the capture |
| `test_inventory_capture_and_enemy_kit`, `test_coin_drops` | variant grants and scaling effects show up in the battle's attributes; seeded drops with the elite bonus |
| `test_golden_replays` | every slice 1 golden and the v2 golden replay in a fresh process, twice |
| `test_trigger_order`, `test_triggered_passive_fires_from_data`, `test_trigger_chain_cap` | queue order; Ice to Fire from data alone; chain cap |
| `test_carry_over_and_dead_stay_dead` | HP/MP/energy flow battle to run state to the next battle; dead members stay dead |
| `test_revive_and_used_items_in_battle`, `test_death_keeps_item_effects`, `test_field_mode` | dead-ally targeting, revive mid-battle, item effects kept on the dead, field mode |
| `test_usable_items_and_slots`, `test_cooling_item_refused_on_map` | revive on the map, consumable removed, cooldown counts won battles, extra use slots |
| `test_field_actions_and_refusals`, `test_battle_only_ability_refused_in_field` | heal in the field, MP spent, refusals |
| `test_item_pools`, `test_item_effect_depends_on_holder` | no repeats, held and seen items excluded, any party gets any item, fallback item; a Birthright-like item acts per holder |
| `test_items_hooks_and_remove`, `test_items_pickup_and_floor_hooks` | `on_pickup`, `on_floor_start`, `on_room_cleared`; `RemoveItem` removes its grants from the next battle |
| `test_shop_and_treasure`, `test_coin_drops` | prices, coins never negative, seeded drops including the elite bonus |
| `test_event_flow` | conditions, outcome order, `ApplyPartyEffect` through GAS, `StartEncounter` |
| `test_ult_charge_and_cost` | ult charge from `Event.Ability.Used`, the ult gated and paid by its energy cost, map actions don't charge |
| `test_run_navigation_and_refusals`, `test_run_lost`, `test_run_won`, `test_run_battle_runner_error`, `test_content_problems` | section 4; the fixture run can be won (seed 11) |
| `test_run_scripted` | a scripted player plays the fixture run to the end twice: identical run log and run hash; golden |
| `test_demo_content` | the example set loads, a run starts, its floor generates for 50 seeds (skipped without `content/demo/`) |

### Golden vectors (`tests/fixtures/golden/`)
`game/seed_derive.json`, `game/floor_7.txt`, `game/floor_123456789.txt`, `game/run_scripted.json`, and the v2 battle
`run-v2-seed-7.json` (+ `.result.json`). Regenerated only on purpose with `--update-goldens`.

### C# (`tests/Rpg.Contracts.Tests`)
`run-v2-seed-7.json` binds to the v2 records and round-trips; every v1 golden still binds (optional fields null).

### Done when
- [x] Godot system tests pass (94: the slice 1 tests plus the new ones). Slice 1 goldens changed only in hash values,
      re-recorded on purpose for the snake_case attribute names (same turns, actions and outcomes).
- [x] `dotnet build` and `dotnet test` pass at the root (32).
- [x] With the fixtures content root, a full 2-floor run can be played by clicking: battles with carry-over, an elite,
      an event, a treasure room, a shop, a field heal, a usable item in battle and on the map, a death and a revive,
      a triggered passive, the boss, a win and a loss (played headless through the screens; the win: `test_run_won`).
- [x] With the `content/` root, the example run plays from start to boss. Only new files under `content/demo/` and
      `presentation/demo/`; `godot_gas/` changes are additions.
- [x] Root `CLAUDE.md` status table, `client-godot/CLAUDE.md` (section 0 `game/` row; section 3 trigger-queue and
      field-mode rules) and the roadmap updated.

### Suggested implementation order (one slice, four checkpoints, tests green at each)
A. World and run on v1 battles (3.1 world, 3.2 steps 1–6, 3.3, run state/log, placeholder map/room/battle/event).
B. Units and snapshot v2 (subclasses, ability sets, loadouts, variants, scaling, carry-over, C# records, v2 golden).
C. Triggers, death and revive, field mode, usable items (trigger queue, battle events, field context).
D. Items and economy (pools, pickups, treasure, shop, drops, hooks, equipment, remaining outcomes) and the full scripted run.

## Files this slice creates or changes (system-owned unless noted)
```
client-godot/game/          game_main(.tscn), view_gate, tag_match, run_seeds, floor_generator, floor_map, run_state,
                            run_controller   (layout loading, enemy and pickup resolution, the run log, the run hash and
                            the field context live in these: implementation decision 5)
client-godot/game/defs/     character_definition, enemy_definition, loadout, enemy_variant, equipment_definition,
                            item_definition, unlocks (stub), room_definition, room_placement, chapter_definition, scaling_rules,
                            floor_gen_rules, run_structure, floor_slot, floor_layout, floor_layout_cell,
                            event_definition, event_page, event_choice, conditions/*, outcomes/*
client-godot/game/tools/    build_demo.gd(.tscn), sync_tags.gd(.tscn)
client-godot/combat/        new: ability_set.gd, encounter_slot.gd, trigger_queue.gd, loadout.gd, enemy_variant.gd,
                            equipment_definition.gd, skill_tags.gd
                            changed: battle.gd (v2 setup, trigger draining, events, field mode), battle_unit.gd,
                            combat_asc.gd (send_gameplay_event override), unit_definition.gd, encounter_definition.gd,
                            execution_row.gd (tags), content_index.gd (all folders, recursive, inline refs)
client-godot/tests/         game/test_*.gd, combat/test_* (new), tools/build_fixtures.gd, fixtures/..., golden/...
src/Rpg.Contracts/Battle/   BattleSnapshot.cs (v2 fields; UseSlotSnapshot and EnemySnapshot live here too)
tests/Rpg.Contracts.Tests/  v2 golden cross-check
client-godot/project.godot  main scene → res://game/game_main.tscn
```
In your folders (new files only): `content/demo/**` (3.8), `presentation/demo/` (menu, map_view, room_view_3d,
unit_view, battle_panel, event_panel, pickup_panel, party_panel, run_end_view, sound_board, cues/),
`presentation/audio/rtp/` (sound pack), `godot_gas/attributes_draft.cfg`, `cue_registry.tres` (hit cue)
(new set), generated AttributeSet and `gameplay_tags.gd`, `tag_registry.tres` (appended).

## Decisions (review, 2026-10-19)
1. **Characters and enemies subclass `UnitDefinition`** (not wrappers): one file per unit, combat code and fixtures keep
   working, and later fields appear on existing files with no migration.
2. **Usable items are abilities on the character who holds them,** used in battle and on the map like skills. Each is
   either a single-use consumable or has a cooldown counted in won battles. Their targeting (one, several, blast) is
   the ability's own.
3. **Ult charge always carries over.** To set it by hand, use a GAS effect from an event (`ApplyPartyEffect`).
4. **Dead characters stay dead until revived.** The revive mechanic (dead state, dead-ally targeting, revive by GAS
   effect, in battle and on the map) is built now; revive items and interactable objects are content for later.
5. **Items are held by one character.** Passives apply to the holder or the whole party (`applies_to`); usable items
   target whoever their ability targets.
6. **One use slot per character;** an item can add slots (`extra_use_slots`, like Isaac's Schoolbag).
7. **Every item is in the pools,** behind a stub unlock check that always says yes until gacha exists. No item twice per run.
8. **Coins are added directly** on room clear. **No walking in this design:** screens only (battle, map, event).
9. **Equipment comes from loadouts and the `GiveEquipment` outcome;** a gear inventory comes with the hub.
10. **Trigger dispatch** goes through a `CombatASC` override of `send_gameplay_event` (FIFO queue, awaited, chain cap
    10), so designers keep using GodotGAS's normal `trigger_event_tag`. A test pins the addon behaviour it relies on.
11. Carried over: Isaac map rules (no fleeing), numeric seeds, fixed 13 × 7 rooms, server authority in slice 2b, dev
    tools in slice 1c, then the full demo in 1d.
12. **Example set in your folders** (2026-10-19): `content/demo/` and `presentation/demo/` show the hand-made structure;
    tags use real names in the one registry; one shared `UnitAttributeSet`. Created by a one-time builder that never
    overwrites (3.8). Slice 1d grows this into the full demo with the dev tools.
13. **Loadout = starting kit, inventory = current state** (review 2026-10-19). A character's loadout seeds its run
    state once; battles capture the run state (level, learned skills, passive items, use slots, equipment, HP/MP/ult
    charge). Other stats are re-derived, so permanent changes must be items or equipment. Enemies are initialized from
    a loadout each battle, recorded as a `LoadoutRef` (a loadout id or `<ownerId>#<n>` for an inline one).
14. **Inventory storage:** local `RunState` in this slice; Postgres from slice 2b (run inventory) and with gacha
    (account inventory). The party capture stays a client claim, uploaded with each battle and checked by run replay
    (slice 4a; `specs/server-authority.md`).

## Decisions made during implementation (2026-10-19)
1. **v1 JSON unchanged by construction:** every v2-only field on the C# records carries
   `[JsonIgnore(Condition = WhenWritingNull)]`, so a v1 snapshot serializes exactly as before (tested).
2. **Trigger drain points:** the queue drains after battle start, turn start, each action and turn end, never inside an
   ability's own executions (draining there would re-enter the presentation gate mid-ability). Spec 3.4 said "after
   every execution"; order and determinism are unchanged.
3. **A used usable item is revoked from the ASC** for the rest of the battle (not blocked by a tag), and recorded in
   `Battle.used_items`; the run applies consumable removal / cooldowns from that list.
4. **`ContentIndex` classifies resources by class, not folder,** recursively (skipping `golden/`), so subfolders and
   the 3.1 folder names are conventions only. Duplicate or missing ids are content problems.
5. **`RunHasher` folded into `RunState.run_hash()`** (canonical lines → SHA-256); `RunLog` is `RunController.run_log`.
   `floor_layout_loader`, `encounter_resolver`, `pickup_resolver` and `field_context` live inside `FloorGenerator`,
   `RunController` and `Battle.setup_field` instead of separate files.
6. **No item ↔ character fields** (user decision 2026-10-19): `CharacterDefinition.signature_item` and
   `ItemDefinition.character` are gone (a two-way link is also a cyclic resource reference). Any character can hold any
   item and pools don't filter by party. Almost all items behave the same for every holder; the rare Birthright-like
   one (1–2 in the game) grants one ability per character, each with an `activation_query` on the holder's
   `Character.<Name>` tag (fixture: `crest`, test `test_item_effect_depends_on_holder`; demo: Oath Stone, triggered on
   `Event.Battle.Start`).
7. **Loadout refs:** besides `<loadout id>` and `<ownerId>#<n>`, an enemy's default loadout is `<unitId>#default`.
8. **Extra seed streams:** `floor/<n>/gift/<k>` (items given by outcomes) and `floor/<n>/event/<cell>` (event battles),
   plus a `/event` suffix on the event battle's id and combat stream, so an event fight never reuses the room's seed.
9. **Goldens:** game goldens live in `tests/fixtures/golden/game/` (`seed_derive.json`, `floor_7.txt`,
   `floor_123456789.txt`, `run_scripted.json`), outside the C# golden scan. The v2 battle golden is
   `golden/run-v2-seed-7.json` (+ `.result.json`), bound by the C# records (`GoldenSet_IsComplete` = 4).
   The scripted fixture run ends `Lost` on floor 2 (a fixed, deterministic result; it isn't meant to win).
10. **Fixtures use `FixtureRunAttributeSet`** (`FixtureAttributeSet` + mp, max_mp, energy) for the run units, so slice 1
    units and goldens are untouched.
11. **Attribute names are snake_case** (`hp`, `max_hp`, …; user decision 2026-10-19), matching the GodotGAS dashboard,
    which snake-cases names and generates `x ≤ max_x` clamps (so `max_energy` and `max_toughness` were added).
    `BattleUnit` applies `max_*` stats first. The few clamps the generator can't write (crit rate, minimums) live in a
    content subclass (`content/demo/attributes/demo_unit_attributes.gd`). The rename changed only hash values in the
    slice 1 goldens (re-recorded; same turns, actions and outcomes).
12. **Screens:** `GameMain` (`game/game_main.tscn`, the main scene) loads each screen from an export or, if empty, from
    `res://presentation/demo/<name>.tscn`; screens get `setup(main)`. `ViewGate extends ClientGate` tells the room view
    which unit acts. The battle panel has an Auto toggle (first usable ability, first target) for watching runs.
13. **Content root switch** is remembered in `user://game_main.cfg`; `res://content/` must hold exactly one
    `RunStructure` (the demo's), so real runs added later need the hub or a picker (1d).
14. **Tag checkpoint tool** (`game/tools/sync_tags.tscn`, user request 2026-10-19): Godot, not a hand edit, regenerates
    `gameplay_tags.gd` (GodotGAS's `GameplayTagGenerator`) and reports content/system tags missing from the registry,
    badly formatted tags, and unused registered tags. It only adds to the registry with `--add-missing`.
15. **Ult charge through GAS** (user request 2026-10-19): the battle sends `Event.Ability.Used` to a unit after each
    action it takes (not triggered passives, not map actions). A character's charge listener is a triggered passive on
    that event applying an instant `energy` gain; an ult's `cost_effect` spends `energy`, so GodotGAS's own cost check
    blocks it until the bar is full and the cost empties it. Tags carry no values, so the bar is the `energy`
    attribute (`max_energy` 100), not a tag. Test: `test_ult_charge_and_cost`. Demo: +25 per action; Warrior Cleave
    (all enemies, 200%), Cleric Sanctuary (party +400 HP).
16. **Tag segments follow the GodotGAS dashboard** (user decision 2026-10-19): `add_tag()` re-capitalises each segment
    to `Xxxx`, so tags are written that way (`State.Infield`, `Ability.Iceblast`, `Ability.Passive.Ultcharge.Action`), never
    camel-case inside a segment. `sync_tags` warns about any tag the dashboard would rename and adds missing tags
    exactly as written (not through `add_tag()`). The rename changed only hash values in `run_scripted.json`.
    Words stay apart through real hierarchy only (`Ability.Passive.Ultcharge.Action` / `.Hit`: a query on
    `Ability.Passive.Ultcharge` matches both ult charge listeners, as intended); no fake parents like `State.In.Field`.
    Long names get a better word instead (`Ability.Item.Revive`).
