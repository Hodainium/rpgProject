# Spec: class-pick (slice 5b4): the class pick screen, Mewgenics-style

Status: **built and playtested 2026-11-19 on `feat/class-pick`; spec synced to the build (playtest decisions in section 8).** Part 1 of the character slice (the look touch-up) is done on
`design/character-touchup` (Arcanist hat straight and on the head, Plaguewright plague-doctor look, all 11 card portraits re-shot at
2160 px, imported at 1024 with mipmaps, lossless). This spec is Part 2: the new class pick screen, including spec `card-ui` 2.6 (locked
classes), which moved here on 2026-11-18.

Layout reference: the browser prototype in `specs/design/class-pick-prototype/` (README), published at
https://claude.ai/artifact/SVtwmh3LZWw89eSRQ95EFk. Feel reference: Mewgenics' "Equip Class Collars" screen
(`H:\assets\references\mewgenics\char select.jpg`): layout and feel only, never its art or characters.

### Decided in discussion (user, 2026-11-18)

| # | Decision |
|---|---|
| D1 | Left: a carousel of the classes, turned left and right (only the arrows, D13). Right: the party, then recommended parties, then Lock in. |
| D2 | Carousel **A, the turntable**: every class stands on one ring, the selected one in front. (B, a frame with one neighbour each side, was not picked; the gold frame around the front cube was dropped in the playtest, P1.) |
| D3 | The carousel is a **live 3D view**: the real cubes with their attachments, look effects and idle motion, lit like the portrait studio. The cubes travel in and out **with the ring's rotation**, always facing the screen, and shrink away toward the back of the ring (P4); the selected cube **sways gently** in front (Q2: no full turn, its face stays toward the screen) while its floor effect holds still (P3). |
| D4 | The rising motes take the selected class's colour, **blending** from the old colour to the new one. The colour is the portrait studio's approved rim colour, falling back to the class's `display_color` (Q1). |
| D5 | Under the stage: the class name, role (in title case, P9), description, its moves by type, the "Learns" line, and the stats as **plain numbers** (no bars). |
| D6 | The party shows as **portrait slots** (the card portraits). Clicking a member removes it. |
| D7 | Recommended parties: a developer-made list for now (no win or play rates yet; the analytics backend comes later). No description line under a preset. |
| D8 | A class the account does not own is **greyed** and cannot be added; when it is in front (and the ring has stopped) a **lock icon** shows over it (P8). A preset holding one fills its slot **empty**; nothing else marks it (no message, P10). |
| D9 | The footer says **"Only N slots filled."** when the party is short; never anything about starting short-handed. |
| D10 | The run picker, the seed field and the content-root picker are **removed** from this screen. A dev console command opens them as a modal for debugging; the player build has none. |
| D11 | With nothing set in that modal, a run is the content's **default run** (`RunStructure.default_run`, The Descent): the intended player experience. |
| D12 | Every cube on the ring plays its look effect (Q3). |
| D13 | **Only the arrows turn the ring** (Q8): the two arrow buttons and the Left / Right keys (and their UI actions). Hovering or clicking a cube or a party member, and the mouse wheel, never turn it. |
| D14 | The screen keeps its own layout (stage left, party right) but is built only from the common UI parts (Q4); windows are never nested (P7, the FF7 reference). |

## 1. Purpose & enterprise mapping

