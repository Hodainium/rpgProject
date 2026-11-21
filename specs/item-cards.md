# Spec: item-cards (slice 5b2)

Status: **spec written and reviewed 2026-11-21 (decisions in section 7).** First build step: a **concept round** in the engine (gate 1 picks the
shape, gate 2 the tier auras), the same way the pickups of `cube-style` Set K were picked live (spec `cube-style` 6a). Builds on
`specs/card-ui.md` (the card face, `CardFaces`, `CardView3D`, the icon art set), `specs/cube-style.md` Set K (`PropView`,
`PropStyle`, the rarity colours, the inverted-hull outline, `fx.loot_glow`), `specs/vfx-framework.md` (effects as data) and the
roadmap entry "5b2. `item-cards`". References: `H:\assets\references\ror\` (white, green, red, void): for feel only, nothing copied.

## 1. Purpose & enterprise mapping

**Purpose.** Items on the floor are still the placeholder of the first build: a gold cube with a `Label3D`
(`presentation/demo/room_view_3d.gd` `_prop`). Keys, armor and chests got their looks in Set K; items are the last. This slice
draws every **item** pickup (item-room pedestals, shop shelves, an open chest's items) as a floating, turning, bobbing object in the
style of Risk of Rain 2's pickups:

1. **A shape built from the card data** (no new art; the item's game-icons glyph from `card_icons.tres`, its rarity and pools from
   its tags). Which shape is the concept round's question (section 2.1): the glyph alone, the glyph as a 3D silhouette, a square icon
   tile, or the whole Grimoire card.
2. **A silhouette outline in the rarity's colour**, and **an aura that grows with the tier** (the RoR read from across the room):
   Common a thin plain outline; Rare a glowing outline; Epic adds sparks; Legendary adds rising ribbon trails and a glow pool on the
   floor. A **corrupted** item (`Item.Corrupted`, the 15 Void items) is magenta whatever its rarity (RoR's void tier; roadmap,
   user 2026-11-13). **One** aura effect with `color` and `tier` parameters, not one per rarity.

What the references show, and what we take from them:

| RoR tier (reference) | What it does | Ours |
|---|---|---|
| White | The model, a thin white outline, a faint ground glint | Common: thin outline in the rarity colour, a few soft motes |
| Green | A bright green outline that glows, green motes rising, a soft glow under it | Rare: the outline glows and pulses, a faint floor disc |
| Red | Thin luminous ribbons spiralling up around the item, a bright glow pool on the floor | Epic: + sparks; Legendary: + ribbon trails and the glow pool |
| Void | A magenta outline and wisps on a dark item | Corrupted: magenta outline and aura at the Legendary tier, the glyph dark (the card face's void glyph) |

Our rarity colours stay the ones already in `StyleRegistry.props.rarity_colors` (Common light grey, Rare blue, Epic violet,
Legendary amber; the same map tints the armor icons), not RoR's white / green / red (user, 2026-11-21, Q1). **One map for every
floor pickup** (user, Q2): items take the armor's colours, so changing a colour there changes both. The card faces keep their own
rarity colours (`CardStyle`'s `CardRarityLook`s); a concept that shows a card face (D, E, F) shows the face's colours with the
outline and aura in the floor map's colour.

**Presentation only.** Nothing in a hash, snapshot, upload or verifier input changes; `combat/`, `game/verify/` and the run never
reference the new classes; headless runs build no view; no golden moves. Armor keeps its Set K shapes but switches from `fx.loot_glow` to the tiered aura (user, Q2); keys keep their look.
Event "?" props are unchanged.

**Components used:** the Godot client only (`RoomView3D`, the style registry, the card art, the effects framework).
**Not used:** the API, PostgreSQL, Redis, RabbitMQ, Redpanda, the verifier. No contracts, endpoints, tables or metrics.
**Acceptance scenarios:** none (no server path).

## 2. Sequence flow

### 2.1 Gate 1: the concept round (in the engine, live window)

A dev showcase lays real demo items out in the current room, like `style props` did for Set K: the console command
`style items [concepts | <concept> | room]` (section 3.4), opened by Claude in a live window on the preview monitor
(memory: live preview window, `--screen 2`) that the user closes themselves. Each concept is shown with one real item per tier
(the first Common, Rare, Epic and Legendary item by id, and the first corrupted one), one with a shop price, and seen from the
real explore camera, so size and readability are judged where they will be played.

| # | Concept | What floats | Outline | Notes |
|---|---|---|---|---|
| **A** | **Glyph** | The item's glyph alone, ivory, on a flat double-sided quad (alpha cut), turning and bobbing | In the quad's shader: the glyph's alpha dilated, in the rarity colour (`item_glyph.gdshader`) | Closest to RoR's flat-shaded silhouettes; edge-on it thins to a line while turning (a slow sway of ±35° instead of a full spin is an option to try) |
| **B** | **Glyph 3D** | The glyph extruded into a solid (`GlyphMesh`: the texture's alpha → `BitMap.opaque_to_polygons` → an extruded mesh, 0.06 thick), ivory faces, sides in the rarity colour | Inverted hull (`PropView.outline`) | The most "object-like", in line with the cube look and Set K's armor icons; never thin edge-on |
| **C** | **Tile** | A square icon tile: a rounded slab in the rarity's colour (the floor map, lighter and darker), a dark inset, the ivory glyph on both faces | Inverted hull | The "square floating around" of the user's ask; reads like an inventory icon or a coin |
| **D** | **Card** | The whole Grimoire card, small (`CardView3D` face, its own SubViewport; the card back on the reverse), turning and bobbing | The card shader's rounded outline in the rarity colour | Ties the floor to the collection; the name is on the card but small at room distance |
| **E** | **Facing card** | Concept D, but it always faces the camera (no spin; a gentle sway and bob) | As D | Readable at a glance; less "loot", more "offer" |
| **F** | **Tile and card** | Concept C floating low with the aura, and the full card always open above it, facing the camera (user, Q4: the card is always open, no focus link) | As C, and as D | The RoR read from afar and the card's facts at once |

Each concept is shown **both with and without the name label** (today's `Label3D`, name and price; user, Q3: show both).
The **chest drop flash** (Q5) is shown as its own concept too: `style items pop` drops one item per tier out of a chest, with and
without a one-shot flash at Epic and above (`fx.card_flip_flash` in the rarity colour); it is built only if the user picks it. The user may pick one
concept for everything, or mix (for example C on pedestals and D in shops); the look data allows a concept per placement kind
(3.1). Concepts not picked are deleted after the gate, as Look A was in `card-ui`.

### 2.2 Gate 2: the tier auras

On the picked shape, `style items room` lays out the five tiers side by side and the user tunes the aura in the live window (the
aura's parameters are effect data, editable in the inspector and reloaded with `style reload`). One effect,
`presentation/demo/fx/item_aura.tres`, layers enabled by `tier` through stepped bindings (`FxBinding` curve):

| Layer | Tier 0 Common | 1 Rare | 2 Epic | 3 Legendary |
|---|---|---|---|---|
| Outline (on the shape, not the effect) | thin, plain | thicker, emissive, slow pulse | as Rare | as Rare, brighter |
| Motes (soft dots rising, like Set K's sparkles) | few | more | more | more |
| Floor disc (additive quad under the item) | none | faint | faint | the glow pool, bright, pulsing |
| Sparks (short bright streaks) | none | none | yes | yes |
| Ribbon trails (particles with ribbon trails spiralling up, RoR red) | none | none | none | yes |

A corrupted item plays the aura at tier 3 in magenta (`ItemCardLook.void_color`, `void_tier`), with the dark void glyph the card
face uses (`CardStyle.corrupted_glyph` / `corrupted_glyph_halo`); motes swap for `fx.void_wisps` if the user prefers (try both).
The aura follows the effects quality tier (`off` shows the outline only) and stops when the prop leaves.

### 2.3 In play (after the gates)

1. `RoomView3D` rebuilds the room (unchanged triggers). For each untaken item pickup on an `ITEM_PEDESTAL` or `SHOP_SLOT`
   placement, and each untaken item an open chest put out (spec `floor-chests`), it asks the registry for the item look
   (`registry.item_look(kind)`); with one, it adds an `ItemPropView` on the cell (`_styled_prop` grows an item branch); with none,
   today's `_prop` cube is drawn (so a content set without the look still plays).
2. `ItemPropView` reads the item's card face (`CardFaces.face_of(content, style, row)` for the item's catalog row, with the content's `CardStyle`: glyph, rarity, corrupted)
   and builds the picked shape under a turning, bobbing holder; the tier comes from the rarity tag (`ItemCardLook.tier_by_rarity`)
   or the void override; the outline and the aura take the rarity colour (`registry.rarity_color(tags)`).
3. A chest's pop-out (`_pop_out`) moves the new view as it moves any prop. Taking an item rebuilds the room as today, so the view
   leaves and its aura stops (`PropView._exit_tree`).
4. Battles hide the props as today. Nothing is sent anywhere.

## 3. Data contracts

**C# records, queues, topics, Redis keys: N/A** (no server path, nothing uploaded).

### 3.1 Godot resources (system classes in `game/view/`, data in `presentation/demo/style/`)

```gdscript
## How items look on the floor (spec item-cards). On PropStyle.item; resolved through the registry's base chain like key_look().
class_name ItemCardLook extends Resource
enum Concept { GLYPH, GLYPH_3D, TILE, CARD, FACING_CARD, TILE_AND_CARD }  # trimmed to the picked one(s) after gate 1
@export var concept: Concept
@export var shop_concept: int = -1          # -1 = same as `concept` (a mix, if the user picks one at gate 1)
@export var size: float = 0.55              # world units, the shape's height
@export var offset: Vector3 = Vector3(0, 0.6, 0)
@export var spin_speed: float = 0.25        # turns a second; 0 with sway_degrees > 0 = a sway instead
@export var sway_degrees: float = 0.0
@export var bob_amount: float = 0.06
@export var bob_speed: float = 0.5
@export var outline_by_tier: PackedFloat32Array = [0.02, 0.035, 0.035, 0.045]
@export var outline_glow_from_tier: int = 1
@export var aura: FxDefinition              # item_aura.tres; params color, tier
@export var tier_by_rarity: Dictionary[StringName, int]   # Item.Rarity.* -> 0..3; unlisted = 0
@export var void_tag: StringName = &"Item.Corrupted"
@export var void_color: Color = Color(1.0, 0.25, 0.85)
@export var void_tier: int = 3
@export var label: bool = true              # the name / price Label3D (Q3)
@export var drop_flash: FxDefinition        # Q5, if picked: played once when a chest puts the item out
@export var drop_flash_from_tier: int = 2
@export var label_height: float = 1.15
@export var glyph_thickness: float = 0.06   # GLYPH_3D
```

- `PropStyle` gains `item: ItemCardLook`; the aura's `color` comes from `PropStyle.rarity_colors` (the one floor map); `PropLook`
  for armor gains the same `aura` use (its `effect` = `item_aura.tres`, `tier` from the piece's rarity), so both tier alike; `StyleRegistry.item_look(kind)` resolves it through the base chain (a specific look
  anywhere in the chain wins, as for the other props). `style_registry.tres` is the user's file: the concept round uses a variant
  file of its own (`presentation/demo/style/variants/item_cards/<concept>.tres`, `base` = the registry), and the one line that
  adds the picked look to the main registry is asked for at gate 1 (Set K did the same).
- `presentation/demo/fx/item_aura.tres` (+ its sub-resources) and the ribbon trail mesh, created by the builder (3.3), added to
  `fx_registry.tres` by `RegistryPatch.add_missing_effects()` (the approved text patch).

### 3.2 Godot code (system code, presentation only)

| File | Role |
|---|---|
| `game/view/item_prop_view.gd` `ItemPropView` (extends `PropView`) | `ItemPropView.item(look, face, color, tier, text)`: builds the shape of the look's concept, the outline, the label, and plays the aura with `color` and `tier` |
| `game/view/glyph_mesh.gd` `GlyphMesh` | B: an extruded mesh from a texture's alpha (polygons simplified to a tolerance, front and back caps triangulated with `Geometry2D.triangulate_polygon`, sides with normals), cached by texture path, size and thickness |
| `game/view/shaders/item_glyph.gdshader` | A: the glyph quad, alpha cut, the outline by alpha dilation (`outline_width`, `outline_color`, `glow`), double-sided, fog off (as the library's effect shaders) |
| `game/cards/card_view_3d.gd` | D, E, F: `outline_color` / `outline_width` uniforms on `card_view.gdshader` (the rounded outline exists; it gains a colour and a glow); a `world_mode` so it lives in the room's world, not only on a card stage (no hover input, its own render scale from the explore camera) |
| `presentation/demo/room_view_3d.gd` | `_styled_prop` draws items through the registry; `show_item_showcase(content, concept)` for the console; armor views play the tiered aura; `_pop_out` plays the drop flash if picked |

### 3.3 Builder

`game/tools/build_item_cards.tscn` (creates files only, never overwrites without `--force`): `item_aura.tres`, the six concept
variant files for the round, and after gate 1 the picked `ItemCardLook` file. Run once by Claude.

### 3.4 Dev tools (headless parity)

- Console `style items` (refused in a battle, like `style props`): `concepts` (every concept side by side, a Rare and a Legendary
  each, labelled A–F), `<concept>` (that concept: the five tiers, a shop item with its price, a food item), `room` (the current
  room's real pickups redrawn with the live look), `use <concept>` (switches the in-memory look for this session, so a real floor
  can be walked with each concept), `label on|off`, `pop` (the chest drop flash, Q5).
- `style check` and `validate_content.tscn` gain `style_item_*` codes: no aura, an aura that does not loop, a tier map naming a tag
  not in the registry, an item with no glyph (it falls back to `CardStyle.default_icon`: a warning listing them).
- `dev_run` scripts can call all of the above; the preview script for the live window goes with the cube preview tools.

## 4. Failure modes

| Case | Behaviour |
|---|---|
| No `ItemCardLook` in the registry chain (another content set, or a missing file) | Today's gold cube and label; no error |
| An item with no glyph in the art set | `CardStyle.default_icon`; validator warning `style_item_glyph_missing` |
| A glyph whose alpha gives no polygon (B) | The flat glyph of concept A for that item; a warning once per texture |
| Effects quality `off`, or headless | Shape and outline only (headless: no view at all; `FxManager` inert) |
| Many cards in one room (a full shop, a chest's items) for D, E, F | Still faces render once (`UPDATE_ONCE`); only Legendary / corrupted faces with their sheen update every frame, as on the collection page; the showcase counts the frame time with every card on screen and gate 1 reports it |
| A battle starting in the room | Props hidden as today; auras stop with them and return after |

Idempotency, retries, dead letters: N/A (no server path). Replay mismatches: N/A (nothing here reaches a hash or the verifier).

## 5. Observability

N/A: client presentation only; no metric, log or event. The showcase prints the frame time with every concept on screen (dev only).

## 6. Test plan

`tests/view/test_item_cards.gd` (in the Godot suite; nothing in the .NET suite changes):

- **Look resolution:** `item_look()` through the base chain; a variant's look wins; none = the cube path.
- **Tiers:** every `Item.Rarity.*` maps to its tier; `Item.Corrupted` overrides any rarity with `void_tier` and `void_color`; an
  untagged item is tier 0 in the default colour.
- **Every demo item builds** an `ItemPropView` under each kept concept without a script or engine error (`ScriptErrorLog`), with
  its own glyph (or the default icon, listed).
- **`GlyphMesh`:** a fixture texture (a square with a hole) gives the expected cap and side counts, the same mesh on a second call
  (cache), and an empty texture falls back.
- **Room view:** a pedestal item, a priced shop item and an open chest's item are drawn as `ItemPropView`s with the right
  colour, tier and label; keys and armor stay Set K views; no item view on a battle's stage; taking an item removes its view.
- **Aura:** `item_aura.tres` passes `fx check` and `fx_smoke` at every quality tier, at tiers 0–3; the layers enabled per tier
  match 2.2's table; quality off leaves the outline only.
- **Armor:** an armor icon plays `item_aura` at its rarity's tier in the same colour as an item of that rarity; changing
  `rarity_colors` changes both.
- **Drop flash (if picked):** a chest pop-out plays it from `drop_flash_from_tier` only.
- **Presentation guard:** `combat/`, `game/verify/` and the run's scripts never reference `ItemPropView`, `ItemCardLook` or
  `GlyphMesh` (the guard `test_fx` uses); every combat and run golden replays unchanged (the existing suites).
- **Validator:** a broken fixture per `style_item_*` code in `tests/broken_fixtures/`.
- **Console:** `style items concepts|<concept>|room|use|label|pop` run headless and print their lines; refused in a battle.

The visual result is judged by the user at the two gates in the live window, not by a golden image.

## 7. Decisions

Decided by the user at review, 2026-11-21:
- **Q1 Colours:** ours (grey, blue, violet, amber), not RoR's.
- **Q2 Armor:** armor switches to the tiered aura too. Items use the armor's colours (`PropStyle.rarity_colors`), one map, so a
  change there changes both. The card faces keep the rarity colours they already have.
- **Q3 Label:** shown both with and without at gate 1.
- **Q4 Card:** always open; no focus link. Concept F became "tile and card" (the card always shown above the tile).
- **Q5 Chest drop flash:** yes, but shown as a concept first (`style items pop`), built only if picked.

## 8. Out of scope

Picking items up by walking onto them, new item mechanics, item mesh models (`ItemDefinition.mesh` stays as an override nobody
uses), event "?" props, key and chest shapes, the card face itself (5b's), floor rooms (5b3), anything on the server.
