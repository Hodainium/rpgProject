# Spec: vfx-content-pass (slice 5a2, after 5a `vfx-framework`, before 5b `card-ui`)

Status: **built, open for tuning like the UI slice** (synced to the code 2026-11-09; all D-decisions made; the user may request fixes as they playtest) · Date: 2026-11-09 · Roadmap: slice 5a2 (already listed, "Not started").
Builds on `specs/vfx-framework.md` (the framework, the cue bridge, the proof set), `specs/gameplay-messages.md` (the bus),
`specs/content-pass.md` (statuses, hit tags), `specs/item-pass.md` (break, weakness), `specs/dev-tools.md` (proposal-pass
tools and console parity). Design ownership: this slice edits existing user content, so it works by a **proposal the user
approves** (section 2.4), never by silent edits.

## 1. Purpose & enterprise mapping

**Purpose.** Slice 5a gave the game an effects framework and a proof set, and put one generic `Cue.Fx.HitSpark` on
`content/demo/effects/damage.tres`, so *every* damage application sparks the same way. The user's requirement
(2026-11-09, memory `no-generic-damage-effect`): **no single generic effect on every damage proc.** Effects must carry
information: a poison tick must not look like a sword hit, a fire hit not like an ice hit, a crit, weakness hit or break
must read differently. This slice authors the effects (as `FxDefinition`/cue data, no new code paths for content) for the
content made before the framework existed, and removes the generic spark.

Scope of content, by what the player must be able to read:

| Group | Count today | Effect |
|---|---|---|
| Hits by damage type | `Physical`, `Fire`, `Ice` (+ none) | Distinct hit effect per type, on the target |
| Damage numbers | every HP change | Honkai-style floating numbers (section 2.5): element colour, crit accent, DoT/heal variants |
| Hit modifiers | `Hit.Critical`, `Hit.Weakness`, `Hit.Resisted`, `Hit.Drained`, `Hit.Break`, `Hit.FollowUp` | A layered accent on top of the type effect (crit flash, weakness ring, resist "clink", drain stream, break shatter exists) |
| DoTs | Poison, Bleed, Burn (+ `poison_2`) | Own tick effect each, and a looping aura while the status lasts |
| Controls | Freeze, Stun, Entangle, Slow | Looping aura while active, a one-shot on apply |
| Buffs / debuffs | Attack/Defense up/down, Haste, Regen, Ward, Taunt, Weaken, Vulnerable, Exposed, Exhausted, Enrage, Fury, Finale, Fracture, Malady, Combustion | Aura per family (buff = rising, debuff = sinking), colour per stat, one-shot on apply |
| Ability roles | `Ability.Role.Heal / Revive / Buff / Cleanse / Dispel / RestoreMP / Guard` (all demo party abilities carry one) | Cast effect per role on the caster/targets |
| Ultimates | 24 `Ability.Ult.*` | A cast flourish per ult: the shared flourish stays, and each ult also has its own signature effect (decision D12, 24 distinct looks) |
| Death, revive, phase change, break recovery, One More | battle messages | Listener-driven effects |
| Items and equipment | 118 items, 33 equipment | Not built (cut list, section 8): per-item proc looks. Items still get the heal/revive/status cues of their effects |
| Run events | level-up, key/chest found, chest opened, rest, gift | Screen flashes from listeners on `Message.Run.*` (`support_fx_rules`, `moment_fx_rules`); richer HUD effects are on the cut list |

**Not in scope:** a new effect system (5a is it), card screens (5b), final art/audio (placeholder-quality like the proof
set; the user tunes in the inspector), new shaders unless a group needs one (section 3.4), balance.

**Presentation only**, as in 5a: effects are never in a hash, snapshot, upload or replay; `combat/` does not reference
`game/fx/`; headless (verifier, tests) skips cues (`suppress_cues`).

**Enterprise mapping: none at runtime.** Client-only; no endpoint, queue, broker, cache or database. One consequence to
state honestly: editing effect `.tres` files under `content/` changes the **ruleset version** (it hashes content), so the
verifier worker needs the matching export, like any content edit. That is the only server-side effect.

## 2. Sequence flow

N/A as a client-to-server flow. The slice has three client-side flows.

### 2.1 Cue-driven effects (statuses, ability roles, instant hits)
```
GAS applies a GameplayEffect / ability executes
  instant effect       application_cue_tags      → FxCueNotify one-shot on the target view
  duration effect      persistent_cue_tags       → FxCueNotify loop, end_cue() fades it when the status ends
  removal              removal_cue_tags          → one-shot (cleanse sparkle, shatter on Freeze end)
FxCueBinding feeds colour/scale from literals, the payload or the target's tags (one cue scene serves a family).
```

