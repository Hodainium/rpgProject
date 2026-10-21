# Spec: animation-sets (slice 1c3)

Status: 📝 Spec written, reviewed (rev 2) · Roadmap: slice 1c3 · Date: 2026-10-20
Builds on: `specs/combat-replay-core.md` ("Execution table and animation events": an ability's animation `execute`
keys time its hits), `specs/game-skeleton.md` 3.7 (placeholder screens, `ViewGate`), `specs/dev-tools.md` (templates,
Play, validator, console parity).

## 1. Purpose & enterprise mapping
Today every unit is a cube (`presentation/demo/unit_view.tscn`) whose idle, hit, death and "default hop" are
hand-written tweens in `unit_view.gd`, and each ability's animation is played straight on the unit's
`AnimationPlayer`. A real character would need all of that wired again by hand. This slice makes a unit's look
**data**:

- **Animation set** (`UnitAnimationSet`, a resource): named slots (`idle`, `walk`, `hit`, `block`, `death`,
  `dead`, `revive`, `victory`, `cast`) each holding an `Animation`. A new character or enemy is set up by dragging
  animations into slots; anything empty falls back to the default set (the demo's cube moves).
- **One AnimationTree for every unit** (`res://game/view/unit_animation_tree.tres`, shared): a state machine over
  the slots, plus a **montage** one-shot on top where the casting ability's own animation plays. Its `execute` keys
  still time the hits, so combat and replay don't change.
- **One unit view script** (`UnitAnimator`, system) that drives the tree from `combat/` signals and the gate. The
  user's view scenes hold only the model, the skeleton and an `AnimationTree` node using the shared tree.
- **Shared animations across models** through Godot's humanoid retargeting (`SkeletonProfileHumanoid` + a
  `BoneMap` at import, skeleton named `GeneralSkeleton`), so one set can serve every humanoid model. Documented and
  validated; the demo itself stays cubes (no rigged model in the repo yet).

**Presentation only.** Combat stays animation-free: the headless verifier never builds a view, never loads a set and
never plays an animation. The ability's `Animation` resource stays where it is (combat input, read by
`ExecutionReader`); only *where* it plays changes.

