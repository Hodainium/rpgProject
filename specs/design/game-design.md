# Game design outline

Design intent only, like `combat-design.md`. Once an asset type exists in Godot, the Godot resource wins and this file
just describes it. Slice specs (`specs/<slice>.md`) turn sections of this file into code.

Number notation: as everywhere else, values are written as designers type them. Anything that can reach combat or has
decimals (multipliers, chances, weights) is stored ×100. Plain counts (coins, prices, room counts, charges) are whole
numbers and stay as typed.

## 1. Pitch
A roguelike run in the shape of *The Binding of Isaac*, with *Honkai: Star Rail* turn-based combat in every combat room and
*Slay the Spire*-style text events. Like *Darkest Dungeon*, your party is worn down from room to room.

- A **run** spans several **floors**. Each floor is a generated grid of **rooms** with a **boss** at the end.
- Combat rooms start an HSR-style battle (the existing `combat/` kernel). Other rooms are events, shops, treasure rooms, etc.
- You bring **1 to 4 characters**. Each has **HP, MP (magic points) and ult charge** (the `Energy` attribute in
  `combat-design.md`). **HP and MP carry over** between battles; buffs, debuffs and DoTs do not.
- **Coins** are the run currency: scarce, with low prices (an item costs about 20).
- **Items** work like Isaac items: passive or active, with a rarity, drawn from pools; some are character-specific (like Birthright).
  Items are **unlocked through gacha**, like characters: a run's item pools only contain items you have unlocked.
- **Active items and characters' spells/moves can be used in the dungeon, outside battle** (e.g. heal between rooms).
- **Equipment** is per character, like HSR Light Cones/relics, kept simple at first.
- **Completion marks** (beating a boss, or winning a run, with a given character) grant **gems**, the meta currency
  (working name; it plays the role of Stellar Jade). Gems pay for character and item rolls.
- **Hub:** a basic menu for now (choose characters → start run). Later a real hub where you roll for characters and items.
- **3D game.** Rooms are basic Isaac-shaped 3D rooms for now. Like *Chrono Cross*, the enemies are already standing in
  the room when you arrive; the battle starts at once (enemies may reposition slightly into formation).
- **Navigation, for now:** a floor map. Click an adjacent room to enter it; after a battle or event you return to the map.
  Walking around inside rooms is a late goal, not planned yet.

## 2. Data-driven principles
1. **Every piece of content is a Godot `Resource` (`.tres`) in `content/`**, with a stable `id` (`StringName`), a display
   `name` and `tags`. Code refers to content only by id.
