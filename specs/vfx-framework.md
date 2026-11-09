# Spec: vfx-framework (slice 5a, before 5b `card-ui`)

Status: **decisions F1-F7 settled; awaiting final review** · Date: 2026-11-09 · Roadmap: new slice 5a, between 5 `card-collection` and
5b `card-ui` (the roadmap entry is added when this spec is approved).
Model: Unreal's **Niagara system assets** (reusable effects with exposed, tunable user parameters) triggered from
**GameplayCues** (Lyra's `GameplayCueNotify` pattern). Builds on `specs/gameplay-messages.md` (the bus effects can
listen to), `specs/ui-framework.md` (UI-space effects live inside screens), `specs/animation-sets.md` (the 3D
battle views), `specs/dev-tools.md` (console parity: every tool has a command usable headless).

## 1. Purpose & enterprise mapping

**Purpose.** The game has no visual effects: its presentation is the cube unit view, UI windows, sounds and one hit
cue (`Cue.Sfx.Hit`, a sound only). This slice adds an **extensible, data-driven effects layer** so that new effects
are authored as resources, not code, and so that Claude can create and test them headless:

1. **`FxDefinition`**: a resource (the Niagara System equivalent). It lists **layers** (particles, shader quad, mesh
   flash, light, sound, screen shake/punch, camera/UI tween, sub-FX with a delay) and a set of **exposed parameters**
   (`color`, `scale`, `intensity`, `duration`, `rate`, ...), each with type, default and range. Layers bind their own
   properties to the parameters, so one "glow burst" serves every rarity by passing a different `color`.
2. **`FxManager`** (autoload) spawns a definition with a parameter dictionary at an anchor (a 3D node or position, a UI
   `Control`, or the screen), pools instances, and frees them when every layer has finished. Looping effects (an aura)
   return a handle that can be updated (`set_param`) and stopped (`stop`, fading out).
3. **Cue bridge.** A GodotGAS cue entry can name an `FxDefinition` and parameter bindings (from the cue payload or
   tags) instead of a hand-made scene. Existing scene cues (the hit cue) keep working unchanged.
4. **Shader library** (`presentation/demo/fx/shaders/`): rarity glow, foil shimmer, dissolve, outline, radial burst,
   rays, vignette flash, each with documented uniforms that `FxDefinition` layers set as parameters.
5. **Dev tooling:** console `fx play <id> [key=value ...]`, `fx list`, `fx params <id>`, `fx stop`, an inspector
   preview in the `rpg_dev` dock (a Play button on an `FxDefinition`), a content-validator pass, and a headless smoke
   runner so Claude can verify an effect without a window.
6. **Proof effects** that slice 5b consumes: `glow_pulse` (looping rarity aura), `burst_flash`, `card_flip_flash`,
   `pack_burst`, `legendary_rays`, `screen_shake`; and a small combat set that proves the 3D path: `hit_spark`
   (wired to the existing `Cue.Sfx.Hit` entry as an additional effect), `heal_glow`, `break_shatter`.

**2D, 3D and hybrid are equal first-class targets (user, 2026-11-09).** Effects must work in the 2D menus, in the 3D
battles and rooms, and in **hybrid screens**: Hearthstone's collection and pack opening are a 3D stage (card and pack
meshes that tilt toward the cursor, flip, catch light, burst) behind 2D chrome (filters, buttons, counters). So the
framework has an **`FxStage`**: a `SubViewport` + `Camera3D` + light rig that a `Control` screen embeds
(`SubViewportContainer`, transparent background), with its own 3D world root where card meshes live. FX anchor to a
card mesh inside the stage exactly as they anchor to a unit cube in a battle, and a 2D layer (flash, vignette, rays)
can sit over the stage in the same effect. A single `FxDefinition` may mix 3D and 2D layers (a pack burst: 3D
particles and mesh flash on the pack, a 2D screen flash and shake over everything).

**Presentation only.** FX never touch combat or run state, are never in a state hash or a snapshot, are never
uploaded, and `combat/` never references them (combat code stays headless-clean). Replays, the verifier worker and
every golden are unaffected. FX are skipped entirely when the process is headless (no rendering), except through the
smoke runner (section 6), which checks the data and the lifecycle without drawing.

**Enterprise mapping: none at runtime.** Client-only; no endpoint, queue, broker, cache or database. (Server-side
asset delivery, hot-patching effects or remote tuning are out of scope; effects ship in the pack.)

