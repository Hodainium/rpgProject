# Stencil over own unit: the technique (Godot 4.7.2)

**What this is.** A reference for drawing an effect over *its own* character, and only that one, with Godot's stencil buffer. It is
written so the technique can be reused in another project. The record of how it was decided (claims tested, hypotheses, measurements,
user decisions) is the slice spec, `specs/vfx-stencil.md`. The code lives in `client-godot/game/fx/` and `game/view/`.

Everything below was checked on **Godot 4.7.2-stable (official)**, Forward+ (D3D12, Vulkan), Mobile and Compatibility, on an NVIDIA
RTX 5080. Godot marks the stencil API experimental: re-run the claim probe (section 7) after any engine upgrade.

## 1. The problem and the idea

An effect on a character is usually a camera-facing quad or particles centred *inside* the character's mesh. With a normal depth test
the character's own mesh cuts the effect in half. The usual fix is a depth bias (Unreal's Pixel Depth Offset): the depth test sees the
effect closer to the camera. But then it also shows through anything standing within the bias in front of it, such as another
character in a tight formation.

**The idea (Unreal's Custom Depth-Stencil, as Lyra uses it):**
1. Every character writes its own small number into the stencil buffer where it is drawn: its *stamp*.
2. An effect on that character is drawn in two passes:
   - **OWN:** only where the stencil holds that character's number, with **no depth test**, so it covers its own character;
   - **OTHER:** everywhere else, with the **normal depth test**, so anything really in front hides it.

Result: the effect covers its own character, and every other character, wall and the floor hides it at any distance. There is no
bias to tune.

Measured: with a character standing 0.05 in front of another, the bias let the back character's glow light **270 of the front
character's 6,430 pixels**. Stencil lit **6**, the antialiased edge pixels of the front character's own floor ring. GPU time per
frame was the same, 0.22 ms.

## 2. Engine facts it rests on (tested, not taken from the docs)

| # | Fact on 4.7.2 | Consequence |
|---|---|---|
| K1 | A material that **writes** stencil stays in the **opaque** pass. The docs say otherwise; the engine source agrees with the test. Stencil is applied in the colour pass, not the depth prepass. | Characters stay opaque: they keep shadows, SSAO and the depth prepass, and they are in the depth texture. Stamping changed no pixel of a frame with no effects. |
| K2 | A material that **reads** stencil must be in the **transparent** pass (alpha blend, or `depth_draw_never` / `depth_test_disabled`). An opaque reader draws nothing and logs an error. | Effects are transparent anyway. They draw after every opaque character, so the stamp is always there before they test it. |
| K3 | The stencil members are marked experimental. | Keep all stencil code in one include and one helper class (section 4), and re-run the probe on upgrade. |
| K4 | No shader can *sample* stencil (there is no hint for it). A `CompositorEffect` *can* attach the scene's depth-stencil buffer, stencil-test against it and copy the stamps into a texture of its own. | Option for later: one-pass effects, outlines and silhouettes read a stamp texture (section 8, option E). |
| K5 | In a shader, the stencil reference is a **compile-time literal**: `stencil_mode read, compare_equal, 5;`. A `const` or a `uniform` is refused; a `#define` works, because the preprocessor turns it into a literal. `BaseMaterial3D` has `stencil_reference` as a setting; `ShaderMaterial` has none. | A shader effect needs **one compiled copy per stamp value and per pass** (section 4). |
| K6 | There are no read or write masks: a pixel holds one whole byte. The parser also accepts any word that only *begins* with a mode name (`write_foo` silently counts as `write`). | Share the byte by **ranges** (section 3), and validate stencil words exactly (section 6). |
| K7 | `write` stamps where the depth test passes; `write_depth_fail` stamps where it fails. | A character hidden behind a wall does not stamp the hidden pixels (on Forward+, thanks to its depth prepass). |

## 3. The value table: ranges, by battle position

One byte, no masks, so every feature gets a range of values, and nothing writes a raw number. The table lives in
`game/view/stencil_ids.gd`:

| Range | Use |
|---|---|
| 0 | Nothing (the cleared value) |
| 1–4 | Party positions P1–P4 |
| 5–24 | Enemy positions by slot (slot n → 4 + n) |
| 25–31 | Characters added mid-battle |
| 32–63, 64–127, 248–254 | Reserved: marked props (silhouettes), target highlights, objects outlines skip (Lyra's 123 case) |
| 255 | Dev probes |

**Values belong to positions, not to characters.** P2 is always 2. So the set of shader copies is fixed and known before any battle,
and it can be compiled ahead of time (section 5).

Watch out: Godot's own Outline and X-Ray material presets write stencil with a reference that defaults to **1**, which collides with
P1. The validator refuses any content material using the unit range (section 6).

## 4. The pieces

### 4.1 Stamping a character
`UnitAnimator.mark_stencil(material) -> Material`. The view's paint passes each material through it.
- An opaque-pass `BaseMaterial3D` (opaque, alpha scissor, alpha hash) gets a **copy** stamped with: `stencil_mode = CUSTOM`,
  `stencil_flags = WRITE`, `stencil_compare = ALWAYS`, `stencil_reference = <value>`. Nothing else changes; the material stays opaque.
  It's a copy so that a material shared by several characters never carries another character's number.
- A **blending** material (alpha, depth pre-pass) is not stamped. It draws in the transparent pass, together with the effects, so its
  stamp could land after an effect has tested. It writes no depth either, so the plain depth test is right for effects on it.
- **Stamped or not** (`effect_stencil_value()`): the *latest* paint decides, so a character that fades out and comes back solid is
  stamped again. An unstamped character gives its effects value 0.

### 4.2 Shader copies, without writing files
The stencil lines are written **once**, inside `#ifdef` blocks in the shared include that every effect shader already uses,
`game/fx/shaders/fx_stencil_depth.gdshaderinc`:

```glsl
#ifdef FX_STENCIL_REF
stencil_mode read, FX_STENCIL_COMPARE, FX_STENCIL_REF;
#endif
#ifdef FX_STENCIL_OWN
render_mode depth_test_disabled;
#endif
```

**A copy** (`FxStencilShaders.variant(shader, value, pass)`) is a `Shader` made in memory: a few `#define` lines followed by the
original code.

```
#define FX_STENCIL_REF 5
#define FX_STENCIL_COMPARE compare_equal      // OWN; compare_not_equal for OTHER
#define FX_STENCIL_OWN                        // OWN only
<the original shader code>
```

- **The file on disk, with no defines, is the plain one-pass shader.** The editor, the gallery and the validator load it, and so does
  any effect with no character.
- Copies are cached per (shader, value, pass) and rebuilt when the shader's code changes (a hot reload).
- Defines placed before `shader_type` reach an `#include` (tested).
- Only a shader that `#include`s this file goes two-pass (`FxStencilShaders.supports`). Any other would draw its whole effect twice.

### 4.3 The material with a stencil setting
`FxStencilMaterial extends ShaderMaterial`, with `base_shader` and `stencil_unit`. Setting `stencil_unit` feels like
`stencil_reference` on `StandardMaterial3D`:
- **0:** the base shader, one pass, exactly a plain `ShaderMaterial`.
- **A value:** the material's shader becomes the OTHER copy, and the OWN copy is added as its `next_pass`. Parameter values carry over
  the swap.

### 4.4 Keeping the two passes in step (the parameter copy)
**Why it is needed.** Effects animate their uniforms through bindings and curve tracks. The engine writes those through a property
path (`material:shader_parameter/x`) on the *first* material only, and a script cannot intercept that write. The OWN pass is a
second `ShaderMaterial`, so nothing updates it.

**What is done.** `FxStencilMaterial.sync_own_pass()` copies the first pass's uniform values to the OWN pass.
- **Which uniforms:** the shader's uniform list, read once per shader code (`FxStencilShaders.uniform_names`; a script-side cache,
  because `get_shader_uniform_list()` goes through the RenderingServer and allocates).
- **Skipped:** engine-filled samplers such as `fx_scene_depth` (`hint_depth_texture`).
- **Also mirrored:** `render_priority`, so both halves sort the same against other transparents.
- **When it runs:**
  - on every swap (a new `stencil_unit`, an edited base shader);
  - on `apply` (each play) and `reset` (back to the pool), so a pooled effect never starts with the last play's values;
  - **on every tick of a live over-unit layer** (`FxLayer.follow_stencil`), after bindings and tracks have written.

**What it costs.** For each live two-pass effect, each tick: N reads and N writes, N being about 10–15 uniforms. No frame-time cost
showed with a handful of effects. The load grows with live effects × uniforms, and it is CPU and render-thread work, not GPU.

**Making it cheaper (not done; ranked).** The full table with trade-offs is in `specs/vfx-stencil.md`, "Open: the per-tick parameter
copy".
- **A, copy only the animated uniforms.** Each layer knows the uniforms its bindings and tracks write; the tick copies only those
  (about 3–5), and a full copy runs on apply, rebind, a parameter change and reset. The cheap first step.
- **B, copy only what changed.** Still reads everything; the smallest gain.
- **C, write through at the source.** Bindings and tracks write both passes, so nothing is copied per tick. Exact, but it touches the
  effects framework's core, and every writer must use it.
- **D, instance uniforms.** A node's `instance uniform` values apply to every material and pass it draws, so there is nothing to copy.
  Cleanest at runtime, but a large change, with Godot's limits (16 per shader, no samplers); the probe must first confirm they reach
  a `next_pass` and particles.
- **E, one pass.** Read a stamp texture (K4) instead of having an OWN pass. No second material at all, and the base for outlines too,
  but a project of its own, and not available on Compatibility.

Measure before choosing: many looping effects on 8 characters, CPU frame time with `fx stencil on` against `off`.

### 4.5 Which layers draw over their character (`over_own_unit`: AUTO / ON / OFF)
| Layer | AUTO means | Why |
|---|---|---|
| Camera-facing quad | Over its character | A glow centred in the body |
| Flat quad (a ring, a crack on the floor) | Plain depth test, and no soft fade | Its back half must stay behind the legs; fading against the floor it lies on would dim it |
| Particles (generated draw material) | Over its character **only when born on its mesh surface** (`emit_from_mesh`) | Rings, orbits (stun stars) and sparks flying behind must stay behind the body |
| Mesh (a rock, a spike, a shield) | Plain depth test | A solid object; set ON for a see-through shell (its shader must use the include) |

A live effect follows its character every tick: if the switch, or the character's stamp, changes while it loops (a fade-out, a
revive), it swaps to one pass or back.

