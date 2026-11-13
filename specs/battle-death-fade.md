# Spec: `battle-death-fade`

Status: draft (2026-11-13), awaiting the user's review.
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
2. **The view registers a hold** on the battle's `ViewGate` for the length of its fade plus `end_beat`, and releases it when the
   fade ends (or the view is freed).
3. **The battle ends** (`Battle.run` returns in `RunController._do_fight`). Before `battle_finished` is emitted and the results
   are applied, `_do_fight` awaits `gate.hold_end()`:
   - **holds open:** it returns when the last one is released, or after `HOLD_CAP` seconds at most (3 s), so a broken fade can
     never stall the game;
   - **no holds** (headless, no enemy died, the gate's `skip_all`): it returns at once.
4. **Then** `battle_finished` fires as today: the HUD switches, the room view rebuilds the room, rewards and XP are applied.
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
- `ViewGate` (`game/`): `begin_hold() -> int` / `end_hold(id)` from views, and `hold_end()` that waits for every open hold, up to
  `HOLD_CAP` (3 s), and returns at once with `skip_all` or no holds.
- `RunController._do_fight` awaits `gate.hold_end()` when it has a gate, after the battle's result is final and before
  `battle_finished`. This is the only change to the run layer's flow.

### 3.4 Dev tools
- Console `style death` shows the fade settings in use.
- `style death test <unit>` plays the fade on a live enemy view without killing it, for live previews; presentation only.

## 4. Failure modes
N/A for the acceptance scenarios: none is about presentation. Presentation failure modes:
- **A fade that never finishes** (a freed view, a paused tree): the cap releases the end after 3 s; a freed view releases its
  hold in `_exit_tree`.
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

Plus the full suites unchanged: `tools/godot_tests.sh` (all goldens) and `tools/dotnet_test.sh`. A live window for the user's
review (memory: live previews), with the fade on a 5-enemy fight and on a boss.

## 7. Decisions (user, 2026-11-13)
- **Q1** Only the battle's end waits; fades during the battle never pause the next turn.
- **Q2** Bosses get a longer, more dramatic fade (`boss_death`, 3.1).
- **Q3** Timings are tuned after a live preview.

## 8. Dependencies and order
The fade lives in `UnitAnimator` and the style registry, both changed by cube-style rounds 1 and 2 (PRs #26 and #27, open). The
implementation branch starts from `feat/cube-style-round2`, or from `main` once those merge.
