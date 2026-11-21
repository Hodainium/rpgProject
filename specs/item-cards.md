# Spec: item-cards (slice 5b2)

Status: **built 2026-11-21 on `feat/item-cards`; both gates passed in the live window and the look accepted by the user; spec
synced to the build 2026-11-21** (decisions in section 7). Built on `specs/card-ui.md` (the card face, `CardFaces`, `CardView3D`,
the icon art), `specs/cube-style.md` Set K (`PropView`, `PropStyle`, the rarity colours), `specs/vfx-framework.md` (effects as data)
and the roadmap entry "5b2. `item-cards`". References: `H:\assets\references\ror\` (white, green, red, void): for feel only,
nothing copied.

## 1. Purpose & enterprise mapping

**Purpose.** Items on the floor were still the placeholder of the first build: a gold cube with a `Label3D`
(`presentation/demo/room_view_3d.gd` `_prop`). Keys, armor and chests got their looks in Set K; items were the last. Every **item**
pickup (item-room pedestals, shop shelves, an open chest's items) is now **its own card**, small, turning and bobbing over the
floor in the style of Risk of Rain 2's pickups:

1. **The item's Grimoire card** (the face of spec `card-ui`, built from the card data: no new art), with the card back on the
   reverse, at a card height of 0.7.
2. **A rim in the rarity's colour** around the card, brighter by tier, and **one aura that grows with the tier** (`fx.item_aura`,
   parameters `color` and `tier`), the RoR read from across the room:

| RoR tier (reference) | What it does | Ours |
|---|---|---|
| White | The model, a thin outline, a faint ground glint | Common: the rim, a faint floor glow, a few soft motes |
| Green | A glowing outline, motes rising, a soft glow under it | Rare: a brighter rim, a faint floor disc, more motes |
| Red | Luminous ribbons spiralling up, a bright glow pool | Epic: + sparks; Legendary: + ribbons spiralling up and a bright glow pool |
| Void | A magenta outline and wisps on a dark item | Corrupted (`Item.Corrupted`): magenta at the Legendary tier, whatever its rarity |

3. **A floating label** with the name and, on a shop shelf, the price ("Battle Horn (5)"), the same for cards, keys and armor.

Our rarity colours are the ones already in `StyleRegistry.props.rarity_colors` (Common light grey, Rare blue, Epic violet,
Legendary amber), **one map for every floor pickup**: items take the armor icons' colours, so a change there changes both. The card
faces keep their own rarity colours (`CardStyle`); the rim and the aura use the floor map's.

Armor keeps its Set K shapes and now plays the same tiered aura (instead of `fx.loot_glow`). Keys and armor were made larger,
game-wide, in their own looks (section 7). Event "?" props are unchanged.

**Presentation only.** Nothing in a hash, snapshot, upload or verifier input changes; `combat/`, `game/verify/` and the run's
scripts never name the new classes (`test_item_cards` checks); headless runs build no view; no golden moved.

**Components used:** the Godot client only (`RoomView3D`, the style registry, the card faces, the effects framework).
**Not used:** the API, PostgreSQL, Redis, RabbitMQ, Redpanda, the verifier. No contracts, endpoints, tables or metrics.
**Acceptance scenarios:** none (no server path).

## 2. Sequence flow

### 2.1 How the look was picked (gates, in the engine)

Gate 1 showed six concepts side by side in a live window from the real explore camera, on real demo items of every tier: A the
glyph alone, B the glyph as a 3D solid, C a square icon tile, D the whole card spinning, E the card facing the camera, F a tile with
the card above it. The user liked C and D and picked **D**, then its size (0.7, from 0.7 to 1.6 side by side), the label, the key
and armor sizes and the shop look; the other concepts and their code were deleted. Gate 2 compared the aura at three strengths
and a drop flash on chest items: the aura as built, no wisps, no flash. Section 7 has every decision.

### 2.2 In play

1. `RoomView3D` rebuilds the room (unchanged triggers). For each untaken pickup on an `ITEM_PEDESTAL` or `SHOP_SLOT` placement,
   and each untaken item an open chest put out (spec `floor-chests`), `_styled_prop` asks the registry:
   - an **item** with an item look (`registry.item_look()`) → `ItemPropView.for_item(look, content, id, registry, price)`;
   - a **key** or an **armor piece** → its Set K `PropView`, labelled like the cards and at the cards' label height when there is
     an item look (`_beside_cards`); an armor piece plays the item aura at its rarity's tier (`_armor_aura`);
   - no item look → today's gold cube (a content set without the look still plays).
2. `ItemPropView.for_item` reads the item's card face (`CardFaces.face_of` on its catalog row, with `CardStyle.current()`), its
   tier (`ItemCardLook.tier_of`: the rarity tag, or the void tier for a corrupted item) and colour (the floor map, or `void_color`),
   builds the card (`CardView3D` with its back) on a turning, bobbing holder, sets the rim, plays the aura with `color` and `tier`,
   and adds the label (`ItemPropView.label_for`).
3. When the view is ready, the card **bakes** its face and back once into mipmapped textures (`CardView3D.bake`): a 4.7.2
   viewport texture has no mipmaps, so a 360 x 480 face drawn a few dozen pixels tall shimmered. The live viewports then stop.
4. Every frame, each labelled pickup **places its label** along the camera's up from the shape's centre (`PropView._place_label`):
   the camera looks down, so a label straight above its pickup in the world landed beside it on screen. The label follows the
   pickup's scale (a chest's item grows as it pops out).
5. A chest's pop-out (`_pop_out`) moves the new view as it moves any prop. Taking an item rebuilds the room, the view leaves and its
   aura stops (`PropView._exit_tree`). Battles hide the props as before. Nothing is sent anywhere.

## 3. Data contracts

**C# records, queues, topics, Redis keys: N/A** (no server path, nothing uploaded).

### 3.1 Godot resources

```gdscript
## game/view/item_card_look.gd: how items look on the floor; on PropStyle.item, resolved through the registry's base chain.
class_name ItemCardLook extends Resource
const DEFAULT_PATH := "res://presentation/demo/style/items/item_card_look.tres"
enum LabelMode { NAME_AND_PRICE, PRICE_ONLY, NONE }
@export var size: float = 0.7                    # the card's height (gate 1)
@export var offset: Vector3 = Vector3(0, 0.735, 0)
@export var spin_speed: float = 0.2              # turns a second; 0 with sway_degrees > 0 = a sway
@export var sway_degrees: float = 0.0
@export var bob_amount: float = 0.06
@export var bob_speed: float = 0.5
@export var rim_energy_by_tier: PackedFloat32Array = [1.0, 1.8, 2.0, 2.4]
@export var card_rim: float = 7.0                # design pixels of the 300 x 420 face
@export var card_render_scale: float = 1.0
@export var aura: FxDefinition                   # fx.item_aura: color, tier
@export var tier_by_rarity: Dictionary[StringName, int]   # Item.Rarity.* -> 0..3
@export var void_tag: StringName = &"Item.Corrupted"
@export var void_color: Color = Color(1.0, 0.25, 0.85)
@export var void_tier: int = 3
@export var label: LabelMode = LabelMode.NAME_AND_PRICE
@export var label_height: float = 1.6
```

- `PropStyle.item: ItemCardLook` and `StyleRegistry.item_look()` (the nearest in the base chain; null = the cube).
- Data (the user's folders): `presentation/demo/style/items/item_card_look.tres` (size 0.7, offset 0.735, the aura), named by
  the main `style_registry.tres` (`props.item`); `presentation/demo/fx/item_aura.tres` (`fx.item_aura`), in `fx_registry.tres`.
  Both made by the builder (3.3). The key and armor Set K looks in `style_registry.tres` were scaled (section 7).
- `fx.item_aura` layers, each gated by `tier` through a curve binding (tier 0..3 on the curve's points):

| Layer | Common | Rare | Epic | Legendary / corrupted |
|---|---|---|---|---|
| `pool`: a flat additive glow under the card (`glow_3d`), intensity | 0.15 | 0.45 | 0.55 | 1.4, pulsing |
| `motes`: soft dots rising from a ring, `amount_ratio` | 0.3 | 0.6 | 0.8 | 1.0 |
| `sparks`: short streaks falling back (medium quality and up) | none | none | yes | yes |
| `ribbons`: bands spiralling up an open cylinder (`item_ribbons.gdshader`, medium quality and up) | none | none | none | yes |

### 3.2 Godot code (system code, presentation only)

| File | Role |
|---|---|
| `game/view/item_card_look.gd` `ItemCardLook` | The look above; `tier_of(tags)`, `rim_energy(tier)`, `label_text(mode, name, price)` |
| `game/view/item_prop_view.gd` `ItemPropView` (extends `PropView`) | `for_item(look, content, id, registry, price)`, `item(...)`, `label_for(look, name, price)` (the label of any floor pickup), `face_for` (the card face from the catalog row); bakes its card when ready; dev statics `override_label`, `bake_faces` |
| `game/view/prop_view.gd` | `pickup(look, text, color, label_height)`; every pickup turns around its shape's middle (`bounds_centre`); `_place_label` (camera-up, scale-aware); `label_node` |
| `game/cards/card_view_3d.gd` | `bake()`: the face and back copied once into mipmapped textures, through a static coroutine holding a weak reference (a card freed mid-bake ends it); a cache keyed by the face's data, the style and the render scale (`baked_face_key`), oldest evicted first at 48 (`_store_baked`), `clear_baked()` |
| `game/cards/shaders/card_view.gdshader` | `rim_color` / `rim_width` / `rim_energy` (the rarity rim outside the card's edge) and `face_baked` / `use_baked` (the baked face, sampled with mipmaps and anisotropy) |
| `game/fx/shaders/material/item_ribbons.gdshader` | The Legendary ribbons: `color`, `strength`, `intensity`, `ribbons`, `twist`, `speed`, `thickness` |
| `presentation/demo/room_view_3d.gd` | `_styled_prop` draws items, keys and armor through the registry; `_beside_cards`, `_armor_aura`; the dev showcase `show_item_showcase(content, mode, look)` |

### 3.3 Builder

`game/tools/build_item_cards.tscn` (creates files only; `--force` rewrites its own): `presentation/demo/fx/item_aura.tres` and
`presentation/demo/style/items/item_card_look.tres`, then `RegistryPatch.add_missing_effects()` (the approved additive patch).
Run once.

### 3.4 Dev tools (headless parity)

Console `style items` (the showcase needs a window and is refused in a battle, like `style props`):
`labels` (the three label modes), `shop` (everything a shop sells: an item per tier and food, a key, an armor piece per slot),
`tiers` (an item per tier), `sizes [h,h,...]` (the card at several heights), `pop` (a chest putting items out one at a time);
`label name|price|none|auto` and `bake on|off` set the session's label mode and face baking (work headless).

## 4. Failure modes

| Case | Behaviour |
|---|---|
| No `ItemCardLook` in the registry chain | Today's gold cube and label; keys and armor keep their own label heights and glow |
| An item that is not a card (no catalog row) | A plain common face from its id |
| An item with no glyph in the art set | The card face's own fallback (`CardStyle.default_icon`) |
| A card freed while its face bakes (a room rebuilt twice in two frames) | The static bake sees the weak reference gone and stops; no "instance is gone" error |
| A style reload, content change or another size | A new cache key: the face bakes anew |
| More than 48 different faces | The oldest baked face is dropped, one at a time |
| Effects quality `off`, or headless | The card and its rim only (headless: no view; `FxManager` inert); sparks and ribbons only from medium |
| A battle starting in the room | Props hidden as before; auras stop with them and return after |

Idempotency, retries, dead letters: N/A (no server path). Replay mismatches: N/A (nothing here reaches a hash or the verifier).

## 5. Observability

N/A: client presentation only; no metric, log or event.

## 6. Test plan

`tests/game/test_item_cards.gd` (11 tests, on the in-memory card fixtures `card_world.gd` and looks built in code, so the user's
content and style cannot fail them):

- tiers by rarity, the corrupted override, an untagged item, the rim energy table;
- the label modes and `label_for` with the session override;
- an item as its card: its own face, the back, tier, floor-map colour, rim, aura and its parameters, label, size; a corrupted
  item in magenta at the void tier;
- the room view: an item drawn as its card, a key and armor labelled like the cards at the cards' height, armor on the item aura
  at its tier, no item look → the cube path;
- a pickup turning around its middle, its label risen along the camera's up and as high as a straight rise, and following the
  pickup's scale;
- baked faces: reused from the cache, keyed by face, style and render scale, faces and back apart; a card freed mid-bake; the
  oldest evicted first;
- the aura's tier gates read from `item_aura.tres` (sparks from Epic, ribbons at Legendary, the pool brightest at Legendary);
- the console's `style items` (headless refusal, label, bake with a bad argument refused, the deleted concepts gone);
- `combat/`, `game/verify/` and the run's scripts never name `ItemPropView`, `ItemCardLook` or the aura.

Plus the full suites (Godot 1109, .NET 616), content validation, `fx_smoke` at every quality tier, and the look judged by the user
in the live window at both gates (no golden image).

## 7. Decisions

User, 2026-11-21 (review, then both gates in the live window):
- **Colours:** ours (grey, blue, violet, amber), one floor map shared with the armor icons; the card faces keep their own.
- **Armor:** plays the tiered item aura; its shapes stay.
- **Shape:** D, the spinning card (C, the tile, the runner-up), at a card height of **0.7**; A, B, C, E and F deleted.
- **Label:** name and price for cards, keys and armor alike; a free pickup its name; above the pickup on screen.
- **Sizes, game-wide:** keys x1.2 and armor x1.3 in their own Set K looks in `style_registry.tres` (scale and float height):
  key 1.15 → 1.38 (0.5 → 0.6), weapon 0.85 → 1.105 (0.4 → 0.52), head 0.78 → 1.014 (0.45 → 0.585), body 0.85 → 1.105
  (0.46 → 0.598), arms 1.05 → 1.365 (0.5 → 0.65), legs 0.88 → 1.144 (0.46 → 0.598), accessory 0.72 → 0.936 (0.38 → 0.494).
- **The key's label:** centred on its pivot (every pickup now turns around its middle).
- **Aliasing:** fixed by baking the floor faces into mipmapped textures; the Legendary sheen holds still on the floor.
- **Aura:** as built (Soft and Strong copies compared live); no void wisps on corrupted items.
- **Chest drop flash:** shown live and dropped; items just land.
- **Never a two-key buy:** a shop slot sells exactly one key (it already does; only the first demo showed two).

Changed from the reviewed spec while building (raised with the user at the gates): the concept round used one look file and session
overrides instead of six variant files; the tier outline became the card's rim (the picked concept has no hull outline); no
`style_item_*` validator codes (the look has no field a broken file could get wrong that the tests do not cover); the label,
pivot and baking work above came from playtesting the gates.

## 8. Out of scope

Picking items up by walking onto them, new item mechanics, item mesh models (`ItemDefinition.mesh` stays an unused override),
event "?" props, chest shapes, the card face itself (5b's), floor rooms (5b3), anything on the server.