Out of scope: a node-graph FX editor (the inspector edits the resources, per the "lean on Godot tooling" decision),
GPU custom simulation stages beyond what Godot's `shader_type particles` offers (authors can write one and assign it
to a particle layer), attractor/collision fields, ribbon/mesh-trail renderers beyond Godot's built-in particle trails,
post-process stack (bloom, color grading) as a framework feature (the WorldEnvironment is set per scene by the user),
the final card art, and any card screen (slice 5b).

## 2. Sequence flow

N/A as a client-to-server flow (no server involvement). Client-side flow:

```
spawn (any caller):   var h := FxManager.play(&"fx.glow_burst", FxAnchor.control(card_node), {color = rarity_color})
  1. FxManager looks the id up in the FxCatalog (built at startup from res://presentation/**/fx/*.tres + res://game/dev/content
     fx; an unknown id is a warning and returns an inert handle, never an error that stops play)
  2. params = definition defaults, overridden by the caller's dictionary; unknown keys warn; values are clamped to each
     parameter's range and type-checked
  3. instance = pool.acquire(definition) (a Node with one child per layer, built once per definition and reused)
  4. each layer.apply(instance, params, anchor) copies parameters into its node (particle amount/lifetime/color ramp,
     shader uniforms, light energy, shake strength, tween targets) through the layer's bindings
  5. the instance is parented under the anchor's host: a 3D world root, the Control itself (UI), or the FxManager's
     screen layer (CanvasLayer); play() starts every layer (a layer may have a start delay)
  6. one-shot: when the longest layer finishes (particles' lifetime + delay, tween end, sound end) FxManager emits
     finished(handle) and returns the instance to the pool; looping: stays until handle.stop(fade)
  7. anchor freed early (a card scene closed mid-effect): the instance is released at once, never leaks
```

```
cue bridge:           GodotGAS applies an effect with application_cue_tags = [&"Cue.Fx.HitSpark"]
  cue registry entry (scene cue, as today)  → unchanged
  cue registry entry with fx = FxDefinition → FxCueNotify (a GameplayCueNotify subclass, pooled by GodotGAS) calls
        FxManager.play(definition, anchor = the cue target's view, params from entry.bindings)
        bindings: {param: "payload.<key>" | "tag:<Tag.Prefix>=<value map>" | literal}, for example color from the
        damage type tag (Damage.Type.Fire → orange).
        end_cue() stops a looping handle with the layer's fade; one-shot cues finish through the FxManager signal
```

```
messages:             an FxListener resource (optional) maps a Message.* channel to an FxDefinition and an anchor
                      rule, so a screen can say "when Message.Run.LevelUp, play fx.level_up at the party strip"
                      without code; it registers on the GameplayMessages bus and goes away with its node
```

```
dev / Claude:         console `fx play fx.glow_burst color=#ff9a00 scale=1.5` (local mode and dev builds only, like the
                      other commands); headless `game/tools/fx_smoke.tscn -- --all | --id <id> [--param k=v]` loads
                      each definition, validates it, instantiates it, runs a short scripted clock and reports JSON
```

## 3. Data contracts

**Server contracts: N/A** (no DTOs, queues, topics or Redis keys). The contracts are Godot resources, in
`game/fx/` (system code), with the proof set in `presentation/demo/fx/` (user-owned, new files only, listed after the
build).

### 3.1 Resources

```gdscript
class_name FxParam extends Resource            # one exposed, tunable parameter
@export var name: StringName                   # "color", "scale", "intensity", "duration", "rate", custom ones
@export var type: FxParam.Kind                 # FLOAT, INT, BOOL, COLOR, VECTOR2, VECTOR3, TEXTURE, CURVE, GRADIENT
@export var default: Variant
@export var min: float; @export var max: float # FLOAT/INT/VECTOR clamp (ignored by others)
@export var description: String                # shown by `fx params`, the validator and the inspector

class_name FxBinding extends Resource          # a layer property driven by a parameter
@export var property: String                   # NodePath-style on the layer's node, e.g. "process_material:color" or
                                               #  "material:shader_parameter/glow_color"
@export var param: StringName                  # which FxParam feeds it
@export var scale: float = 1.0                 # value = param * scale + offset (floats/vectors)
@export var offset: float = 0.0
@export var curve: Curve                       # optional remap of a normalized param

