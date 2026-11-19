# Spec: class-pick (slice 5b4): the class pick screen, Mewgenics-style

Status: **spec written and reviewed 2026-11-18 (answers in section 7).** Part 1 of the character slice (the look touch-up) is done on
`design/character-touchup` (Arcanist hat straight and on the head, Plaguewright plague-doctor look, all 11 card portraits re-shot at
2160 px, imported at 1024 with mipmaps, lossless). This spec is Part 2: the new class pick screen, including spec `card-ui` 2.6 (locked
classes), which moved here on 2026-11-18.

Layout reference: the browser prototype in `specs/design/class-pick-prototype/` (README), published at
https://claude.ai/artifact/SVtwmh3LZWw89eSRQ95EFk. Feel reference: Mewgenics' "Equip Class Collars" screen
(`H:\assets\references\mewgenics\char select.jpg`): layout and feel only, never its art or characters.

### Decided in discussion (user, 2026-11-18)

| # | Decision |
|---|---|
| D1 | Left: a carousel of the classes, turned left and right (arrows, keys, wheel, a click on a cube). Right: the party, then recommended parties, then Lock in. |
| D2 | Carousel **A, the turntable**: every class stands on one ring, the front one in a gold frame. (B, a frame with one neighbour each side, was not picked.) |
| D3 | The carousel is a **live 3D view**: the real cubes with their attachments, look effects and idle motion, lit like the portrait studio. The cubes travel in and out of the frame **with the ring's rotation**, always facing the screen; the selected cube **sways gently** in the frame (Q2: no full turn, its face stays toward the screen). |
| D4 | The rising motes take the selected class's colour, **blending** from the old colour to the new one. The colour is the portrait studio's approved rim colour, falling back to the class's `display_color` (Q1). |
| D5 | Under the frame: the class name, role, description, its moves by type, the "Learns" line, and the stats as **plain numbers** (no bars). |
| D6 | The party shows as **portrait slots** (the card portraits). Clicking a member removes it. |
| D7 | Recommended parties: a developer-made list for now (no win or play rates yet; the analytics backend comes later). No description line under a preset. |
| D8 | A class the account does not own is **greyed** with a padlock and cannot be added. A preset holding one fills its slot **empty**; nothing else marks it. |
| D9 | The footer says **"Only N slots filled."** when the party is short; never anything about starting short-handed. |
| D10 | The run picker, the seed field and the content-root picker are **removed** from this screen. A dev console command opens them as a modal for debugging; the player build has none. |
| D11 | With nothing set in that modal, a run is the content's **default run** (`RunStructure.default_run`, The Descent): the intended player experience. |
| D12 | Every cube on the ring plays its look effect (Q3). |
| D13 | **Only the arrows turn the ring** (Q8): the two arrow buttons and the Left / Right keys (and their UI actions). Hovering or clicking a cube or a party member, and the mouse wheel, never turn it. |
| D14 | The screen keeps its own layout (stage left, party right) but is built only from the common UI parts (Q4). |

## 1. Purpose & enterprise mapping

The player picks up to four classes on one screen built around the cubes themselves, sees what each class does, can load a ready-made
party, and starts the run. In server mode the screen shows which classes the account owns, so the run start's `400 1409
CharacterLocked` is never reached by a player who only presses what the screen allows.

Backend components used (none new):

| Component | Use |
|---|---|
| `GET /api/v1/cards/collection` (slice 5, account-session 5b1) | Ownership: owned = core characters + the collection's owned character cards, read through `ServerLink` with the account session. |
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
| |   <                [ gold frame ]                   >  | +------------------------------+
| |                    front cube sways                    | | RECOMMENDED PARTIES          |
| |   rising motes in the class colour                     | |  Classic Four      All owned |
| +--------------------------------------------------------+ |  [4 portraits]               |
|   o o o * o o o o o o o   (position dots, hollow = locked) |  Iron Wall       1 not owned |
| +--------------------------------------------------------+ |  [4 portraits, greyed one]   |
| | Warrior   Damage dealer / off-tank   [Locked][In party] | |  ...                         |
| | description                              HP    1000    | +------------------------------+
| | [Basic Strike][Skill Provoke][Ult Cleave][Ult Execute] | | Only 2 slots filled. [LOCK IN]|
| | Learns: Lv 3 Ice Blast · Lv 5 Challenge · ...  ATK 500 | |                              |
| | [Add to party]  or  "Find X in a pack or craft it."    | |                              |
| +--------------------------------------------------------+ +------------------------------+
```

