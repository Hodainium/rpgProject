# Spec: `battle-death-fade`

Status: built (2026-11-13), playtested by the user in live previews; the battle-end hitch fixes it showed are section 9.
Roadmap: a small presentation slice after 5a4 `cube-style` round 2 (PR #27), before the cube-style content pass.
Builds on `animation-sets` (`UnitAnimator`), `cube-style` (`StyleRegistry`, attachments) and `vfx-stencil`. **Presentation only.**

## 1. Purpose & enterprise mapping

### 1.1 Purpose
When an **enemy** dies, it does what enemies do in FF7: it turns red and fades out, instead of the cube tipping over and greying
out. Party members keep today's grey knocked-out pose (user, 2026-11-13: enemies only).

When the battle is over, the game **waits for any enemy still fading** (plus a short beat) before it leaves the battle, so the
end no longer snaps straight to exploration: the last enemy fades, a breath, then the room comes back.

### 1.2 What it is not
- It never changes the battle: the battle's outcome, log and final hash are decided before the wait starts. Only the moment the
  screens switch moves.
- Enemies fading during a battle do not slow the battle down: the next turn starts as today; only the battle's end waits.

### 1.3 Enterprise mapping
N/A: no backend component. Nothing here is in a hash, snapshot, upload, verdict or event. The headless verifier, the replay and
trace runners and `step_main` have no views, so nothing registers a hold and the end never waits (3.3). `presentation/` is not a
`RulesetVersion` root; the system code (`game/`, `combat/`) changes the ruleset version only as any code change does.

## 2. Sequence flow
N/A on the server. The client-side flow:

1. **An enemy dies** (`Battle.unit_died` → `RoomView3D._set_dead` → `UnitAnimator.die()`). For an enemy view (battle id `E…`)
   `die()` starts the **death fade** instead of the `death` animation slot:
   - the body and every attachment tint toward the fade colour over `tint_seconds`;
   - then their alpha goes to 0 over `fade_seconds`;
   - then the view hides.

   The idle animation stops at once (FF7 enemies freeze as they die). A cast still playing finishes first, as `die()` does today.
2. **The fade holds the battle's end** for the length of its fade plus `end_beat`: its driver node joins the group
   `DeathFadeDriver.GROUP` (`death_fades`), and `ViewGate` counts every driver there that is not done as an open hold. A freed view
   takes its driver with it, so it never holds. (Built as a group rather than explicit `begin_hold` calls, so the room view, a
   design file, needs no hold code; `begin_hold` / `end_hold` remain for any other screen.)
3. **The battle ends** (`Battle.run` returns in `RunController._do_fight`). Before `battle_finished` is emitted and the results
   are applied, `_do_fight` awaits `gate.hold_end()`:
   - **holds open:** it returns when the last one is released, or after `HOLD_CAP` seconds at most (3 s), so a broken fade can
     never stall the game;
   - **no holds** (headless, no enemy died, the gate's `skip_all`): it returns at once.
4. **Then** `battle_finished` fires as today: the HUD switches, the room view shows the room (section 9: once, keeping the party
   cubes), rewards and XP are applied. The battle's outcome is read before the wait, since the battle node is freed during it.
5. **A revive** (an enemy brought back, e.g. by a boss phase) cancels its fade and restores its materials and visibility.

## 3. Data contracts
No C# DTOs, queues, topics or Redis keys. The Godot pieces:

### 3.1 `DeathFade` (Resource, `game/view/`)
| Field | Type | Default | Meaning |
|---|---|---|---|
| `color` | `Color` | red `(0.85, 0.08, 0.08)` | The colour the unit turns |
| `tint_seconds` | `float` | 0.35 | Time to turn fully red |
| `fade_seconds` | `float` | 0.6 | Time to fade from red to invisible |
| `end_beat` | `float` | 0.3 | Extra pause the battle's end waits after this fade |
| `emission` | `float` | 1.5 | A red glow while it fades (0 = none), so it reads in dark moods |
| `flash_seconds` | `float` | 0 | A white flash before the tint (0 = none) |

`StyleRegistry.enemy_death` and `boss_death: DeathFade` (through the base chain; null everywhere = built-in defaults, so the game
always fades enemies). A unit tagged `Enemy.Boss` uses `boss_death` (user, 2026-11-13: "a longer more dramatic one"): defaults
flash 0.12 s, tint 0.8 s, fade 1.4 s, glow 3, end beat 0.2 s (0.6 s first; the user, after the live preview: the battle
waited too long once the boss was no longer visible).

### 3.2 `UnitAnimator`
- `die()`: an enemy view (`unit_id` starts with `E`) runs the fade; a party view keeps today's `death` slot.
- `revive()` / `set_dead(false)`: cancels a running fade and repaints.
- The fade is driven by a small child node, like the attachments' motion driver: its own presentation clock, independent of the
  view's processing, never in a hash.
- **Materials:** the fade puts the body's and attachments' materials in alpha mode. A transparent material takes no stencil stamp,
  so for the fade's short life the unit's effects fall back to the plain depth test (spec `vfx-stencil`). A dead enemy has no live
  effects worth protecting; the fallback is accepted.

### 3.3 `PresentationGate` / `ViewGate`
- `PresentationGate.hold_end()` (base, `combat/`): returns at once. So the replay, trace and step runners, scripted controllers
  and tests behave exactly as today.
- `ViewGate` (`game/`): `begin_hold() -> int` / `end_hold(id)`, `open_holds()` (those plus every running death fade in the
  `death_fades` group), and `hold_end()` that waits for every open hold, up to `HOLD_CAP` (3 s, then a warning), and returns at
  once with `skip_all` or no holds.
- `RunController._do_fight` awaits `gate.hold_end()` when it has a gate, after the battle's result is final and before
  `battle_finished`. This is the only change to the run layer's flow.

### 3.4 Dev tools
- Console `style death` shows the fade settings in use (enemy and boss).
- `style death test <unit id>|all` plays the fade on live enemy views without killing them, for live previews; presentation
  only. Also `UnitAnimator.play_death_fade()` / `death_fade_driver()` / `fades_on_death()`.

## 4. Failure modes
N/A for the acceptance scenarios: none is about presentation. Presentation failure modes:
- **A fade that never finishes** (a paused tree): the cap releases the end after 3 s. A freed view takes its fade driver out
  of the group, so it holds nothing.
- **Many enemies dying at once:** each holds its own fade; the end waits for the longest one plus the beat, not the sum.
- **Skip or fast-forward:** `ViewGate.skip_all` skips the hold. The fade's timings follow the engine's time scale like the other
  animations.
- **Headless and the verifier:** no views → no holds → no wait. Covered by tests (6) and by every existing headless suite
  running unchanged.
- **No golden can move:** the hold happens after the battle's final hash. Every combat and run golden replays unchanged.

## 5. Observability
N/A: client presentation, no Prometheus metrics.

## 6. Test plan
`tests/game/test_battle_death_fade.gd`, on the probe view and fixture battles (never `content/` or `presentation/`):

| Test | Proves |
|---|---|
| An enemy fades, a party member falls | `die()` on an `E` view runs the fade (red at `tint_seconds`, alpha 0 and hidden after `fade_seconds`); on a `P` view it plays the `death` slot and greys as today |
| Attachments fade too | every attachment material tints and fades with the body |
| Revive cancels | a revive mid-fade restores colour, opacity and visibility |
| Hold: none, one, many | `hold_end()` returns at once with no holds; waits for one; waits for the longest of several; returns at the cap |
| `skip_all` | `hold_end()` returns at once |
| The run waits, the result does not change | a fixture battle through `RunController.fight` with a `ViewGate` and a held fade: `battle_finished` fires only after the release, and the logged battle (outcome, final hash, action log) is identical to the same battle with no hold |
| Headless untouched | the replay runner and a scripted run never call into a hold (base `hold_end` returns at once); the existing goldens pass unchanged |
| Settings | `StyleRegistry.enemy_death` through the base chain; null falls back to the defaults |
| Console | `style death`, `style death test` |

| A fading enemy holds the gate | a death fade in the tree counts as an open hold until it and its end beat are done |

Plus the section 9 tests, the full suites (`tools/godot_tests.sh`: 822 with every golden unchanged; `tools/dotnet_test.sh`) and
live windows for the user's review (a bat fight and the Golem, played by Auto).

## 7. Decisions (user, 2026-11-13)
- **Q1** Only the battle's end waits; fades during the battle never pause the next turn.
- **Q2** Bosses get a longer, more dramatic fade (`boss_death`, 3.1).
- **Q3** Timings are tuned after a live preview. Result: the boss end beat 0.6 → 0.2 s; the rest as specified.
- **Q4** (playtest) The battle-end hitch is fixed at its causes, and nothing that already exists is rebuilt (section 9; the
  user approved each change to a design file).
- **Q5** (playtest) Effects of the battle never stay on the kept party cubes in exploration (9.5).

## 8. Dependencies and order
The fade lives in `UnitAnimator` and the style registry, both changed by cube-style rounds 1 and 2 (PRs #26 and #27, open). The
implementation branch starts from `feat/cube-style-round2`, or from `main` once those merge.

## 9. The battle-end hitch (playtest, 2026-11-13)
The user saw a hitch when the fade ended, most on the Golem. Measured in a window (a scratch command timing every frame; two
battles, the bats then the Golem, in one session): not the fade (playing it never went over 6.6 ms a frame) and not graphics
(render CPU and GPU 0.3 ms in the slow frames), but script work when the battle switched back to the room: 40–58 ms frames. It was
there before the fade too (41 ms at the kill); the fade made it visible by putting a smooth moment in front of it.

| Cause | Fix | Where |
|---|---|---|
| The HUD's extension panels were freed and built again at each state change (22 ms) | **9.1** a panel whose state ends is hidden and kept (`UIManager._park` / `_unpark`, `is_parked`); shown again, it is activated (`on_activated` refreshes it). Panels that are not `CanvasItem`s are freed as before | `game/ui/ui_manager.gd` |
| Panels did `refresh.call_deferred()` on every run signal: a won battle refreshed the party strip four times, hidden screens too | **9.2** `UIScreen.queue_refresh()`: one refresh at the end of the frame, however many ask; a hidden screen skips it and refreshes when it is visible again (`visibility_changed`) | `game/ui/ui_screen.gd`; the eight demo panels call it |
| The room view rebuilt the whole room on each of `battle_finished`, `party_changed` ×3 and `room_cleared` (5 builds in a frame) | **9.3** `_queue_build()`: one build at the end of the frame from the final state; the victory celebration after it; a battle that starts in the same frame keeps its views | `presentation/demo/room_view_3d.gd` |
| Every build made new party cubes (animation tree, attachments, materials) and walls | **9.4** party cubes are made once (`P<slot>`, the battle id) and kept across rooms and battles: a cube is made only for a slot with none or another character, and a pose changes only when the member's state does; walls and floor are rebuilt only when floor, cell, doors or chapter change; the props each build; enemy cubes are made at battle start and freed after their fade. A new view gets its unit id before it is ready, so its attachments are built once | `presentation/demo/room_view_3d.gd` |

Result, the worst battle-end frame: 40–58 ms → 17–19 ms (repeated runs; 0 script errors).

**9.5 Effects on kept cubes.** A battle frees its units' persistent cue nodes without `end_cue()`; their looping looks (buff
arrows, auras) play on the unit views, which now outlive the battle, so they stayed on the party in exploration (4 and 6 left after
two test battles). `FxCueNotify` fades its effect out (`stop_fade`) when it is freed: 0 left.

**9.6 Freed cue nodes in GodotGAS.** `GameplayCueManager.remove_persistent_cue(cue: GameplayCueNotify)` refuses a freed node
through its typed parameter before its own `is_instance_valid` guard runs: a script error per cue whenever a battle was freed
with a persistent cue on (seen as four errors per dev `spawn` battle, there before this slice). `CombatASC` drops freed cue nodes
first (`remove_active_effect`, `_suppress_effect`, `_unsuppress_effect`, `drop_freed_cues`); no addon edit.

Tests: `test_ui` (a hidden panel is kept and comes back as the same node; `queue_refresh` coalesces and waits while hidden),
`test_explore_hud` / `test_battle_hud` (count shown panels), `test_fx` (a freed persistent cue stops its effect),
`test_combat_asc` (freed cues dropped).

Not done (left for later): a first-ever shader compile on a machine with a cold shader cache can still hitch once per new effect;
effects could be pre-compiled at load like the stencil copies.

## 10. Code review fixes (2026-11-13)
- **The battle stays current and alive through the wait.** `_do_fight` clears `current_battle` and frees the battle after
  `hold_end()`, just before `battle_finished`: a 1103 / 1108 rebuild (`ServerLink`) waits for `battle_finished` while
  `current_battle` is set, and the screens holding the battle drop it on `battle_finished`, so none holds a freed one. A run
  stopped during the wait gets no rewards, XP, drops or room clear.
- **A death during the unit's own cast** starts its fade before the cast releases the gate (`_finish_montage`), so the battle's
  end sees the fade.
- **`hold_end()`** counts game time (the fades' clock), stops waiting when `skip_all` is set during the wait, and at the cap or on
  Skip finishes every running fade (`DeathFadeDriver.finish_now`), so no fade can hold a later battle.
- **The unit's label** (name and HP) fades with it, and a revive restores it.
- **A parked screen** refreshes once when it is shown again (not from the visibility change and `on_activated` both); a placed
  `UIToastHost` takes no toasts while parked and drops what it showed (as a freed one did), so nothing comes out in a burst.

Accepted for now: the fade copies only `BaseMaterial3D` overrides (the cube and its attachments; an imported model with shader or
per-surface materials would pop out at the end instead of fading, to handle with the models); a dev `style` restyle in the middle
of a fade repaints the dying unit solid. No HUD panel uses `on_pushed` or holds a nested slot, so showing a parked panel again
needs neither. Worst battle-end frame after these fixes: 14–17 ms.