### 2.2 Message-driven effects (per-hit variants, battle moments, run events) — Lyra's route, decision D11
A cue cannot know a hit's damage type, so these follow Lyra (`HealthSet` broadcasts a verb message after execution; a message-to-cue
bridge turns it into a GameplayCue with parameters from the message). Built:
```
battle.damage_dealt → BattleMessages → Message.Battle.Damage (VerbMessage: instigator, target, magnitude, tags = Hit.* + Damage.Type.*)
  FxListener(s) on that channel with tag filters (require_tags / exclude_tags / tag_order) either
    play an effect on the target (the number: fx.damage_number), or
    execute a CUE on the target's view (FxListener.cue; MessageCueParams carries the message into the cue's bindings):
    [Damage.Type.Fire] → Cue.Fx.Proc.Fire   [Hit.Critical] → Cue.Fx.Proc.Crit   [Hit.Weakness] → Cue.Fx.Proc.Weakness ...
  A hit with several tags plays several; a DoT tick carries no hit tags and is handled by its status (2.1).
battle.damage_drained (source, target, amount, tags = Hit.Drained + Damage.Type.*) → Message.Battle.Drained → Cue.Fx.Drain.<type>
battle.hp_changed → Message.Battle.HpChanged → the numbers of heals and DoT ticks (2.5)
Message.Battle.Trigger (tags: the ability's tag and the event tag) → proc cues; Message.Run.* → screen flashes
```
The listeners live in data: `presentation/demo/fx/battle_fx_rules.tres`, `support_fx_rules.tres` and `moment_fx_rules.tres` (`FxRuleSet`s),
attached by `GameMain` when a battle is shown (the registry's `rule_sets`; headless never attaches). No code per effect.

### 2.3 Replacing the generic spark
```
today:  damage.tres  application_cue_tags = [Cue.Sfx.Hit, Cue.Fx.HitSpark]       (every hit, same look)
after:  damage.tres  application_cue_tags = [Cue.Sfx.Hit]                         (sound only, as before slice 5a)
        hits get their look from the rule set in 2.2; DoT ticks from their status cues in 2.1
```
Done (shown `old → new` and approved first, 2026-11-09; a test pins that `damage.tres` lists only the hit sound). `Cue.Fx.HitSpark` stays in the registry for the gallery/proof set.

### 2.4 How content got its cues (the proposal pass was not built)
No `build_vfx_pass` tool was written. The cue tags were added to existing content by approved `Edit`s, shown `old → new` per group (the standing rule),
and every new file came from create-only builders:
```
game/tools/build_fx_textures.tscn        procedural sprite sheets (our own art)
game/tools/build_vfx_slice / _status / _support / _ults / _signatures / _signatures2 / _moments .tscn
                                         effects, cue scenes and rule sets; never overwrite (--only <name> rebuilds one, --force rewrites the builder's own set and discards tuning)
                                         a new effect or rule set is appended to fx_registry.tres by RegistryPatch (decision D14); cue-registry entries and tag cues by Edit
```
Delivery followed D5: a vertical slice first (D10), then groups, each shown to the user before the next.

### 2.5 Damage numbers (added at the user's request, 2026-11-09)
Honkai: Star Rail style floating numbers over the unit that lost (or gained) HP. A number is an effect like any other: an
`FxDefinition` (`fx.number`) with a new **text layer** (`FxTextLayer`, system code: a Label3D billboard in the world, or a
Label for UI anchors, with outline, pop-in scale, rise and fade on the FX clock), played by listener rules, so colours and
sizes are data.
```
Message.Battle.Damage (amount ×100, tags: Damage.Type.X + Hit.*)  → fx.number at the target unit
  text   = amount / 100 as a whole number (display only; the hash never sees it)
  colour = by element: Physical, Fire, Ice (rule per type, colour is a parameter)
  Hit.Critical  → bigger, bold: thick outline in a second accent colour, a short shake, and a small "Crit!" line above the number (as in Honkai)
  Hit.Weakness  → a small weakness mark beside the number in the element colour (as Honkai's weakness icon)
  Hit.Resisted  → smaller, desaturated; Hit.Drained → green number with "+" (the unit is healed by it)
  Hit.Break     → "Break" tag beside the number in the break element colour
Heals (HP gained)    → green "+N", Regen/HoT ticks the same, smaller
DoT ticks (HP lost with no hit)   → number in the status colour (Poison green-purple, Bleed red, Burn orange), small
```
Several numbers at once (an AoE, a multi-hit row): each unit stacks its own numbers with a small vertical stagger so they
do not overlap, a cap of live numbers per unit (older ones fade faster, like the toast soft cap).

**Source of the data (verified in the code, 2026-11-09).** `Battle.damage_dealt` is emitted only by execution-row hits; a DoT tick (the periodic
modifier from `CombatASC.turn_start`) and a heal are plain HP changes that emit no such signal. So `combat/` gained one presentation signal, in the
spirit of D2-A: `hp_changed(unit_id, delta_x100, cause_tags)`, emitted from `Battle._on_attribute_changed` for `hp`. A row hit's own HP loss is
excluded (`_row_hit_depth`), so a hit makes exactly one number (from `Message.Battle.Damage`); a DoT's stacks are grouped into one report per tick through
`CombatASC.tick_started/tick_finished`. `BattleMessages` bridges it as `Message.Battle.HpChanged`. None of these signals is read by the action log, the trace or the state hash
(pinned by `test_a_battle_with_every_effect_attached_is_identical` and the unchanged goldens). Several numbers on one unit are not staggered or capped yet (cut list).

### 2.6 Tag cues for loose state tags (added in the build)
Break, Downed and Dead are loose tags, not effects, so they have no cue tags of their own. `FxTagCue` (in the registry's `tag_cues`) maps a unit's
state tag to cues for added / present (a persistent look) / removed; `FxTagCues` attaches to the battle's units from `GameMain._on_battle_started` (never headless).

## 3. Data contracts

**Server contracts: N/A** (no DTOs, queues, topics, Redis keys).

### 3.1 Content produced (user-owned, new files; listed after the build)
- **Reuse rule (user, 2026-11-09, clarified): reuse where effects are alike, do not force everything into one.** When two looks
  differ only in colour, size or the texture sheet (a fire effect that should be green, or larger), they are one
  `FxDefinition` with different parameters (listener `params`, cue `FxCueBinding`s, or the caller). When the structure
  differs, or merging would make an effect convoluted, make several definitions; there is no target count and no pressure to
  collapse effects. Example: Fire hit and Ice hit share `fx.hit` with colour and texture parameters only if their layers are
  the same; if ice needs shard particles and a frost ring that fire does not, ice is its own definition. Judgement call made
  per effect in the proposal, which states "reuses X with params" or "new, because Y". **What decides sharing is behaviour, not the picture:** motion (rise, fall, burst), lifetime, gravity/damping, size and fade curves, blend mode and the other layers. Smoke and a water splash are separate definitions even though both are particles on a sheet. A texture parameter travels with its own `h_frames`/`v_frames` (the sheet's grid); that is bookkeeping for the sheet, never a reason to merge. If a texture swap would also need different motion or layers, it is a new definition. The validator's `fx_near_duplicate`
  warning (identical layer structure) only flags likely accidental copies and can be dismissed.
- `presentation/demo/fx/` : about 64 files, the `FxDefinition`s (names `fx.<name>`) and the rule sets `battle_fx_rules`, `support_fx_rules`, `moment_fx_rules` (2.2), all listed in `fx_registry.tres`. Cue scenes (about 82) are in `presentation/demo/cues/`.
- Tags: new `Cue.Fx.*` entries, added to `godot_gas/tag_registry.tres` (`sync_tags --add-missing`) and `cue_registry.tres` (by `Edit`): per status family, per hit proc (`Cue.Fx.Proc.*`), per drain type (`Cue.Fx.Drain.*`), per ultimate, plus heal, revive and the moments. Per-status and per-ult names are in the registry itself, not copied here.

### 3.2 Framework additions (system code, `game/fx/`)
The framework is mostly sufficient; three small gaps this slice needs, each tested:
```gdscript
# FxListener gains tag filters on a VerbMessage's tags (decision D1)
@export var require_tags: Array[StringName] = []     # all must be present (hierarchical match, Hit.Weakness / Damage.Type.Fire)
@export var exclude_tags: Array[StringName] = []     # none may be present

class_name FxRuleSet extends Resource                # a list of FxListener attached together, detached with the node
@export var rules: Array[FxListener]
func attach(owner: Node) -> Array[GameplayMessageHandle]

# FxListener gains a text parameter for numbers (damage numbers, section 2.5)
@export var text_param: StringName                    # a STRING param filled from the message's magnitude (÷100, whole number, "+" for heals)
@export var text_prefix: String; @export var text_suffix: String   # "Crit!" etc. is a suffix param, or a second rule

class_name FxTextLayer extends FxLayer               # new layer kind: outlined text that pops, rises, fades (Label3D or Label)
# params: text, color, outline_color, outline_size, scale, rise, hold, fade, suffix

# Built in addition (decisions D11-D13):
# FxListener.cue (execute a GAS cue instead of playing an effect), MessageCueParams (message → cue bindings), FxListener.tag_order
# FxCueNotify.target_fx / target_bindings / target_stagger (a look per target from the cue payload's target_ids)
# BattleAbility.cast_cue_tags (combat/, GAS cue tags executed on the caster at activation with {target_ids}; never in a log or hash)
# FxTagCue / FxTagCues, FxRegistry.rule_sets / tag_cues, FxService.unit_view(id)
# FxCueBinding's TARGET_ATTRIBUTE source: NOT built (no need appeared)
```
Unit anchors already exist (`FxAnchor.unit(id)`); `TARGET_UNIT` / `INSTIGATOR_UNIT` rules are enough for hits and casts.

### 3.3 Damage type on the message (decision D2: **A chosen by the user, 2026-11-09**)
The listener in 2.2 needs the hit's `Damage.Type.*`. Today `Message.Battle.Damage` carries the hit tags (`Hit.*`); the
damage type is on the execution row and may not be among them. Two ways:
- **A (chosen):** `Battle.damage_dealt`'s *signal* tags also include the row's `Damage.Type.<X>`. It is the signal the
  presentation bridge listens to; the action log, state hash and trace do not read it, so no golden changes. Needs a check
  at build start that the trace/hash path truly never sees these tags (a test pins it).
- **B:** no `combat/` change: a per-type damage effect variant (`damage_fire.tres`, ...) each with its own cue tag, abilities
  switched to the variant by the proposal pass. Heavier content edit (111 abilities reference `damage.tres`) and every
  new type needs a new variant.

### 3.4 Shaders and layers
Reuse the 5a library (`glow_aura`, `radial_burst`, `rays`, `outline`, `dissolve`, `vignette_flash`, `glow_3d`, `burst_3d`,
`rays_3d`). A new shader or layer kind is added only if the proposal marks an effect "needs X", and is listed for approval
Built: `particle_3d` (billboard flipbook, depth bias, soft particles), `fresnel_overlay`, `lava_rock`, `hex_shield`, `rune_circle`, `crack_ground`, `beam_3d`, `slash_3d` and the `fx_depth_bias.gdshaderinc` include, each documented in its header and checked by `test_fx`.

### 3.5 Visual quality: real fire, explosions, smoke (added at the user's request, 2026-11-09)
The proof set of slice 5a is blurred circles and flat quads. This slice's effects use **textured, animated particles and
shaders** so fire looks like fire. Techniques (all supported by Godot's `GPUParticles3D`/`2D`; the framework needs only
small additions):
- **Flipbook particles:** a sprite-sheet texture on a particle material (`particles_anim_h_frames/v_frames`, animation over
  lifetime) for flames, smoke puffs, explosion cores. `FxParticles3DLayer` gets `texture`, `h_frames`, `v_frames`, `anim_speed`
  fields (small, tested).
- **Layered effects:** an explosion is several layers in one `FxDefinition`: flash (light + radial burst), fireball flipbook,
  debris/ember sparks, smoke trail, a ground/screen shake; a flame is a flipbook plus embers plus a flickering light.
- **Procedural shaders** where a texture is not needed (stylized flame, dissolve, frost crystals), as in the 5a library.
- **Element looks:** Fire = flames and embers; Ice = shards, frost mist and a crystal flash; Physical = slash trail and dust
  puff; Poison = rising green bubbles and spores; Bleed = droplets; Burn = a small flame on the unit; Freeze = an ice shell.

**Sources to study and, when the licence allows, use** (checked at the start of the build; each file's own licence is read
before anything is copied, anything used is credited in `presentation/demo/fx/CREDITS.md`, and I write our own
`FxDefinition`s around them, per the standing open-source-references rule):
- [Kenney Smoke Particles](https://kenney.nl/assets/smoke-particles) and [Kenney Particle Pack](https://godotengine.org/asset-library/asset/784): CC0 textures (smoke, explosion, flash, sparks).
- [Reactorcore Fire Smoke Animations](https://opengameart.org/content/smoke-particle-assets) and [flame particle set](https://opengameart.org/content/flame-particle-set-4-in-total): CC0 frame animations (licences re-read per page).
- [GDQuest godot-4-vfx-assets](https://awesome.ecosyste.ms/projects/github.com%2Fgdquest-demos%2Fgodot-4-vfx-assets): MIT, reference for particle setups and shaders.
- godotshaders.com: [Procedural Torch & Candle (fire, smoke, sparks)](https://godotshaders.com/shader/procedural-torch-candle-shader-fire-smoke-sparks/) (listed CC0/MIT), [3D Explosion VFX](https://godotshaders.com/shader/3d-explosion-vfx/), [Stylized BOTW Fire](https://godotshaders.com/shader/stylized-botw-fire/): per-shader licences differ, read each.
- Not used: paid or attribution-required packs (PYROLUX, EffectBlocks, VFX 2D Free is CC-BY) unless the user asks.
Textures live in `presentation/demo/fx/textures/` (user-owned, new files, size-checked: a flipbook sheet at most 1024x1024).
As built, the sprite sheets are procedural (`build_fx_textures`, our own art, no licence and no `CREDITS.md` needed); the open-source packs above were references only.
Acceptance: gallery screenshots of fire, ice, poison and an explosion were shown to the user before the rest was made (D10), and quality tiers keep a plain-but-readable version at LOW (D6).

### 3.6 Character-attached effects (added 2026-11-09, user-approved plan)
Effects were centred on a unit's origin, which for the cube is inside its mesh, so the unit's own surface sliced every camera-facing
sprite. Studios solve this with several techniques together (Niagara's skeletal-mesh data interface with sockets and surface
sampling, Unity VFX Graph's skinned-mesh sampler, soft particles, depth offset, mesh-based skins such as Divinity: Original Sin 2's
burning lizard); sockets alone only move the start point. The stack, in build order:
1. **Sockets and radius.** Four role names, not body parts: `Center` (whole body, auras), `Hit` (where an impact lands), `Top` (just above
   the unit: numbers, icons), `Base` (where it meets the ground: shockwaves, ground fire). `FxSocket` (a `Marker3D`, `game/fx/`) with a
   `role`, as children of a unit's view; a view without them gets all four derived from its mesh's bounding box (`FxAttach`), so nothing
   needs authoring to start. A view's radius is its mesh's bounding-sphere radius (override: an `fx_radius` property on the view). The cube
   view gets four explicit markers (a `presentation/` edit, shown `old -> new` first). `FxDefinition.socket` is where an effect attaches by
   default (`Center`); `FxAnchor.unit(id, shift, socket)` overrides it; a layer's own `socket` moves just that layer (a shockwave on `Base`,
   the fireball on `Center`). Offsets stay in world units. This replaces the hand-set `height` parameter of the slice effects.
2. **Default depth bias from the radius.** When a play does not pass `depth_bias` and the effect has that parameter, it is set to the anchor's
   radius, so no caller passes numbers per unit. Explicit values still win. The depth bias (3.5 notes) stays as the safety net and is retuned
   at the end.
3. **Surface emission.** `FxParticles3DLayer.emit_from_mesh` samples points on the target's first mesh (area-weighted, cached per mesh,
   unseeded: presentation only) and emits from them in the mesh's own space, so flames and bubbles start on the surface, not in the middle.
   Rigid units follow because the emitter follows the mesh each tick; a skinned model later uses a bone-attached emitter (Godot's baked
   points do not follow skinning).
4. **Soft particles.** `soft_distance` in the shared particle shader fades each particle where its (biased) depth nears the scene's depth,
   which removes the hard cut line against walls and other units; with the bias applied first, the two do not cancel.
5. **Mesh-shell status look.** `FxFresnelLayer` gains `fill`, `grow` (a slight outward vertex offset) and a noise erosion that scrolls up, so
   a status can burn, freeze or ooze on the unit's own mesh. It follows animation for free and cannot intersect the model.
Mixamo humanoids are a later slice: each socket then becomes a bone attachment (the role-to-bone map is per-model data) and the cube's
markers go away; effects name roles only, so they do not change. Tests: socket derivation from bounds and explicit markers, radius, default
bias, per-layer socket, surface points lie on the mesh and the emitter follows it, the soft fade, and the shell uniforms.

## 4. Failure modes

Presentation-only: no idempotency, retries or dead letters. Root `CLAUDE.md` acceptance scenarios 1-7: **none covered or
affected**; the guard is that every golden, replay/step runner test and e2e scenario passes unchanged (except the
ruleset-version consequence below).

| Failure | Behaviour | Test |
|---|---|---|
| A status has no cue yet / unknown cue tag | no effect, no error (GodotGAS skips an unregistered cue); the validator flags the gap | `test_dot_and_control_statuses_name_their_cues_and_the_cues_exist`, `test_stat_statuses_and_cleanse_name_their_cues_and_the_cues_exist`, `test_every_ultimate_has_its_own_cast_cue`, `test_every_moment_cue_is_registered_and_plays_an_effect` (`fx coverage` is not built) |
| Several hit tags at once | each matching rule plays; bounded by each effect's `max_instances` | `test_tag_filters`, `test_hit_messages_execute_the_per_type_hit_cues` |
| Spam (AoE hitting 5 targets, 10 DoT ticks a turn) | `max_instances` recycles the oldest; quality tiers drop MEDIUM/HIGH layers first | `fx_smoke` at every tier, `test_status_effects_play_at_every_tier` (`max_instances` is covered by 5a's `test_fx`) |
| Looping status aura outlives the status (death, battle end, cleanse) | `end_cue` fades it; `stop_all` at battle end; unit freed releases it | `test_a_persistent_look_ends_when_its_unit_dies`, `test_looks_are_released_when_their_views_are_freed`, `test_status_cues_play_through_the_real_cue_manager` |
| Effects mutate state | impossible by construction (5a); hash, trace and run hash are identical with rules attached or not | `test_a_battle_with_every_effect_attached_is_identical` (scripted battle played twice) |
| Headless / verifier | cues suppressed, listeners inert (no `FxManager`), result identical | existing suite + `verifier_image_check` unchanged |
| A registry lacks a file (builders append, a hand edit can forget one) | `FxValidator.sync_problems` reports `fx_unregistered`, `fx_rule_set_unregistered`, `cue_scene_unregistered`, `cue_scene_missing`, `cue_unknown` as errors in `validate_content.tscn` | `test_registries_list_every_effect_rule_set_and_cue_scene`, `test_the_registry_patch_only_appends` |
| Cue/FX edit changes ruleset version | expected: re-export the full build so the worker's version matches | noted in the PR; `tools/dev_stack.sh` doc line |
| Proposal applied to a file the user changed since | `--apply` refuses a file whose hash differs from the report's | no proposal tool was built: the content was made by create-only builders and by approved `Edit`s |

## 5. Observability

N/A for Prometheus (client-only). Client dev observability, extending 5a: `fx stats` already counts plays per definition;
the planned **coverage report** (`fx coverage`) was not built; the coverage tests (section 6, item 6) and the registry sync check in `validate_content.tscn` stand in for it. The
`Message.Dev.Fx` channel already logs plays.

## 6. Test plan

Godot tests (`tests/game/test_vfx_content.gd`, in-memory fixtures where possible; the shipped set checked by the validator):
1. **Listener filters:** `require_tags`/`exclude_tags` (hierarchical match, empty = no filter, order independence), on a
   fake `VerbMessage`; unchanged behaviour when both are empty (regression of 5a tests).
2. **Rule set:** attach/detach with the owner; a fire crit plays exactly the fire hit and the crit accent; a DoT tick plays
   neither; a weakness break plays the break set.
3. **Damage type on the message (D2-A):** the signal carries `Damage.Type.*`; the action log, trace and state hash of the
   golden battles are byte-identical (all combat goldens pass unchanged).
4. **Replacement:** `damage.tres` has `Cue.Sfx.Hit` and no `Cue.Fx.HitSpark`; a hit still plays its sound (regression).
5. **Cue families:** each new `FxCueNotify` scene plays its effect through the real cue manager; `TARGET_TAGS` bindings pick
   the colour per status tag; persistent cues end on removal and on unit death.
6. **Coverage:** tests assert every DoT, control and stat status names a cue that exists, every ult has its own signature (unique), and every moment cue is registered. The `fx coverage` report is not built.
7. **Builders and registries:** `RegistryPatch` only appends and is idempotent (`test_the_registry_patch_only_appends`); `FxValidator.sync_problems` reports a file a registry lacks (`test_registries_list_every_effect_rule_set_and_cue_scene`); `sync_tags --remove` refuses a used tag (`test_sync_tags`). The proposal-pass tool was not built.
8. **Safety:** state hash, run hash and trace identical with the rule sets attached and absent over a scripted battle and a
   scripted run (`test_vfx_not_in_hash`); anchors' visuals restored after every new effect.
8a. **Reuse:** no accidental near-duplicate definitions (`fx_near_duplicate`, dismissible), and a parameter change alone (colour, texture, size) changes the played effect.
8b. **Damage numbers:** text and colour per type; crit/weakness/resist/drain/break variants and suffixes; a DoT tick and a heal
    produce a number through `hp_changed` and a row hit produces exactly one; AoE stagger and the per-unit cap; `hp_changed`
    and the type tags are in no log, trace or hash (all combat goldens unchanged); text is display-only (no float math in combat).
9. **Smoke:** `fx_smoke.tscn` runs every new definition at every tier (headless, no script errors); the validator
   (`fx_*` codes) is clean over the new set.
10. **Window checks (not automated):** screenshots by Claude of a real battle per group (hit types, a DoT tick, an aura, a
    cast, an ult, a break, a death) to `H:\claudeOutShots\<date> vfx-content\`; the user judges the look.

No golden vectors (no deterministic simulation output). Existing goldens must not change; the only artifact expected to move
is the ruleset version.

## 7. Decisions for the user

- **D1. Tag-filtered `FxListener` (3.2) for per-hit variants.** Recommended over cue-per-variant: one place (a rule set
  resource) to read and tune every hit look, new damage types need only a rule, no ability edits.
- **D2. DECIDED, option A:** the damage signal's tags also carry `Damage.Type.*`. With the damage numbers, `combat/` also gains
  the presentation signal `hp_changed` (section 2.5). Both are pinned by a test that no golden, trace or hash moves.
- **D3. Granularity (parameter sets for looks that differ only in colour/size/texture; separate definitions when the structure differs):** per-status effects for DoTs and controls (they differ in meaning), **per-family** for stat buffs and
  debuffs (colour per stat via bindings), per-role for casts, ultimates changed by the user's decision D12: each has its own signature effect. Otherwise as recommended; the
  alternative (one effect per each of ~70 statuses/abilities) is a lot of data for little extra reading value.
- **D4. Items:** effects only on usable items and on passives that visibly trigger; the proposal lists which, the user
  strikes or adds. Recommended.
- **D5. Order of delivery:** (1) framework gaps + hit types/accents + replacing the spark (the stated requirement), (2) DoTs
  and controls, (3) buffs/debuffs, roles, (4) ults, battle moments, run events, items. Each group is its own proposal and
  approval so the user can stop after any.
- **D6. Quality tiers:** base reading (type colour, shape) at LOW; extra particles/light/shake at MEDIUM/HIGH, so a
  low-end machine still tells a poison tick from a fire hit. Recommended.
- **D7. VERIFIED (2026-11-09), recorded here:** GodotGAS effects have `periodic_cue_tags`, and `CombatASC.turn_start()` executes
  them on every tick (once per effect per tick, not per stack). So a DoT tick **can** have its own one-shot effect from its
  status (`periodic_cue_tags` on poison/bleed/burn), and a looping aura from `persistent_cue_tags`; no listener workaround is
  needed. Caveat: a stacked DoT plays its tick cue once even when it deals damage per stack (the numbers, which come from
  `hp_changed`, show one per stack). Built: the DoTs and Regen list periodic cues.
- **D8. DECIDED (2026-11-09): both, like Honkai.** A bold accent outline on the number, and "Crit!" above it (param `label`, placed above the number);
  each switchable in the inspector. Every number rises and fades away (`rise`, `hold`, `fade` params).
- **D10. DECIDED (2026-11-09): show examples first.** textured flipbook and layered effects (3.5), CC0/MIT sources only, credits file. A first set (fire hit, ice hit, explosion, poison tick) is shown as screenshots for approval before the rest is made.
- **D9. DECIDED (2026-11-09), colours approved:** Physical, Fire and Ice are the only damage types. Proposed starting colours: Physical white-grey,
  Fire orange-red, Ice cyan; DoT colours by status; heal green. All are rule parameters; the user tunes them.

- **D11. DECIDED (user, 2026-11-09): GAS first, and follow Lyra.** Anything a GodotGAS feature can carry is a GAS feature: effect cue tags
  (`application`/`persistent`/`periodic`/`removal`), `BattleAbility.cast_cue_tags` with the cue payload carrying `target_ids`, and
  `FxCueNotify.target_fx` for per-target looks. The two things a cue cannot know (a hit's damage type and the damage number) follow Lyra:
  the kernel emits a message after execution (`Message.Battle.Damage`, `HpChanged`) and a message-to-cue route (`FxListener.cue`,
  `MessageCueParams`) executes a cue on the unit's view. Loose tags (`State.Broken/Downed/Dead`) get cues from `FxTagCues`.
  The Lyra source at `G:/Unreal Projects/ProjectBotGame` is always the reference.
- **D12. DECIDED: reuse by parameters only for look-alikes.** One effect with parameter sets when two looks differ in colour, size or texture sheet
  (stat arrows, buff rings, heals, drains); separate definitions when the structure differs (smoke is not a water splash). Every ultimate has its
  own signature effect (24); the shared ult flourish stays.
- **D13. DECIDED: depth bias, sockets and surface emission** (Pixel-Depth-Offset-like bias, soft particles, `Center/Hit/Top/Base` sockets with a mesh-bounds fallback) instead of drawing on top.
- **D14. DECIDED: builders create files, never rewrite them.** `ResourceSaver` re-saves of existing design files were removed. The only exception
  is `RegistryPatch.add_missing_effects()`, an additive text patch of `fx_registry.tres` (user, 2026-11-09), with `FxValidator.sync_problems`
  as the backstop. Cue-registry entries and tag cues are added with `Edit`. A forced rebuild (`--force`) rewrites a builder's own files and
  discards tuning (it reset `fx.ult_flourish` and `fx.slash_hit` once): rebuild one file with `--only <name>`.
- **D15. DECIDED: tags can be removed.** `sync_tags -- --remove Tag,Tag` / `--remove-unused` (refuses a tag the code or content still uses).

## 8. Implementation notes

Vertical slice built 2026-11-09 (D10) and the remaining groups the same day (below); the slice stays open for fixes from playtest.
- **Combat (presentation signals only):** `damage_dealt`'s tags are now the hit's `Hit.*` tags followed by the row's `Damage.Type.*` tags
  (decision D2-A as written: one channel, not a parallel one; seven test expectations updated), and `Battle.hp_changed` reports heals,
  DoT/HoT ticks and costs (a row hit's own HP loss is excluded, so there is one number per hit). `BattleMessages` sends
  `Message.Battle.Damage` from `damage_dealt` and the new `Message.Battle.HpChanged` (verbs `Verb.Damage` / `Verb.Heal`, new tags).
  No golden, trace or hash moved.
- **Framework:** `FxTextLayer` (Label3D number, pop/rise/fade, a tag line above), `FxParam.Kind.STRING`, `FxListener`
  `require_tags` / `exclude_tags` / `require_verb` / `tag_params` + `tag_order` / `text_param` (a saved Dictionary does not keep its
  order, so overrides are listed explicitly), `FxRuleSet`, flipbook fields on particle layers (`h_frames`, `v_frames`,
  `anim_cycles`, `random_frame`), `GameMain.fx_rules` (attached when effects are enabled).
- **Content (new files, builders never overwrite):** `build_fx_textures.tscn` makes five procedural sprite sheets (our own art, no
  licence) in `presentation/demo/fx/textures/`; `build_vfx_slice.tscn` makes `fx.damage_number`, `fx.fire_hit`, `fx.ice_hit`,
  `fx.explosion`, `fx.poison_tick` and `battle_fx_rules.tres`, and adds them to `fx_registry.tres`. Each effect has a `height` parameter
  (so it is not hidden inside the unit cube). Reuse calls: fire and ice are separate (ice has shards and a ring); the number is one
  effect for every element, with colour, size and label chosen by tag.
- **Generic spark removed (user, 2026-11-09):** `damage.tres` now lists only `Cue.Sfx.Hit`; physical hits have no visual effect until their slash effect is made. `Cue.Fx.HitSpark` stays in the registry for the gallery.
- **Character-attached effects built (3.6, 2026-11-09):** `FxSocket`, `FxAttach`, `FxDefinition.socket`, `FxLayer.socket`, `FxAnchor.socket` / `radius` / `placed()`, the radius as the default `depth_bias`, `emit_from_mesh` (+ `emission_min_normal_y`, so nothing is born under a unit), soft particles (`soft_distance`), the shell fields on `FxFresnelLayer` (`fill`, `grow`, `erosion`, `scroll`), four markers on `presentation/demo/unit_view.tscn`, `UnitAnimator.fx_radius`. The slice effects dropped their `height` parameter for a `socket`; numbers attach to `Top`, the explosion's shockwave to `Base`. Offsets stay in world units (the plan said radii; not needed yet).
- **Depth bias (user chose option A, 2026-11-09):** a camera-facing flame centred on a unit was sliced by the unit's own mesh. The first fix
  (`draw_on_top`, no depth test) also painted over walls and units in front, so it was removed. Now every particle and glow quad lifts its
  depth toward the camera by `depth_bias` world units for the depth test only (Unreal's Pixel Depth Offset): `shaders/fx_depth_bias.gdshaderinc`
  (an include: `fx_biased_depth`), used by `glow_3d`, `burst_3d`, `rays_3d` and the new shared particle draw material
  `shaders/material/particle_3d.gdshader` (billboard, flipbook, additive or normal blend, the bias), which replaces the StandardMaterial3D
  `FxParticles3DLayer` drew with. Effects expose `depth_bias` (default 0.9, about a cube's radius; later a unit reports its own radius) and `height`.
  Walls and units that really are in front still hide an effect.
- **Fresnel (user, 2026-11-09):** `FxFresnelLayer` (extends `FxMeshFlashLayer`, which gained `make_overlay` / `set_strength` hooks) puts a rim-glow
  shader (`shaders/material/fresnel_overlay.gdshader`) on the unit's own mesh, restored when it ends; the fire, ice and poison effects carry one.
  The shader library test now expands `#include`s and also checks `shaders/material/`.
- **Number arrival (Honkai, user, 2026-11-09):** a number starts large and transparent and settles to normal size as it fades fully in, then holds, rises and fades out; it spawns at a random spot around the target (`scatter`, `scatter_y`).
- **Groups built after the slice (2026-11-09):**
  - *Statuses:* DoT and control effects name `periodic/persistent/application/removal` cue tags (D7 as verified); 29 stat statuses plus cleanse and dispel share stat-arrow and ring effects chosen by parameters (solid block arrows, a little shorter than first drawn); Stun is Persona 5 stars with a white chaser trail.
  - *Casts and ultimates:* `BattleAbility.cast_cue_tags` + payload `target_ids` + `FxCueNotify.target_fx` / `target_bindings` / `target_stagger`; 24 ultimates each with a distinct signature (`build_vfx_signatures`, `signatures2`), the shared ult flourish kept; a caster ring coloured by `Ability.Role.*`.
  - *Heals and revives:* `Cue.Fx.Heal` on 18 heal effects (+ Regen's periodic cue) and `Cue.Fx.Revive` on 4 revive effects.
  - *Hits:* per damage type through `Message.Battle.Damage` to a cue (`Cue.Fx.Proc.*`: crit, weakness, fire, ice, break, physical, taken, kill, ult); drained hits (`Hit.Drained`, `Message.Battle.Drained`, `Cue.Fx.Drain.*`) show what was absorbed, and the feed line reads "{target} absorbed {instigator}'s attack".
  - *Moments:* `Message.Battle.Trigger`, tag cues for `State.Broken/Downed/Dead`, run-event screen flashes (`moment_fx_rules`, `support_fx_rules`).
  - *Numbers:* every damage text is size 64 except Break (76); a crit has a 15 outline and "Crit!" above; ONE MORE! matches a crit (64 / 15); pixel size 0.0095; a DoT's stacks make one number per tick (`CombatASC.tick_started/tick_finished`).
- **Combat-side additions (presentation signals, no golden moved):** `Battle.hp_changed(unit, delta_x100, cause_tags)` with `_row_hit_depth` excluding a row hit's own HP loss; `damage_drained(source, target, amount, tags)` is now 4-argument (consumers `run_controller.gd`, `ui_battle_panel.gd` and two tests updated); `CombatASC.tick_started/tick_finished`; `BattleAbility.cast_cue_tags`. `ability_activated` stays 3-argument (a 4-argument version was tried and reverted: GAS cue payloads carry the targets).
- **Framework additions:** `FxTextLayer`, `FxMeshLayer`, `FxFresnelLayer`, `FxListener.cue` / `exclude_tags` / `tag_order`, `FxRegistry.rule_sets` / `tag_cues` / `all_*`, `FxTagCue(s)`, `MessageCueParams`, `FxService.unit_view`, shaders `particle_3d`, `fresnel_overlay`, `lava_rock`, `hex_shield`, `rune_circle`, `crack_ground`, `beam_3d`, `slash_3d`, procedural sprite sheets from `build_fx_textures`.
- **Content:** about 64 files in `presentation/demo/fx/` (effects and the rule sets `battle_fx_rules`, `support_fx_rules`, `moment_fx_rules`), about 82 cue scenes in `presentation/demo/cues/`, cue tags on the effect and ability files, `cue_registry.tres` entries, four `FxSocket` markers on `unit_view.tscn`; `ult_fx_rules.tres` (a short-lived message route) was deleted. Builders (create-only; `--only <name>`, `--force`; registry entries by `RegistryPatch`): `build_fx_textures`, `build_vfx_slice`, `_status`, `_support`, `_ults`, `_signatures`, `_signatures2`, `_moments`.
- **Tools:** `fx_gallery.tscn -- --rules --shots <dir>`, `--play cue:<tag>`, `sync_tags --remove`, `FxValidator.sync_problems`.
- **Not built (cut list):** the `fx coverage` command, a number stagger/cap, `STYLE.md`, separate crit/weakness/drain accent effects, per-item proc looks, richer HUD run-event effects, the proposal-pass tool, Mixamo humanoids (a later slice: sockets and tuning will change then).
- **Ongoing fixes log:** (empty; add playtest requests here.)

## 9. Production approach (studio practice, user request 2026-11-09)

Work as a game studio would: a small vertical slice first, review, then scale. Clean design over volume.
- **Readability first (VFX design pillars):** (1) *Read at a glance:* element, hit strength and event type are told apart by
  silhouette and colour before detail; (2) *Hierarchy:* player-critical info (damage numbers, break, crit, weakness) is always
  above ambient effects (auras, embers), which dim or drop first at lower tiers or when many effects overlap; (3) *Feel:*
  anticipation, impact, follow-through (a hit has a flash frame, a burst and a fade; a crit adds a hit-stop-like punch via
  scale/shake, never by pausing the simulation); (4) *Budget:* a battle with 5 enemies and 4 party members stays smooth at
  every tier, measured by the smoke runner's instance counts, not guessed.
- **Iteration loop:** brief (what the player must feel/read) -> blockout (plain shapes, right timing and colour, no art) ->
  first pass with textures -> review screenshots/clip with the user -> tune parameters in the inspector -> lock. The four
  D10 examples are the first vertical slice and go through the full loop before the other groups start.
- **Review gates:** each delivery group (D5) ends with a contact sheet of the group and a short "what changed / what to tune"
  note; the user approves, asks for changes, or postpones. No group starts before the previous is signed off.
- **Tuning data, not code:** everything a designer would tweak after review (colours, sizes, timings, rise/fade, outline,
  intensity per tier) is an exposed parameter in the resource, grouped and documented, so iteration needs no developer.
- **Style guide file (not built, cut list):** `presentation/demo/fx/STYLE.md` records the colour language (element, status, buff/debuff, heal),
  timing ranges (hit 0.2-0.4 s, cast 0.4-0.8 s, ult 1-2 s), size classes and naming, so new content stays consistent.
- **Playtest checklist per group:** can a new player tell fire from ice without reading text? Is a crit obvious in a
  5-enemy AoE? Does Auto-battle at speed stay readable? Does LOW tier still read? Findings go in section 8.
- **Scope control:** a cut list is kept (effects deferred to later) instead of lowering quality to fit everything.