Built only from the common UI parts (`specs/ff7-ui.md` 2.12, D14): FF7 windows from `ui_theme.tres` (`UIWindowStyle`), Back top
left (`UIBackButton`), the class card on `description_window`, the presets as a `UIList` with entry scenes, buttons and texts from
the theme; new look goes into the theme, not overrides. It does not inherit `menu_frame.tscn` (its description window sits under the
stage and the characters are the stage itself); `ff7-ui` 2.12's list gains a line naming this screen's layout as the exception, and
the party slot and preset row join the shared component list for reuse.

### 2.2 The carousel (presentation only)

- A `SubViewport` with its own 3D world (like `FxStage`) holding a `ClassCarousel3D`: one stand per selectable character on a ring
  (`ring_radius`, the front stand on the camera axis), each holding the character's real view (`UnitAnimator.instantiate_for`, the
  main `StyleRegistry` look, attachments, look effect), facing the camera at rest (`StyleRegistry.facing_degrees` 0 in memory, as the
  portrait tool does).
- The lighting is the portrait studio's (`PortraitStudio`, `presentation/demo/cards/portrait_studio.tscn`): key spot, rim and glow
  lights and the rising motes. The rim, glow and mote colours follow the **selected** class (`PortraitStudio.rim_colors`, else the
  class's `display_color`) and blend from the previous colour over `color_blend_seconds` (D4).
- Turning: the ring's angle eases toward the selected index (a critically damped step, `turn_seconds`), wrapping around (left of the
  first is the last). The cubes ride the ring and keep facing the screen: no cube turns about itself (D3). Once the ring rests, the
  cube in the frame sways about its Y axis by `sway_degrees` (±15°) over `sway_seconds` (a sine, 3 s a cycle), so its face never
  leaves the screen; a cube that leaves the frame eases back to facing the camera.