class_name FxLayer extends Resource            # base; each kind is a script subclass (new kinds = new small script)
@export var id: StringName
@export var start_delay: float = 0.0
@export var duration: float = -1.0             # -1 = the layer's natural length (particle lifetime, sound length)
@export var loop: bool = false
@export var bindings: Array[FxBinding]
@export var min_quality: FxLayer.Quality = LOW # lowest tier it plays at: LOW, MEDIUM, HIGH (OFF plays nothing)
func build(host: Node) -> Node                 # create the node once (pooled)
func apply(node: Node, params: Dictionary, anchor: FxAnchor) -> void
func start(node: Node) -> void; func stop(node: Node, fade: float) -> void
func length(params: Dictionary) -> float       # for the manager's lifetime; INF when looping

# Layer kinds in this slice:
FxParticles2DLayer / FxParticles3DLayer   # GPUParticles2D/3D wrapping a ParticleProcessMaterial (or a custom shader)
FxShaderQuadLayer                         # a ColorRect/TextureRect (UI) or MeshInstance3D quad with a ShaderMaterial, animated uniforms (a `timeline` Curve per uniform)
FxMeshFlashLayer                          # tint/emission pulse on the anchor's mesh (the unit cube) with restore
FxLightLayer                              # OmniLight3D / PointLight2D pulse
FxSoundLayer                              # AudioStreamPlayer(2D/3D) with pitch/volume randomisation (uses the sound board's bus)
FxShakeLayer                              # camera shake (3D), or a UI shake/punch-scale on the anchor Control
FxTweenLayer                              # tween any property of the anchor (scale punch, modulate, position) with an ease Curve
FxSubFxLayer                              # plays another FxDefinition after a delay, with a param map

class_name FxDefinition extends Resource       # the asset: what artists author and what ids point to
@export var id: StringName                     # "fx.glow_burst" (unique; the validator checks)
@export var display_name: String
@export var params: Array[FxParam]
@export var layers: Array[FxLayer]
@export var space: FxDefinition.Space          # WORLD_3D, UI, SCREEN, HYBRID (HYBRID: layers pick their own space;
                                               #  each layer declares FxLayer.space and resolves its host from the anchor:
                                               #  a 3D layer on a stage anchor goes into the stage's world root, a 2D layer
                                               #  into the stage container's overlay; WORLD_3D/UI definitions are single-space)
@export var pool_size: int = 4                 # instances pre-built / kept
@export var max_instances: int = 16            # beyond this, the oldest is recycled (a spam guard)
@export var tags: Array[StringName]            # asset tags, e.g. Fx.Kind.Burst (search/filters)
```

### 3.2 Runtime API

```gdscript
FxManager.play(def_or_id, anchor: FxAnchor, params := {}) -> FxHandle
FxManager.catalog() -> Array[StringName]
FxAnchor.node3d(n) / .position3d(v) / .control(c) / .screen() / .unit(unit_id)   # unit → the room view's cube
FxAnchor.stage(stage: FxStage, node3d)   # a 3D node inside a hybrid screen's stage (a card or pack mesh)
FxStage (Control, script in game/fx/): a SubViewportContainer with a transparent SubViewport, Camera3D, light rig,
        world_root: Node3D, overlay: Control (2D layers over the stage); `FxManager` resolves HYBRID layers through it