The player picks up to four classes on one screen built around the cubes themselves, sees what each class does, can load a ready-made
party, and starts the run. In server mode the screen shows which classes the account owns, so the run start's `400 1409
CharacterLocked` is never reached by a player who only presses what the screen allows.

Backend components used (none new):

| Component | Use |
|---|---|
| `GET /api/v1/cards/catalog` (slice 5) | Which classes are core (the catalog's `core` flags); an empty catalog means the server enforces nothing (2.3). |
| `GET /api/v1/cards/collection` (slice 5, account-session 5b1) | Ownership: owned = core characters + the collection's owned character cards, read through `ServerLink` with the account session (the session's own snapshot when it is new). |
| `POST /api/v1/runs` (server-authority, card-collection) | Unchanged. It still validates the party against the account (1409) and stays the authority; the screen only avoids the refusal. |
| Postgres, Redis | Only behind those two endpoints, as today (the collection read falls back to Postgres when Redis misses). |
| RabbitMQ, Redpanda, outbox, verifier | Not used. |

Later (not this slice): recommended parties by win rate and play rate come from the analytics read API (party composition per verified
run, projected from the event log; root `CLAUDE.md`, "Player analytics"). This spec leaves a seam for that source (3.2, `PartyPresetSource`).

## 2. Sequence flow

### 2.1 Screen layout (one screen, Menu layer, `UI.State.Menu`)

```
+------------------------------------------------------------+------------------------------+
| < Back   Choose your party                                 | PARTY                  2 / 4 |
| +--------------------------------------------------------+ | [Warrior][Cleric][ ... ][ ...]|
| |   (3D turntable: 11 cubes on a ring, live)             | |  portrait slots, click=remove |
| |   <           front cube (a lock if locked)         >  | +------------------------------+
| |                    front cube sways                    | | RECOMMENDED PARTIES          |
| |   rising motes in the class colour                     | |  Classic Four      All owned |
| +--------------------------------------------------------+ |  [4 portraits]               |
|   o o o * o o o o o o o   (position dots, hollow = locked) |  Iron Wall       1 not owned |
| +--------------------------------------------------------+ |  [4 portraits, greyed one]   |
| | Warrior             Damage Dealer / Off-Tank           | |  ...                         |
| | description (always two lines high)                    | +------------------------------+
| | Locked · In party                                      | | Only 2 slots filled. [LOCK IN]|
| +--------------------------------------------------------+ |                              |
| | Basic Strike  Skill Provoke  Ult Cleave  Ult Execute   | |                              |
| | Learns: Lv 3 Ice Blast · Lv 5 Challenge · ...  HP 1000 | |                              |
| | [Add to party]  or  "Find X in a pack or craft it."    | |                              |
| +--------------------------------------------------------+ +------------------------------+
```

Built only from the common UI parts (`specs/ff7-ui.md` 2.12, D14): FF7 windows from `ui_theme.tres` (`UIWindowStyle`), Back top
left (`UIBackButton`), the class card on `description_window`, the presets as a `UIList` with entry scenes, buttons and texts from
the theme; new look goes into the theme, not overrides. It does not inherit `menu_frame.tscn` (its description window sits under the
stage and the characters are the stage itself); `ff7-ui` 2.12's list gains a line naming this screen's layout as the exception, and
the party slot and preset row join the shared component list for reuse. The class card is **two windows stacked edge to edge**: the
description window on top (name, role, description, the Locked / In party line) and a window with the moves, the Learns line, the
stats and Add below; never a window inside a window (P7, the FF7 reference in `H:\assets\references\ff7\`). The card keeps one
height for every class (the description takes `description_lines` 2; the chips and Learns lines keep their place when empty), so it
never jumps as the ring turns. The role reads like a title (`title_case`: "Damage Dealer: Magic", small words lower case; P9).

### 2.2 The carousel (presentation only)

- A `SubViewport` with its own 3D world (like `FxStage`; sized to the window's real pixels with `FxStage.screen_pixel_ratio`, with the
  player's anti-aliasing) holding a `ClassCarousel3D`: every selectable character's real view (`UnitAnimator.instantiate_for`, the
  main `StyleRegistry` look, attachments, look effect) on an **oval** ring (`ring_radius` x `ring_depth`; the numbers live in
  `class_carousel.tscn`), the front place on the camera axis, every view facing the camera (`UnitAnimator.facing_override` 0; the
  style registry is not touched).
- The lighting is the portrait studio's (`PortraitStudio`, `presentation/demo/cards/portrait_studio.tscn`): key spot, rim and glow
  lights and the rising motes. The rim, glow and mote colours follow the **selected** class (`PortraitStudio.rim_colors`, else the
  class's `display_color`) and blend from the previous colour over `color_blend_seconds` (D4).
- Turning: a turn eases in and out over `turn_seconds` (0.25 s; the same curve both ways, P5); a turn pressed while one is under way
  carries on from where the ring is with an ease-out only, so a held key flows. It wraps around (left of the first is the last). The
  cubes ride the ring and keep facing the screen: no cube turns about itself (D3). Once the ring rests, the front cube sways about its
  Y axis by `sway_degrees` (±15°) over `sway_seconds` (a sine, 3 s a cycle), so its face never leaves the screen; a cube that leaves
  the front eases back to facing the camera.
- Cubes shrink away from `shrink_start` (1) places from the front and are gone (hidden) at `shrink_end` (2.6): the back of the ring
  never reaches the studio's wall, and a cube grows as smoothly coming in as it shrinks going out (P4, P5).
- Look effects on the ring (P3, P6): each view plays its look effect on an upright `look_anchor` child
  (`UnitAnimator.upright_look_effect`), counter-turned against the sway so a floor ring never spins; the anchor is measured as its view
  (`FxAnchor.measured_node`), so the effect sits on the floor; on the ring the effect's particles live in the cube's own space (they
  scale and travel with it), the ring takes that space again after a quality change, and a cube coming into view has its particles
  cleared (no flash on the side it wrapped from).
- A locked class's cube is greyed (`UnitAnimator.set_greyed`: the grey paint without the death pose, no look effect; it keeps its idle
  motion, body and attachments together). When it is in front and the ring has stopped, a lock icon shows over it (P8:
  `presentation/demo/ui/icons/lock_filled.svg`, the minimap lock with its body filled, imported at 16x with mipmaps; white, at
  `lock_size` 0.7 of the cube's height, centred on the cube via `ClassCarousel3D.front_on_screen()`; it fades in over
  `lock_fade_seconds` 0.15 and is gone the moment the ring turns). Never on the cubes beside it.
- The stage reuses the portrait studio (`class_carousel.tscn` instances `portrait_studio.tscn`), so the studio now ships in the
  player build.
- Input (D13): only the two arrow buttons and Left / Right (keys and the UI actions) turn the ring, one class a press; holding a key
  repeats at the UI's key-repeat rate. Clicks on cubes, hovering and the mouse wheel do nothing to the ring. Enter adds or removes
  the class in front.
- Cost: every cube and its look effect run live (D12). A `classpick bench` command measures it (6, test plan) and the screen must
  stay within budget on the user's 4K screen; if it does not, the build stops and the user decides (no silent fallback).
- Headless (tests, the verifier): no viewport and no views are built; the carousel keeps only its index. Nothing here is read by
  `combat/`, the run, a hash, a snapshot or an upload.

### 2.3 Ownership

```
screen opens or comes back into view (and on GameMain.server_changed, ServerLink.session_changed)
  local mode (no server)                    → every selectable character is pickable (unchanged; spec card-ui 2.6)
  server mode: the core classes only until the account first answers, then
    the server's catalog (GET /cards/catalog, kept on the link once it has cards):
      empty (cards off or unseeded)         → every class is pickable (the run start enforces nothing either); an empty
                                              catalog is not kept, so it is read again next time
      with cards                            → core = the catalog's `core` cards
    the account (the session's snapshot when it is new, else GET /cards/collection):
      answered                              → pickable = core ∪ owned character cards
      no answer, first time                 → core only; the line says "Couldn't check your collection. Only starter
                                              classes can be picked." (a replaced session: "Your account was opened
                                              somewhere else. Only starter classes can be picked here.")
      no answer, later                      → what the account last said is kept (with the same line)
  (the player build reaches this screen only online: the main menu's New run needs_online, debug builds skip that)
```

`ClassPickModel.ownership(...)` decides it from the core ids, the collection (or none) and the mode; the screen never decides
ownership itself. `loading` covers the whole read (the console's `classpick` waits on it).

### 2.4 Building the party

- Four slots (`max_party`, 4). Add puts the class in the first empty slot; a class is in the party at most once; a full party
  disables Add and the hint says "The party is full. Click a member to take it out."
- Clicking a filled slot empties it (its later members do not shift; an empty slot is filled first by the next Add).
- A preset fills the slots in its order; a class that is not pickable leaves its slot empty (D8); a class listed twice keeps its
  first slot only. No message (P10: the empty slot says it).
- The party opens as last saved (`[menu] party`, as today; a root without those classes, the fixtures, takes its first two); any
  member no longer pickable leaves its slot empty. A party the player has changed before the account answers is kept (only a real
  change counts). While Lock in is starting, the ring and the party do not change.
- Lock in is disabled with no member. The footer: nothing at 4 members, "Only N slots filled." below 4, "Pick at least one class."
  at 0 (D9).

### 2.5 Lock in

```
Lock in
  → GameMain.can_continue(); a continuable run → confirm "Start a new run? Your current run will be abandoned." (as today)
  → save [menu] party
  → GameMain.start_run(ids, seed, run_id)
       seed, run_id, content root: from the dev run setup (2.6) when set; else "" (a random code locally,
       the server's seeds online) and &"" (the content's default run, D11)
  server mode → POST /api/v1/runs { party, session, ... } (unchanged)
       201 → the run starts
       400 1409 CharacterLocked (the account changed elsewhere) → the message line names the class,
              ownership is read again, the locked member's slot empties; nothing starts
       1412 / no answer / 5xx → today's handling (the 1412 dialog, the connecting pop-up)
```

### 2.6 Dev run setup (D10)

- Console command `runsetup [open | show | clear | content <root> | run <id> | seed <code>]`, a file in `game/dev/commands/` (dev and
  full builds only, never in the player pack: `test_export_keeps_what_runs`).
- `runsetup open` pushes `game/dev/run_setup.tscn` on the Modal layer: the content-root picker (when more than one root), the run
  picker (the content's runs, the default marked), the seed field with Random (local mode only; "issued by the server" online), Clear
  and Back. The other forms set the same values from a script.
- The values live in `GameMain.dev_run_setup` (a Dictionary: `content_root`, `run_id`, `seed`; empty = defaults), for the session
  only (Q5: a forgotten test setup never leaks into the next play), and are what 2.5 reads. `runsetup content` switches the root at
  once without writing the Settings (`GameMain.set_content_root(path, persist)`); `clear` goes back to the default root, also one an
  older build saved in the Settings, and is refused outside the menus (the modal's Clear too); seeds are checked (`RunSeeds.parse`),
  and online the seed is the server's. `runsetup show` prints them; Lock in uses them silently, and the class pick's
  footer shows a dev line "Dev run setup: <run> · seed <code>" while any is set, so a test run is never mistaken for the real one.

### 2.7 What goes away

`presentation/demo/ui/title_menu.tscn/.gd` (the old class pick), `class_card.tscn/.gd` and `class_details.tscn/.gd` (nothing else uses
them) are replaced by the new screen; the main menu's New run pushes `class_pick.tscn` instead. They are the user's files; their
deletion in the build PR is approved (Q6). `ClassCard.kit_lines` moves to `ClassPickModel.moves` (system code).

### 2.8 Framework changes found on this screen

- **Effects ignore fog** (P2): the studio's fog tinted the clear edges of every additive or transparent effect quad into grey squares.
  The spatial effect shaders in `game/fx/shaders/` say `fog_disabled`; `FxLayer.without_fog` / `mesh_without_fog` give a layer's
  transparent standard materials (the designer's effect files' own included, as copies) `disable_fog`; the mesh flash overlay too.
  The 11 card portraits were re-shot at 2160 px without the squares.
- `FxStage.screen_pixel_ratio(control)` (shared by `FxStage` and the class pick's stage); `FxParticles3DLayer.apply` sets the layer's
  own `local_coords` on every play (a pooled instance never keeps the carousel's override).

## 3. Data contracts

### 3.1 C# records, queues, topics, Redis

**N/A: no new or changed record, queue, topic or Redis key.** The screen reads `CollectionResponse` (slice 5, 5b1) and starts runs with
the existing `RunStartRequest`; `ApiErrors.CharacterLocked` (1409) is unchanged.

### 3.2 Godot types (system code in `game/ui/class_pick/`, data in `presentation/demo/ui/class_pick/`)

```gdscript
## presentation/demo/ui/class_pick/party_presets.tres: the recommended parties (D7). Design data, outside the ruleset roots.
class_name PartyPresetList extends Resource
@export var presets: Array[PartyPreset] = []

class_name PartyPreset extends Resource
@export var id: StringName          ## stable id, for later analytics joins
@export var display_name: String    ## "Classic Four"
@export var members: Array[StringName] = []   ## character ids in slot order, 1..max_party

## Where a list of recommended parties comes from. This slice ships one source; the analytics slice adds "Top win rate" and
## "Most played" sources (tabs appear only when more than one source is available).
class_name PartyPresetSource extends RefCounted
func title() -> String          ## "Recommended parties"
func presets() -> Array         ## [{preset: PartyPreset, stat: String}]; stat "" for the developer list
class DeveloperPresets extends PartyPresetSource   ## reads party_presets.tres

## Pure, headless-testable: everything the screen shows, from content + ownership + party.
class_name ClassPickModel extends RefCounted
static func ownership(character_ids: Array, core_ids: Array, collection: Variant, server_mode: bool) -> Dictionary
                                                                ## id -> OPEN | CORE | OWNED | LOCKED (no core ids or local mode: all OPEN)
static func moves(character: CharacterDefinition) -> Array      ## [{name, type: Basic|Skill|FollowUp|Passive|Ultimate}], shared kit left out;
                                                                ## names through AbilityName.of, types from Ability.Type.* asset tags
static func learns(character: CharacterDefinition) -> Array     ## [[level, ability name]] from level_skills
static func stats(character: CharacterDefinition) -> Array      ## [[label, number]] HP ATK DEF SPD SP from stats_x100 / 100
static func add(party: Array, id: StringName, max_party: int) -> Array
static func remove(party: Array, slot: int, max_party: int) -> Array
static func apply_preset(members: Array, states: Dictionary, max_party: int) -> Dictionary  ## {party, missing: n}
static func restore(saved: Array, states: Dictionary, max_party: int) -> Array
static func footer(party: Array, max_party: int, short_text, one_text, empty_text) -> String

## The 3D turntable (presentation): turning, sway, shrink, colour blend. Exports, tuned in the scene:
class_name ClassCarousel3D extends Node3D
@export var studio: PortraitStudio
@export var ring_radius: float
@export var ring_depth: float = 1.0         ## above 1 the ring is an oval (the neighbours sit farther back)
@export var turn_seconds: float = 0.25      ## eased in and out
@export var shrink_start: float = 1.0       ## places from the front where a cube starts shrinking away
@export var shrink_end: float = 2.6         ## gone (hidden) from here
@export var sway_degrees: float = 15.0      ## the selected cube's sway, either side of facing the screen (Q2)
@export var sway_seconds: float = 3.0       ## one sway cycle
@export var color_blend_seconds: float = 0.4
signal selected_changed(index: int)
func show_characters(characters: Array, locked: Dictionary) -> void
func turn(steps: int) -> void               ## the arrows (D13)
func select(index: int) -> void             ## script and tests only (console classpick select): turns the shortest way
func turning() -> bool
func front_on_screen(body_height: float = 0.8) -> Rect2   ## the front cube's centre and height in viewport pixels (the lock)
```

The screen `presentation/demo/ui/class_pick/class_pick.tscn` (root extends `UIScreen`), its party slot
`party_slot.tscn` (portrait from `CardArtSet` `card_portraits.tres`; the 1024 mipmapped import) and preset row `preset_row.tscn` (a
`UIList` entry). Texts are `@export`s; the lock is `lock_icon`, `lock_size`, `lock_fade_seconds`, the card's height `description_lines`.
The stage scene `class_carousel.tscn` instances the portrait studio (lights, motes, backdrop and floor; the camera pulled back for the
ring). `UnitAnimator` gains `greyed` / `set_greyed()` / `shows_grey()`, `facing_override`, `upright_look_effect` / `look_anchor`;
`PortraitStudio` gains `apply_color()` and `rim_color()`; `GameMain` gains `dev_run_setup`, `run_start_refused` and
`set_content_root(path, persist)`.

Validator (`validate_content.tscn`, `ClassPickCheck`): `party_preset_unknown_character`, `party_preset_too_big` (more than
`max_party`), `party_preset_duplicate` (a class twice, or two presets with one id), `party_preset_not_selectable`, as errors. It
checks the presets and the party size the screen itself exports (`ClassPickCheck.validate_screen` reads `class_pick.tscn`).

## 4. Failure modes

| Case | Behaviour | Test |
|---|---|---|
| No session or the collection read fails (server mode) | Only core classes are pickable; the message line says so; Lock in works with core classes. | `test_class_pick`: fake bridge failing the read |
| A class unlocked or crafted elsewhere | Ownership is read again whenever the screen comes back into view (from the Collection or Open packs) and on `session_changed`; the cube un-greys. | `test_class_pick` (a re-read keeps owned members); the come-back path itself has no test yet |
| The server enforces no cards (empty catalog) | Every class is pickable; the catalog is read again next time. | `test_class_pick` |
| `400 1409` at Lock in (the account changed elsewhere) | Message names the class, ownership re-read, the slot empties, no run starts. | `test_class_pick` over the fake bridge; e2e `class_pick_locked` |
| `409 1412` session replaced | Today's 1412 dialog (account-session); nothing new. | existing `test_account_session` |
| No answer / 5xx at Lock in | Today's run start handling (connecting pop-up). | existing `test_server_mode` |
| Lock in pressed twice | The button disables until `start_run` returns. | `test_class_pick` |
| A preset names a class the content lacks | Validator error; at runtime the slot is left empty. | `test_class_pick` (in-memory presets) |
| Headless | No 3D built; the model and screen logic still run. | `test_class_pick` headless |

Idempotency, retries, dead letters: N/A here (the run start's own idempotency is unchanged). Acceptance scenarios of the root
`CLAUDE.md`: **none is covered by this slice** (no settlement, queue or verdict). Scenario 4 (Redis flushed) still holds for the
collection read through its Postgres fallback, already tested by the card slices. No replay, so no 2002.

## 5. Observability

**N/A: no server change, so no new Prometheus metric.** Party composition is already in the run start's stored row; the
recommended-party analytics (later) aggregate it from the event log, never as a Prometheus label (root `CLAUDE.md`: no character ids as
labels). Client side: `classpick bench` reports the screen's frame time (avg, p95, max, GPU) for the performance budget.

## 6. Test plan

**Godot unit / screen tests (`tests/game/test_class_pick.gd`, built on the fixtures and the demo content where noted):**
- `ClassPickModel.ownership`: local mode all pickable; server collection → core ∪ owned; no collection → core only; a retired or
  unknown card id ignored.
- `moves` / `learns` / `stats`: the demo Warrior gives Basic Strike, Skill Provoke, Ult Cleave, Ult Execute (shared kit left out),
  Learns Lv 3 Ice Blast, Lv 5 Challenge, Lv 7 Retaliate, Lv 9 War Cry, and HP 1000, ATK 500, DEF 300, SPD 100, SP 60 (values read from
  content, not hard-coded in the test: the test checks they equal `stats_x100 / 100`).
- `add` / `remove` / `apply_preset` / `footer`: first empty slot, no duplicates, full party, removal leaves a hole, a preset with two
  locked classes gives two empty slots and `missing` 2, the footer texts of D9.
- The screen over the fake bridge: locked classes greyed and Add disabled with the pack hint; a preset loads; a slot click removes;
  the saved party restored minus unowned members; Lock in calls `start_run` with the party, `""` seed and the default run; the 1409
  path; Lock in disabled at 0 and while starting; the dev setup line shown only when a dev setup is set.
- The carousel headless: `turn(+1)` from the last wraps to the first, `turn(-1)` from the first to the last, `select` the shortest
  way, `selected_changed` once per turn (at once: the card updates as the ring starts); Left / Right turn it, a click on a cube, a hover and the wheel do not (D13); the
  sway stays within `sway_degrees` of facing the screen and no other cube turns about itself (D3).
- The main menu's New run pushes `class_pick.tscn`; the UI policy check passes; `test_export_keeps_what_runs` (the run setup modal and
  command stay out of the player build); the validator's `party_preset_*` codes on in-memory presets and the shipped ones.
- The playtest additions: the lock only over a locked class in front once the ring stops, the role in title case, no preset message,
  effects ignoring fog, the look anchor measured as its view, a pooled particle layer getting its own space back.
- `test_tool_parity`: the screen is reachable headless through the console `classpick [open | state | turn <n> | select <id> | add |
  remove <slot> | preset <id> | lockin | bench [seconds]]` and `runsetup ...`.

**Window checks (the user's 4K monitor, fullscreen, MSAA on):**
- `classpick bench`: frame time of the screen with all 11 cubes live against the main menu, vsync off. Budget: within 2 ms of the
  main menu's average and a p95 under 8.3 ms (120 fps) on the user's machine; numbers recorded in the PR.
- Shots of the screen per class, with a locked class in front, and during a turn, to `H:\claudeOutShots\<date> class pick\`.
- A live window for the user's playtest (the motion: the turn, the sway in front, the colour blend).

**e2e (on demand, `tools/e2e.sh`):** `class_pick_locked` (`#! cards`): a fresh account sees exactly the core classes pickable,
`classpick select` on a locked class refuses, Lock in with core classes starts a server run. **Passed 2026-11-19.**

**Results (2026-11-19):** Godot suite 1071+ passed; `classpick bench` on the user's left monitor, fullscreen, vsync off: the class pick
0.99 ms average (p95 1.18 ms) against the main menu's 0.41 ms, within the 2 ms budget. Shots in `H:\claudeOutShots\2026-11-19 class
pick*\`; playtested on the 4K in local mode and on the dev stack as the user's account.

**No golden changes:** nothing here touches combat, the run, a hash, a snapshot or the verifier.

## 7. Review answers (user, 2026-11-18)

| # | Question | Answer |
|---|---|---|
| Q1 | Mote and rim colour | The portrait studio's `rim_colors`, falling back to `display_color` (D4). |
| Q2 | Spin in the frame | No full turn: the cubes keep the ring's rotation and face the screen; the selected cube sways gently (D3). |
| Q3 | Look effects on the ring | On every cube (D12). |
| Q4 | Not inheriting `menu_frame.tscn` | Accepted as long as the screen is built from the common UI parts (D14). |
| Q5 | Dev run setup kept | For the session only (2.6). |
| Q6 | Delete `title_menu`, `class_card`, `class_details` | Yes, in the build PR (2.7). |
| Q7 | First presets | The prototype's six: Classic Four, Iron Wall, Break Squad, Firestorm, Deep Freeze, Plague House (3.2). |
| Q8 | Hover turns the carousel | No: only the arrows turn it (D13). |

Status after review: **ready for `/implement class-pick`.**

## 8. Playtest decisions (user, 2026-11-19)

| # | Decision |
|---|---|
| P1 | No gold frame around the front cube. |
| P2 | The grey squares around effects were the studio fog: effects ignore fog everywhere (2.8). |
| P3 | Floor effects hold still while the cube sways, and stay on the floor. |
| P4 | Cubes shrink away toward the back of the ring (option B) instead of going through the wall. |
| P5 | Turns ease in and out, the same both ways, at 0.25 s; the shrink spans the whole step, so nothing snaps. |
| P6 | Effects scale and travel with their cube; no flash on the side a cube wrapped from. |
| P7 | Windows are never nested (the FF7 reference): the class card is two stacked windows. |
| P8 | A lock icon over a locked class, only when it is in front: the filled map lock (1b), white, medium. |
| P9 | The role line reads like a title. |
| P10 | No message when a preset loads. |