2. **Pools are tag queries, not lists.** A floor never holds a list of rooms. It holds a `GameplayTagQuery`
   ("rooms tagged `Chapter.Basement` and `Room.Type.Normal`"). Adding content = creating a file with the right tags.
   This is what makes Delirium-style floors (rooms from any chapter's pool) a one-field change.
3. **Defaults with overrides, at every level:** enemy default loadout → encounter override → individual placement override.
   An override is either a reference to a reusable asset or inline values.
4. **Reskins are data:** elite/variant enemies and multi-chapter rooms reference a palette/skin in `presentation/`;
   the rules don't care about the look.
5. **System code never contains content.** Generators, tools and loaders live in system folders; everything the designer
   fills in lives in `content/`.
6. **Work with GAS, not around it** (section 2a). If a game concept can be expressed as an attribute, tag, effect or
   ability, it is one. New asset types only exist to hold things GAS has no concept for (rooms, floors, events).

## 2a. How the game maps onto GodotGAS (the UE5/Lyra way)
| Game concept | GAS concept | Notes |
|---|---|---|
| HP, MaxHP, **MP, MaxMP**, ATK, DEF, SPD, CritRate, CritDmg, **ult charge** (`Energy`), Toughness | **AttributeSet** (made in the GodotGAS dashboard, user-owned) | One shared set for characters and enemies, so any effect works on anyone. Clamps live in `pre_attribute_change`. |
| A character's or enemy's starting stats | `UnitDefinition.stats` → `initialize_attribute_overrides` | The DataTable/"init stats" pattern from UE5: values per unit, typed in the inspector. Already built. |
| `Loadout`, item, equipment, elite variant | **Ability set** (Lyra's `AbilitySet`): abilities + effects + tags granted together, with handles so they can be removed together | One system code class; an item is "an ability set you hold", equipment is "an ability set in a slot". |
| Stat bonus from equipment/items, floor scaling, elite buffs | **Infinite `GameplayEffect`** with modifiers (multiply/add) | Floor scaling = one effect applied to every enemy at battle start, chosen by `ScalingRules` per depth. No custom stat math anywhere. |
| HP/MP carried between battles | Snapshot values → initial attribute values at battle start | Battles stay fresh ASCs (replay rule), seeded from run state. |
| Skill MP cost, ultimate cost | **Cost effect** on the ability (`check_ability_cost`) | Ult gated by `Energy`, spells by `MP`. |
| Item triggers ("on follow-up attack…", "when Ice damage is dealt…") | **Gameplay events** (`send_gameplay_event`) + passive abilities that listen for them | Event tags like `Event.Attack.FollowUp`, `Event.Damage.Dealt.Ice`. Deterministic dispatch order in `combat/` (slice 1d). |
| "Usable in battle / in the dungeon" | **Tags** on the ability + activation tag requirements (`State.InBattle`, `State.InDungeon`) | Same ability resource in both places. |
| Out-of-battle spells and active items | A **dungeon ASC per character**, built from run state, same effects as in battle; results written back to run state | Uses the run's RNG stream, recorded in the run log. |
| Room types, chapters, pools, rarity, enemy types, `Enemy.Boss` | **Gameplay tags** in the one GodotGAS tag registry; pools are `GameplayTagQuery` resources | One vocabulary for combat and world content. |
| VFX/SFX for hits, item procs, pickups | **Gameplay cues** | Presentation only, never changes state. |

Not GAS: coins, gems, map state, unlocks. They are run/meta state, not unit stats.

## 3. Content assets
`★` = in scope for the first slice (rooms, layout, battles, sample events). The rest is defined now so the shapes don't
change later, but built in later slices.

### Rooms and floors
| Asset | Key fields | |
|---|---|---|
| `RoomDefinition` | `id`, `name`, `tags` (type: `Room.Type.Normal/Boss/Treasure/Shop/Secret/Arcade/Event/Start`; chapters: `Chapter.*`), `shape` (1×1 first; Isaac's 2×1/2×2/L later), `doors` (which sides *may* have a door: N/E/S/W), `min_doors`, `weight`, `difficulty`, `content` (see below), `placements` | ★ |
| Room `content` | One of: a fixed `EncounterDefinition`; an encounter tag query (pick at generation); a fixed or queried `EventDefinition`; none (empty/treasure/shop rooms use their placements) | ★ |
| `Placement` | grid cell (whole-number x, y), `kind` (enemy spawn, interactable, pickup, event trigger, item pedestal, shop slot), and kind-specific data (enemy + loadout override, item pool query, price…) | ★ |
| `ChapterDefinition` | `id`, `name`, room query, encounter query, boss encounter query, item pool overrides, `ScalingRules` ref, skin/palette ref, music | ★ |
| `ScalingRules` | enemy stat multipliers by floor depth, coin drop chances, elite chance | ★ |
| `FloorGenRules` | target room count (as a function of depth), required special rooms (1 boss, 1 treasure, 1 shop, 1 secret…), dead-end rules, max grid size | ★ |
| `RunStructure` | ordered floor slots, each with candidate chapters (alt paths), plus floor-level rule flags such as "rooms pull from every chapter" (Delirium) | ★ |
| `FloorLayout` | hand-made floor: a grid of room ids/positions. Loaded instead of generating, for testing | ★ |

**Dead ends and connections:** the generator decides how many doors each map cell needs, then picks a `RoomDefinition`
whose `doors` cover them and whose `min_doors` is met. A room that allows only one door is dead-end-only, which is
where special rooms go (Isaac rule: boss = farthest dead end).

### Units and battles
| Asset | Key fields | |
|---|---|---|
| `UnitDefinition` (exists) | `id`, AttributeSet, base stats, abilities, brain | ✅ |
| `CharacterDefinition` | wraps a `UnitDefinition`: `name`, portrait, default `Loadout`, signature (Birthright-like) item id, unlock condition | ★ |
| `EnemyDefinition` | wraps a `UnitDefinition`: `tags` (`Enemy.Type.*`, `Enemy.Boss`), default `Loadout`, allowed variants. **Bosses are normal enemies tagged `Enemy.Boss`** | ★ |
| `EnemyVariant` | elite/champion: stat multipliers, extra abilities/effects, skin/palette ref, reward bonus | later |
| `Loadout` | abilities, passive effects, stat overrides, (characters) equipment | ★ |
| `EncounterDefinition` (exists, extended) | `tags` (chapters, difficulty, `Encounter.Boss`), `weight`, list of slots: enemy + optional loadout override (asset or inline) + optional variant | ★ |

### Events, items, equipment, economy
| Asset | Key fields | |
|---|---|---|
| `EventDefinition` | `tags`, pages of text, choices with conditions (coins ≥ X, has item, character in party) and **outcomes** | ★ (sample events) |
| `RunOutcome` | small reusable ops: gain/lose coins, heal/damage the party (%), give item (id or pool query), start encounter, go to page, remove item | ★ (a few) |
| `ItemDefinition` | `id`, `name`, icon, mesh, `rarity`, `kind` (passive/active), `tags` (pools: `Pool.Treasure/Shop/Boss/Secret`), `price`, character restriction, **granted battle abilities and effects**, run hooks, active charge | later |
| `EquipmentDefinition` | slot, stat modifiers, optional granted ability | later |
| `CompletionMark` | character × (boss or run win) → gems | later |

**How items work in combat:** an item is a bundle of GodotGAS abilities and effects granted to the holder (or the whole
party) at the start of each battle. Conditional items ("on follow-up attack…", "extra Fire damage when Ice damage is
dealt") are **passive abilities triggered by gameplay events** (`Event.Damage.Dealt.Ice`, `Event.Attack.FollowUp`).
Since every battle builds fresh ASCs from the snapshot, "removed when you lose the item" is automatic: the next battle
simply doesn't grant it. Triggered passives need a deterministic trigger order in `combat/` (no concurrent activation;
see `client-godot/CLAUDE.md` section 3), which is system work in the items slice.

## 4. Run state (save data, not content)
Run seed, current floor and map (cells, room ids, visited/cleared), party (character id, level, current HP, MP and ult
charge if it carries over, equipment), items held, coins, active item charge, RNG stream positions. Meta save (outside runs): gems, completion marks,
unlocked characters and items.

**Out-of-battle actions** (active items, spells cast in the dungeon) change run state, so they go through the same
GodotGAS effects as in battle, use the run's RNG streams, and are recorded in the run log.

## 5. Seeds and the server (the one hard constraint)
The backend verifies **battles**, and today a `BattleSnapshot` holds only identities (encounter id, party unit ids and
levels). A run adds things that change combat: carried-over HP/MP, items, equipment, floor scaling, enemy variants and
loadout overrides. Two consequences:

1. **The snapshot must grow** (schema v2): per-member current HP/MP, item and equipment ids, chapter/scaling id, and the
   encounter's resolved overrides. Godot still derives every number from content; the server still stores ids only.
   This changes `combat/`, `Rpg.Contracts` and the goldens, so it's a `feat:` slice of its own (with the items work).
2. **Everything outside combat is deterministic and seeded too**, so a whole run can later be checked by the server
   the same way a battle is (and so "play seed X" works as a dev tool). The run seed feeds separate RNG streams:
   floor layout, room/encounter picks, item pools, shops, events, and a per-battle combat seed. Separate streams mean
   that opening a shop doesn't change the next floor's layout. Choices in rooms (event choices, purchases, which
   rooms you enter, out-of-battle item and spell use) go into a **run log**, like the battle action log.
   Same rules as combat: integer math only, seeded `RandomNumberGenerator` only, stable iteration order (sorted ids).
   Verifying runs on the server is *not* planned yet; this just keeps the door open at no extra cost.

## 6. Dev tools
| Tool | What it does |
|---|---|
| **Console** (Isaac-style, backtick key) | Command registry with autocomplete from content ids: `spawn <encounter>`, `give <item>`, `coins <n>`, `heal`, `kill`, `stage <n>`, `room <room id>`, `seed <seed>`, `reveal`, `win`. New commands are a one-file addition. Works in any scene. |
| **Room editor** | 3D view of the room with a grid on the floor (Hammer/Forge style) for a `RoomDefinition`: paint placements from a palette (enemy spawn, interactable, pickup, event trigger, pedestal, shop slot), set doors and tags, inspect and override each placement, save to `content/rooms/`, and **Play this room** in one click. |
| **Floor layout editor** | Same canvas at map scale: place rooms on the floor grid and save a `FloorLayout`; start a run on it. |
| **Seed runner / gen viewer** | Enter a seed, see the generated floors as a map without playing; regenerate many seeds to tune `FloorGenRules`. |
| **Content validator** | Finds dangling ids, duplicate ids, queries that match nothing (a chapter with no boss rooms), rooms whose doors can't be satisfied. Runs as a test, so broken content shows up immediately. |

## 7. Suggested slice split
| Slice | Scope |
|---|---|
| **1b `game-skeleton`** | Asset classes for rooms, floors, chapters, scaling, encounters, characters/enemies, loadouts, events (sample outcomes only). Seeded floor generator (Isaac-style) plus `FloorLayout` loading. Run state. Minimal flow: menu → pick 1–4 characters → floor map → enter rooms → battle (existing kernel, isolated) or sample event → boss → next floor. Generator determinism tests. |
| **1c `dev-tools`** | Console, room editor, floor layout editor, seed runner, content validator. |
| **1d `items-and-loadouts`** | Items, equipment, shops/treasure rooms, run carry-over into battles, snapshot v2, triggered passives. |
| **1e `playable-demo`** | Glue and polish so a short run can be played start to finish with your content. |

## 8. Decided (2026-10-19)
- MP is magic points; every character has HP, MP and ult charge. HP and MP carry over between battles.
- 3D: basic Isaac-shaped 3D rooms; enemies are in the room on arrival and the battle starts at once.
- Navigation is click-on-the-map for now; walking inside rooms is a late goal.
- Active items and character spells work outside battle too.
- Items and characters are unlocked through gacha in a hub (hub and gacha come later).
- Everything is seeded (section 5). Slice split as in section 7.

## 9. Open questions
1. **The twist on Isaac's generation:** to be decided after `game-skeleton`.
2. **Does ult charge carry over between battles** (like HP/MP), or reset each battle?
