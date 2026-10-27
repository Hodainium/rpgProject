# Spec: auto-battle (slice 1e)

Status: ✅ Done (2026-10-27; small follow-ups in 6) · Roadmap: slice 1e · Date: 2026-10-26
Builds on: the smart policy (`specs/playable-demo.md` 3.9, D20), ult windows and presses (`specs/ult-interrupts.md`),
the client-mode recorder (`specs/combat-replay-core.md`, "Client mode (record)"), the battle panel and Settings screen
(`specs/ui-framework.md`), export levels (`specs/playable-demo.md` 3.12). Authority table: `specs/server-authority.md`
section 0 (Auto is client-only).

## 1. Purpose & enterprise mapping
Smart auto play becomes a **player feature**. Today two policies exist and they disagree:

| Today | Where | Shipped to players |
|---|---|---|
| Battle panel **Auto**: every ready ult on its first target, then the first usable ability on the first target | `presentation/demo/ui/battle_panel.gd` `_auto_pick` | yes |
| **Smart** policy: revive, heal under 45%, best scored move, ults worth casting | `game/dev/smart_controller.gd` | no (excluded from the player export) |

The balance target (D25: 35–55% wins, smart, four members) is measured on a policy players never get. After this slice
there is **one policy, `AutoPolicy`, in system code** (`game/auto/`), used by the battle panel's Auto and by the dev
reports' `smart` policy through the same `ActionRecorder` path. The reports measure what players get.

Abilities say what they do through **GAS asset tags**, `Ability.Role.*` (heal, revive, buff…), instead of the
file-name word list (`HEAL_WORDS`) the dev policy guesses with today. The content validator checks every
party-usable ability has a role and that the role fits the ability's targeting and rows.

**Enterprise mapping:** none at runtime. Auto picks are ordinary player inputs: they go into the `ActionLog` like
manual picks and are replayed and verified like them (slices 3, 4a), with **no wire change**. The one backend-facing
decision is analytics (A5): whether a battle was played on Auto is a client-reported, **unverified hint**, kept out of
the `ActionLog` and the run hash, and only reaches the server once slice 2b defines the battle upload.

| Area | What | Owner |
|---|---|---|
| `AutoPolicy` | The smart policy as system code (3.9 rules, roles by tag, options A2–A4) | system (`game/auto/auto_policy.gd`) |
| Autopilot hook | `ActionRecorder.autopilot`: the recorder asks it before waiting for the player; its picks log like manual ones | system (`combat/action_recorder.gd`) |
| Auto state | Run-wide on/off held by `GameMain` (presentation state, never in `RunState` or a hash); Settings defaults | system (`game/game_main.gd`) + yours (`presentation/demo/ui/`) |
| Role tags | `Ability.Role.*` in the tag registry; on every party ability and usable item ability | yours (`godot_gas/`, `content/demo/`), added by a builder you approve |
| Validator | `role_missing`, `role_mismatch` | system (`game/dev/content_validator.gd`) |
| Reports | `smart` policy = `ActionRecorder` + `AutoPolicy`; `SmartController` removed; chaos sits on `AutoPolicy` | system (`game/dev/`) |
| Console | `auto on\|off [ults=on\|off]`; turning it on also stops the console's own first-legal auto (still the script runner's default) | system (`game/dev/commands/`) |

## 2. Sequence flow
Client-only; no ASP.NET Core endpoint, store or broker is involved. Flow inside the Godot client:

### 2.1 Turning Auto on
1. The player presses **Auto** on the battle panel (or the Settings default "Start battles on Auto" is on when a run
   starts; or the console runs `auto on`). The panel sets `GameMain.auto_battle = true`.
2. `GameMain` sets `recorder.autopilot = make_autopilot()` (`AutoPolicy.new(options, content)`) on the current
   battle's recorder and on every recorder it prepares later in this run (A1: Auto stays on across battles until
   turned off; it resets to the Settings default when a new run starts; headless runs always start with it off).
