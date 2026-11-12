# Spec: `vfx-stencil` (slice 5a3), an experiment

Status: draft for review, 2026-11-11. This version rewrites the first draft as a reversible experiment (user, 2026-11-11).
Roadmap entry: `specs/roadmap.md`, "5a3. `vfx-stencil`" (from `playtest-fixes` B14).
Builds on `vfx-framework` (5a) and `vfx-content-pass` (5a2). Presentation only.

## 1. Purpose & enterprise mapping

### 1.1 The problem
Today a depth bias (Unreal's Pixel Depth Offset, set to the unit's radius, in `game/fx/shaders/fx_depth_bias.gdshaderinc`) keeps an
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
| H4 | Stamped units are missing from the scene depth texture, so an effect touching a neighbouring unit cuts hard instead of fading | The soft fade against units; fades against the floor and walls are not affected |
| H5 | Without a draw-order rule, an effect centred on its unit sometimes draws before the unit's stamp and flickers; `render_priority` (units low, effects higher) fixes it | Correctness |
| H6 | Stamped units lose SSAO, SSR and the depth prepass | Look and cost; the battle room may not use SSAO or SSR at all |
| H7 | Stencil works on Forward+ (D3D12, the project's renderer), and on Vulkan, Mobile and Compatibility | Portability; the shipped renderer comes first |
| H8 | The cost is small: GPU frame time with 8 units and 8 live effects, stencil vs bias, within 10% | Cost |
| H9 | A battle with 8 units needs at most about 128 shader copies, prepared at battle start without a visible hitch | Cost |

H4 and H6 are inferences from K1, not facts. If H4 holds and the fade loss looks bad, that alone can decide the experiment.

**Order of work.** The K claims are tested first (the probe's part 1). They come out as a findings note added to this spec. The
design in section 3 is built only after that note, and is adjusted where a claim failed. The H hypotheses are tested on the built
design (the probe's part 2).

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

### 1.6 Enterprise mapping
N/A. This is client presentation only and uses no backend component. It never reaches a hash, snapshot, upload or golden:
- `combat/` never references it;
- the verifier never loads a unit view or an effect (`FxManager` is inert headless, cues are suppressed headless).

## 2. Sequence flow

N/A for the client → ASP.NET Core → stores path: nothing is sent. The flow inside the client, in `stencil` mode:

1. **Battle start.** `RoomView3D` creates the unit views. It gives each one a `unit_id` (as today) and a `stencil_value` from
   the table (3.1), and prepares the shader copies for those values (3.4).
2. **The units are stamped.** Each view marks its materials to write its value (3.2). Per K1, the units are now drawn in the
   transparent pass, at a low `render_priority`, and they write depth.
3. **An effect plays on a unit.** `FxService.play` resolves `FxAnchor.unit(id)` to the view (as today) and passes the view's value
   to the 3D layers that draw over their unit (3.3). A value of 0 means the fallback: today's bias (3.5).
4. **Drawing.** Effects draw at a higher `render_priority`, so after every unit (H5). An over-unit layer draws in two passes:
   - **OWN:** only the pixels holding its unit's value, with no depth test and full strength;
   - **OTHER:** the rest, with the normal depth test and the soft fade.
5. **The battle ends.** The values go back to the table for the next battle.

In `bias` mode, steps 1–4 do nothing new: no value, no mark and no copy. Rendering is today's.

## 3. Design

### 3.1 The stencil table
`game/view/stencil_ids.gd` (`class_name StencilIds`, constants only). Features take **ranges**, because one byte per pixel and no
masks (K6) rule out bit flags.

| Range | Name | Use |
|---|---|---|
| 0 | `NONE` | Everything unmarked; the cleared value |
| 1–31 | `UNIT_FIRST`…`UNIT_LAST` | Battle unit views, one value each per battle |
| 32–63 | `MARKED_PROP_*` (reserved) | Non-unit objects a later feature must tell apart (silhouettes behind walls) |
| 64–127 | `TARGET_*` (reserved) | Target highlights, if one ever needs its own value |
| 128–247 | (free) | For slices not planned yet |
| 248–254 | `OPT_OUT_*` (reserved) | Lyra's 123 case: objects later outlines must skip |
| 255 | `DEV` | The gallery probe only |

Values are given out per battle in order:
- party P1–P4 → 1–4;
- enemies by slot → 5 upward;
- a unit added mid-battle takes the next free value, and a value is never reused within the battle.

Past 31 units, a unit gets 0 (the fallback) with one warning. Presentation never stops a battle.

### 3.2 Stamping a unit
- `UnitAnimator.stencil_value: int` (system code, `game/view/`), set by `RoomView3D` beside `unit_id`. It is 0 in `bias` mode.
- `UnitAnimator.mark_stencil(material) -> Material` returns the material set to stamp:
  - on a `BaseMaterial3D`: stencil mode Custom, Write, compare Always, Reference = the value, `render_priority` =
    `StencilIds.UNIT_PRIORITY`, and depth drawing Always (so a transparent-pass unit still hides what is behind it);
  - on a `ShaderMaterial` that includes `game/fx/shaders/unit_stencil.gdshaderinc`: its copy for the value (3.4);
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

### 3.4 Shader copies (because of K5 and H2)
- Each effect shader that draws over units carries the marker line `// @fx_stencil`.
- `game/fx/fx_stencil_shaders.gd` (`FxStencilShaders.variant(shader, value, pass)`) returns a cached copy with the marker
  replaced:
  - **OWN:** `render_mode depth_test_disabled; stencil_mode read, compare_equal, <value>;`
  - **OTHER:** `stencil_mode read, compare_not_equal, <value>;`
- The layer's material is the OTHER pass with the OWN pass as `next_pass`. Parameters are set on both passes (`FxLayer.apply` and
  bindings walk the `next_pass` chain). Both passes get `render_priority` = `StencilIds.EFFECT_PRIORITY`.
- `RoomView3D` prepares the values present at battle start. The cache is bounded by the table.
- If H2 is false (a `ShaderMaterial` can set the reference per material), the copies are dropped for that: one shader, the value
  as a setting. The spec is updated with the finding.

### 3.5 The fallback
When `stencil_unit` is 0, a layer behaves exactly as today: depth bias and depth fade. This happens:
- in `bias` mode;
- for anchors with no unit;
- for a unit past the table;
- for a see-through unit (section 4);
- on a renderer without stencil (H7);
- inside an `FxStage`, unless its views are stamped too (the hybrid card screens do not need it yet).

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
  - `game/tools/fx_stencil_probe.tscn` and its script;
  - `tests/game/test_vfx_stencil.gd`;
  - the broken validator fixture.
- **Changed system code:**
  - `UnitAnimator` (`stencil_value`, `mark_stencil`, `stencil_changed`);
  - `FxAnchor`, `FxService` and the three layers (`stencil_unit`, `over_own_unit`, `next_pass` parameters);
  - the `// @fx_stencil` marker line in the over-unit shaders in `game/fx/shaders/`;
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
| More than 31 units | Overflow units get 0, one warning, the battle goes on | `test_stencil_overflow_falls_back` |
| A unit view's material is neither base nor marked shader | Left unchanged, a warning naming the view, effects on it use the bias | `test_stencil_unknown_material_warns` |
| An effect draws before its unit's stamp (H5) | Units at `UNIT_PRIORITY`, effects at `EFFECT_PRIORITY`, so effects always draw after every unit | `test_stencil_priorities_set`; probe H5 |
| A see-through unit (fading out, dissolving on death, made of glass) | Its blending draw is ordered against effects only by priority, and its stamp and depth stay where its pixels are fully transparent, so effects on it and behind it could flicker or vanish. It uses the fallback: while any of its materials blends, `stencil_value` reads 0, nothing is stamped, and the view emits `stencil_changed`, so live effects on it switch to the bias and back once it is solid | `test_stencil_see_through_unit_falls_back` |
| An effect shader without the `// @fx_stencil` marker | Validator `fx_stencil_marker_missing` (error) for shaders that include the depth-bias include | `test_fx_validator_stencil_marker` |
| A shader copy compiled mid-battle | The values present are prepared at battle start; a unit added later compiles once | `test_stencil_variants_prewarmed` |
| Parameters drift between the two passes | `apply` and bindings walk `next_pass` | `test_stencil_next_pass_params_in_sync` |
| A view freed while an effect still plays on it | The effect keeps its value until it ends; the value is not reused in that battle | `test_stencil_value_not_reused_in_battle` |
| A Godot upgrade changes the stencil API (K3) | The generated `stencil_mode` lines live in `FxStencilShaders` alone; the tests fail on the text they expect, and the switch goes back to `bias` until it is fixed | `test_stencil_variant_code` |
| Script or engine error while drawing | `ScriptErrorLog` fails the test, as everywhere | (suite rule) |

## 5. Observability

Prometheus: **N/A.** Nothing runs on a server, and no client metric is exported.

Dev observability:
- `fx stencil dump`: views and their values, copies made, priorities, the mode;
- `fx stats`: the copy count and the mode;
- `fx check`: unit views with unmarked materials;
- the probe's timings and the report (3.7).

## 6. Test plan

**Headless suite** (`tools/godot_tests.sh`), new file `tests/game/test_vfx_stencil.gd`:
- **Table:** ranges do not overlap, every constant is inside its range, 0 is `NONE`, the two priorities are ordered.
- **Assignment:** a fixture battle gives P1–P4 1–4 and enemies 5 upward by slot; values are unique within a battle and handed out
  again in the next one; overflow gives 0 and one warning.
- **Stamping:**
  - on a `StandardMaterial3D`, `mark_stencil` sets mode, flags, compare, reference, priority and depth drawing;
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
  - the OWN and OTHER code carry the right `stencil_mode` line, and OWN has `depth_test_disabled`;
  - the same key returns the same `Shader`;
  - the prepare step makes exactly the values present;
  - parameters are set on both passes.
- **`bias` mode:** the layers' materials, priorities and parameters are identical to today's. The existing `test_fx` and
  `test_vfx_content` pass unchanged in both modes.
- **Validator:** `fx_stencil_marker_missing` on a broken fixture shader in `tests/broken_fixtures/`.
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

It also times both modes (H8) and the prepare step (H9). It exits non-zero on a hard failure (H1 or H5). It reports H3, H4, H6,
H8 and H9 as findings for the report instead of failing. In `bias` mode it shows the leak, which documents the problem.

**Goldens:** none. The contact sheets and the report are for the user's decision.
