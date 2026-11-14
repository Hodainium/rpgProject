# Spec: `cube-style` (slice 5a4), an art experiment

Status: draft (2026-11-12, rewritten the same day as an experiment), awaiting the user's review.
Roadmap: new slice 5a4, before 5b `card-ui` (added to `specs/roadmap.md` when this spec is approved).
Builds on `animation-sets`, `vfx-framework`, `vfx-content-pass`, `vfx-stencil`. **Presentation only.**

## 1. Purpose & enterprise mapping

### 1.1 Purpose
The units stay cubes (user, 2026-11-12: an art choice, not a placeholder). This slice finds out, by trying things, what makes the
cubes read as a deliberate style. **It is an experiment run as a demo:** Claude makes art changes in rounds and presents each as
comparison shots; the user approves or rejects every variant. Only approved variants stay.

Today every unit is the same 0.8 `BoxMesh` with a flat `StandardMaterial3D` in its `display_color`. The room has one
`DirectionalLight3D` and no `WorldEnvironment`: no tonemap, glow or ambient occlusion. Units differ only by colour.

**The main idea to test: personality through attachments.** A cube wears objects that say who it is: a sword, a set of wings,
horns, a crown. A silhouette reads from any angle, unlike an icon on a face. (The face-glyph idea of the first draft is dropped from
this slice. game-icons stay for the card art in 5b; see memory `card-art-direction`.)

### 1.2 Enterprise mapping
N/A: no backend component. Nothing here is in a hash, snapshot, upload, verdict or event.
- The data and art live in `presentation/`, which is **not** a `RulesetVersion` root (`combat/`, `game/`, `content/`, `godot_gas/`,
  `addons/GodotGAS/`). Art changes never change the ruleset version and never force a verifier re-export.
- The system code lives in `game/view/` (a ruleset root, like `UnitAnimator`). The headless verifier never loads it (3.6).

## 2. The rounds