- The front cube is drawn larger by the ring's perspective; the farther cubes are darker (the prototype's falloff). A locked class's
  cube is greyed (the view's existing grey paint, as for a dead party member, without the death pose) with a padlock over the frame
  when it is in front.
- Input (D13): only the two arrow buttons and Left / Right (keys and the UI actions) turn the ring, one class a press; holding a key
  repeats at the UI's key-repeat rate. Clicks on cubes, hovering and the mouse wheel do nothing to the ring. Enter adds or removes
  the class in front.
- Cost: every cube and its look effect run live (D12). A `classpick bench` command measures it (6, test plan) and the screen must
  stay within budget on the user's 4K screen; if it does not, the build stops and the user decides (no silent fallback).
- Headless (tests, the verifier): no viewport and no views are built; the carousel keeps only its index. Nothing here is read by
  `combat/`, the run, a hash, a snapshot or an upload.

### 2.3 Ownership

```
screen opens (and on GameMain.server_changed, ServerLink.session_changed, after a pack open or craft)
  local mode (no server)                    → every selectable character is pickable (unchanged; spec card-ui 2.6)
  server mode, session, collection read OK  → pickable = core characters ∪ owned character cards
  server mode, no session or no answer      → pickable = core characters only; the message line says
                                              "Couldn't check your collection. Only starter classes can be picked."
                                              (the player build reaches this screen only online: main menu's New run
                                              needs_online, debug builds skip that)
```

`ClassPickModel.ownership(...)` decides it from the same inputs as `CollectionModel` (a `CollectionResponse`, or the local test pool,
or neither); the screen never decides ownership itself.

### 2.4 Building the party

- Four slots (`max_party`, 4). Add puts the class in the first empty slot; a class is in the party at most once; a full party
  disables Add and the hint says "The party is full. Click a member to take it out."
- Clicking a filled slot empties it (its later members do not shift; an empty slot is filled first by the next Add).
- A preset fills the slots in its order; a class that is not pickable leaves its slot empty (D8) and the message line says
  "Classic Four loaded. 1 class not owned, its slot is empty."
- The party opens as last saved (`[menu] party`, as today); any member no longer pickable leaves its slot empty.
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
  only (Q5: a forgotten test setup never leaks into the next play), and are what 2.5 reads. `runsetup show` prints them; Lock in uses them silently, and the class pick's
  footer shows a dev line "Dev run setup: <run> · seed <code>" while any is set, so a test run is never mistaken for the real one.

### 2.7 What goes away

`presentation/demo/ui/title_menu.tscn/.gd` (the old class pick), `class_card.tscn/.gd` and `class_details.tscn/.gd` (nothing else uses
them) are replaced by the new screen; the main menu's New run pushes `class_pick.tscn` instead. They are the user's files; their
deletion in the build PR is approved (Q6). `ClassCard.kit_lines` moves to `ClassPickModel.moves` (system code).

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
static func ownership(characters: Array, collection: Variant, local_mode: bool) -> Dictionary  ## id -> "owned"|"core"|"locked"
static func moves(character: CharacterDefinition) -> Array      ## [{name, type: Basic|Skill|FollowUp|Ultimate}], shared kit left out;
                                                                ## names through AbilityName.of, types from Ability.Type.* asset tags
static func learns(character: CharacterDefinition) -> Array     ## [[level, ability name]] from level_skills
static func stats(character: CharacterDefinition) -> Array      ## [[label, number]] HP ATK DEF SPD SP from stats_x100 / 100
static func add(party: Array, id: StringName, max_party: int) -> Array
static func remove(party: Array, slot: int) -> Array
static func apply_preset(preset: PartyPreset, pickable: Dictionary, max_party: int) -> Dictionary  ## {party, missing: n}
static func footer(party: Array, max_party: int) -> String

## The 3D turntable (presentation): stands, turning, spin, colour blend. Exports, tuned in the scene:
class_name ClassCarousel3D extends Node3D
@export var ring_radius: float
@export var turn_seconds: float = 0.35
@export var sway_degrees: float = 15.0      ## the selected cube's sway, either side of facing the screen (Q2)
@export var sway_seconds: float = 3.0       ## one sway cycle
@export var color_blend_seconds: float = 0.4
signal selected_changed(index: int)
func show_characters(characters: Array, locked: Dictionary) -> void
func turn(steps: int) -> void               ## the arrows (D13)
func select(index: int) -> void             ## script and tests only (console classpick select): turns the shortest way
```

The screen `presentation/demo/ui/class_pick/class_pick.tscn` (root extends `UIScreen`), its party slot
`party_slot.tscn` (portrait from `CardArtSet` `card_portraits.tres`; the 1024 mipmapped import) and preset row `preset_row.tscn` (a
`UIList` entry). Texts are `@export`s. The stage scene `class_carousel.tscn` instances the portrait studio's lights and motes.

Validator (`validate_content.tscn`, `ClassPickCheck`): `party_preset_unknown_character`, `party_preset_too_big` (more than
`max_party`), `party_preset_duplicate` (a class twice, or two presets with one id), `party_preset_not_selectable`, as errors.

## 4. Failure modes

| Case | Behaviour | Test |
|---|---|---|
| No session or the collection read fails (server mode) | Only core classes are pickable; the message line says so; Lock in works with core classes. | `test_class_pick`: fake bridge failing the read |
| A class unlocked or crafted while the screen is open | Ownership is read again on `session_changed` and after a pack open or craft; the cube un-greys. | `test_class_pick` |
| `400 1409` at Lock in (the account changed elsewhere) | Message names the class, ownership re-read, the slot empties, no run starts. | `test_class_pick` over the fake bridge; e2e `class_pick_locked` |
| `409 1412` session replaced | Today's 1412 dialog (account-session); nothing new. | existing `test_account_session` |
| No answer / 5xx at Lock in | Today's run start handling (connecting pop-up). | existing `test_server_mode` |
| Lock in pressed twice | The button disables until `start_run` returns. | `test_class_pick` |
| A preset names a class the content lacks | Validator error; at runtime the slot is left empty. | validator fixture in `tests/broken_fixtures/` |
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
  way, `selected_changed` once per settled turn; Left / Right turn it, a click on a cube, a hover and the wheel do not (D13); the
  sway stays within `sway_degrees` of facing the screen and no other cube turns about itself (D3).
- The main menu's New run pushes `class_pick.tscn`; the UI policy check passes; `test_export_keeps_what_runs` (the run setup modal and
  command stay out of the player build); the validator's `party_preset_*` codes on broken fixtures.
- `test_tool_parity`: the screen is reachable headless through the console `classpick [open | state | turn <n> | select <id> | add |
  remove <slot> | preset <id> | lockin | bench [seconds]]` and `runsetup ...`.

**Window checks (the user's 4K monitor, fullscreen, MSAA on):**
- `classpick bench`: frame time of the screen with all 11 cubes live against the main menu, vsync off. Budget: within 2 ms of the
  main menu's average and a p95 under 8.3 ms (120 fps) on the user's machine; numbers recorded in the PR.
- Shots of the screen per class, with a locked class in front, and during a turn, to `H:\claudeOutShots\<date> class pick\`.
- A live window for the user's playtest (the motion: turn, spin in the frame, the colour blend).

**e2e (on demand, `tools/e2e.sh`):** `class_pick_locked` (`#! cards`): a fresh account sees exactly the core classes pickable,
`classpick select` on a locked class refuses, Lock in with core classes starts a server run.

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