3. Setting `autopilot` emits the recorder's internal `_submitted`, so a decision already waiting for the player is
   taken at once (today's `_on_auto_toggled` behaviour, now in one place).

### 2.2 A party decision (DECISION window) with Auto on
`ActionRecorder.choose(battle, unit)`, in order:
1. Queued dev decisions (unchanged).
2. Queued ult **presses** by the player (unchanged: a press always beats Auto).
3. `autopilot.interrupt(battle)`: a ready ult worth casting (only with A2 `ults` on). Returned as an interrupt choice;
   the battle fires it and asks again, like a press.
4. `autopilot.choose(battle, unit)`: the turn action (`AutoPolicy.choose` checks the ult rule first too, so it may
   still return an ult). Returned at once; no `action_requested` is emitted, so the panel shows no ability list.
5. Only if the autopilot returns `{}` (nothing legal): the refusal count is set to the limit and the recorder waits
   for the player as today.

### 2.3 Between actions (BETWEEN window)
`ActionRecorder.interrupt(battle)`: queued presses first (unchanged), then `autopilot.interrupt(battle)` when Auto is
on. Enemy interrupts still come first in the window (spec ult-interrupts 2).

### 2.4 Recording and refusals
- Every choice the battle accepts is logged by `after_party_turn` / `after_interrupt` exactly as a manual pick
  (same `ActionEntry` shape, `extra` and `interrupt` flags). The recorder counts accepted autopilot choices in
  `auto_picks` (A5), outside `entries`.
- A refused autopilot choice (should never happen: the policy picks from `can_activate_ability` and
  `target_candidates`) goes from the recorder's `on_invalid` to `AutoPolicy.on_invalid`: `push_warning`, the next
  `choose` takes the first legal move; after `ActionRecorder.AUTO_REFUSALS` (2) refusals in a row Auto sits this
  decision out and the recorder waits for the player. An accepted pick resets the count. A warning is an engine message,
  so in tests and reports `ScriptErrorLog` turns it into a failure, which is the intent.

### 2.5 Pacing
Auto picks return without waiting on the UI; animations still gate the battle through the `ViewGate` (skip and speed
unchanged). Presentation only: a battle with the same inputs gives the same hash at any speed and with Auto on or off.

### 2.6 Reports (dev)
`play_report` `smart`: `ActionRecorder.new()` with `autopilot = AutoPolicy.new(AutoPolicy.Options.new())` (player
defaults). `chaos`: `ChaosController.base = AutoPolicy` (its smart share). `auto` (the first-legal scripted baseline)
is unchanged.

## 3. Data contracts
### 3.1 C# (`src/Rpg.Contracts/`)
**No change.** Auto picks are `ActionEntry` rows like any other; nothing in `ActionLog`, `BattleSnapshot` or
`ReplayRequest` says Auto. (A5: an unverified `AutoPicks` count is proposed for the slice 2b battle upload, specified
there, not here.)

### 3.2 GAS tags (yours, `godot_gas/tag_registry.tres`, synced by `sync_tags.tscn`)
A new root, **not** under `Ability.Type.*`: `Battle` sends `Event.Ability.Used.<Type>` for every `Ability.Type.<X>`
asset tag (spec content-pass), so role tags there would send new events. Under `Ability.Role.*` they are read only by
`AutoPolicy` and the validator, and battle hashes cannot change.

| Tag | Meaning | Validator rule (`role_mismatch` when broken) |
|---|---|---|
| `Ability.Role.Damage` | Deals damage | targets enemies; has a row with `damage_mode` SCALED or FLAT |
| `Ability.Role.Debuff` | Applies a `Status.Debuff.*` | targets enemies (the role pass proposes it from a row with `applies_debuff()`) |
| `Ability.Role.Dispel` | Removes enemy buffs | targets enemies |
| `Ability.Role.Heal` | Restores HP | targets allies or self |
| `Ability.Role.Revive` | Brings a dead ally back | targeting `SINGLE_DEAD_ALLY` or `ALL_DEAD_ALLIES`, and every such ability has it |
| `Ability.Role.Buff` | Applies a `Status.Buff.*` (incl. Ward, Taunt) | targets allies or self |
| `Ability.Role.Cleanse` | Removes ally debuffs | targets allies or self |
| `Ability.Role.RestoreMP` | Restores MP (Auto never picks it on its own) | targets allies or self |

An ability may carry several roles (a damaging debuff is `Damage` + `Debuff`). `role_missing` (error): a party action
ability, party ult or usable item's `use_ability` with no `Ability.Role.*` tag. Enemy abilities need none (brains
decide for enemies); a role on one is allowed and checked like any other.