Each round ends at a **gate**: Claude renders the shots to `H:\claudeOutShots\<date> cube-style round <n>\` (a contact sheet per
variant, the same units, camera and battle moment in each, plus a short written note per variant), and the user marks each variant
**approve**, **reject** or **change** (with what to change). A round's code may land before its gate; its art stays a proposal until
approved. Rejected variants are deleted.

| Round | What is tried | Variants shown |
|---|---|---|
| 1. Stage | Lighting and mood: `WorldEnvironment` (AgX tonemap, glow, SSAO, ambient), key / fill / rim lights, floor and wall materials; one mood per chapter. Rim light on the cubes (kept **unbevelled**: user, 2026-11-12). The battle framing (3.9) | Today vs 2–3 moods on the same battle, today's camera vs a closer battle framing; one shot per chapter for the approved one |
| 2. Primitives | Attachments **Claude builds from engine shapes** in code (cylinders, cones, prisms, tori, extruded outlines, path sweeps): a crown, bat wings, devil horns, a sword, a halo, a wizard hat, on five units (a Warrior, a Bat, a Fire Imp, the Lich, the Golem); motion on them (wings flap, a crown floats) | Each object 1–2 shapes, on its unit, still and in motion |
| 3. Downloaded models | Single headwear models picked from Poly Pizza (CC0 or CC-BY, 3.5 (b)) on the same five units, side by side with the approved primitives, each shown with its own textures and **recoloured** (flat colour + our rim, which makes mixed sources read as one style); mixing with primitives is allowed (a downloaded hat + primitive wings) | One sheet per source, then a mixed sheet |
| 4+. Roll-out | The chosen sources on every class and enemy, a few units a round | Per unit: 1–2 proposals |
| Later rounds (only if wanted) | Proportions (tall casters, wide tanks, small Bats), party vs enemy finish, archetype animation sets (heavy, bouncy, floaty), state looks (Broken, Downed, shatter on death) | Decided at the round-4 gate |

Voxel (blocky) attachments are not tried: the user prefers simple, non-blocky styles (2026-11-12).

**Preview before the spec was approved (2026-11-12, a throwaway scene outside the repo; shots in
`H:\claudeOutShots\2026-11-12 cube-style primitives\`).** Round 1's stage and round 2's primitives on seven demo units: a sword and a
crest (Warrior), a glowing halo (Cleric), a bent wizard hat (Arcanist), a top hat with a feather (Bard), wings and ears (Bat), curved
horns and a tail (Fire Imp), a crown and glowing eyes (Lich); all built in code (bevelled box, lathe, tapered tube along a curve,
extruded outline). **The user liked the direction.** Findings carried into the rounds:
- **Scale vs camera:** today's battle camera (`RoomView3D`: (0, 9, 8), pitched −50°) shows the units small, so attachments are hard
  to read in a real battle. Round 1 decides between bigger attachments (about 1.5–2×) and a closer battle framing (Honkai frames
  units tighter); the shots include both.
- To fix in round 2: the Warrior's crest reads as a handle (try a plume or a helmet), the Bat's wings are small and hidden behind
  it, the top hat catches too much rim light; metal needs a low `metallic` with no reflection probe (it renders dark).
- The preview's code is the starting point for `AttachmentMesh` (3.3, 3.5).

The experiment ends when the user says the look is done. The spec is then synced to what was kept (`/sync-spec cube-style`).

## 3. Data contracts
No C# DTOs, queues, topics or Redis keys. The Godot resources (system code in `game/view/`, data in `presentation/demo/style/`):

### 3.1 `StyleRegistry` (Resource), `presentation/demo/style/style_registry.tres`
| Field | Type | Meaning |
|---|---|---|
| `default_look` | `UnitLook` | Used when nothing else matches |
| `looks` | `Dictionary[StringName, UnitLook]` | Unit definition id → its look (characters and enemies) |
| `tag_rules` | `Array[UnitLookRule]` | A `GameplayTagQuery` on the definition's tags + a partial look; first match fills what an exact look leaves unset (e.g. `Enemy.Boss` → a larger body). GAS-first: archetypes come from tags the content has |
| `default_mood` | `StageMood` | For a chapter with no mood, the sandbox and rooms outside a chapter (never the menus: the room view's environment is detached while it is hidden) |
| `moods` | `Dictionary[StringName, StageMood]` | Chapter id → its mood |
| `explore_camera`, `battle_camera` | `CameraFraming` | The room camera out of and in battle (3.9) |

A registry keyed by id (like `FxRegistry`), not fields on `UnitDefinition`: that class lives in `combat/` and the verifier loads it,
so it must not reference meshes or textures (the reason `UnitDefinition.view` is a path). `display_color` stays the unit's base colour.

### 3.2 `UnitLook` (Resource)
| Field | Type | Default | Meaning |
|---|---|---|---|
| `use_color_override`, `color_override` | `bool`, `Color` | off = unset | Replaces `display_color` (a switch, not "alpha 0 = unset": the inspector's picker keeps alpha 0) |
| `rim` | `float` | from the default look | `StandardMaterial3D.rim` strength |
| `attachments` | `Array[UnitAttachment]` | none | What the cube wears |
| `effect`, `effect_params` | `FxDefinition`, `Dictionary` | null = unset | A looping effect the cube carries (user, 2026-11-13: "for these cubes effects we can add shaders or effects"; the Ember Knight's `fx.fire_ring`, flames rising from a ring on the floor). The view plays it on itself (`FxAnchor.node3d`) once it is built, stops it (faded) when the unit dies or the view leaves the tree, starts it again on a revive, and swaps it on a restyle. Unset fields come from the rule, then the default look, like the others. Presentation only: headless `FxManager` is inert. Validator: `style_effect_not_looping` (an effect with no looping layer would play once and end). It follows the effects quality (off stops it, a raised tier starts it again), keeps playing while a death waits behind a cast, and goes with a death fade. Known limit: `effect_params` travel with their `effect`, so a look cannot recolour an effect it inherits from a rule or the default look |
| `size` | `Vector3` | unset = the 0.8 cube | Later rounds only |
| `animation_set` | `UnitAnimationSet` | the view's | Later rounds only |

### 3.3 Attachments as data (round 2; decided 2026-11-13, option A)
An attachment is **data built at run time**, not a baked mesh: the designer edits it in the inspector, and a new attachment is a new
`.tres`. Meshes are built on first use and cached by their parameters (an edit makes a new mesh). Baking stays possible later: a
tool can save the cached meshes as mesh files (for speed or an export) without changing the data.

`AttachmentShape` (Resource, `presentation/demo/style/attachments/<name>.tres`): `display_name` and `parts: Array[AttachmentPart]`.

`AttachmentPart` (Resource): one primitive.
| Field | Meaning |
|---|---|
| `kind` | `BOX`, `CYLINDER` (a cone when one radius is 0), `SPHERE`, `TORUS`, `PRISM`, `LATHE` (a 2D profile spun around Y), `TUBE` (a tapering tube along a quadratic curve), `EXTRUDE` (a 2D outline with thickness) |
| `size` | `BOX` / `PRISM` size; `EXTRUDE`'s depth is `size.z` |
| `radius_bottom`, `radius_top`, `height` | `CYLINDER`; `SPHERE` uses `radius_bottom`; `TORUS` uses `radius_bottom` (inner) and `radius_top` (outer); `TUBE` tapers from `radius_bottom` to `radius_top` |
| `profile` | `PackedVector2Array`: `LATHE`'s profile (x = radius, y = height) or `EXTRUDE`'s outline |
| `curve` | `PackedVector3Array`: `TUBE`'s three control points (start, bend, end) |
| `segments` | Sides of round shapes, steps of a tube |
| `position`, `rotation_degrees`, `scale` | Placement inside the attachment |
| `ring_count`, `ring_radius` | Repeat the part `ring_count` times around Y at `ring_radius` (a crown's spikes); 0 = once |
| `color`, `metallic`, `roughness`, `emission` | Its `StandardMaterial3D`; `emission` > 0 glows (and blooms) in its colour |
| `tintable` | Whether a `UnitAttachment`'s tint replaces this part's colour (a gem stays its own colour) |

`UnitAttachment` (Resource, in a `UnitLook`):
| Field | Meaning |
|---|---|
| `shape` | The `AttachmentShape` |
| `socket` | Where it sits: `Center`, `Top`, `Base`, `Front`, `Back`, `Left`, `Right` (3.4) |
| `offset`, `rotation_degrees`, `scale` | Placement relative to the socket |
| `mirror` | Also a copy mirrored across the unit's middle (X): a pair of wings, two horns |
| `use_tint`, `tint` | Replaces the colour of the shape's tintable parts (one hat shape, many colours) |
| `motion`, `motion_speed`, `motion_amount` | `NONE`, `BOB` (up and down), `SPIN` (around Y), `FLAP` (a swing around Z, mirrored for pairs) |
| `spin_axis` | `SPIN` only: the axis in the attachment's own frame (after its rotation), so a gear stood on its side turns on its axle (the Brass Colossus, Set 2; its scale stays outside the turn); zero (unset) = around the parent's Y, as before; set with another motion it does nothing (warning `style_spin_axis_unused`) |

`UnitLook.attachments` is unset when empty: an exact look's list wins whole over a rule's, a rule's over the default's (lists are
not merged). Attachments are children of `Body`, so every unit animation moves them. Every part's material goes through
`mark_stencil()` like the body's, so an effect "over own unit" also draws over them (spec `vfx-stencil`). Motion runs on the
view's own presentation clock, never in a hash.

### 3.4 Body and sockets
- **Body mesh:** a plain `BoxMesh` at the look's size. The cubes stay unbevelled (user, 2026-11-12: "for now"); a bevel
  (`SurfaceTool`, proven by the preview) is a possible later round, not built.
- **Material:** `StandardMaterial3D` with `rim_enabled`; no custom shader, so `mark_stencil()` stamps it as today.
- **Sockets:** today `SocketCenter`, `SocketHit`, `SocketTop`, `SocketBase` (`FxSocket`, for effects). Attachments use
  `UnitAnimator.socket_position()` from `body_size` (default the 0.8 cube), in the unit's own frame: `Center`, `Top`, `Base` and the
  face centres `Front` (+Z), `Back`, and the unit's own `Left` (+X) and `Right` (-X); no scene edit.
- **Facing (user, 2026-11-13: the helmet faced the wrong way, the enemies faced the screen):** a unit's attachments turn toward its
  opponents: the party (and every unit outside a battle) faces +X (90° around Y), enemies (battle ids `E…`) face -X (-90°).
  The body is a cube, so only the attachments turn.
- **One detail per cube (user, 2026-11-13):** a look wears one attachment (a mirrored pair counts as one). Party characters
  wear hats and never hold items; enemies their signature detail (the Bat its wings, the Imp its horns).
- **Death:** a dead unit's attachments turn grey and stop moving, like its body; a revive restores them.
- **Surface (user, 2026-11-13: "an accessory can be just to change the texture of the cube"):** `UnitLook.surface`, a
  `StandardMaterial3D` template (noise textures, triplanar; still stampable) that replaces the plain colour; the Golem wears
  `presentation/demo/style/surfaces/stone.tres` (rock plates: a cellular-noise normal map and a light shade variation, tinted by the unit's own colour, so the Golem stays orange-brown; a first grey noise stone read as "just a noise texture", and glowing cracks washed the cube white) as its one detail. The
  meteor's `lava_rock` shader was not reused: its lumps push vertices along normals, which splits a cube's edges, and a custom
  shader takes no stencil stamp.

### 3.10 Battle formation (user, 2026-11-13: units too close together)
`BattleFormation` (Resource, `game/view/`): `row_sizes` (front row first; the last size repeats), `front_x` (distance from the
centre line to the front row), `row_spacing`, `lane_spacing`, `center_z`. `StyleRegistry.party_formation` / `enemy_formation`
(null = the rooms' own spawn cells, today's layout). `RoomView3D` places each side's battle units in slot order. The demo: enemies
2 in front and 3 behind, 1.8 apart; the party 2 and 2 with its front row moved right (x -4 → -2.6) and a wider back row
(`row_lane_spacing` 2.0 then 4.0, staggered like the rooms' old spawn cells: the user found a perfect grid odd). Presentation only: the battle
itself has no positions; rooms keep their spawn cells for exploration. All follow the body's size; the size lives in the mesh, never `Body.scale` (animations key the scale); the
  bottom stays at y = −0.4, so floor rings keep their place. `fx_radius` stays derived from the body only.

### 3.5 Where attachment scenes come from (rounds 2 and 3 decide)
- **(a) Primitives (round 2):** `AttachmentShape` data (3.3), built at run time by `AttachmentMesh` (`game/view/`): engine primitive
  meshes plus three `SurfaceTool` generators proven by the preview (lathe, tube, extrude). No builder, no CSG.
- **(b) Downloaded models (round 3):** single models (Poly Pizza: about 20 crowns, 43 hats, 52 helmets, 2026-11-12; no CC0 artist
  found ships a headwear pack: KayKit Adventurers bakes its hats into the characters) or packs: (glTF) copied in from `H:\assets\<pack>\` by `game/tools/import_models.tscn -- --from <folder> --pick
  <file>[,...]` into `presentation/demo/style/attachments/<pack>/`, never overwriting (`--force`). Only a licence that allows
  publishing the model files (CC0, or one that says so) while the repo is public: most paid store licences forbid it. Each pack's
  licence file is copied beside its models.
- Every builder creates files only and never overwrites (`--force`), like `build_fx_set`.

### 3.6 `StageMood` (Resource) and headless
| Field | Type | Meaning |
|---|---|---|
| `environment` | `Environment` | Tonemap, glow, SSAO, ambient, optional fog; authored in the inspector |
| `key_light`, `fill_light`, `rim_light` | `MoodLight` (colour, energy, rotation; shadows on the key only) | Three-point rig, the rim light behind the units, opposite the camera |
| `floor_material`, `wall_material` | `Material` | The room box's floor and wall cubes |
| `wall_bevel` | `float` (metres, default 0.06, 0..`MAX_WALL_BEVEL` 0.25) | How deep the wall blocks' edges and corners are chamfered; 0 = sharp boxes |

**Bevelled room walls (user, 2026-11-13: "the rooms get the bevelled-cube look of the preview").** The room box's wall blocks
(1 × 0.6 × 1) are chamfered boxes, the look of the 2026-11-12 preview shot `2_after_battle.png`; the floor stays a plain slab and the
units stay unbevelled (3.4). `AttachmentMesh.bevel_box(size, bevel)` builds the block (flat-shaded edge strips and corner triangles,
UVs projected per face, cached by size and bevel so every wall shares one mesh; a bevel of 0 is a plain `BoxMesh`, a too deep one is
held inside the box), `StageRig.wall_mesh()` gives the mood's block (no mood = today's sharp box), `RoomView3D` builds its walls
from it and swaps it with the materials on a battle restyle. The floor slab runs under the wall ring (`COLUMNS + 2` × `ROWS + 2`;
user, 2026-11-13: the chamfered bottom edges left a crack between the floor and the walls), so the walls stand on it and every
groove shows floor, never the background. Its four vertical corner edges are chamfered by the same `wall_bevel` (user, same day:
"just the short edges at the corners"; the long edges stay sharp) so the slab's corners match the corner blocks:
`AttachmentMesh.corner_slab(size, bevel)` through `StageRig.floor_mesh(size)`, swapped on a battle restyle like the walls. Both shapes are flat-shaded with UVs projected per face (a texture tiles once per metre) and tangents (a normal map lights right); a `BoxMesh` maps a 3 × 2 atlas instead, so a textured material looks different at bevel 0. A bevel that is not finite, or that a too thin box holds to nothing, is a plain box. The room view passes its own sizes (`WALL_SIZE`, `FLOOR_SIZE`). Door gaps show floor (user, 2026-11-13: keep it). Every mood bevels by default (0.06, the preview's), so the
registry file is unchanged. Validator: `style_wall_bevel_invalid` (a mood's bevel outside 0..0.25 or not a number). Shots:
`H:\claudeOutShots\2026-11-13 bevelled walls\`.

`RoomView3D` applies the mood of `RunState.chapter_id` when it builds a room or a battle. `UnitStyle` (the lookup in `game/view/`)
loads nothing in a headless process (the rule `FxManager` follows); the verifier, replay, trace and step runners never build a view.

### 3.7 Credits
CC0 needs no credit, but each pack is named anyway. `CREDITS.md` at the repo root lists every pack used, with its author, link and
licence, plus what ships today without one: the RTP sound pack and Chakra Petch (OFL). The game-icons authors join it in 5b. A test
fails when a folder under `attachments/<pack>/` has no line in `CREDITS.md`.

### 3.8 Dev tools
- Console `style list` (each unit's look and where it came from: exact, rule, default), `style show <unit>`, `style mood [<chapter>]`
  (apply a mood to the current room), `style reload`, `style check`.
- Validator in `validate_content.tscn`: `style_look_unknown_unit`, `style_mood_unknown_chapter`, `style_wall_bevel_invalid`, `style_socket_unknown`,
  `style_attachment_shape_missing`, `style_part_invalid` (a lathe or outline with fewer than 2/3 points, a tube without 3 curve points), `style_pack_uncredited` (round 3).
- **Shots** come from the real game: a window `dev_run` (`--window --local --manual --shots <dir>`) starts a run, `goto boss`, then
  switches with `style registry <variant>` / `style mood <chapter>` and takes `shot <name> [seconds]` (the delay, added here, waits
  out the camera move). No separate stage scene (built 2026-11-12: the real room view, HUD and battle line-up are what the user
  judges). Variants under test are registries of their own in `presentation/demo/style/variants/<round>/<name>.tres` until the gate:
  usually a `base` registry plus what they change (a partial look merges over the base's), or a standalone alternative with no
  `base` (round 1's `bright`: one look for every chapter). `validate_content.tscn` checks every variant too.

### 3.9 Camera framing
`CameraFraming` (Resource: `position`, `rotation_degrees`, `fov`). `StyleRegistry.explore_camera` and `battle_camera`; `RoomView3D`
moves its camera to the battle framing when a battle starts and back when it ends (a short tween, presentation only). Unset = today's
camera ((0, 9, 8), pitched −50°, the default fov) for both, so a registry without framings changes nothing. Round 1 shows today's
framing beside a closer battle framing.

## 4. Failure modes
N/A for the acceptance scenarios: none is about presentation. Presentation failures:
- No registry, or a headless run: today's look (plain cube, colour only). The game never depends on the style.
- A missing attachment scene: the unit without it, a warning once per unit.
- An unstampable attachment material: `mark_stencil` warns and that unit's effects use the plain depth test; the validator flags it.
- No golden, hash or snapshot can move: the full suites run unchanged (6).

## 5. Observability
N/A: no Prometheus metrics (client presentation). Dev only: `style list`, the gallery's Style page, and `fx stats` for draw calls
before and after (each attachment adds a draw per unit; merging an attachment's meshes into one keeps it at one).

## 6. Test plan
`tests/game/test_cube_style.gd`, on fixture looks in `tests/fixtures/style/` (never `presentation/`), plus a smoke test over the
demo registry:

| Test | Proves |
|---|---|
| Resolution order | exact id > first matching tag rule > default; unset fields filled in that order |
| Sockets follow the size | every socket and the label for three sizes; the bottom stays at −0.4 |
| Attachments | placed at their socket, `mirror` makes the opposite copy, `color` tints, they move with `Body` during the default set's idle, hit and death |
| Motion | `bob`, `spin`, `orbit`, `flap` on a manual clock give the expected transforms |
| Stencil | with stencil on, every material under the view (body and attachments) is stamped with the unit's value |
| Mood | a fixture chapter's mood is applied; an unknown chapter gets the default |
| Headless | a headless battle loads nothing under `style/`; `RulesetVersion.files()` holds nothing under `presentation/` |
| Builders | the primitive builder gives the same mesh twice and never overwrite without `--force`; the model import keeps the pack folder and its licence |
| Credits | every pack folder has a `CREDITS.md` line |
| Validator | each `style_*` code on a broken fixture in `tests/broken_fixtures/` |
| Console | `style list / show / mood / reload / check` |

Plus the existing suites unchanged: `tools/godot_tests.sh` and `tools/dotnet_test.sh`.

## 6a. Round 4: the roll-out design sheet (in progress; Sets P, 1-5, 4b, 5b, the party pass and the floor-1 refresh done 2026-11-13; Set K next)

The looks for the 36 units that had none (round 2 dressed Warrior, Cleric, Arcanist, Bard, Bat, Fire Imp, Knight, Lich, Golem).
Each unit gets a first proposal (**A**) and an alternative (**B**); the user picks A, B, a mix, or a change, usually over several
iterations. Every detail is data: primitive attachments (3.3), a surface (`UnitLook.surface`), a looping effect (`UnitLook.effect`,
3.2), or a shader in the effect library. "Reuse" means an existing shape or effect with a tint or parameters (memory
`reuse-vfx-parameterize`). Colours come from the unit's `display_color` unless noted.

**Design approach (evolved during Set P, Set 1 and Set 2, user, 2026-11-13; memory `cube-style-design-lessons`):**
- **Start simple, combine freely.** A proposal starts from one signature detail, but combined details are fine and often chosen
  (A and B together, plus a face). The original "one detail per cube" rule is relaxed.
- **Party:** headwear, a centred face and, since the party pass, sometimes a held item plus a **floor effect** in the class's theme under the cube (fire, bubbles, frost, holy
  glow, runes, golden glow, cracks). **Enemies:** a signature detail, often a **face** (eyes, muzzle, skull, tongue), plus an effect
  or surface where it fits.
- **See-through bodies** are allowed for jelly and spirit creatures (an alpha surface with both faces drawn and a colour override
  alpha around 45-55%). They are not stencil-stamped, so effects on them use the plain depth test; that is accepted because those
  effects show through the body. They need something to see inside or behind, and no solid part may start inside them.
- **Placement:** nothing clips into the cube or sits close to the floor, orbiting parts are evenly spaced, round shapes are smooth.
  The battle camera sees enemies from the side, so front details lean toward the camera side and tails swing sideways.
- **Effects:** each unit gets its own (a party effect is reused on an enemy only when the user asks); pulses go clearly from light
  to dark; every shader uniform a track animates is set in the layer's `shader_params`.
- **Held items and long shapes (Set 2):** a held item sits on the unit's camera side in battle: an enemy's own Left, a party member's own Right and clear of the body;
  a ladle's handle rises from its bowl's rim, not through it; a hammer's head runs along the unit's facing (Z), so its long side
  shows from the battle camera. A gear stood on its side spins on its own axle (`UnitAttachment.spin_axis`, 3.3).
- **Faces on the face plate:** small glowing eyes read best on a dark plate behind them (the Anvil Guard's visor, the Smelter's
  eye plate); eyes stay flush with the face (the user turned down eyes that stick out).
- **Surfaces glow through colour, not emission:** an emission texture on a body surface renders the whole cube white (seen on the
  Golem's cracks and the Cinder Hound's crust), so a hot surface uses bright seams in its albedo and a looping effect for heat.
- **Faces centred, expressions by slant (Set 3):** a face that is the unit's whole identity (a mouth, a sucker, a spider's eyes)
  sits in the middle of the face plate, not leaned to the camera side. Angry reads by slant: lids or brows low in the middle (a V);
  the opposite slant reads worried.
- **Textures that work and don't (Set 3):** a vein net (cellular noise, the cell edges dark, with matching bumps) reads on any
  colour, matte or glossy. Ribs or bands from a gradient texture in triplanar projection did not read (the user dropped them):
  stripes need real geometry or a texture made for the cube's faces.
- **Drool, legs and other hanging parts stop above the body's bottom** (the cube stands on the floor); bent legs are two tubes
  (thigh and shin, each a three-point curve) with a ball at the knee.
- **Beats in step:** a shader pulse runs on the layer's own clock (`time` since the effect started, never wrapped by
  `loop_period`), so pulses keep a fixed ratio by their speeds (the Mother Heart once a second, the twin hearts at half that) and
  are in phase when their effects start together, as the units of one battle do. An effect started later (a revive, a quality
  change) beats out of phase; a shared clock would be a change to the VFX system.

**Review (user, 2026-11-13; memory `live-preview-window`):** set by set in a live window the user closes. First an A/B room with
every unit **facing the camera** (to see the faces), with a **Turn** button that turns the cubes to their battle facing and back
(the review tools' `lineup`, outside the repo; user, Set 2); then each iteration shown with **only the units under discussion**; finally
**one demo fight** facing the party as in battle, with the party moving first so no enemy acts. Rejected files are deleted with the
user's OK when the set is approved; a code review runs before each set's PR.

### Set P: the party (7)
| Unit | Colour | A | B |
|---|---|---|---|
| Ranger | forest green | Feathered cap: a peaked hunter's cap (extruded side outline) with a long red feather (tube) | A pulled-up hood (lathe cowl) |
| Bulwark | khaki brass | Great helm: a flat-topped bucket helm with a cross-shaped eye slit, brass | Horned helm: a round helm with two short horns (`devil_horn` reused, ivory) |
| Cryomancer | ice blue | Frost crown: tall uneven ice shards (prism ring), pale cyan, faint glow | A frosted hood with an icicle fringe |
| Pyromancer | orange-red | A floating flame above the head (teardrop lathe, emissive, `BOB`), like the Cleric's halo | A pointed hood whose tip burns (emissive cone) |
| Ember Knight | coral red | Visored sallet with a flame plume (emissive tubes on the crest) | Kettle helm (Warrior's, reused) with an ember plume; risks reading as the Warrior |
| Plaguewright | acid green | Plague-doctor beak mask on the front face (long cone, leather brown, two round lenses) | Wide-brimmed plague hat (lathe), dark leather |
| Shatterweaver | rose | A ring of glass shards orbiting the head (prism ring, glass pink, `SPIN`) | A crystal tiara (still, low) |

Cryomancer and Shatterweaver both use crystals: the Cryomancer's stand still and upright in a crown; the Shatterweaver's are loose
and turn.

**Picked (Set P, approved 2026-11-13, PR #34):** Ranger: a pointed green cap (the wizard-hat shape) with a red bobble on its tip.
Bulwark: B, the horns swept back and up. Cryomancer: A, plus a frost ring on the floor. Pyromancer: B, plus the fire ring.
Ember Knight: neither; a welding mask with head flames, plus a fire ring rising from the floor. Plaguewright: A (the beak straight
and level), plus a green bubble ring. Shatterweaver: seven gem shards orbiting the body evenly, plus pink floor cracks pulsing light
to dark. Round 2 classes gained floor effects too: Cleric (now a white body) a holy glow with rising motes, Arcanist a ring of runes
(new shader `rune_glyphs`), Bard a golden glow.

### Set 1: Cellar and Crypt (6)
| Unit | Colour | A | B |
|---|---|---|---|
| Slime | green | **Surface:** gooey: glossy (low roughness, clearcoat), strong rim, a light subsurface tint (user's note) | The same, really see-through (see the catch below) |
| Bog Toad | olive | **Surface:** spotted and slimy: dark cellular spots on the colour, wet low roughness (user's example) | A throat sac on the front (sphere, pale) |
| Frost Wisp | pale cyan | **Surface:** frosted glow: emission in its own colour, strong rim | A wispy tail curling up from the back (tapered tube, emissive, `BOB`) |
| Shaman | orchid | Held totem staff: a crooked staff topped with a small skull and two feathers | A feathered headdress (ring of feather shapes) |
| Rat King (boss) | brown | A long knotted rat tail from the back (tube, pink); tells it apart from the Golem's identical brown | A crooked, tilted crown (`crown` reused, tarnished bronze) |
| Bone Warden (boss) | bone white | Curling ram horns (new curled-tube horn, ivory) | A ribcage on the front (a row of curved tubes) |

**The Slime's catch:** `mark_stencil()` skips alpha-transparent materials (`TRANSPARENCY_ALPHA` is not in the opaque pass), so a
see-through Slime would lose "draw over own unit" effects and use the plain depth test. A keeps it opaque and fakes the goo with
gloss, rim and subsurface. B (real transparency) needs either dithered alpha (`TRANSPARENCY_ALPHA_HASH`, opaque pass, stampable;
grainy) or a change to the stencil system, proposed on its own. A wobble (squash) cannot go on `Body.scale` (animations key it):
it would be a new motion or a vertex shader, not in this sheet.
**Decided (user, 2026-11-13):** after trying A, the user chose real transparency without a stencil change: the plain depth test is
fine for a see-through body (see the design approach above).

**Picked (Set 1, approved 2026-11-13, PR #35):** Slime: see-through goo (`goo_clear`, 45% opaque) with the green bubble ring.
Bog Toad: warty spotted skin, bulging eyes with slit pupils turned toward the battle camera, a spotted throat sac and a mlem with a
black line. Frost Wisp: frosted glass (`frost_clear`, 55%) with drifting motes (`wisp_motes`), no tail. Shaman: A and B (staff and
headdress). Rat King: a tail along its side, a straight bronze crown and a mouse muzzle with dark whiskers. Bone Warden: neither;
a longhorn skull on its face and a crown of bone spikes.

### Set 2: Forge (5)
| Unit | Colour | A | B |
|---|---|---|---|
| Cinder Hound | orange | Dog ears (`pointed_ear` reused, charcoal) | **Surface:** ember crust: dark plates with a faint orange glow in the seams (kept dim: the Golem's glowing cracks washed the cube white) |
| Smelter | rust orange | Held ladle: a long handle with a bowl of glowing metal (emissive) | A chimney on the back |
| Anvil Guard | iron grey | An anvil on its head (extruded anvil outline, dark iron) | A held smith's hammer |
| Forgemaster (boss) | firebrick | Held great forge hammer (box head, long handle, iron) | A welding visor on the front |
| Brass Colossus (boss) | brass gold | A big gear on the back, turning (torus + ring of teeth, `SPIN`) | **Surface:** riveted brass plates (like the Golem's stone, metal plates) |

**Picked (Set 2, approved 2026-11-13):** Cinder Hound: B, the ember crust (`ember_crust`: dark plates with bright orange seams in
the colour) with charcoal ears, a snout, ember eyes and rising embers (`cinder_embers`). Smelter: A and B together, a ladle of
molten metal held clear of the body, a chimney with smoke (`chimney_smoke`) and a furnace-mouth face with slit eyes on a dark plate.
Anvil Guard: A and B together, an anvil on its head (horn toward the party), a smith's hammer and a visor with glowing slits.
Forgemaster: B, the great forge hammer and smith's goggles, with a handlebar moustache in place of the first proposal's beard.
Brass Colossus: B (`riveted_brass` plates, steam pipes, porthole eyes) with A's brass gear turning on the camera side.

### Set 3: Hollow (6)
| Unit | Colour | A | B |
|---|---|---|---|
| Gutter Maw | moss green | A jaw on the front face: two rows of teeth (cone rings), ivory | A wide lower lip and tongue |
| Leech | dark red | A round sucker mouth on the front (torus with a ring of tiny teeth) | **Surface:** glossy, banded (stripes) |
| Vein Weaver | crimson | Spider legs: four bent legs a side (tubes, mirrored) | **Surface:** a red vein network |
| Left Heart (boss) | red | Arteries from the top: two or three thick curved tubes (one shape for all three hearts) | **Surface:** veined flesh |
| Right Heart (boss) | royal blue | The same arteries, tinted blue | The same surface, blue |
| Mother Heart (boss) | magenta | The arteries, larger and more of them (ring copies) | The arteries and a pulse |

A heartbeat (a `PULSE` motion: a scale beat on the attachment) would need a fourth `UnitAttachment.Motion`; not in the sheet unless
asked.

**Picked (Set 3, approved 2026-11-13):** Gutter Maw: A, reworked: a centred mouth with gums and uneven teeth with two fangs, two
strands of drool ending above the floor, angry yellow slit eyes under heavy green lids slanting down to the middle (no brows).
Leech: a big sucker centred on the face (a fleshy lip and two rings of teeth) on glossy dark veins (`leech_veins`); the banded and
ribbed skins were dropped. Vein Weaver: A's spider legs (four a side, thigh, knee and shin) with eight eyes and two fangs, centred,
on B's vein net (`vein_net`). Left and Right Heart: B, the arteries tinted red or blue on veined flesh (`heart_flesh`), with a floor
glow beating in their colour (`heart_pulse`, `speed` 0.5). Mother Heart: B, five arteries arching out round a central aorta on the
same flesh, beating in magenta twice as fast (`speed` 1). The beat is the floor glow; no `PULSE` motion was built.

### Set 4: Cathedral and Vault (6)
| Unit | Colour | A | B |
|---|---|---|---|
| Choir Seraph | cream white | Feathered wings (new extruded outline with a scalloped edge, mirrored, `FLAP`); the bat wing stays the Bat's | Two pairs of small wings |
| Penitent Knight | slate | A crown of thorns (torus with a ring of thorn cones, dark wood) | A held censer on a chain |
| Hallowed Judge (boss) | white | Held balance scales (a bar, two pans on chains, gold) | A tall mitre (extruded outline, gold trim) |
| Gilded Mimic | gold | A chest lid on top, open, with a row of teeth; the lid chomps (`FLAP` around its hinge) | A tongue out of the front |
| Vault Sentry | steel blue | One large lens eye on the front (rim cylinder + glowing ice-blue sphere; it drains Ice) | A held halberd |
| The Collector (boss) | dark gold | A loot sack on the back (lathe sack, a few coins on top) | A monocle on the front |

**Picked (Set 4, approved 2026-11-13):** Choir Seraph: B, two pairs of small feathered wings (scalloped extruded outlines, each
pair flapping at its own speed), with a singing face (closed eyes, a round open mouth, blush) and soft light drifting down
(`seraph_down`). Penitent Knight: A and B, the crown of thorns, a linen blindfold with two matching blood stains where the eyes are,
each with a drip, and a brass censer swinging front to back on its chain. (Replaced with Set 4b: no religious symbols, a spiked iron band and a swinging iron lantern; see below.) Hallowed Judge: A and B, the gold balance scales (beam
along the facing), a barrister's curled wig, the mitre on top of it (its gold cross removed with Set 4b) and stern gold eyes under a V of grey brows. Gilded Mimic: B, a
chest (iron straps and a lock on the face), the lid open about 60° and chomping on its hinge (`FLAP` on a pivot turned so its axis
is the hinge), a row of teeth on the lid and on the front edge, eyes glowing inside and a centred tongue. Vault Sentry: B, the lens
eye, a halberd (blade along the facing) and a steel crest (the crest symmetric front to back). The Collector: B, a monocle with its chain, a
squint and a centred grin with a gold tooth, gold coins orbiting slowly (`SPIN`) with a gold effect (`gold_hoard`: sparks rising from a floor ring, coins raining down and
glints; it replaced the first `coin_glints` in Set 5 when the user asked for more gold on a final boss), and a plum top
hat with a gold band and a coin resting on it, upright (the user's addition).

**More enemies (user, 2026-11-13):** 3 new enemies (an elite and two regulars) for each of the Cathedral, Vault, Coven and Void,
so each of those floors has 6 counting its boss. New enemies are content, so they have their own slice and spec (`route-enemies`),
which also holds their looks as two sets, 4b (Cathedral, Vault) and 5b (Coven, Void).

### Set 5: Coven and Void (6)
| Unit | Colour | A | B |
|---|---|---|---|
| Cultist | purple | A deep pointed hood (lathe cowl) | A held ritual dagger |
| Bound Demon | dark red | Chains: two links of chain wrapped around the body (torus rings) and a broken shackle | Big curled horns (a new curled-horn shape, black; the Bone Warden's ram horns were dropped in Set 1); risks reading as the Imp |
| High Witch (boss) | indigo | A wide-brimmed witch hat with a buckle, much larger than the Arcanist's | A crescent moon floating behind the head (extruded outline, `BOB`) |
| Void Wraith | midnight blue | A tattered shroud from the base (jagged extruded skirt, `BOB`) | Two glowing eyes (`glow_eye` reused) |
| Abyssal Hulk | black | Two glowing violet eyes (`glow_eye` reused): on a black cube the eyes carry it | A row of spikes down the back |
| The Nameless (boss) | dark teal | A void halo: a dark ring tilted behind the head, a faint violet glow, slowly turning (`SPIN`) | **Surface:** a starfield (dark, sparse emissive specks) |

**Picked (Set 5, approved 2026-11-13):** Cultist: A and B, the deep robe hood (a square peak, drapes and a rim round a shadowed face
with glowing pink eyes) and the ritual dagger held on the camera side (its first wavy outline failed to triangulate and was
replaced by a leaf blade). Bound Demon: A and B, two slanted bands of chain with a broken shackle, big curled black horns and an
angry ember face with fangs. High Witch: A, the big witch hat (bent tip, green band, gold buckle), green eyes, a hooked nose and a
grin, with green motes (`hex_motes`). Void Wraith: B, a see-through violet body (`void_clear`, 50%) with hollow glowing eyes and
rising wisps (`void_wisps`). Abyssal Hulk: renamed **Guardian** (display name only; the id `demo.enemy.abyssal_hulk` stays; `build_full_descent.gd` writes the
new name too; the only content-root change of the roll-out, so it changes the ruleset version: re-export the full build for the
dev stack's verifier): the
Nameless's B proposal, retuned to stand apart: a blue starfield (`starfield` under a blue colour override), a cyan void slit and a
smaller, still cyan ring behind the head. The Nameless: C (a second iteration), a starfield body, a black-hole face (a black
disc in a glowing accretion ring with beads, turning on its own axle) and seven dark shards orbiting, with dark smoke rising from
the floor and violet embers (`void_smoke`, the user's ask for a final boss). Rejected: the hoodless chanting face, the Hulk's
faces and spikes, the crescent moon, the shroud, the turning void halo and the slit.

### Set 4b: Cathedral and Vault, the route enemies (6; spec `route-enemies` 3.1, 3.2)
Built with the lessons of Sets 1-5 from the start: every unit has a centred face, A and B share their parts so a mix is one
step, and the two elites (`Enemy.Rank.Elite`) are more ornate than the regulars and get a looping effect of their own.
| Unit | Colour | A | B |
|---|---|---|---|
| Bell Ringer | tan | A bronze bell hanging from a wooden yoke on its head, swinging (`FLAP`), and a monk's face: wide eyes, a round open "dong" mouth | A brown monk's cowl and a hand bell held on the camera side (clapper showing), the same face |
| Candle Acolyte | cream | A crown of three candles with wax drips and glowing flames, serene closed eyes, warm motes rising (`votive_glow`) | A pale hood with a red trim and a brass candlestick held on the camera side, the same face and motes |
| Glass Saint (elite) | pale cyan | **Surface:** stained glass (`stained_glass`: coloured panes in dark lead lines, glossy, opaque), a halo of glass shards behind the head, a serene face with glowing eyes, prismatic glints (`prism_glints`) | **Surface:** clear glass (`saint_clear`, see-through 50%) with a gold rose-window halo (ring, spokes, coloured panes), the same face and glints |
| Tally Clerk | tan | A green accountant's eyeshade, round spectacles over a pursed mouth, a quill behind the ear | A wooden abacus held on the camera side (rows of coloured beads), the same spectacles and mouth |
| Vault Gargoyle | slate grey | **Surface:** stone (`stone`, tinted), folded stone wings (a jagged outline, mirrored, still), two short horns, glowing eyes under a stone brow (its Stone Gaze) | The stone surface, a rain-spout face: a gaping mouth with fangs, curled horns, the same glowing eyes |
| Hoard Drake (elite) | gold | A drake's head on the cube: swept-back horns, a snout with nostrils and fangs, slit eyes, a row of back spines and small wings flapping slowly, embers rising (`drake_embers`) | **Surface:** gold scales (`gold_scales`), the same horns and face, a tail along its side and a heap of coins round its base, the same embers |

### Set 5b: Coven and Void, the route enemies (6; spec `route-enemies` 3.4, 3.5)
| Unit | Colour | A | B |
|---|---|---|---|
| Hex Doll | orchid | A voodoo doll's face: two mismatched button eyes (one a stitched X), a stitched mouth; three pins with coloured heads in its top | **Surface:** burlap (`burlap`), stitched seams down the edges and a yarn tuft on top, the same face |
| Coven Familiar | dark slate blue | A black cat: ears, glowing green slit eyes, a pink nose and whiskers, a tail curling up from its side; icy omen motes (`omen_motes`) | A raven: a beak, a feather crest and small black wings flapping, the same eyes and motes |
| Hag Sister (elite) | olive | A ragged shawl hood (no hat, so she reads apart from the High Witch) with grey hair strands, one bulging eye and one squint, a warty hooked nose and a crooked grin; green brew steam (`brew_steam`) | The same face and hood with a gnarled staff held on the camera side, a little cauldron hanging from it; the same steam |
| Null Moth | lavender | Two pairs of moth wings (rounded outlines with eye spots, `FLAP`), feathery antennae, big dark compound eyes | A fluffy fur collar, the same antennae and eyes, pale dust drifting down (`moth_dust`) |
| Hollow Echo | slate grey | A hollow ivory mask on its face (empty dark eye holes, a wailing mouth) and two faint echo rings round the body, tilted, turning (`SPIN`) | A see-through grey body (`echo_clear`, 50%) with the mask, and ripples drifting outward (`echo_ripples`) |
| Void Devourer (elite) | dark teal | A giant round maw over the face (two rings of teeth round a black void with a teal glow inside), a row of small glowing eyes above it, tendrils curling from its sides | A vertical split maw (teeth on both lips, the teal glow), spikes along the top, motes pulled inward into it (`devour_pull`, negative radial acceleration) |

**Picked (Sets 4b and 5b, approved 2026-11-13):** Bell Ringer A (the bell swinging front to back under its yoke). Candle Acolyte
A. Glass Saint B (see-through `saint_clear`, the rose window, `prism_glints`). Tally Clerk A and B (the eyeshade with its quill and
the abacus). Vault Gargoyle A. Hoard Drake A (`drake_embers`). Hex Doll A. Coven Familiar A (its tail starts off the back face
and stays behind the body until it is past its side; `omen_motes`). Hag Sister B (the staff with its cauldron, `brew_steam`). Null
Moth A, its wings at 95% of the first proposal. Hollow Echo A. Void Devourer A, its tendrils at 85% (`devour_pull`). Not used:
the B props and surfaces of the other units (`stained_glass`, `gold_scales`, `burlap`, `echo_clear`, `moth_dust`, `echo_ripples`).

**No unit intersects its neighbours (user, 2026-11-13):** enemy lanes are 2.2 apart and rows 1.8, so every look keeps its
footprint (body, attachments at every point of their motion) within 0.9 of the unit's centre to the sides and front to back.
Measured on every enemy at its battle facing (the review tools' `overlap` command, exact mesh vertices sampled over the motion);
the Null Moth's wings, the Devourer's tendrils and the Bat's wings (1.4 to 1.1) were scaled down to fit. The Vein Weaver's legs
reach 0.91, accepted.

**No religious symbols (user, 2026-11-13):** the Penitent Knight lost its crown of thorns and censer: a rusted iron band with
sixteen outward spikes (a spiked collar, not an upright crown) and a swinging iron lantern, the blood-stained blindfold kept
(an iron cage helm with a ball and chain was the other proposal). The Hallowed Judge's mitre lost its gold cross (bands kept).

### Party pass: faces and held items (user, 2026-11-13)
After the enemy sets the party looked plain next to the enemies, which all have faces. The user chose **faces for every class**
(the Ember Knight and Plaguewright keep their masks) and, for the first time, **held items** for the party (the earlier rule
"the party never holds items" is lifted; not every class holds one). Faces are symmetric about the middle (the eye highlights are
mirrored, each toward the outside). Items sit on the **Right** socket: facing +90, the party's own right is the side the battle
camera sees (the enemies' camera side is their Left).

**Picked:** Warrior B (heavy angry brows, gritted teeth) with a sword; Cleric B (amber eyes, soft gold brows, a smile) with a sun
staff; Arcanist A (round spectacles, an "o" mouth) with a closed leather tome (an open book at its side did not make sense);
Bard A (happy closed eyes, an open smile, blush) with a lute; Ranger D2 (round eyes, thin high brows, freckles, a small smile;
its first faces read like the Bulwark's) with a bow; Bulwark A (stern eyes under a heavy brow) with a round shield; Cryomancer A
(glowing ice eyes) with an ice staff; Pyromancer A (glowing ember eyes, gritted teeth) and Shatterweaver A (pink gem eyes), both
empty-handed. Files: `face_<class>_<pick>.tres` and `item_*.tres` in `presentation/demo/style/attachments/`.

### Floor-1 refresh (user, 2026-11-13)
The round-2 enemies looked plain next to the later sets. The user asked for fangs on the Bat and a second look at the first
floor's enemies; the Bat, Fire Imp, Knight and Golem (the ones still on their round-2 looks) got faces and one more detail each,
and the user picked B for all four: **Bat** red eyes, a pug nose, two fangs and big pointed ears (wings kept); **Fire Imp**
yellow slit eyes under a V of brows and a fanged grin, with a devil tail (horns kept); **Knight** a great-helm visor with a glowing
cross slit and a red plume, the sword kept and the kite shield moved off the face to its Right; **Golem** amber eyes under a stone
brow, a glowing crack of a mouth, and moss with two mushrooms on top (the rock surface kept). The Imp's tail is scaled to 70% so it stays clear
of the row behind. Files: `bat_face`, `bat_ear`, `imp_face`, `knight_visor`, `knight_plume`, `golem_face`, `golem_moss` (enemy faces
are named by unit, without the party's `_<pick>` suffix).

### Sets 2-5 and what the roll-out needed so far
- Sets 3-5 above are first proposals. They are built under the design approach above, so expect faces, effects and combined
  details to be added while iterating.
- System code the roll-out added: `UnitAttachment.spin_axis` (3.3, Set 2), `UnitLook.effect` / `effect_params` (3.2), the `rune_glyphs` shader, see-through bodies keeping
  their alpha in the death fade, a `speed` parameter on `fx.heart_pulse` (Set 3); nothing for Sets 4 and 5 (data only: new effects and surfaces; a dark particle
  effect uses the particle layer's existing `additive = false`). Still only if picked: a body wobble.
- Q3 (the props) is answered below for keys and armor; items wait for their own slice.

### Set K: pickups on the floor (user, 2026-11-13)
Today every pickup is a small cube with a `Label3D` (`presentation/demo/room_view_3d.gd` `_prop`): items gold, armor silver, events
cyan "?". **A key for sale shows as a gold cube named "?"** (the shop slot's id is neither an item nor equipment). In this slice:
| Prop | A | B |
|---|---|---|
| Key (shop slot, and a key drop if it shows on the floor) | A key (ring + shaft + bit, extruded outline, gold metal), turning slowly (`SPIN`), labelled "Key" with its price | The golden key's look tinted brass |
| Armor, one icon per slot | A simple 3D icon floating and turning, by the piece's `Equipment.Slot.*` tag: **Head** a helm, **Body** a breastplate, **Arms** a gauntlet, **Legs** greaves/a boot, **Accessory** a ring with a gem, **Weapon** a sword (`sword` reused); `BOB` + `SPIN` | One floating loot bag for every piece (Dark Souls style), the slot shown by its label only |
| Chest (wooden, gilded) | Three states of one shape: **closed**, **open and filled** (the lid up, a glow and the reward showing), **open and empty** (the lid up, dark inside); the gilded chest tinted gold with metal bands | One closed chest and one open chest, no filled state |

**Armor in its rarity's hue (user, 2026-11-13):** every armor icon is tinted by the piece's `Item.Rarity.*` tag (all 33 demo pieces
have one), with the UI's rarity colours (`ui_theme.tres`: Common light grey, Rare blue, Epic violet, Legendary amber) kept in one
rarity → colour map in `StyleRegistry`. Like the Dark Souls pickups (references in `H:\assets\references\ds-items\`), the icon
glows softly in that hue with a few sparkles (an `FxDefinition` with a `color` parameter, reused for every rarity). It also gets
the floor items' **rarity outline** (roadmap 5b2, references `H:\assets\references\ror\`): a silhouette outline in the rarity
colour (likely an inverted-hull `next_pass` material; props are not units, so no stencil stamp is needed), built here once and
reused by the item cards.

**Chests (user, 2026-11-13):** a chest is never in a room today: a drop goes to the chest inventory (spec `keys-and-gear`) and is
opened from the menu. The user wants chests on the floor, opened where they lie: a rule change (run state, hash, the logged
`open_chest`, the bots), so it is its own slice (roadmap 5a5 `floor-chests`, right after this one; a chest works like a shop). This slice only draws the three chest states, ready
for it.

The content's slots are Weapon, Head, Body, Arms, Legs and Accessory (there is no Feet slot: a boot stands for Legs). The icons are
`AttachmentShape`s too, picked by a slot-tag → shape map in `StyleRegistry` (GAS-first: the tag the piece already has). Items stay
as today until slice 5b2 `item-cards` (floating cards on the floor, after `card-ui`). Event "?" props stay as they are.

**No props during a fight (user, 2026-11-13; fixed the same day):** an event or room that starts a battle kept its props on the
stage (the event's cyan "?" cube sat in the middle of the fight). `RoomView3D` hides its props when a battle starts; the rebuild
after the battle shows what the room holds then, so a reward appears only after the fight.

## 6b. Open items
- **Battle camera hides the faces (user, 2026-11-13, Set 3 demo fight):** the battle camera looks down at the units from the side,
  so the face details this roll-out adds are hard to see. Ideas: push both sides closer to their own walls (the Bat's wings
  would then clip into the walls), a rotatable camera, or a bigger room. Left for a later slice (with the camera modes, memory
  `camera-modes-later`).
- **Fog and effects (found in the 2026-11-13 playtest):** the Crypt and Coven moods had fog, and Godot's fog tinted the
  transparent parts of every effect quad, so effects showed as pale boxes. The fog was removed from both moods. Fog can come
  back once the effect materials opt out of it (`render_mode fog_disabled` in the effect shaders, `disable_fog` on the
  particles' draw materials): a change to the VFX system (spec `vfx-framework`), to be proposed on its own.

## 7. Open questions for the user
All answered (user, 2026-11-13):
- **Q1** Round 3's models: **dropped.** Primitives only: every detail is primitive data (3.3), so the import tool, the model packs
  and `style_pack_uncredited` (3.5 (b), 3.7, 3.8) are not built in this slice.
- **Q2** Credits: **`CREDITS.md` in the repo and a small Credits entry on the Settings screen.**
- **Q3** Props: keys, armor and chests in this slice (6a Set K); items in 5b2 `item-cards`; event "?" props unchanged.