### 4.6 How an effect knows its character
- The anchor carries the character's value (`FxAnchor.stencil_value`), read from the view when the effect is placed and re-read every
  tick (`live_stencil_value`).
- A caller can mark another character with the reserved effect parameter `stencil_unit`: a beam starting on its caster draws over the
  caster. A forced value carries into sub-effects.
- A stage anchor (a separate 3D world) takes no value, because that world's characters are not stamped.

### 4.7 Depth fade
The include's `fx_depth_fade` is classic soft particles: alpha fades over `depth_fade` world units before the scene, so a big disc
leaning into the floor fades out instead of ending in a hard line. In the OWN pass it is 1, full strength over the effect's own
character. Particle shaders guard their own soft fade the same way: `#ifndef FX_STENCIL_OWN`.

## 5. Compile cost and prepare

Each copy is a new pipeline: the first draw of a copy compiles it. Measured cold, that was **about 18 ms a copy**, and Godot's own
shader cache does **not** remove it. With the driver's pipeline cache warm it was **about 2 ms**.

**Prepare before any battle** (`FxService.prepare_stencil(camera, values, per_frame, label)`). Because values follow positions, the
whole set is known at boot: `StencilIds.values_for(largest encounter)` × the shaders that over-unit layers of the effect registry
draw with (`FxLayer.stencil_shader()`) × 2 passes. It runs three times, each skipping what an earlier one drew:
1. **Boot** (`GameMain.load_content`): in the background on the main menu, 2 copies a batch, so no frame stalls.
2. **Run start** (`GameMain.start_run`): whatever boot has not finished (a player who starts a run at once), 8 a batch.
3. **Battle start** (`RoomView3D`): the battle's own positions, the safety net. Normally nothing is left.