### 3.3 `AutoPolicy` (`game/auto/auto_policy.gd`, exported in every build)
```gdscript
class_name AutoPolicy extends RefCounted
class Options:
    var ults: bool = true          # A2: cast ults worth casting
    var consumables: bool = false  # A4: never spend a CONSUMABLE item
func _init(options: Options = null, content: ContentIndex = null)  # content tells CONSUMABLE items apart
func choose(battle: Battle, unit: BattleUnit) -> Dictionary     # a worthy ult first, else {"ability", "target"}, or {}
func interrupt(battle: Battle) -> Dictionary                    # interrupt choice or {}
func on_invalid(battle, unit, reason, detail) -> bool          # warning; the next choose takes the first legal move
static func has_role(ability, role) -> bool
static func score_of(battle, unit, ability, target) -> int      # moved unchanged from SmartController
static func damage_type(row: ExecutionRow) -> String
```
Decision order (3.9 rules; changes in **bold**): revive a dead ally (`Role.Revive`); heal the most hurt ally when one
is under 45% HP (`Role.Heal`, **by tag, not file name**); **cleanse an ally that is `State.Controlled` or carries two
or more debuffs (`Role.Cleanse`)**; the best-scored enemy move (`score_of`, unchanged, MP reserve 30%); **a
`Role.Buff` move whose status no living ally has yet**; the first legal move. Ults: unchanged rules (two or more
enemies, a boss, a kill; support ults revive or heal a hurt party). Abilities are filtered first by A4: an item
ability whose item is CONSUMABLE is skipped unless `consumables` is on. Deterministic and RNG-free (unchanged).

`HEAL_WORDS` leaves the policy; it survives only in `build_role_pass.gd` as one clue for proposing `Role.Heal`. `RefCounted` with no `Node` or presentation dependency, so the verifier and headless runs
can load it; it never runs during replay (replay reads the log).

### 3.4 `ActionRecorder` (`combat/action_recorder.gd`)
```gdscript
## Spec auto-battle: any object with choose(battle, unit) and interrupt(battle); null = the player decides.
var autopilot: Object = null:
    set(value): autopilot = value; _submitted.emit()
var auto_picks: int = 0   # accepted autopilot choices this battle (A5); never in entries
const AUTO_REFUSALS: int = 2  # refused or empty autopilot picks before the player decides
```
A refused autopilot pick goes to `autopilot.on_invalid`, never to `action_rejected`, so the panel stays quiet.
Duck-typed so `combat/` keeps no dependency on `game/`. The wait loop also wakes when `autopilot` becomes non-null.

### 3.5 Settings (`user://game_main.cfg`, `[settings]`)
| Key | Default | Screen |
|---|---|---|
| `auto_battle` | `false` | Settings: "Start battles on Auto" (read when a run starts; ignored headless) |
| `auto_ults` | `true` | Settings: "Auto casts ultimates" (also sets `GameMain.auto_ults` at once) |

