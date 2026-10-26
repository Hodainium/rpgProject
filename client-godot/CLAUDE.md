# Godot 4.7 (.NET) + GodotGAS Client Rules

GodotGAS v1.1.2 by YulRun (`res://addons/GodotGAS/`, repo `yulrun/godot-gas`) is a pure-GDScript Gameplay
Ability System and the **only** combat implementation. The same project also runs headless as the server's replay
verifier (see "Battle workflow decisions" in the root `CLAUDE.md`), so all combat code must run without rendering.

## 0. Ownership: the user's design work is protected
| Folder | Owner | What lives there |
|---|---|---|
| `combat/` | System (Claude) | Battle kernel (spec `combat-replay-core`): `Battle`, `TurnManager`, `CombatASC`, `BattleAbility`, `ExecutionRow`, gates, recorder, state hasher, replay runner, headless entry `combat/headless/replay_main.tscn`. No balance numbers. |
| `game/` | System (Claude) | Run layer (spec `game-skeleton`): content types in `defs/`, floor generator, `RunState`, `RunController`, `GameMain` shell (main scene), `ViewGate`, one-time example-set builder `tools/build_demo.tscn`. No balance numbers. |
| `game/dev/`, `addons/rpg_dev/` | System (Claude) | Dev tools (spec `dev-tools`): console and its commands, sandbox, validator, templates, room grid ops, seed runner, Play entry scene, dev content (`game/dev/content/`); our editor plugin (dock, room grid, Play buttons). |
| `tests/` (except `fixtures/`) | System (Claude) | In-house test runner `run_tests.tscn`, `TestCase`, system tests in `tests/combat/` and `tests/game/`, fixture builder `tests/tools/`. |
| `content/` | **User** | Abilities, `GameplayEffect` `.tres`, ExecCalcs, characters, cue definitions, balance values. |
| `presentation/` | **User** | Battle scenes, UI, VFX, animation, flare. Listens to `combat/` signals and never changes combat state. |
| `godot_gas/` | **User** (via GodotGAS dashboard) | Tag registry, attribute drafts, generated files. |
| `tests/fixtures/` | System (Claude) | Frozen test-only content for system tests. Never references `content/`. |
| `addons/GodotGAS/` | Vendored | Never edited by anyone; upgrade only by replacing the whole addon. |

- `content/`, `presentation/` and `godot_gas/` have `ask` permission rules: every edit there prompts the user.
  Create files there only when a spec needs them or the user asks, and edit them with minimal `Edit`s.
- **Design help on request:** when the user asks Claude to create abilities, effects, rooms, encounters or other content:
  - New files: fine. List every path created, and every value Claude picked (so the user knows what to playtest).
  - Existing files: **always ask first, in chat**, before changing anything, even when the request implies the change.
    Show each value as `old → new` and name the content that uses that file (other abilities, units, encounters).
    Change only what was agreed: no "while I'm here" tweaks, no reformatting, no reordering.
  - Never delete, rename or move a design file without explicit confirmation.
  - Start from a clean git tree so the result is one reviewable diff. Leave it uncommitted for the user to playtest;
    commit as `design:` only when asked.
  - Reason: small tuning changes cause hard-to-find bugs and need extensive playtesting. Never replace a whole file with `Write`, and never
  remove values, functions, nodes or cues you didn't add in this task. **Never change these folders through shell
  commands** (sed, mv, rm, redirection, or scripts), which would bypass the permission prompt.
- **One approved exception:** `game/tools/build_demo.tscn` (spec `game-skeleton` 3.8) writes the example set through
  `ResourceSaver` into `content/demo/` and `presentation/demo/` only, and never overwrites an existing file. Run it
  only with the user's go-ahead. `game/tools/build_animation_sets.tscn` (spec `animation-sets` 3.3) works the same way
  for `presentation/demo/animation_sets/` (the default unit animation set).
- **Approved generators (2026-10-20):** `game/tools/generate_attributes.tscn` (the dashboard's attribute Generate,
  headless) and `game/tools/sync_tags.tscn` write GodotGAS's generated files in `godot_gas/` the way the dashboard
  does. Claude runs them after editing `attributes_draft.cfg` or the tag registry (each edit itself still prompts).
- If system code needs something from a design file (a new signal, field or tag), propose the exact change and say why.
  Don't restructure the file.
- **System tests run only against `tests/fixtures/`**: determinism, tamper detection, turn order, hash stability.
  The user's tuning in `content/` must never be able to fail them. A failing system test means system code changed.
- **Content golden replays** (recorded from real `content/`) are expected to change when the user tunes. When they
  fail, ask whether the change was intentional. If it was, re-record them and suggest `/sync-spec`. Never "fix" content to make them pass.
- **Godot editor:** before editing any `.tscn`/`.tres`, remind the user to Save All in the editor if it might be open.
  Afterwards, tell them to accept Godot's "reload from disk" prompt.