- **How:** each copy is drawn once as a speck in front of the room view's own camera (it exists from boot, so the pipelines match
  the battle's), for two frames. A particle shader is drawn through a one-particle emitter, because particles draw instanced.
- **Remembered:** copies drawn, or being drawn by another prepare, are skipped; a copy only counts once really drawn.
- **Measured:** boot drew 84 copies in 575 ms. In the first battle, the worst frame while 7 effects played was 15 ms. Before this,
  the battle-start prepare alone was 60 copies, 117 ms warm and about 1 s cold, as a freeze when the battle appeared.
- **Measuring a first launch:** set the environment variable `RPG_FX_SALT` to a new word. Every copy then gets a comment line, so
  Godot's shader cache sees new code. The preprocessor strips comments, so the GPU driver's own cache may stay warm.
- **Porting:** prepare at the earliest point a 3D camera of the same viewport exists, spread over frames. A hidden viewport only
  helps if its render target matches the game's (buffer formats, MSAA), so verify by measuring.

## 6. Guard rails (validator, tests, dev switch)
- **Validator** (`game/dev/fx_validator.gd`):
  - `fx_stencil_include_missing`: a layer set to draw over its character whose shader lacks the include;
  - `fx_stencil_mode_unknown`: a `stencil_mode` word that is not exactly a mode, a compare, a number or an `FX_STENCIL_*` define (K6);
  - `fx_stencil_value_taken`: a content material or shader writing a unit value (Outline and X-Ray default to 1).