### 3.6 RabbitMQ / Redpanda / Redis
N/A: client-only; nothing is sent. (A5's hint travels with the slice 2b upload when that slice is built.)

## 4. Failure modes
| Case | Behaviour | Test |
|---|---|---|
| Auto pick refused by the battle | warning, first legal move next; second refusal → wait for the player; never logged | `test_auto_refusal_falls_back_to_the_player` (a stub autopilot returning an illegal pick) |
| Auto turned on while a decision waits | taken at once, logged once | `test_auto_toggle_wakes_and_releases` |
| Auto turned off mid-battle | the next decision waits for the player; queued presses still fire | `test_auto_toggle_wakes_and_releases` |
| Player presses an ult while Auto is on | the press fires first at the next window; Auto does not cast the same ult twice (the charge is spent) | `test_press_beats_auto` (ultists at full charge: P1's press fires first, one P1 ult in that window, the battle verifies) |
| Auto with nothing legal (all controlled / no MP) | `{}` → the recorder waits for the player; a controlled unit is skipped by the battle before any choice (unchanged) | `test_auto_refusal_falls_back_to_the_player` (stub `empty`; no real-policy case yet) |
| Auto stays on for the next battle; a new run resets it; `auto` vs the console's own auto | as A1 | `test_auto_command` (`tests/game/test_dev_console.gd`) |
| Same battle, Auto vs the same picks typed by hand | identical `ActionLog` and final hash | `test_auto_log_equals_manual` |
| Auto battle replayed | `ReplayRunner` verifies it; tampered copy → 2002 `MismatchReason` as for any log | `test_auto_battle_replays`, goldens `auto-seed-4`, `auto-seed-4-tampered-drop` |
| Ability with no role / wrong role | validator error `role_missing` / `role_mismatch`; content with errors fails the validator test | `test_content_validator_broken_root` (`EXPECTED_ERRORS` on `broken_fixtures/characters/roles.tres`), `test_content_valid` |
| Player build | `AutoPolicy` loads in the exported `player` build with no `game/dev` class referenced | `test_export_keeps_what_runs`, the player export and `release_check.sh` (which doesn't press Auto yet; a real-content Auto boss fight was played in the dev build) |

**Acceptance scenarios (root `CLAUDE.md`):** this slice covers **scenario 5** only, and only on the client side:
an Auto-made log is an ordinary log, so a tampered Auto log is rejected deterministically with `errorCode` 2002 and a
`MismatchReason` (a verdict, never an HTTP status). Scenarios 1–4, 6, 7 are N/A (no server, queue or cache). Idempotency,
retries and dead letters: N/A (nothing is sent).

## 5. Observability
N/A for Prometheus: no service runs. Local signals:
- Play reports: the `smart` report now runs `AutoPolicy` through `ActionRecorder`; the report JSON gains
  `"autoPolicy": "<options>"` so a report says which options it measured.
- `messages on Message.Battle`: the battle-finished message payload gains `autoPicks` (presentation only).
- Later (4b, not built here): if A5 is accepted, a bounded label `auto` = `true|false` on battle counters is allowed
  (two values; never ability or character ids as labels).

## 6. Test plan
### Unit tests (`tests/game/test_auto_policy.gd`, replaces `test_smart_policy.gd`)
- Every case of today's `test_smart_policy` moved over unchanged in meaning (revive, heal below 45%, weakness ×2,
  drain never, break ×1.5, kill ×1.3, area sums, MP reserve, ult rules), with heals found by `Ability.Role.Heal`.
- New: cleanse a `State.Controlled` ally; buff only when no ally has the status; consumable item skipped by default
  and used with `consumables = true`; `ults = false` never returns an interrupt.
- Determinism: same battle twice → same choices; no RNG draw (the battle's RNG state is unchanged after `choose`).

### Recorder and panel (`tests/combat/test_action_recorder_auto.gd`, `tests/game/test_auto_battle_ui.gd`)
`test_panel_auto_button`: pressing the panel's Auto turns on `GameMain.auto_battle`, clears the waiting choices and
plays the battle; the button shows Auto still on in the next battle; turning it off hands the next decision back with
its choices shown. (It found a bug, now fixed: with animations skipped the hand-over can finish the battle at once, so
the panel clears its choices before turning Auto on.)
The section 4 rows above, on fixtures; the panel's Auto button and the `auto` console command set the same
`GameMain.auto_battle` (parity test entry); Auto persists into the next battle of the run and resets on a new run.

### Validator (`tests/game/test_content_validator.gd`)
`role_missing`, `role_mismatch` on a new broken character (`tests/broken_fixtures/characters/roles.tres`, its
abilities in `broken_fixtures/abilities/`); `content/` validates clean
once the roles are added.

### Golden vectors (`tests/fixtures/golden/`)
- New combat golden `auto-seed-4.json` (+ `.trace.json`): a fixture battle fought by `AutoPolicy` (strikes, combos
  and a Flask heal; no revive or ult in this seed), recorded as `ActionLog` v2, plus `auto-seed-4-tampered-drop` (the
  Flask entry removed), rejected with 2002 `TurnMismatch`. A target tamper verifies here (both grunts die either way).
- Existing combat goldens: **unchanged** (role tags send no events). A test asserts it: every combat golden replays to
  its committed hash after the fixtures gain role tags.
- `seed_report_play.json` (policy `auto`): unchanged. Smart report goldens, if any, are re-recorded once, as an
  intentional change, with the diff explained in the commit.

### C# (`tests/Rpg.Contracts.Tests`)
The cross-check against Godot goldens picks up `auto-seed-4.json` (no new DTO).

### Balance (not a test; a step)
After the change, the smart four-member report on The Descent is re-run (memory: gold standard first). A4 (no
consumables) and the cleanse and buff rules will move the 35.7%; the new number goes in `specs/playable-demo.md`.
Measured 2026-10-27: 106/300 won (35.33%), 0 violations.

### Done when
Both suites pass; validator clean on `content/`; the player export plays a battle on Auto (`release_check.sh`);
the smart report is re-measured and recorded.

Follow-ups (not blocking, 2026-10-27): a real-policy "nothing legal" case; `release_check.sh` pressing Auto; the
report JSON `"autoPolicy"` and the battle-finished message's `autoPicks` (section 5).

## 7. Files
| File | Change |
|---|---|
| `client-godot/game/auto/auto_policy.gd` | new (from `smart_controller.gd`) |
| `client-godot/game/dev/smart_controller.gd` | removed; `play_report.gd`, `chaos_controller.gd`, `export_presets.cfg` follow |
| `client-godot/combat/action_recorder.gd` | `autopilot`, `auto_picks` |
| `client-godot/game/game_main.gd` | `auto_battle`, options from Settings, set on each recorder |
| `client-godot/game/dev/content_validator.gd` | `role_missing`, `role_mismatch` |
| `client-godot/game/dev/commands/auto.gd` | new console command |
| `client-godot/game/tools/build_role_pass.gd` + `.tscn` | new builder (`RolePass`): proposes role tags (dry run); `--write` adds them to existing abilities as a one-line text edit; exit 3 while an ability has no role |
| `client-godot/game/tools/sync_tags.gd` | `AutoPolicy.ROLES` always checked against the registry |
| `client-godot/tests/fixtures/` builders | role tags on fixture abilities (`build_fixtures.gd` `ROLE_OVERRIDES` where the role pass misses one) |
| `client-godot/presentation/demo/ui/battle_panel.gd`, `settings.gd` + scenes | yours, edits shown first: Auto button drives `GameMain.auto_battle`; `_auto_pick` deleted; two Settings rows |
| `godot_gas/tag_registry.tres` | yours: the eight `Ability.Role.*` tags |

## 8. Decisions (decided 2026-10-26 by the user; A8 on 2026-10-27)
- **A1 Scope: run-wide.** Auto stays on across battles until you turn it off; a new run starts from the Settings
  default (`auto_battle`, off). Not saved per battle. Headless runs ignore the setting (tests and reports).
- **A2 Ults on Auto: yes, by the smart rule**, with a Settings switch (`auto_ults`) to hold ults for manual presses.
  Your presses always fire first.
- **A3 No Simple / Smart choice for players.** One policy, as the roadmap asks. The dev `auto` (first legal) policy
  stays as a report baseline only.
- **A4 Auto never spends consumable items** (cooldown items are fine), unlike today's smart policy, which does. This
  changes the balance gold standard; the report is re-measured (section 6).
- **A5 Analytics: record it as an unverified hint, outside the log.** The recorder counts `auto_picks` per battle;
  nothing goes in the `ActionLog`, `RunState` or any hash (it can't be verified, and the log stays the player's
  inputs only). Slice 2b's battle upload carries `AutoPicks` as a hint; 4b may aggregate "share of battles on Auto".
- **A6 Roles as `Ability.Role.*` asset tags** (eight with A8, section 3.2), not under `Ability.Type.*`, checked by the validator.
  The tags on your demo abilities are proposed by `build_role_pass` from today's rows and word list, and written only
  after you approve the diff.
- **A7 Two new smart rules (cleanse, buff)** so the new roles are used. Drop them if you want this slice to change
  only where the code lives; then `Buff`/`Cleanse` tags are recorded for later.
- **A8 MP restore is its own role, `Ability.Role.RestoreMP`** (Ether, Honey Cake), not Buff. Auto never picks it on
  its own; the role pass proposes it from an effect that adds to `mp` (a modifier or a percent-of-max ExecCalc).