## 1. Language split (decided 2026-10-19)
Rule: **GDScript for anything that touches GodotGAS or is authored in the editor; C# for everything else that gains
from C#.**
- **GDScript (GodotGAS):** all combat: `AbilitySystemComponent` nodes, `GameplayAbility` scripts,
  `GameplayExecutionCalculation` scripts, `GameplayEffect` resources, `GameplayCue`s, the turn manager, and the seeded RNG.
  Also content types (rooms, items, events, loadouts…), the run layer (`game/`: floor generator, run state, run
  controller), dev tools, and **any UI that reads GAS values**, as long as it isn't performance-critical.
- **C# (.NET):** the backend (server, verifier-worker host, outbox relay, SignalR), `Rpg.Contracts`, `Rpg.Client`, and in
  Godot: server sync (HTTP, retries, quick messages, offline queue), save/load, settings, telemetry, platform services,
  physics/movement (in-room walking, later), pathfinding, procedural meshes and other heavy computation with no GAS
  dependency. UI that never reads GAS values may be either. Never put combat math or RNG in C#, and never re-implement
  run rules in C# (the server verifies runs through headless Godot, like battles).
- **The boundary is coarse and data-only:** C# and GDScript exchange whole `Rpg.Contracts` records as JSON (`WireJson`
  on the GDScript side) through one adapter, never chatty `Call()`/`Get()` glue. Glue loses compile-time checking,
  converts every value through `Variant`, mixes `await` and `Task` badly, and invites determinism bugs (locale
  `ToString`, `Dictionary` order, float math) that show up as false 2002 rejections.
  `rpgDemo.csproj` (`Godot.NET.Sdk/4.7.2`, `net10.0`) references `src/Rpg.Client`; no C# scripts yet. The local
  `Directory.Build.props`/`Directory.Packages.props` deliberately shield it from the repo-root build settings.

## 2. GodotGAS conventions (verified against addon source)
- **Extending GodotGAS (Lyra-style):** subclassing addon classes in `combat/` to make them bespoke to this project is
  allowed (e.g. `CombatASC extends AbilitySystemComponent`, `BattleAbility extends GameplayAbility`). Keep each subclass
  minimal and in GodotGAS's design philosophy: add project concepts, don't reimplement or fight the addon. Never edit
  the addon itself. Where a subclass relies on addon internals (`_`-prefixed members), pin that behaviour with a test.
- **Generated files:** `res://godot_gas/gameplay_tags.gd` and the AttributeSet scripts in `res://godot_gas/attributes/`
  are generated by the GodotGAS editor dashboard from `tag_registry.tres` / `attributes_draft.cfg`. Edit the
  registry/draft, then regenerate (tags: `sync_tags.tscn`; attribute sets: `generate_attributes.tscn`, same text as the
  dashboard's Generate, pinned by `test_attribute_generator`). Never hand-edit the generated output. (Paths are the defaults in
  `addons/GodotGAS/utilities/project_settings.gd` and can be changed under Project Settings → `godot_gas/`.)
- **Tag format:** dot-separated PascalCase segments, any depth (`^([A-Z][a-zA-Z0-9]*)(\.[A-Z][a-zA-Z0-9]*)*$`).
- Use `GameplayTagQuery` resources on abilities and effects. Exported tag fields use `@export_custom(PROPERTY_HINT_NONE, "gas::tag")`.
- `GameplayAbility.try_activate()` is a coroutine returning `bool`. Await it when you need the result.
- Payload path: `TargetData → GameplayEffectContext → GameplayEffectSpec → AbilitySystemComponent`.
- Never assign `AttributeData.base_value`/`current_value` directly during gameplay. Use an instant effect.

## 3. Determinism rules for combat
- **Turn-based durations only:** use `DurationPolicy.TURN_BASED` (`duration_turns`, `period`, `tick_on_turn_start`).
  The battle drives them through `CombatASC.turn_start()` (DoTs/HoTs tick) and `turn_end()` (buffs/debuffs count
  down); never call GodotGAS's `advance_turn()`. Never use `DURATION` or real-time `period` on combat effects; those
  run on `_process(delta)`.
