# Spec: `vfx-stencil` (slice 5a3), an experiment

Status: built (2026-11-11, PR #22); stencil kept and on by default. This spec is the record of the experiment that led there, in
order. **For how the technique works (to reuse it), read `specs/design/stencil-over-own-unit.md`.**
Roadmap entry: `specs/roadmap.md`, "5a3. `vfx-stencil`" (from `playtest-fixes` B14).
Builds on `vfx-framework` (5a) and `vfx-content-pass` (5a2). Presentation only.

## 1. Purpose & enterprise mapping

### 1.1 The problem
Today a depth bias (Unreal's Pixel Depth Offset, set to the unit's radius, in `game/fx/shaders/fx_stencil_depth.gdshaderinc`) keeps an
effect from being cut by its own unit's mesh. The cost is a leak: an effect on the back unit shows through any unit standing less
than the bias in front of it. The bias also has to be tuned per effect.

### 1.2 The experiment
We try Godot's built-in stencil buffer (`stencil_mode`, Godot 4.5+, experimental). Each unit view stamps its own value. An effect
on a unit draws over the pixels that hold its unit's value, and everywhere else with the normal depth test and no bias.

What the experiment produces:
- answers to the hypotheses in 1.4;
- shots and measured costs;
- a decision by the user: keep stencil, keep it and tune it, or revert.

Until that decision, **bias stays the default** and nothing the content depends on changes (1.5).

The reference design is Unreal's Custom Depth-Stencil as Lyra uses it:
- one value per object, set as data;
- a named table of values (not Lyra's magic 123);
- readers that decide for themselves.

### 1.3 What we would gain
1. **No leak.** The front unit hides an effect on the back unit at any distance.
2. **Floor rings come out right.** A ring around a unit's feet stays behind its legs, and the front unit still covers it.
3. **No bias tuning for effects on units.**
4. **A base for later features.** Target highlights, outlines and silhouettes behind walls can use the same per-unit values. This
   only pays off if those features get built.

### 1.4 What is known and what the experiment must test

**Documented claims, also verified (user, 2026-11-11: anyone can post a PR, so documentation is a claim, not a fact).** The sources
are godot-docs PR #11373 (merged 2025-10-22), the 4.x class reference and the engineer-game.org devlog of 2026-02-08. Each claim is
tested on our pinned Godot 4.7.2 before anything is built on it. The design below assumes the claims hold. A claim that fails is
reported to the user, and the spec is updated before the build goes on.

| # | Claim | Test on 4.7.2 (in the probe, 3.7) |
|---|---|---|
| K1 | "Materials that write to the stencil buffer are always drawn in the transparent pass." So a unit that stamps becomes a transparent draw | A stamping cube and a plain opaque cube. A transparent reader quad samples `hint_screen_texture`, which is copied after the opaque pass. The plain cube shows in it and the stamping cube does not. Also the engine's own render info (`RenderingServer.get_rendering_info`, draw calls per pass where it is available) |
| K2 | Stencil reads work only in the transparent pass; an opaque reader fails | An opaque shader with `stencil_mode read, …`: note whether it compiles, whether the engine logs an error, and what it draws |
| K3 | Stencil support is experimental and the API may change in a minor version | `godot --doctool <dir> --headless` on our build: the class reference XML marks `stencil_*` members experimental or not |
| K4 | A compositor effect cannot copy the main renderer's stencil buffer to a texture. No shader reads the values; it only passes or fails a fixed comparison | Two parts: (1) a spatial shader that tries to sample stencil (no such hint is expected to exist); (2) a `CompositorEffect` at `POST_TRANSPARENT`, after the stamps (K1), that attaches the scene's depth-stencil buffer (`RenderSceneBuffersRD.get_depth_layer`, as in the MIT dmlary outline compositor) and draws a full-screen pass with a stencil test. If (2) works, the readable texture (the first draft's (b)) is possible after all. It is reported as an option for a later slice, not built in this one |
| K5 | In a shader the reference is a literal in the code (`stencil_mode read, compare_not_equal, 1`); `BaseMaterial3D` has `stencil_reference` (0–255) as a setting | Compile `stencil_mode` with a literal, then with a `const`, a `#define` and a uniform as the reference. Note which are accepted. Check that `stencil_reference` on a `StandardMaterial3D` changes what a reader sees. H2 below is the `ShaderMaterial` side |
| K6 | No read or write masks exist; a pixel holds one whole byte | Search the shader parser's accepted `stencil_mode` keywords (try mask-like tokens and note the errors), and list `BaseMaterial3D`'s stencil properties through `ClassDB.class_get_property_list` |
| K7 | A material writes its reference value where it passes the depth test (and `write_if_depth_fail` where it fails) | A stamping cube half behind a wall. A reader shows the value only on the visible half, and with `write_if_depth_fail` only on the hidden half |

The Unreal-style readable texture (the first draft's (b)) is dropped from this slice because of K4. It comes back only if K4's
second test shows otherwise.

**Hypotheses, each tested in the gallery (3.7):**

| # | Hypothesis | Why it matters |
|---|---|---|
| H1 | The leak is gone: an effect on the back cube does not show through the front cube at 0.3 apart | The reason for the slice |
| H2 | A `ShaderMaterial` can only take the reference as a literal in code (K5) | If false, there are no shader copies (3.4) |
| H3 | Stamped units still cast and receive shadows | A visible loss if false |
| H4 | Stamped units stay in the scene depth texture (K1 fails: they are opaque), so the soft fade works against a neighbouring unit too | Expected true after K1; still checked |
| H5 | Effects (transparent) always draw after the stamps (opaque), so an effect on its unit never flickers, with no `render_priority` rule | Expected true after K1; still checked |
| H6 | Stamped units keep SSAO, SSR, the depth prepass and shadows like any opaque mesh | Expected true after K1; still checked |
| H7 | Stencil works on Forward+ (D3D12, the project's renderer), and on Vulkan, Mobile and Compatibility | Portability; the shipped renderer comes first |
| H8 | The cost is small: GPU frame time with 8 units and 8 live effects, stencil vs bias, within 10% | Cost |
| H9 | All shader copies (each over-unit shader × 31 unit values × 2 passes) compile behind the run's loading screen in an acceptable time, and none compiles during a battle | Cost |

H4, H5 and H6 were written as fears while K1 was taken for a fact. K1 failed (1.4.1), so they are now expected to come out in our favour; part 2 still checks them.

**Order of work.** The K claims are tested first (the probe's part 1). They come out as a findings note added to this spec. The
design in section 3 is built only after that note, and is adjusted where a claim failed. The H hypotheses are tested on the built
design (the probe's part 2).

### 1.4.1 Findings, probe part 1 (2026-11-11)
Run on Godot 4.7.2-stable (official), Forward+, D3D12, an NVIDIA RTX 5080, MSAA off. The scenes are in
`game/tools/fx_stencil_probe.tscn` (+ `fx_stencil_probe_pass.gd`). The raw results and one PNG per scene are in
`H:\claudeOutShots\2026-11-11 vfx-stencil\probe1b\` (`findings.json`). Where a result went against the docs, the 4.7.2-stable
engine source was read to explain it.

| # | Verdict | Evidence |
|---|---|---|
| K1 | **Fails** | A stencil-writing `StandardMaterial3D` (Custom, Write, Always) **is** in the post-opaque screen copy, beside a plain opaque cube; only the transparent control is missing from it. The source agrees: the Forward+ and Mobile renderers move only **readers** to the alpha queue (`render_forward_clustered.cpp`: "Stencil materials which read from the stencil buffer must be in the alpha pass"), and `BaseMaterial3D` adds no transparency for a writer (`material.cpp`). Writers stay opaque. Stencil is applied in the colour pass only, not the depth prepass (`scene_shader_forward_clustered.cpp`, `use_stencil … PIPELINE_VERSION_COLOR_PASS`). A compositor at `POST_OPAQUE` already sees the stamp (K4). |
| K2 | **Holds** | An opaque reader draws nothing, and the engine logs "Attempting to use a shader that reads stencil but is not in the alpha queue. Ensure the material uses alpha blending or has depth_draw disabled or depth_test disabled." A transparent reader (`ALPHA = 1.0`) reads correctly. |
| K3 | **Holds** | Not a runtime fact. In the 4.7.2-stable source (`doc/classes/BaseMaterial3D.xml`), every `stencil_*` member carries `experimental="May be affected by future rendering pipeline changes."` Our build's own `--doctool` dump carries no experimental marks at all, so it cannot show this. |
| K4 | **Partly holds** | (1) No shader can sample stencil. `hint_stencil_texture` is rejected ("Expected valid type hint after ':'"), and the engine binary has only `hint_depth_texture`, `hint_screen_texture` and `hint_normal_roughness_texture`. (2) Against the docs: a `CompositorEffect` attaches the scene's depth buffer (it has a stencil aspect; data format 129), runs a stencil-tested pass at `POST_OPAQUE` and at `POST_TRANSPARENT`, and **copies the stamp into a texture of its own** (read back from the GPU: magenta exactly on the writer, black elsewhere). So the readable texture, the first draft's (b), **is possible** on this renderer and driver. |
| K5 | **Holds, with one extra form** | The reference is a compile-time literal. A `const` or a `uniform` is rejected ("Invalid stencil mode: 'REF'"). A `#define` works, because the preprocessor replaces it with a literal. `BaseMaterial3D.stencil_reference` is used: the writer stamped 7, a reader of 7 drew and a reader of 1 did not. `ShaderMaterial`, `Shader`, `Material`, `VisualShader` and `GeometryInstance3D` have no stencil property, so H2 is answered: one shader copy per value for shader materials. |
| K6 | **Holds** | `BaseMaterial3D` has no mask property, and a second number is rejected ("Duplicated stencil mode reference value"). Found on the way: the parser accepts any identifier that **begins with** a mode name (`shader_language.cpp`, `_parse_shader_mode`, `begins_with`), so `read_mask` passes as `read` and a typo such as `write_foo` is silently accepted as `write`. |
| K7 | **Holds** | `WRITE` stamps only the half of a cube that passes the depth test (the half behind a wall is not stamped). `WRITE_DEPTH_FAIL` stamps only the hidden half. |

**Follow-up checks (2026-11-11, run `probe1c-d3d12` and `probe1c-vulkan` in the same folder):**
- **Vulkan.** The whole probe was repeated with `--rendering-driver vulkan` beside D3D12. Every claim gives the same result on
  both drivers, down to the depth format (129).
- **Other GPUs.** AMD and Intel GPUs are **not tested**: there is only one GPU on this machine. They stay an open risk for H7,
  and the probe is ready to run on any machine.
- **Both kinds of writer stay opaque.** In K1, a `ShaderMaterial` with `stencil_mode write, compare_always, 1;` shows in the
  post-opaque copy just like the `StandardMaterial3D` writer.
- **Where the `#define` goes.**
  - A `#define FX_STENCIL_REF 7` works placed **before** `shader_type`.
  - It also reaches a `stencil_mode … FX_STENCIL_REF;` that sits inside an `#include` (`fx_stencil_probe_ref.gdshaderinc`).
  - Both compiled with no message and read the stamp. The copies exist only in memory, so `test_fx`, the validator and the
    gallery, which read the shader files on disk, never parse them.

**What changes in the design (agreed by the user 2026-11-11, applied to sections 2–6):**
1. **Units stay opaque (K1 fails).** The cost section's biggest item goes away:
   - no transparent-pass units;
   - units stay in the depth texture, so the soft fade works against units too (H4 is expected false, still checked);
   - SSAO, SSR, the depth prepass and shadows are unaffected (H3 and H6 are expected to hold, still checked).

   The `render_priority` and depth-drawing changes for units in 3.2 are dropped. Effects are transparent and draw after the
   opaque pass anyway, so they always see the stamp (H5 is expected to hold without priorities, still checked).
2. **A see-through unit still uses the fallback.** A blending material is drawn in the transparent pass, so its stamp could land
   after an effect has already tested (section 4).
3. **Shader copies by `#define` (K5).** A copy is the effect shader with the line `#define FX_STENCIL_REF <value>` (and the pass's
   modes) put before the code, and the shader's own `stencil_mode … FX_STENCIL_REF;`. No marker replacement and no code surgery.
4. **The validator checks `stencil_mode` words exactly (K6).** The engine accepts a misspelt mode as a valid one, so
   `fx_stencil_mode_unknown` (error) lists any word that is not exactly a mode name.
5. **Values by battle position, copies compiled while loading** (from the user's other review). The values already follow
   battle slots (P1–P4, then enemies by slot), so the set of copies is fixed: each over-unit shader × the unit range × 2
   passes. They are compiled once, behind the run's loading screen, not at each battle start.
   - A unit added mid-battle (none in the content today) takes a value reserved for added units, not "the next free value".
   - The table's unit range is split into fixed slots: party 1–4, enemy slots 5–24, added units 25–31.
6. **The readable texture is possible (K4).** It is still out of scope for this slice (spec 1.4). It goes into the report as an
   option for later outlines, highlights and silhouettes, after H7 shows how it behaves on Vulkan, Mobile and Compatibility.

### 1.5 Reversibility
- **One switch,** `fx_stencil`: `bias` (the default) or `stencil`. It is set in Settings ("Visual effects" section) and with the
  console's `fx stencil bias|stencil`. Turning it off restores today's rendering exactly.
- **Nothing that content depends on changes.**
  - The FX `.tres` files are not edited.
  - The bias code stays as it is.
  - The stencil code sits beside it, in its own files.
- **Two one-line changes to the user's files, both inert in `bias` mode:**
  - `presentation/demo/unit_view.gd` wraps the cube's material (3.2);
  - `room_view_3d.gd` hands out the values (3.1).

  Both need the user's OK.
- **Reverting** means either keeping the switch on `bias`, or deleting the files listed in 3.8 and the two one-line changes. The
  slice lives on its own branch (`feat/vfx-stencil`) until the user decides.
- **The bias is the A/B baseline, not a permanent fallback** (user, 2026-11-11). Whichever way the user decides, one of the two is
  deleted:
  - **stencil kept:** the bias code goes from the include, the layers and `FxService`. A value of 0 then means the plain depth
    test (3.5);
  - **stencil dropped:** the stencil code goes, and rendering is today's.

### 1.5.1 Build order: two steps (user, 2026-11-11)
**Step 1, the core.** The user decides on the report from this step.
- `StencilIds` (3.1).
- `UnitAnimator.stencil_value` and `mark_stencil`; `RoomView3D` and the cube line (3.2).
- `FxAnchor.stencil_value` (3.3; the `stencil_unit` effect parameter for callers comes in step 2).
- The include's define blocks and `FxStencilShaders` (3.4).
- **One layer kind** using them: `FxShaderQuadLayer` in 3D (the camera-facing glow, burst and rays quads).
- The mode as a static switch (`FxStencilShaders.mode`), the gallery's Stencil page and probe part 2: H1, H3–H6 and H8–H9 on
  the shots and timings.
- The step-1 tests in `test_vfx_stencil`.

**Step 1 as built (2026-11-11), with its differences from the text above** (raised with the user, not yet agreed):
- **The Stencil page is its own dev scene,** `game/dev/fx_stencil_stage.tscn`, opened from the gallery's "Stencil page" button. In
  a window, B and S switch bias and stencil. **Probe part 2 is its `-- --compare <dir> [--frames n]` mode,** not a second mode of
  `fx_stencil_probe.tscn`. It is built from the real pieces: `unit_view.tscn` cubes, `FxManager`, `FxAnchor.unit`.
- **`over_own_unit` is an enum, `AUTO / ON / OFF`,** not a bool: `AUTO` is the layer-kind default (camera-facing on, flat off).
- **`UnitAnimator.assign_stencil()`** takes the value from `unit_id` and the mode. The room view calls it (one line) instead of
  computing the value itself.
- **`UnitAnimator.effect_stencil_value()`** is what the anchor reads: the value only while the view's materials carry the stamp.
  A blending material, or one that is not a `BaseMaterial3D`, leaves the unit unstamped, and its effects keep today's bias
  instead of losing it (review fix).
- **`mark_stencil` stamps a copy of the material,** never the one passed in (a shared material would carry the wrong value), and
  alpha scissor and alpha hash count as opaque.
- **The leak scene stands P1 0.05 in front of E1, not 0.3.** The cubes are 0.8, so the bias is their radius, about 0.69. At 0.3
  the front cube's visible faces are already more than the bias closer to the camera than E1's centre, and no leak shows.
- **`FxStencilMaterial`** (user, 2026-11-11, from another review): the swap lives in a `ShaderMaterial` subclass with a
  `stencil_unit` setting, so using it feels like `stencil_reference` on `StandardMaterial3D`. It swaps in the cached copy, adds
  the OWN pass, keeps parameter values over the swap, gets fresh copies of an edited shader and keeps its uniform names per swap.
  Bindings write the material through the engine, so its owner calls `sync_own_pass()` after writing (the layer, every tick).
  Only a shader that includes `fx_stencil_depth.gdshaderinc` goes two-pass (`FxStencilShaders.supports`).
- **The probe freezes the units' idle animation** while it takes frames. The bob moved the cubes' edges a pixel between frames,
  and those edges read as leaks.

**Step 1 results (probe part 2, `H:\claudeOutShots\2026-11-11 vfx-stencil\step1g-*` and `step1h-d3d12`).** D3D12 and Vulkan on the
RTX 5080 give the same counts.

| Check | Bias | Stencil |
|---|---|---|
| H1: the front unit's pixels lit by the back unit's glow | 270 of 6430 | 6 (edge pixels of the front unit's own floor ring) |
| The effect over its own unit's visible face | lit | lit |
| Behind a wall; the ring's back half behind the front unit | hidden | hidden |
| H3/H6: stamping changes the frame (no effects; shadows, SSAO) | n/a | 0.0 mean change |
| H5: flicker over 60 frames | none | none |
| H8: GPU time, 4 live effects | 0.22 ms | 0.22 ms |
| H9: the first frame with new copies | n/a | 207 ms for 6 copies on a cold shader cache, 1–3 ms with Godot's disk cache |

**Seen in the shots:** big camera-facing glows end at the floor in stencil mode, a soft-edged dome. In bias mode their lower half
spreads over the floor and over floor rings. This is a look change for the user to judge (B14's big discs).

**Open for step 2 (review, 2026-11-11):** the OWN pass relies on the stamp alone (no depth test). Forward+ has a depth prepass,
so a unit hidden behind a wall never stamps the hidden pixels (K7, `behind_wall` in the stage). On a renderer without that
prepass (Mobile, Compatibility), opaque draw order decides: a wall drawn after the unit leaves the unit's stamp under it, and the
OWN pass would draw over the wall. H7 must test exactly this before stencil is turned on for those renderers.

**The decision (user, 2026-11-11): stencil is kept; step 2 goes ahead, with three choices.**
- **The switch is dev-only:** console `fx stencil on|off|dump`, and stencil is on by default. There is no player Setting. Off means
  the plain depth test (after the bias is gone), for debugging and for a renderer without stencil.
- **`prepare()` runs at battle start,** for the positions in that battle only (their values × the over-unit shaders × 2 passes).
  It is not the whole set at run start: there is no loading screen today.
  - **Changed (user, 2026-11-12, after a playtest hitch in the first battle):** prepare runs **at boot, at run start and at battle
    start**, each skipping what an earlier one drew. Since values follow positions, the whole set is known before any battle: the
    party positions plus the enemy slots of the content's largest encounter (`StencilIds.values_for`), × the over-unit shaders × 2.
    - **Boot:** `GameMain.load_content` draws them in the background on the main menu, 2 copies a batch so no frame stalls.
    - **Run start:** `GameMain.start_run` draws whatever boot has not finished, 8 a batch.
    - **Battle start:** `RoomView3D` remains the safety net.
    - All three draw through the room view's own camera, which exists from boot, so the pipelines match the battle's.
    - **Measured** (window, a Godot shader cache made cold with the dev salt `RPG_FX_SALT`): boot drew 84 copies in 575 ms; the
      run-start and battle-start prepares found nothing left. In the first battle, the worst frame while 7 effects played was
      15 ms; the worst menu frame afterwards was 14 ms.
    - **Caveat:** the salt is a comment, which the preprocessor strips, so the GPU driver's own cache may still have been warm. On a
      truly cold driver (about 35 ms a copy) the boot batches make frames of about 70 ms during the first seconds on the menu,
      first launch only.
- **The 45 effect files** in `presentation/demo/fx/` that bind `depth_bias` (327 lines) are stripped of it in a commit of their own
  (`design:`). That commit comes before the system code removes the bias, so no file binds a uniform that does not exist.

**Step 2 as built (2026-11-11), in four commits on `feat/vfx-stencil`:**
- **2a, stencil on by default:**
  - particles (their generated draw material; AUTO = over the unit only when born on its mesh surface, `emit_from_mesh`: the
    user's choice (a), 2026-11-11, so rings, orbits like stun stars and sparks flying behind keep the plain depth test) and mesh layers (a shader material whose shader includes the
    stencil lines; AUTO = not over the unit, ON for a shell) on `FxStencilMaterial`, through shared helpers on `FxLayer`;
  - the reserved `stencil_unit` effect parameter (no declaration needed);
  - `FxService.prepare_stencil(camera)` called by `RoomView3D` at battle start;
  - the three validator rules;
  - console `fx stencil on|off|dump`.
- **Design commit:** the 186 `depth_bias` blocks stripped from the 45 effect files (a one-off text patch with the user's OK).
- **2b, the bias removed:**
  - the include keeps only the stencil blocks and the classic soft fade;
  - the shaders write no `DEPTH`;
  - `FxService`, the quad layer's `flat_depth_bias`, the particle layer's `depth_bias` and the builders' bindings are gone;
  - the switch's off mode is the plain depth test.
- **The include is renamed** (user, 2026-11-11): `fx_depth_bias.gdshaderinc` → `fx_stencil_depth.gdshaderinc`, because it holds the
  stencil blocks and the depth fade and no bias. Every reference in this spec uses the new name; older specs (`playtest-fixes`,
  `vfx-content-pass`) keep the old one as history.

**Step 2 results** (`H:\claudeOutShots\2026-11-11 vfx-stencil\step2b-d3d12`, `h7-*`, `battle\`):
- **The real battle** (Warrior, Cleric, Pyromancer, Cryomancer against the Golem, the game camera, `dev_run --local` in a window):
  - all five units are stamped;
  - prepare drew 60 copies in 117 ms on a warm driver cache;
  - `on_*` / `off_*` shot pairs: a heal glow fills its cube with stencil on and is cut by the cube when off; Judgement's rays show
    over the Golem and fade into the floor.
- **Prepare in the Stencil page:** 48 copies in 830–880 ms on a cold Godot shader cache and a warm one alike (about 18 ms a
  copy). Godot's cache does not change it; the driver's pipeline cache does (the real battle above: 2 ms a copy).
- **H7:** every check passes on Forward+ (D3D12, Vulkan), Mobile (D3D12) and Compatibility (OpenGL 3.3): the glow over its own
  unit, the front unit clean, nothing behind the wall, the ring behind the front unit. Not covered: a wall drawn *after* the unit
  it hides (opaque order by object centre) on Mobile or Compatibility, which have no depth prepass. Forward+ cannot hit it.
- **Open:**
  - floor rings on units that stand **on** the floor (humanoids later) need a small lift: the old `flat_depth_bias` kept them out
    of the floor, and the cubes' Base socket is 0.1 above it;
  - a view with several materials (the last paint decides whether it counts as stamped);
  - the OWN pass copies every parameter each tick (the options are below; not fixed yet, user 2026-11-11);
  - the AMD and Intel GPUs.

**Open: the per-tick parameter copy, possible solutions (user, 2026-11-11: list them, do not fix yet).**

*The problem.* An effect drawn over its unit has two materials: the OTHER pass, which is the layer's material, and the OWN pass,
its `next_pass`. Bindings and curve tracks write only the first, through the engine (`material:shader_parameter/x`), and a script
cannot intercept that write. So `FxStencilMaterial.sync_own_pass()` copies every uniform, read and write, from the first to the
second on every tick of every live over-unit layer. Most of those values do not change. Step 2 measured no frame-time cost with a
handful of effects (0.22 ms GPU), but the cost grows with live effects × uniforms (about 10–15 per shader). The CPU and
render-thread work is the concern, not the GPU.

| # | Option | How it works | For | Against |
|---|---|---|---|---|
| A | **Copy only the animated uniforms** | Each layer works out, once, which uniforms its bindings and tracks write (their property paths), plus the ones the layer drives itself (`progress`, `time`, `fade`). The tick copies only those; a full copy runs on `apply`, `rebind`, `set_param`, a quality change and `reset`. | Small and local: `FxStencilMaterial` keeps a "per tick" name list beside its full one. Usually 3–5 uniforms a tick instead of 10–15. | Still a copy every tick, so any new way of writing a uniform must be added to the list or it is missed for a tick. |
| B | **Copy only what changed** | Keep the last value written to the OWN pass; each tick read the first pass and write only the differences. | Exact; nothing to declare. | Still reads every uniform each tick (half the calls), and comparing Variants costs too. The smallest gain. |
| C | **Write through at the source** | `FxBinding.apply_to` and the curve tracks see that the target material is an `FxStencilMaterial` and write the same value to its `next_pass` as well; the layer's own driven uniforms do the same. Nothing is copied per tick. | Exact and event-driven: work happens only when something writes. No list to keep. | Touches the binding and track code, the heart of the effects framework. Every writer (`set_param`, quality, a future layer kind) must go through the helper, or the OWN pass goes stale. |
| D | **Instance uniforms** | Declare the animated uniforms as `instance uniform` in the effect shaders, and set them on the node (`set_instance_shader_parameter`, binding path `instance_shader_parameters/<name>`). Godot applies a node's instance uniforms to every material and pass it draws, so both passes share the values: there is nothing to copy. | The engine does the sharing; the cleanest at runtime. It also makes per-instance values cheaper for pooled effects. | A large change: every effect shader, every binding path in the 45+ effect files (a design commit) and the builders. Godot limits instance uniforms (16 per shader, no samplers, scalar and vector types only), and the probe would have to confirm they reach a `next_pass` and the particles' draw pass. |
| E | **One pass, no OWN material** | Use the readable stencil texture the probe showed is possible (K4: a compositor copies the stamp into a texture of its own). The effect shader samples it and decides per pixel: over its own unit at full strength, else its own depth test. One material, so nothing to copy. | Removes the second pass entirely: half the draws, no copies; the base for later outlines and silhouettes too. | The most work: the compositor pass, a global texture, a per-pixel depth test in every effect shader. It runs only on the RenderingDevice renderers (Forward+, Mobile), not Compatibility. A slice of its own, not a fix. |

*Leaning (not decided):*
- A is the cheap first step, if the cost ever shows in a profile.
- C is the exact fix, if the framework is being touched anyway.
- D or E are worth it only as part of a bigger change: per-instance values for pooling (D), or outlines and silhouettes (E).

*How to decide:* measure first. A battle with many live auras and DoTs (say 8 units × 3 looping effects), comparing the CPU frame
time with stencil on and off (`fx stencil off` draws one pass and copies nothing).

**Step 2, the finish, only if stencil is kept.**
- The other over-unit layers: `FxParticles3DLayer`, `FxMeshLayer`.
- The `stencil_unit` effect parameter.
- The validator rules: mode words, the include, and stencil values in content and presentation materials (section 4).
- The Settings option and the console's `fx stencil`.
- `prepare()` behind the run's loading screen.
- Removing the bias.
- Battle shots, H7 on other renderers, the rest of the tests, and `/sync-spec`.

### 1.6 Enterprise mapping
N/A. This is client presentation only and uses no backend component. It never reaches a hash, snapshot, upload or golden:
- `combat/` never references it;
- the verifier never loads a unit view or an effect (`FxManager` is inert headless, cues are suppressed headless).

## 2. Sequence flow

N/A for the client → ASP.NET Core → stores path: nothing is sent. The flow inside the client, in `stencil` mode:

0. **Run load.** Behind the loading screen, `FxStencilShaders.prepare()` compiles every shader copy once (3.4). The set is fixed,
   because values follow battle positions (3.1).
1. **Battle start.** `RoomView3D` creates the unit views. It gives each one a `unit_id` (as today) and the `stencil_value` of its
   battle position (3.1).
2. **The units are stamped.** Each view marks its materials to write its value (3.2). The units stay opaque (K1 fails), so the
   stamp is in place before any effect draws.
3. **An effect plays on a unit.** `FxService.play` resolves `FxAnchor.unit(id)` to the view (as today) and passes the view's value
   to the 3D layers that draw over their unit (3.3). A value of 0 means the fallback: today's bias (3.5).
4. **Drawing.** Effects are transparent, so they draw after every opaque unit (H5). An over-unit layer draws in two passes:
   - **OWN:** only the pixels holding its unit's value, with no depth test and full strength;
   - **OTHER:** the rest, with the normal depth test and the soft fade.
5. **The battle ends.** Nothing to hand back: the next battle gives the same positions the same values.

In `bias` mode, steps 1–4 do nothing new: no value, no mark and no copy. Rendering is today's.

## 3. Design

### 3.1 The stencil table
`game/view/stencil_ids.gd` (`class_name StencilIds`, constants only). Features take **ranges**, because one byte per pixel and no
masks (K6) rule out bit flags.

| Range | Name | Use |
|---|---|---|
| 0 | `NONE` | Everything unmarked; the cleared value |
| 1–4 | `PARTY_FIRST`…`PARTY_LAST` | Party positions P1–P4 |
| 5–24 | `ENEMY_FIRST`…`ENEMY_LAST` | Enemy positions by slot (slot 1 → 5) |
| 25–31 | `ADDED_FIRST`…`ADDED_LAST` | Units added in the middle of a battle (none in the content today), in the order they arrive |
| 32–63 | `MARKED_PROP_*` (reserved) | Non-unit objects a later feature must tell apart (silhouettes behind walls) |
| 64–127 | `TARGET_*` (reserved) | Target highlights, if one ever needs its own value |
| 128–247 | (free) | For slices not planned yet |
| 248–254 | `OPT_OUT_*` (reserved) | Lyra's 123 case: objects later outlines must skip |
| 255 | `DEV` | The gallery probe only |

Values belong to **battle positions**, not to units (the user's review, 2026-11-11): P2 is always 2, and enemy slot 3 is always 7.
So the set of values, and with it the set of shader copies, is fixed and known before any battle (3.4). The values 1–31 together
are `UNIT_FIRST`…`UNIT_LAST`.
- A position past its range (an enemy slot above 20, an eighth added unit) gets 0, the fallback, with one warning. Presentation
  never stops a battle.
- Within a battle, an added unit's value is never reused.

### 3.2 Stamping a unit
- `UnitAnimator.stencil_value: int` (system code, `game/view/`), set by `RoomView3D` beside `unit_id`. It is 0 in `bias` mode.
- `UnitAnimator.mark_stencil(material) -> Material` returns the material set to stamp:
  - on a `BaseMaterial3D`: stencil mode Custom, Write, compare Always, Reference = the value. Nothing else changes: the unit stays
    opaque (K1);
  - on a `ShaderMaterial` that includes `game/fx/shaders/unit_stencil.gdshaderinc`: its copy for the value, made the same way as
    an effect's (3.4), with `#define FX_STENCIL_WRITE <value>`;
  - on any other material: unchanged, with a warning.

  With value 0 it returns the material untouched.
- **The cube:** `presentation/demo/unit_view.gd` `_paint()` becomes `_body.material_override = mark_stencil(material)` (one line,
  the user's OK needed).
- **Humanoid materials come later** and follow the same helper.

### 3.3 How an effect knows its unit
- `FxService.play` sets `anchor.stencil_value` from the anchor's view:
  - for a UNIT anchor, or a NODE3D anchor on a `UnitAnimator`: the view's value;
  - for any other anchor: 0.
- An effect parameter `stencil_unit` that the caller did not set takes that value, the same way `depth_bias` does today. A caller
  may set it (a beam starting on its caster marks the caster).
- **New layer field `over_own_unit: bool`** on `FxParticles3DLayer`, `FxShaderQuadLayer` (3D) and `FxMeshLayer`:
  - true by default for camera-facing quads and particles: these draw over their own unit;
  - false by default for flat floor quads (the layers using `flat_depth_bias` today): these keep only the plain depth test, so a
    floor ring's back half stays behind the unit.

  The defaults come from the layer kind, so no `.tres` is edited.
- `FxFresnelLayer`, `FxMeshFlashLayer`, `FxTextLayer` and the 2D layers are unaffected.

### 3.4 Shader copies (K5: the reference is a compile-time literal)
**Why copies.** A shader material cannot take the stencil value as a setting (K5): the value must be written into the shader's
code. So an effect on P1 and the same effect on P2 need two compiled versions of that shader, and each needs two passes (OWN and
OTHER).

**No files are written.** The copies are made in memory, from the shader file that already exists.
- The stencil lines live once, inside `#ifdef` blocks in the shared include `game/fx/shaders/fx_stencil_depth.gdshaderinc`:
  ```glsl
  #ifdef FX_STENCIL_REF
  stencil_mode read, FX_STENCIL_COMPARE, FX_STENCIL_REF;
  #endif
  #ifdef FX_STENCIL_OWN
  render_mode depth_test_disabled;
  #endif
  ```
  The same include turns the bias off and switches to the classic soft fade (3.6) when `FX_STENCIL_REF` is defined.
- **Without the defines the blocks are skipped** and the shader is exactly today's. That covers `bias` mode, the files on disk, the
  validator, the gallery and `test_fx`. No effect shader file is edited: they all already include this file.
- **Making a copy.** `game/fx/fx_stencil_shaders.gd` (`FxStencilShaders.variant(shader, value, pass)`) makes a `Shader` in memory:
  a few `#define` lines followed by the original code. The lines are `FX_STENCIL_REF <value>`, `FX_STENCIL_COMPARE compare_equal`
  or `compare_not_equal`, and `FX_STENCIL_OWN` for the OWN pass. The probe proved that defines placed before `shader_type` reach
  an include. The copies are cached by (shader, value, pass).
- **Materials.** The layer's material is an `FxStencilMaterial`: the OTHER pass, with the OWN pass as its `next_pass`. Bindings and
  tracks write only the first pass (the engine writes `material:shader_parameter/x`, which a script cannot intercept), so
  `FxStencilMaterial.sync_own_pass()` copies the uniforms to the OWN pass: on every swap, on `apply` and `reset`, and on every tick
  of a live over-unit layer (`FxLayer.follow_stencil`). The uniform names are read once per shader code; engine-filled samplers
  (`fx_scene_depth`) are skipped; `render_priority` is mirrored. How it works and how to make it cheaper:
  `specs/design/stencil-over-own-unit.md` and the per-tick options above. No `render_priority` change is needed (H5).
- **Compiled at battle start** (the user's choice, step 2; there is no loading screen). `FxService.prepare_stencil(camera)`, called
  by `RoomView3D`, takes the values of the battle's positions and every shader an over-unit layer of the registry draws with
  (`FxLayer.stencil_shader()`), and `FxStencilShaders.prepare` draws each copy once as a speck in front of the camera (a particle
  shader through a one-particle emitter), so the renderer builds its pipelines before the first hit. Copies drawn once are
  remembered for the session. Cost: about 18 ms a copy on a cold driver cache, about 2 ms on a warm one.

### 3.5 Value 0
During the experiment, a layer with value 0 behaves exactly as today (depth bias and depth fade). After the decision, value 0
means the plain depth test, and the bias is gone (1.5). Value 0 happens:
- **in `bias` mode:** the A/B baseline, only during the experiment;
- **for an anchor with no unit:** it has no bias today either (`FxService` sets the bias only for anchors on a node with a mesh);
- **for a see-through unit:** a blending material writes no depth, so it cannot cut the effect; the plain depth test is right;
- **for a position past its range (3.1):** a warning; no content reaches it;
- **for a unit material that is not marked:** a setup error, which `fx check` and the validator report rather than hide;
- **on a renderer without stencil:** the 4.7.2 source has stencil in Forward+, Mobile and Compatibility; H7 confirms;
- **inside an `FxStage`:** the card screens (5b) decide whether stage meshes take values.

### 3.6 The soft fade
- Over the effect's own unit, the OWN pass draws at full strength with no fade.
- Everywhere else, the OTHER pass uses the classic soft-particle fade: `alpha *= clamp(gap / depth_fade, 0, 1)`, where `gap` is
  how far the scene lies behind the fragment (`fx_scene_gap`, already in the include).
- This works against the floor and walls. Against a neighbouring unit it depends on H4. If stamped units are missing from the
  depth texture, the effect cuts hard there, and the report shows it next to the bias look.

### 3.7 The experiment scene and the report
- **Gallery page.** `game/dev/fx_gallery.tscn` gets a "Stencil" scene:
  - two cubes 0.3 apart along the view, with an effect on the back one;
  - a floor ring under the front one;
  - a big disc leaning into the floor;
  - a wall half covering the back cube;
  - a sun with shadows (H3);
  - the battle room's environment settings (H6).
- **Shots.** `-- --stencil-compare --shots <dir>` saves one contact sheet per mode into `H:\claudeOutShots\<date> vfx-stencil\`.
- **Probe.** `game/tools/fx_stencil_probe.tscn` (windowed, watched by `tools/watch.sh`) has two parts:
  - **part 1:** the K claims (1.4), on small test scenes of their own, run before the design is built;
  - **part 2:** H1, H3, H4 and H5 by reading pixels (section 6), and H8 by timing. The probe also runs on the Vulkan driver (H7). Mobile and Compatibility are tried in the gallery
  with the `--rendering-method` command-line option.
- **Battle shots.** A real battle through `dev_run --local` in both modes.
- **Report.** `H:\claudeOutShots\<date> vfx-stencil\report.md` holds:
  - each documented claim (K1–K7) and each hypothesis (H1–H9) with yes or no and its evidence;
  - the shots side by side;
  - GPU frame time per mode;
  - shader copies made and the prepare time;
  - an assessment of what each outcome means for later outlines and highlights.
- **The user decides:** keep stencil (it becomes the default), keep it off with fixes, or revert (1.5). `/sync-spec` records the
  decision here and in the roadmap.

### 3.8 Files and ownership
- **New system code (the revert list):**
  - `game/view/stencil_ids.gd`;
  - `game/fx/fx_stencil_shaders.gd`;
  - `game/fx/shaders/unit_stencil.gdshaderinc`;
  - `game/tools/fx_stencil_probe.tscn`, `fx_stencil_probe.gd`, `fx_stencil_probe_pass.gd` and `fx_stencil_probe_ref.gdshaderinc`;
  - `tests/game/test_vfx_stencil.gd`;
  - the broken validator fixture.
- **Changed system code:**
  - `UnitAnimator` (`stencil_value`, `mark_stencil`, `stencil_changed`);
  - `FxAnchor`, `FxService` and the three layers (`stencil_unit`, `over_own_unit`, `next_pass` parameters);
  - the `#ifdef FX_STENCIL_*` blocks in `game/fx/shaders/fx_stencil_depth.gdshaderinc` (no effect shader file changes);
  - the validator;
  - the gallery's Stencil page;
  - the console `fx stencil`;
  - the Settings option.

  Each change does nothing in `bias` mode.
- **The user's files (one line each, OK needed):** `presentation/demo/unit_view.gd` and `presentation/demo/room_view_3d.gd`.

## 4. Failure modes

Backend idempotency, retries and dead letters: **N/A** (no queue, endpoint or store). None of the root `CLAUDE.md` acceptance
scenarios 1–7 applies, because none of them touches presentation. Error code 2002 is not involved: this slice cannot change a
battle, a hash or a verdict.

Client-side failure modes:

| Failure | Behaviour | Test |
|---|---|---|
| Headless (dummy renderer) | `FxManager` is inert; no value, mark or copy | `test_stencil_headless_is_inert` |
| `bias` mode | Rendering exactly as today: no value, no mark, no copy, no `render_priority` change | `test_stencil_bias_mode_changes_nothing` |
| Renderer without stencil (H7) | Value 0 for every unit: the fallback | `test_stencil_unsupported_renderer_falls_back` |
| A position past its range (an enemy slot above 20, an eighth added unit) | That unit gets 0, one warning, the battle goes on | `test_stencil_overflow_falls_back` |
| A unit view's material is neither base nor marked shader | Left unchanged, a warning naming the view, effects on it use the bias | `test_stencil_unknown_material_warns` |
| An effect draws before its unit's stamp (H5) | Cannot happen while units are opaque and effects transparent (K1, K2); the probe checks that the pixels stay stable | probe H5 |
| A see-through unit (fading out, dissolving on death, made of glass) | A blending material is drawn in the transparent pass along with the effects, so its stamp may land after an effect has tested, and its stamp stays where its pixels are fully transparent. Effects on it and behind it could flicker or vanish. It uses the fallback: while any of its materials blends, `stencil_value` reads 0, nothing is stamped, and the view emits `stencil_changed`, so live effects on it switch to the bias and back once it is solid | `test_stencil_see_through_unit_falls_back` |
| A misspelt stencil mode word (`write_foo` silently counts as `write`, K6) | Validator `fx_stencil_mode_unknown` (error): every word of a `stencil_mode` line in `game/fx/shaders/` and in the unit include must be exactly a mode name, a compare name, a number or an `FX_STENCIL_*` define | `test_fx_validator_stencil_mode` |
| A content or presentation material uses a unit stencil value (Godot's Outline and X-Ray presets default to reference **1**, which is P1) | Validator `fx_stencil_value_taken` (error): a material under `content/` or `presentation/` with stencil on must use a value outside 1–31, from a range the table gives it | `test_fx_validator_stencil_value` |
| An over-unit effect shader that does not include `fx_stencil_depth.gdshaderinc` | It would never get the stencil blocks: validator `fx_stencil_include_missing` (error) for shaders used by over-unit layers | `test_fx_validator_stencil_include` |
| A shader copy compiled mid-battle | The battle's copies are drawn once at battle start (3.4); a copy missing from the cache (an added unit) compiles at its first draw | `test_the_registry_shaders_to_prepare`; the Stencil page's `first_frames_ms` |
| Parameters drift between the two passes | `FxStencilMaterial.sync_own_pass()` on every swap, `apply`, `reset` and tick (3.4) | `test_the_quad_switches_to_two_passes_and_back_keeping_its_parameters`, `test_the_stencil_material_swaps_on_its_setting_and_follows_an_edited_shader` |
| A view freed while an effect still plays on it | The effect keeps its value until it ends; the value is not reused in that battle | `test_stencil_value_not_reused_in_battle` |
| A Godot upgrade changes the stencil API (K3) | The stencil lines live only in the include and `FxStencilShaders`; the tests and the probe fail on what they expect, and `fx stencil off` (one pass, the plain depth test) holds until it is fixed | `test_a_copy_is_the_defines_in_front_of_the_unchanged_code`; the claim probe |
| Script or engine error while drawing | `ScriptErrorLog` fails the test, as everywhere | (suite rule) |

## 5. Observability

Prometheus: **N/A.** Nothing runs on a server, and no client metric is exported.

Dev observability:
- `fx stencil dump`: views and their values, the copies made and their compile time, the mode;
- `fx stats`: the copy count and the mode;
- `fx check`: unit views with unmarked materials;
- the probe's timings and the report (3.7).

## 6. Test plan

**Headless suite** (`tools/godot_tests.sh`), new file `tests/game/test_vfx_stencil.gd`:
- **Table:** ranges do not overlap, every constant is inside its range, 0 is `NONE`.
- **Assignment:**
  - a fixture battle gives P1–P4 the values 1–4 and enemy slot n the value 4 + n;
  - the next battle gives the same positions the same values;
  - an added unit takes 25 upward;
  - a position past its range gives 0 and one warning.
- **Stamping:**
  - on a `StandardMaterial3D`, `mark_stencil` sets mode, flags, compare and reference, and leaves transparency, priority and depth
    drawing as they were;
  - on a marked `ShaderMaterial`, it uses the cached copy;
  - value 0 returns the material untouched;
  - an unknown material warns;
  - a see-through view reads 0 and emits `stencil_changed`.
- **Service:**
  - a UNIT anchor passes its view's value as `stencil_unit`, and a caller-set value wins;
  - other anchors pass 0;
  - `over_own_unit` defaults by layer kind;
  - a live effect switches to the fallback on `stencil_changed`.
- **Copies:**
  - a copy is the original code with the right `#define` lines in front (OWN has `FX_STENCIL_OWN`), and the file on disk is
    unchanged;
  - the same key returns the same `Shader`;
  - `prepare()` makes every over-unit shader × 31 values × 2 passes, and a battle afterwards makes no new copy;
  - parameters are set on both passes.
- **`bias` mode:** the layers' materials, priorities and parameters are identical to today's. The existing `test_fx` and
  `test_vfx_content` pass unchanged in both modes.
- **Validator:** `fx_stencil_mode_unknown` and `fx_stencil_include_missing` on broken fixture shaders in `tests/broken_fixtures/`.
- **No combat change:** the combat and scripted-run goldens replay unchanged (they already run; no golden is added or moved).

**Windowed probe, part 1: the documented claims** (needs a GPU, run before the build): each K test in 1.4. Every claim is recorded
as holds, fails or partly holds, with the evidence (pixels read, compiler or engine output, the doctool XML). Nothing fails the run;
the note goes to the user and into this spec.

**Windowed probe, part 2** (needs a GPU, not in the headless suite): `fx_stencil_probe.tscn` renders the Stencil scene in each mode
and reads pixels:
- H1: the effect's colour over the back cube, none over the front cube where it covers the back one, and none behind the wall;
- the floor ring's back half hidden by the front cube;
- H3: the shadow region still darkened by the stamped cube;
- H4: the fade band next to the front cube;
- H5: the same pixels stable over 300 frames.

It also times both modes (H8) and `prepare()` (H9). It exits non-zero on a hard failure (H1 or H5). It reports H3, H4, H6,
H8 and H9 as findings for the report instead of failing. In `bias` mode it shows the leak, which documents the problem.

**Goldens:** none. The contact sheets and the report are for the user's decision.