FxHandle: set_param(name, value) (updates bindings live), stop(fade := 0.2), is_playing(), signal finished
```

`FxManager` reads the quality level from the Settings (`fx_quality`: off / low / medium / high). `off` makes `play` return an
inert handle; tiers are `off / low / medium / high`: a layer plays only when its `min_quality` is at or below the setting.

### 3.3 Cue bridge

`GameplayCueEntry` is a vendored GodotGAS resource we do not edit. The bridge is our own `FxCueEntry` /
`FxCueNotify`: an `FxCueNotify` scene (extends `GameplayCueNotify`, in `game/fx/`) with `@export var fx: FxDefinition`
and `@export var bindings: Array[FxCueBinding]`; the registry entry points its `scene` at an `FxCueNotify` scene. So
the registry format is untouched and no addon patch is needed. (If pooling by GodotGAS proves incompatible with a
looping aura, the notify falls back to its own `end_cue()` handling; decided in the build, noted in the sync.)

### 3.4 Settings and tags

New Settings key `fx_quality` (default `high`) and the tags `Cue.Fx.*` (effect cues), `Fx.Kind.*` in
the tag registry (the user's `godot_gas/` is edited through the dashboard format and checked by `sync_tags.tscn`;
Claude proposes the tag list, the user approves, as for all registry changes).

## 4. Failure modes

Presentation-only, so no idempotency, retries or dead letters.

| Failure | Behaviour | Test |
|---|---|---|
| Unknown effect id, missing resource | warning in the log, inert handle returned, play continues | `test_unknown_id_is_inert` |
| Unknown or ill-typed parameter | warning once per (effect, param), clamped or ignored, default used | `test_param_validation` |
| Anchor freed mid-effect | instance released at once, no leak, no error | `test_anchor_freed_releases` |
| Spam (hits in one frame) | `max_instances` recycles the oldest; frame cost stays bounded | `test_max_instances_recycles` |
| Pool exhausted | new instance built, pool grows to `pool_size`, extras freed on finish | `test_pool_reuse` |
| Looping handle never stopped (screen closed) | `FxManager` releases handles whose anchor left the tree; a run end or scene change calls `stop_all` | `test_stop_all_on_scene_change` |
| Headless process | `play` is a no-op that still returns a handle; combat/replay/verifier unaffected | `test_headless_is_noop`, the full existing suite staying green |
| Bad definition (duplicate id, binding to a missing param or node property, layer wants a 3D anchor in a UI effect) | content validator error (`fx_*`), never a runtime crash | `test_validator_fx_rules` + broken fixtures |
| Effect changes game state | impossible by construction: layers touch only their own nodes and the anchor's visual properties (`modulate`, `scale`, material overrides), restored on finish | `test_anchor_visuals_restored`, `test_fx_not_in_hash` |
| Determinism | FX never draw from the run or battle streams; a random layer uses its own non-seeded `RandomNumberGenerator`; goldens and the run hash unchanged | the golden suite unchanged |

Root `CLAUDE.md` acceptance scenarios (1-7): **none covered or affected** (client presentation only). The check that
the framework cannot disturb them is that all existing goldens, the replay and step runners, and the e2e scenarios
pass unchanged.

## 5. Observability

N/A for Prometheus (client-only; the game exports no metrics). Client-side dev observability instead:
- `fx stats` console command: live instances, pool sizes, plays per second, recycled count, per-definition play counts
  (an in-memory counter, shown in dev builds).
- Optional `Message.Dev.Fx` messages (`messages on Message.Dev.Fx`) for each play and finish with the effect id and
  params, in dev builds only.
- A warning budget: unknown id/param warnings are logged once each, and the test runner fails a test on any script or
  engine error as it already does.

## 6. Test plan

Godot system tests (`tests/game/test_fx.gd`, runs under `tools/godot_tests.sh`), using in-memory fixtures in
`tests/fixtures/fx/` (frozen, never reference `presentation/`):

1. **Definition and params:** defaults applied; caller overrides applied; clamping; wrong type rejected; unknown key warns once.
2. **Bindings:** a color param reaches a shader uniform and a particle color ramp; scale/offset/curve remap; `set_param`
   updates a live handle.
3. **Layers:** each kind builds, applies, starts and finishes on a scripted clock (no real time): particle lifetime,
   tween end, sound length, delay ordering, sub-FX after delay, loop until stop with fade.
4. **Manager:** pooling reuse, `max_instances` recycle, `stop_all`, anchor freed, each quality tier (`off`/`low`/`medium`/`high`) keeping only layers at or below it, headless no-op.
5. **Hybrid stage:** an `FxStage` with a card mesh; a HYBRID effect puts its 3D layers in the stage's world root and its
   2D layers in the overlay; the stage freed mid-effect releases everything; two stages on screen do not mix layers.
5b. **Anchors:** 3D node/position, UI control (instance parented under the Control and freed with it), screen layer,
   unit anchor (the room view's cube by unit id).
6. **Cue bridge:** an `FxCueNotify` scene registered under a tag plays the effect when GodotGAS applies a test effect
   with that cue tag; the hit cue's scene entry still plays its sound (regression); bindings map a damage-type tag to a color.
7. **Listener:** `FxListener` reacts to a bus message and detaches with its node.
8. **Validator:** `fx_duplicate_id`, `fx_param_missing`, `fx_binding_invalid`, `fx_space_mismatch`, `fx_layer_unknown`
   against `tests/broken_fixtures/fx/`; the shipped set validates clean.
9. **Safety:** state hash, run hash and battle trace identical with FX on and off (a scripted battle replayed twice);
   anchors' visual properties restored after finish.
10. **Dev tools:** `fx list|play|params|stop|stats` through the headless script runner (`dev_run`), JSON output;
    `fx_smoke.tscn --all` loads and exercises every shipped definition with no script errors.
11. **Shaders:** every shader in `presentation/demo/fx/shaders/` compiles (loaded and set on a material in the test),
    and its documented uniforms exist (a parser check on the `.gdshader` header comment against the `uniform` lines).

No golden vectors (no deterministic simulation output). Visual correctness is checked by the user in-game and by
screenshots Claude takes of a one-shot **FX gallery scene** (`game/dev/fx_gallery.tscn`, local/dev only: a grid of
buttons that play each effect on a card mock and on a cube), saved to `H:\claudeOutShots\<date> vfx\` per the
show-files rule; the 3D and UI paths each get a screenshot before the slice is called done.

Dependencies and ownership. System code: `game/fx/`, `game/dev/commands/fx_*.gd`, tests, the gallery. User-owned
files created by the build (new files only, listed with every value picked afterwards): `presentation/demo/fx/`
(shaders, the proof `FxDefinition`s, the `FxCueNotify` scene for the hit spark), plus the proposed `Cue.Fx.*` /
`Fx.*` tags and one entry added to `godot_gas/cue_registry.tres` (existing file: shown as `old → new` and
approved first, per the design-ownership rule).

## 7. Decisions (all decided by the user, 2026-11-09)

- **F1. Own thin layer on Godot's particles and shaders, no third-party addon.** Decided. A search of the ecosystem
  found no industry-standard Godot equivalent of Niagara (only 2D burst nodes, a paid particle-shader generator, an
  external Effekseer runtime and effect packs). The gdquest MIT VFX assets and shaders are reference material only. The user also allowed (2026-11-09) pulling open-source repositories online to study how
  effects are made: licenses checked (MIT/CC0 preferred), our own versions written, anything adapted credited.
- **F2. Authoring in the inspector on resources, no custom graph editor.** Decided. Extending the framework (a custom
  inspector plugin, reusable modules, a graph view) is a later slice, once real use shows what hurts.
- **F3. Cue bridge through our own `FxCueNotify` (extends GodotGAS `GameplayCueNotify`),** so every GAS mechanism that
  triggers a cue can trigger an FX: instant effects (hit, heal), duration effects (a looping aura for a status, faded
  out through `end_cue()` when it ends), abilities and items (they name a cue tag), with the payload and the target's
  tags bound to FX parameters. No change to the vendored registry or add-on. Decided.
- **F4. Quality tiers: `off / low / medium / high`** (Unreal's Niagara scalability has Low / Medium / High / Epic /
  Cinematic with per-effect culling; this is the same idea at four levels). Each layer declares the lowest tier it plays
  at (`FxLayer.min_quality`, replaces the `Fx.Quality.High` tag idea), the Settings key `fx_quality` defaults to
  `high`. Decided; sections 3.2, 3.4 and the tests follow it (a tier test per level).
- **F5. This slice ships the proof set, then a follow-up sub-slice adds FX to existing content.** Decided.
  - *Here (5a):* the framework plus a proof set that exercises every layer kind, every anchor and the stage: card/UI
    (rarity glow aura, hover glow, card flip flash, pack burst, legendary rays, screen shake) and combat (hit spark per
    damage type, heal glow, break shatter), and the shader library (rarity glow, foil shimmer, dissolve, outline,
    rays, radial burst, vignette flash). The cue bridge is proven on the existing `Cue.Sfx.Hit` entry.
  - *Follow-up, roadmap 5a2 `vfx-content-pass`:* adding FX to the abilities, statuses, items and events made before
    the framework existed (the dust, craft, crit, weakness, death, buff/debuff, ult and level-up effects, a
    `Cue.Fx.*` tag and cue entry per status and ability role), proposed by a pass tool like `build_role_pass` and
    approved by the user, since it edits existing content. It can fold into 5a if the proof set lands quickly and the
    user asks.
  - Card-specific tuning (glow colors per rarity, the pack-opening choreography) belongs to 5b, which only authors data.
- **F6. 2D, 3D and hybrid** are all supported from the first slice. Decided.
- **F7. `FxStage` (SubViewport) is part of this slice,** because the Hearthstone-style card screens are 3D under 2D
  chrome. The card meshes, flip animation and pack models are slice 5b. Decided.
