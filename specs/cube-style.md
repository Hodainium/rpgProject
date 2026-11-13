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
`AttachmentMesh.corner_slab(size, bevel)` through `StageRig.floor_mesh(size)`, swapped on a battle restyle like the walls. Every mood bevels by default (0.06, the preview's), so the
registry file is unchanged. Validator: `style_wall_bevel_invalid` (a mood's bevel outside 0..0.25). Shots:
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

## 6b. Open items
- **Fog and effects (found in the 2026-11-13 playtest):** the Crypt and Coven moods had fog, and Godot's fog tinted the
  transparent parts of every effect quad, so effects showed as pale boxes. The fog was removed from both moods. Fog can come
  back once the effect materials opt out of it (`render_mode fog_disabled` in the effect shaders, `disable_fog` on the
  particles' draw materials): a change to the VFX system (spec `vfx-framework`), to be proposed on its own.

## 7. Open questions for the user
- **Q1** Round 3's models: which ones from Poly Pizza (CC0 preferred; CC-BY needs a CREDITS line per author)?
- **Q2** In-game credits: a small "Credits" entry in Settings, or the repo and README only? (CC0 needs none; it matters once
  game-icons arrive in 5b.)
- **Q3** The props (pedestal items, shop slots, the event "?") are small cubes too: include them in the roll-out rounds, or leave
  them for 5b, where items get their card icons?