- **Abilities await only the presentation gate:** a `BattleAbility` resolves its execution sequence (read from its
  animation's `execute` keys) and awaits nothing but `battle.gate` between executions. Never `task_wait_delay`,
  `task_play_animation`, timers or signals in combat abilities: in replay that is a runner error (`ContentAwaitedFrame`).
  Animation `execute` keys only release the gate; they never apply effects, change attributes or draw from the RNG.
- **Avoid concurrent activation in combat:** `asc.try_activate_abilities_by_tag()` does not await the abilities
  it starts, so passives triggered by events can interleave. Activate combat abilities one at a time with `await`.
- **Fixed-point ×100, whole numbers only:** designers type values with up to 2 decimals (`150` = 150%, `80.5`); authoring
  fields save them ×100 as whole numbers, once, at edit time. Attributes are GodotGAS `float`s but always hold whole
  hundredths. In ExecCalcs and `pre_attribute_change`, use the `combat/fixed.gd` helpers (integer division truncating
  toward zero) and nothing else: no `roundi`/`floori`/`round` in combat math, and no `pow`/`sqrt`/`exp`/trig, whose last
  digit can differ between Windows and Linux. The only rounding is the edit-time conversion and the `CombatASC` snap.
- **Order matters for instant effects:** aggregation is order-independent only for active, non-periodic modifiers.
  Instant and periodic effects mutate `base_value` in application order.
- **One seeded RNG per battle:** combat draws only from the battle's single `RandomNumberGenerator` instance, seeded with
  the server-issued seed. Never use the global `randf()`/`randi()`/`randomize()`, and never create other RNG instances in combat.
  Percentage rolls use `rng.randi_range(0, 9999) < chance` (chance stored ×100, so 5.25% = `525`); avoid `randf()`, which goes through floats.
  Every roll is part of the replay, so the number and order of rolls must depend only on combat state, never on visuals or timing.
- **Triggered passives go through the trigger queue:** an ability with `trigger_event_tag` never activates inside
  `send_gameplay_event`; `CombatASC` queues it (`Battle.triggers`, FIFO, chain cap 10) and the battle drains the queue
  after battle start, turn start, each action and turn end, awaiting each one. Never activate abilities from signal
  handlers. Triggered abilities are never actions (`action_abilities()` skips them).
- **Field mode (out of battle) is a Battle too:** `Battle.setup_field` builds the party only, tags every unit
  `State.Infield`, and `perform()` / `apply_to_units()` change it through GAS; the run reads HP/MP/ult charge back.
  Map-only spells use an activation query requiring `State.Infield`. Run-level randomness uses only `RunSeeds` streams
  (`floor/<n>/...`), never the battle RNG or global `randi()`.
- **Contract JSON goes through `WireJson.stringify`:** Godot parses every JSON number as a float; `WireJson` writes whole
  numbers as integers so the C# records can read them.

## 4. Running tests and replays
- **Headless Godot must always exit:** run it through `../tools/watch.sh` (liveness every 30 s; killed with exit 124
  after 180 s of silence) and pass `--quit-after <frames>`. The `Watchdog` autoload quits a headless run whose main
  scene script failed to load (exit 70) or that gets no `Watchdog.beat()` for `--idle-limit` seconds (default 180, exit
  124); call `Watchdog.beat(label)` in any new long-running tool loop. Script errors once left headless scenes idling
  (9 minutes in 2026-10-19, six report shards in 2026-10-26). Game goldens live in `tests/fixtures/golden/game/`.
- **Parallel by default:** the suite runs as `../tools/godot_tests.sh` (shards by test, default 8); reports shard
  with `game/tools/play_sharded.sh`; independent jobs start together and are waited on.
- **System tests:** `godot --headless --path client-godot res://tests/run_tests.tscn` (add `-- --filter <text>` to
  narrow). They run as a **scene**, not with `--script`: GodotGAS needs its `GameplayCueManager` autoload, which
  `--script` mode doesn't load. A test file that fails to compile counts as a failure.
- **Goldens:** regenerate only on purpose with `-- --update-goldens --filter test_golden`, then rerun the C# tests
  (`BattleGoldenTests` cross-checks the same files).
- **Tag checkpoint:** `res://game/tools/sync_tags.tscn` checks every `gas::tag` field under `res://content/` plus the
  code's system tags against the registry, and regenerates `gameplay_tags.gd` with GodotGAS's own generator. It writes
  the registry only with `-- --add-missing` (through the registry's `add_tag()`). Run it after adding content or tags.
- **Attribute checkpoint:** `res://game/tools/generate_attributes.tscn [-- --check] [--set Unit]` regenerates each
  AttributeSet script from `attributes_draft.cfg`; `--check` writes nothing and exits 1 while one is out of date.
  After a GodotGAS upgrade, Generate once in the dashboard and copy draft + output into
  `tests/fixtures/attribute_generator/` so the test pins the new builder.
- **Fixtures:** `res://tests/tools/build_fixtures.tscn` rebuilds `tests/fixtures/`; rerun only when fixtures must change.
- **Replay one battle:** `godot --headless --path client-godot res://combat/headless/replay_main.tscn -- --in req.json
  --out result.json [--content-root res://content/]`; exit code 0 Verified, 2 Rejected (2002), 1 runner error.
- **Find where a battle diverges** (spec `atomic-battles`; the log has no per-action hashes): `trace_main.tscn -- --in
  req.json --out trace.json --lines [--content-root ...]` writes the hash and canonical lines after every action;
  `trace_main.tscn -- --diff a.json b.json` prints the first divergent action and the differing lines (exit 0 match,
  3 diverged). The client side comes from the console's `trace on` (`user://traces/`).
- After adding or renaming a `class_name` script, run `godot --headless --path client-godot --import` once so the
  global class cache is current.
- **Godot 4.7.2 GDScript quirks hit here:** inside a class, its own enum `Side` and `BattleUnit.Side` count as different
  types (pass enums as `int`); building, sorting and reading arrays in one static function corrupted entries (see
  `ExecutionReader`); a static method Callable from a static function passed bad arguments to `sort_custom` (use a lambda).

## 5. Dev tools (spec `dev-tools`): how Claude uses and extends them
- **Every tool works without a window.** Each editor button has a console command running the same code (`create`,
  `grid`, `play`, `validate`), checked by `test_tool_parity` in `tests/game/test_dev_console.gd`. A new tool or
  button must ship with its command (add it to that test).
- **Play the game headless** with the script runner: one console command per line in a text file, then
  `godot --headless --path client-godot --quit-after 100000 res://game/tools/dev_run.tscn -- --script <file>
  --out <state.json> [--content-root res://tests/fixtures/] [--commands <folder>] [--manual]`. Battles run on auto
  unless `--manual` (then `act`). Exit 0 ok, 2 a command failed (named), 1 tool error. `--window --shots <dir>` (no
  `--headless`) lets `shot <name>` save screenshots.
- **Add a command:** copy `game/dev/commands/_template.gd` (one file, found automatically; give it a test). For a
  one-off check, write it in the scratchpad and pass `--commands <folder>`: it is copied to `user://dev_commands/` and
  leaves nothing in the repo. Commands change units through GAS (effects, items) and the run through `RunController`
  (cheats: its `dev_*` methods, or `run.dev_log()` first). If a command needs a hook the run layer lacks, add a small
  method to system code, never to content.
- **Never point `create`, `grid ... save` or the dock at `res://content/` on Claude's own initiative.** Test on
  `user://` copies or fixtures; the user's files change only through `Edit`/`Write` and their permission prompt.
- **Play whole runs headless** (spec `playable-demo`): `res://game/tools/seed_report.tscn -- --play [--policy chaos]
  [--check] --count 200 --out <report.json>` (large `--quit-after`). Auto plays `RunPlayer`'s policy; chaos plays
  bad and illegal moves on its own seeded stream, checks invariants and replays every battle; failing battles are saved
  next to the report for `replay_main` / `trace_main --diff`. Exit 3 on a stopped run or a violation.
  Balance on the gold standard first, alone: `game/tools/play_sharded.sh 12 <out.json> 1 300 --policy smart
  --party-size 4 --check` (12 parallel shards, merged exactly; about 45 s instead of 4 min). Other policies only
  after it is on target.
- **Check content:** `res://game/tools/validate_content.tscn` (exit 3 on content errors) and the `test_content_valid`
  content test. Seed statistics: `res://game/tools/seed_report.tscn -- --count 1000 --floor 0`.
- Rebuild generated dev and test data only on purpose: `game/tools/build_dev_content.tscn` (dev effects and stat items),
  `tests/tools/build_broken_fixtures.tscn` (validator fixtures).


## 6. UI (spec `ui-framework`): how screens are added
- **The UI is data:** `presentation/demo/ui/ui_policy.tres` (a `UIPolicy`) names the layout, the screens (pushed onto
  layer stacks `UI.Layer.Game/GameMenu/Menu/Modal` by `UI.State.*` tag queries), the HUD panels (plugged into
  `UIExtensionPoint` slots `UI.Slot.*`), the Esc screens and the confirm dialog. Framework code is `game/ui/` (system).
- **A new screen or panel = a scene whose root extends `UIScreen` + one entry in the policy.** Never wire screens in
  `GameMain` or from another screen's code. A menu inside a menu is a `UIPushButton` (scene and layer set in the
  inspector) or `ctx.ui.push(layer, scene, payload)`; Back is Esc, `UIBackButton` or `ctx.ui.back()`.
- Screens read the game through `ctx` (`ctx.main`, `ctx.run`, `ctx.state`), connect to the run with
  `ctx.on_run(self, "signal", callable)` (rebinds on each new run), and change it only through `RunController`.
- Repeated rows are `UIList` + an entry scene with `set_item(item, ctx)`; looks (colors, sizes, rarity) are theme type
  variations in `ui/ui_theme.tres`, and screen texts are `@export`s, not literals in code.
- Check it: `test_ui` (framework, built in code), `test_demo_ui_policy` and `validate_content.tscn` (`UIPolicyCheck`),
  window runs driven with the console's `ui press <name or text> [n]` / `ui back` / `ui`.