- **Tests:** `client-godot/tests/game/test_vfx_stencil.gd` (25 tests, headless). What needs a GPU is covered by the probes (section 7).
- **Dev switch:** console `fx stencil on|off|dump`. Off is one pass with the plain depth test, for debugging, or for a renderer that
  ever lacks stencil. `dump` lists each view's value, stamped or not, and the last prepare.

## 7. Probes to re-run on a new engine version or project
- **`game/tools/fx_stencil_probe.tscn -- --out <dir>`** (windowed): tests K1, K2, K4, K5, K6 and K7 on small scenes, reads pixels and
  the engine's messages, and writes `findings.json` plus one PNG per scene. Add `--rendering-driver vulkan` or
  `--rendering-method mobile|gl_compatibility` for the other back ends. K3 (experimental) is checked in the engine's
  `doc/classes/BaseMaterial3D.xml` at the tag you run.
- **`game/dev/fx_stencil_stage.tscn -- --compare <dir> [--frames n]`** (windowed): the leak scene (two characters 0.05 apart, a wall,
  a floor ring, a big disc), off against stencil. It reports the front character's lit pixels, the own character lit or cut, behind
  the wall, the ring's back half, flicker, stamping changes nothing, GPU time, and prepare time and copies. Freeze animation while
  measuring: an idle bob reads as a leak.

## 8. Porting checklist (another Godot project)
1. **Pin the engine version, and run the claim probe first.** Every fact in section 2 can change in a minor version.
2. **Copy** `StencilIds` (adjust the ranges to your game), `FxStencilShaders`, `FxStencilMaterial` and the include's stencil and
   fade blocks.
3. **Stamp** every character material through a `mark_stencil` equivalent: an opaque-pass `BaseMaterial3D` gets a stamped copy.
   Shader-material characters need their own include with `stencil_mode write, compare_always, FX_STENCIL_WRITE;` behind a define
   (not built here).
4. **Make effect shaders** `#include` the stencil include and stay transparent (K2).
5. **Use `FxStencilMaterial`** for effect materials, set `stencil_unit` from the effect's anchor, and call `sync_own_pass()` after
   your animation system writes uniforms (or pick option A, C or D from 4.4).
6. **Prepare the copies** for the values a scene uses before it shows (section 5).
7. **Add the three validator rules,** and refuse the unit range for Godot's Outline and X-Ray presets.

## 9. Known limits
- **Floor decals on characters standing *on* the floor** z-fight with the floor. The old bias lifted them; with stencil they need a
  small physical lift. The demo's cube characters float 0.1 above the floor, so it does not show today.
- **Mobile and Compatibility have no depth prepass,** so a wall drawn *after* the character it hides (opaque sort by object centre)
  could leave the character's stamp under the wall, and the OWN pass would draw over the wall. Untested; Forward+ cannot hit it.
- **A view with several materials:** the last one painted decides whether it counts as stamped.
- **The OWN pass draws over its whole character,** including parts in front of the effect: an arm raised in front of a body glow.
  This is inherent to the technique; set a layer OFF where it matters.
- **AMD and Intel GPUs** are not tested.