| Area | What | Owner |
|---|---|---|
| `UnitAnimationSet` resource class, `UnitAnimator` node script, shared tree | system (`game/view/`, new) |
| `UnitDefinition.view` (the unit's view scene, as a path) | system (`combat/unit_definition.gd`) |
| Demo default set (cube idle bob, hit shake, death fall, revive, victory spin, cast hop) | yours (`presentation/demo/animation_sets/`, new files via the builder) |
| `unit_view.tscn` / `unit_view.gd` move onto `UnitAnimator`; `room_view_3d.gd` instantiates each unit's own view | yours (`presentation/demo/`, edits need approval) |
| Content templates, Play, validator, console | system (`game/dev/`, `addons/rpg_dev/`) |

**Enterprise mapping: none.** Client-only presentation; no server, store or broker is touched. It matters to the
backend in one way: `ruleset_version` hashes `res://combat/`, `res://game/`, `res://content/`, `res://godot_gas/`
and the addon (`specs/server-authority.md` 3.5), **not** `res://presentation/`. Animation sets live in
`presentation/`, so re-skinning a unit never changes the ruleset; ability animations stay in `content/` because
their `execute` keys are rules. The new `game/view/` scripts are inside `res://game/`, so they are hashed like any
system code (they hold no rules; the hash change is expected and harmless).

Out of scope: in-room walking (the `walk` slot exists for it, unused until then), blend spaces and directional
movement, IK, facial animation, VFX on bones, real rigged demo models (later, unscheduled), ult cutscenes (1c4 may add a
camera hook).

## 2. Sequence flow
No server. Three flows, all on the client.

**Building a unit's view** (`room_view_3d._unit`, map and battle):
```
definition.view (path) ──empty──▶ GameMain.unit_view (today's cube scene) as fallback
load(view) → instantiate → UnitAnimator (root or child named "Animator")
UnitAnimator.setup(definition):
    set := definition's view scene's `animation_set` export, else the default set (presentation/demo/animation_sets/default.tres)
    library "set"      ← every filled slot of `set`, missing slots from the default set
    library "montage"  ← one placeholder animation named "current"
    tree.tree_root     = the shared unit_animation_tree.tres; tree.active = true; travel("idle")
```

**An ability** (`ViewGate.ability_began(unit_id, ability)` → `UnitAnimator.play_ability(ability, gate)`):
```
animation := ability.animation                         (content; null → gate.release_finished(), as today)
library "montage": "current" := animation              (swap per cast; the tree resource is never edited)
if animation has no track on the model (only execute keys, sounds): also fire the set's `cast` slot under it
tree: request the OneShot "montage" (fade-in 0.1 s)    → the state machine keeps running underneath
    each `execute(row_id)` method key  → UnitAnimator.execute(row_id) → gate.release_execution(row_id)
    OneShot finishes (AnimationTree.animation_finished("montage/current")) → gate.release_finished()
safety: a timer of animation.length + 0.5 s releases whatever is still held (an interrupted or broken animation
    never stalls the battle); ViewGate.skip_all bypasses all of this, as today
```
The battle awaits only the gate, exactly as now (combat-replay-core: abilities await nothing but `battle.gate`).
The montage changes only which node plays the animation; key times and their order are the same.

**Reactions** (signals → state machine; never back into combat):
| Signal | Slot |
|---|---|
| battle setup, run map | `idle` (loop) |
| `damage_dealt(target = this)` | `hit` as an **additive flinch** on top of whatever plays (idle, or the unit's own cast); `block` replaces it when the hit carries a `Hit.Blocked` tag (none yet; hook only) |
| `unit_died` | `death` → `dead` (loop, hold last pose) |
| `unit_revived` | `revive` → `idle` |
| `battle_ended(Victory)` | `victory` on living party units |
| (later) in-room movement | `walk` |

A reaction never overrides a montage. The flinch is **additive** (decided 2026-10-20): it plays on its own layer and
is added to the pose, so a unit hit mid-cast keeps casting and flinches at the same time. `death` waits for a running
montage to end (the gate is released either way). The `hit` and `block` slots are therefore authored as **offsets**
from the neutral pose (cube: `Body:position` / `rotation` deltas around zero; humanoid: Godot's additive convention,
relative to the rest pose).

## 3. Data contracts
**C# contracts: none.** Nothing goes on the wire. No queue, topic or Redis key.

### 3.1 Resource classes (system)
| Class | Where | Fields |
|---|---|---|
| `UnitAnimationSet` (`Resource`) | `game/view/unit_animation_set.gd` | `idle`, `walk`, `hit`, `block`, `death`, `dead`, `revive`, `victory`, `cast`: `Animation` (all optional); `fallback: UnitAnimationSet` (default: the demo default set); `skeleton_profile: SkeletonProfile` (empty = cube-style, tracks on the view's own nodes; `SkeletonProfileHumanoid` = tracks on `%GeneralSkeleton:<bone>`) |
| `UnitAnimator` (`Node`) | `game/view/unit_animator.gd` | exports `animation_set: UnitAnimationSet`, `tree: AnimationTree`, `label: Label3D` (optional); methods `setup(definition)`, `play_ability(ability, gate)`, `execute(row_id)` (the method keys' target), `react(slot)`, `set_stats(text)`, `set_dead(dead)` (same surface `room_view_3d` uses today) |
| `unit_animation_tree.tres` | `game/view/` | `AnimationNodeBlendTree`: `StateMachine` (states `idle`, `walk`, `death`, `dead`, `revive`, `victory`, `cast`, each playing `set/<slot>`; any→death→dead, dead→revive→idle, idle→victory) → `OneShot "montage"` (shot: `montage/current`) → `Add2 "flinch"` (input B: a `OneShot` playing `set/hit` or `set/block`, add amount 1) → output |

### 3.2 Changes to existing system files
| File | Change |
|---|---|
| `combat/unit_definition.gd` | `@export_file("*.tscn") var view: String = ""`: a **path**, not a `PackedScene`, so loading a definition (verifier, replays, tests) never loads models, textures or animation sets. Presentation calls `load()` on it. Empty = the default view. |
| `game/game_main.gd` | `unit_view` stays as the default view scene. |
| `game/dev/content_templates.gd` | character / enemy templates: `view = ""` (the default cube) plus a comment pointing at the set; new template `animation_set` (an empty `UnitAnimationSet` whose `fallback` is the default set). |
| `game/dev/content_validator.gd` | Warnings: `view_missing` (a `view` path that doesn't exist or has no `UnitAnimator`), `animation_set_loop` (`idle` / `dead` / `walk` not looping), `animation_set_profile` (humanoid profile, but a track not under `%GeneralSkeleton`), `ability_montage_path` (an ability animation with a track path the default view doesn't have; Body-only cube animations are fine). Never errors: a look can't break a run. |
| Console | `anim <unit id> [slot]`: prints the unit's view, set, filled/fallback slots and validator findings; with a window it also plays the slot on the sandbox unit (Play parity). `play` (exists) shows the unit with its set. |
| `addons/rpg_dev/` | Play on a character / enemy opens the sandbox with its view (already routes through `play`); no new buttons. |

### 3.3 Your files (`presentation/demo/`; edits need your approval)
- **New** (made by a builder run, never-overwrite like `build_demo`): `presentation/demo/animation_sets/default.tres`
  and its animations (`idle` gentle bob, `hit` shake, `death` fall onto its side, `dead` lying, `revive` stand up,
  `victory` spin, `cast` the hop the cube does today, `block` a squash; `walk` a waddle). Values are starting
  values for you to tune; once the files exist they are the source of truth.
- **Edit** `unit_view.tscn`: root gets `UnitAnimator` (or an `Animator` child), `AnimationPlayer` becomes an
  `AnimationTree` using the shared tree. `unit_view.gd` shrinks to the cube's colouring (`_paint`), since the tweens
  (`flash`, hop, death rotation) become the default set.
- **Edit** `room_view_3d.gd`: `_unit()` instantiates `definition.view` (or the default) instead of always
  `unit_view`; calls `react(&"hit")` from `damage_dealt` instead of `flash()`; `victory` on battle end.

### 3.4 Humanoid convention (documented, validated, not demoed)
Import each humanoid model with the **Retarget → Bone Map** set to `SkeletonProfileHumanoid` and "Rename Skeleton"
on, so every model's skeleton is `%GeneralSkeleton` with profile bone names. Animations made for that profile
(Mixamo or any humanoid) then play on every such model. A set with `skeleton_profile = SkeletonProfileHumanoid`
expects tracks under `%GeneralSkeleton`; ability animations meant for humanoids do the same. Cube-style sets keep
tracks on the view's own nodes (`Body:position`).

## 4. Failure modes
Server failure scenarios (root `CLAUDE.md` 1–7): **none apply**. What this slice must protect is that presentation
can never change, slow or stall combat, and that replays stay byte-identical (scenario 5 relies on it later).

| Failure | Behaviour | Test |
|---|---|---|
| The verifier or a replay loads a unit with a `view` | `view` is a path; nothing under `presentation/` is loaded; replay result byte-identical | `test_headless_never_loads_views` (loads every demo definition headless, asserts no `presentation/` resource is cached), every existing golden unchanged |
| Montage drops or reorders `execute` keys | Same row ids, same order as `ExecutionReader.sequence_for` | `test_montage_releases_in_order` (fixture view, ClientGate, records `release_execution` calls) |
| Ability animation is null, has no keys, or is interrupted (unit dies mid-cast, scene freed) | The gate is released (finished) within `length + 0.5 s`; battle continues | `test_montage_never_stalls` |
| `hit` arrives during the unit's own cast | Flinch is added on its layer; the cast keeps playing, its `execute` keys still fire on time | `test_flinch_is_additive` |
| Death during the unit's own cast | `death` starts after the montage ends; the gate is released as usual | `test_death_waits_for_montage` |
| A slot is empty | The fallback set's slot plays; no fallback either → stays in `idle` | `test_animation_set_fallback` |
| `view` path missing or wrong type | Default view, validator warning `view_missing` | `test_content_validator` + broken fixture |
| Skip (Auto/Skip, `skip_all`) | No tree work; identical outcome and hash to animated play | `test_skip_and_animated_same_hash` (fixture battle played both ways) |
| Same ability cast by two units at once (follow-ups) | Each unit's `montage/current` is its own library entry; one never overwrites the other | `test_montage_per_unit` |

## 5. Observability
N/A: client-only presentation, no service runs.

## 6. Test plan
System tests use fixtures only: a fixture view `tests/fixtures/views/probe_view.tscn` (a `Body` node, an
`AnimationTree` with the shared tree, `UnitAnimator`) and a fixture set whose slots are short animations with known
lengths. They run headless (the AnimationTree is advanced manually with `advance(delta)`, no rendering).
- `test_montage_releases_in_order`, `test_montage_never_stalls`, `test_montage_per_unit`,
  `test_flinch_is_additive`, `test_death_waits_for_montage`, `test_animation_set_fallback`, `test_skip_and_animated_same_hash`,
  `test_headless_never_loads_views`.
- **First implementation step (pinned by a test):** check that method-call tracks fire through an `AnimationTree`
  `OneShot` in Godot 4.7.2 (`callback_mode_method`), that `animation_finished` reports the one-shot's animation,
  that an `Add2` flinch over a running montage adds to the pose without stopping it, and that `@export_file`
  stores a `uid://` reference (so moving a view scene keeps the link). If either fails, `UnitAnimator` plays the montage on a dedicated `AnimationPlayer` child instead and
  blends nothing (same gate behaviour); the spec is synced.
- Validator: broken fixtures `views/view_missing` (a character whose `view` is a bad path),
  `animation_sets/not_looping.tres`, `animation_sets/bad_profile.tres`; `test_content_validator` expected lists.
- Templates: `create animation_set <id>` round trip; `test_tool_parity` adds `anim`.
- **Goldens:** no combat or game golden changes (nothing in the simulation path changes). No new goldens.
- Demo smoke: `test_demo_smoke` (exists) still passes with the new view; one demo case checks every demo unit
  resolves a view and a set with no validator warnings.

`dotnet build` / `dotnet test` green (no C# changes). Both suites pass before the slice counts as done. Headless
Godot always with `--quit-after` and a timeout.

## 7. Implementation order
A. The AnimationTree question above (test first).
B. `UnitAnimationSet`, `UnitAnimator`, shared tree, `UnitDefinition.view`, fixture view + tests.
C. Builder for the demo default set (new files only), then the approved edits to `unit_view` and `room_view_3d`.
D. Templates, validator warnings, `anim` command, broken fixtures.
E. `/sync-spec animation-sets`, roadmap, root `CLAUDE.md` table.

## 8. Decisions (review, 2026-10-20)
1. **`view` is a file path on `UnitDefinition`** (`@export_file`, stored as a `uid://` reference), not a
   `PackedScene`: loading a definition must never load models, textures or animation sets, so verifier workers,
   replays and tests stay lean, and a broken model can't break verification. The view scene's
   `UnitAnimator.animation_set` picks the set, so one model scene carries its own look. Rejected: a `PackedScene`
   field (every replay loads every model); a presentation-side id → view table (two places to edit per unit).
2. **Slots** as listed: `idle`, `walk`, `hit`, `block`, `death`, `dead`, `revive`, `victory`, `cast` (for now).
3. **Default set = today's cube motions as animations**, so the demo looks the same and becomes tunable.
4. **Humanoid retargeting: documented and validated only.** A rigged demo model comes at a later, unscheduled date.
5. **The flinch never overrides a cast:** `hit` / `block` are additive (an `Add2` layer over the montage).
