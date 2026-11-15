# Spec: audio-pass (slice 5e, after 5a4 `cube-style`, before 5b `card-ui`)

Status: **approved, ready for `/implement`** (all decisions D0–D8 as recommended, user, 2026-11-15) · Date: 2026-11-15 · Roadmap: slice 5e (listed, "Not started").
Builds on `specs/vfx-framework.md` (the GodotGAS cue bridge, `FxListener`'s cue route, `FxRuleSet`), `specs/vfx-content-pass.md`
(the message → cue route for per-hit variants, the cue families), `specs/animation-sets.md` (ability montages on `UnitAnimator`),
`specs/ff7-ui.md` and `specs/ui-framework.md` (the Settings screens), `specs/playtest-fixes.md` B21 (passives never animate)
and B25 (the Audio placeholder screen), `specs/dev-tools.md` (proposal passes, console parity). Design ownership: the slice
edits existing user files under `content/demo/animations/` and `presentation/`, so it works by a **builder pass with a
report the user reviews** (user, 2026-11-15), never by silent hand edits.

## 1. Purpose & enterprise mapping

**Purpose.** Put every sound into one balanced bank, cover every gap, and add volume settings:

1. **Credit and fold in the shipped pack.** The 96 files in `presentation/audio/rtp/` are the **EasyRPG RTP** sounds
   (https://github.com/EasyRPG/RTP, the `Sound/` folder; all 96 checked byte-identical, 2026-11-15), a free replacement
   for RPG Maker 2000/2003's materials that reuses RPG Maker's file names. They are **not** RPG Maker's own sounds (an
   earlier draft said so; the user corrected it). Licence: CC BY 4.0 for the repo; per file (`AUTHORS.md`) 40 are by
   lumiscosity (CC BY), the rest CC0 (JosephSeraph, Gadesx, null-painter-error, nightskypatr0l, lavendersiren,
   celestialghost8, LokiF, Kenney). So they may stay in the public repo, but they are **not credited anywhere today**:
   this slice adds the credit and moves the pack into the bank like every other source (decision D0).
2. **Cover the gaps** (sound audit, 2026-11-15). Only 32 of the 96 files are used. About 70 active moves are silent (party:
   Discord, Blizzard, Frost Jab, Ignite/Scorch/Immolate, Infect, Lingering Malady, the three Ranger marks, the Shatterweaver
   skills, Fortify/Iron Hide/Bastion Wall, Block; about 45 enemy moves; the boss ults **Overheat, Twin Beat, Black Mass,
   Systole**); `devour.tres` and `gnaw.tres` have an audio track with an empty stream. Outside moves, only one generic hit
   sound (`Cue.Sfx.Hit` → Damage2) and eight sound-board sounds exist: statuses, DoT ticks, cleanse, break, crits, resisted,
   One More, heals, revives, Downed, phase changes, overtime, level-up, keys, gold, unlocks, floors and field item use are
   all silent. Every `Cue.Fx.*` cue scene is silent and no effect uses `FxSoundLayer`.
3. **Volume settings.** No bus layout exists (everything plays on Master) and the Audio screen is a placeholder. Add buses
   and sliders.
4. **Balance.** Today's volumes are set ad hoc per player and per animation (`Audio:volume_db` tracks from −9 to +16.5 dB).
   The new bank is loudness-matched per category at import, so files carry the balance and the players play at 0 dB.

**Sound direction (user, 2026-11-15).** Old-school RPG, the FF7 / RPG Maker era. Recorded pack sounds only, **no generated
or synthesized sounds**. **No music, no fanfares, no stingers.** **Menu and interface sounds are very short.** **Gaining ult
charge makes no sound**, and there is no "ult ready" sound.

**Sources (user, 2026-11-15), all downloaded by the user to `H:\assets\audio\` (outside the repo):**

| Folder | Pack | Licence | Used for |
|---|---|---|---|
| `pixel/` | *FREE Pixel Combat SFX*, Helton Yan (with Beto Bezerra), https://heltonyan.itch.io/pixelcombat | CC BY 4.0 | the main bank: casts, impacts, statuses, run sounds |
| `returoMenu/` | *Retro Menu FX*, NSFRL (Taylor Nickens), https://nsfrl.itch.io/retro-menu-sound-fx | CC0 1.0 (stated on the page; the download has no licence file) | the menu and interface sounds |
| `shonen/` | *FREE Retro Anime Sound Effects*, Helton Yan, https://heltonyan.itch.io/retroanimesfx | CC BY 4.0 (LICENSE.txt) | **reserved**: only over-the-top ults (section 3.4) |
| (in the repo) `presentation/audio/rtp/` | *EasyRPG RTP*, `Sound/` folder, https://github.com/EasyRPG/RTP (per-file authors in its `AUTHORS.md`) | CC BY 4.0 / CC0 per file | stays a source: its RPG Maker–style sounds may fill any category (decision D0) |
| `sfx/` | *Interface SFX Pack 1*, ObsydianX | CC0 | not used unless the user picks one later |
| `do_not_include/` | an FF7 menu-sound rip (Steam Deck theme) | Square Enix's | **never** copied, imported, resampled or shipped; it was only measured for reference |

Rejected and never committed: RPG Maker's own RTP and DLC (Kadokawa / Gotcha Gotcha Games' EULA allows them only in games
made with RPG Maker), Sonniss GDC bundles, ZapSplat, Pixabay, Shapeforms, Leohpaz's itch.io
packs (all forbid redistributing the raw files); CC BY-SA, GPL and NC packs (e.g. a Silent Hill 2–style UI pack, NC).

**Formats.** Every committed file is **WAV, mono, 16-bit, 44.1 kHz**, trimmed of leading and trailing silence. Pixel Combat
ships 96 kHz / 24-bit stereo at 2.1 GB, so only the picked files are converted and committed (the bank should stay around
10–15 MB). The import always writes mono (stereo was left out: no sound needs it). OGG only for music or anything longer than about 5 s;
this slice has neither.

**Not in scope:** music (none is wanted), a music bus, per-item proc sounds (items and equipment get the sounds of the
effects they apply), positional 3D audio (the battle camera is fixed; sounds are 2D), voice, new art.

**Presentation only.** Sounds never reach a hash, snapshot, upload or replay. `combat/` gains nothing. Headless runs
(the verifier, tests, `dev_run`) keep `suppress_cues` and the `RPG_MUTE` master mute.

**Enterprise mapping: none at runtime.** Client-only; no endpoint, queue, broker, cache or database. One honest consequence:
the animation files live under `content/`, which the ruleset version hashes, so the slice changes the ruleset version and
the verifier worker needs the matching export, like any content edit. Combat timing comes from the animations' `execute`
method keys and lengths, which the builder never touches (section 6, the guard test).

## 2. Sequence flow

N/A as a client → server flow. The slice has four client-side flows, all on mechanisms that exist.

### 2.1 Import (a tool, outside the game)
```
H:\assets\audio\<pack>\<file>.wav          (user's downloads, outside the repo)
  └ tools/audio_import.py --source H:\assets\audio      (ffmpeg; never reads do_not_include/)
       reads presentation/audio/sfx/manifest.json  (one row per bank entry: id, pack, file, category, trim, fade, stereo)
       → presentation/audio/sfx/<pack>/<id>.wav    (mono 16-bit 44.1 kHz, trimmed, faded, loudness-matched to its category)
       → writes the measured loudness and peak back into the manifest row
       → regenerates the sound rows of CREDITS.md (pack, author, licence, URL, "changes: trimmed, converted, loudness-matched")
```

### 2.2 The bank (Godot data, the one place to swap a sound)
Each manifest row becomes `presentation/audio/sfx/bank/<id>.tres`, an **`AudioStreamRandomizer`** (Godot's own stream:
`random_pitch` and `random_volume_offset_db` vary repeats; its streams list may hold several takes, e.g. Pixel Combat's
numbered variations). Everything that plays a sound refers to a bank `.tres`, never to a `.wav`, so swapping a sound means
editing one bank file. The Godot builder `game/tools/build_audio_bank.tscn` (re)creates the bank files from the manifest
(new files only, `--force` to rebuild).

### 2.3 Moves (casts and impacts)
```
ability activates → UnitAnimator montage plays the ability's animation
  audio track on the unit's Audio node (bus Sfx) → the bank entry for the move's cast   [existing path, rewired]
damage lands → combat broadcasts Message.Battle.Damage (tags: Damage.Type.*, Hit.*)  [exists, spec vfx-content-pass]
  sfx_rules.tres (an FxRuleSet of FxListeners with cue = Cue.Sfx.*) → the cue scene plays the impact by type
  e.g. Damage.Type.Fire → Cue.Sfx.Hit.Fire; Hit.Critical adds Cue.Sfx.Hit.Crit on top
```
`Cue.Sfx.Hit` on `content/demo/effects/damage.tres` is removed (the message route knows the damage type; the effect does
not), exactly as `Cue.Fx.HitSpark` was removed in vfx-content-pass.

### 2.4 Statuses, battle moments, run and menu events
- **Effects (GAS cues):** sound cues are listed beside the existing visual cues on the status effects
  (`application_cue_tags` for an apply, the periodic cue for a DoT tick, `removal_cue_tags` for cleanse and thaw). A sound
  cue is its own `Cue.Sfx.*` tag and scene (`presentation/demo/cues/sfx/`, script `sound_cue.gd`), never a layer inside an
  `FxDefinition`. **Why separate:** `FxManager` stops every effect at fx quality `off`, and turning visual effects off must
  not mute the game.
- **Battle moments** (break, recovered, Downed, phase change, One More, death, revive, resisted, overtime): `sfx_rules.tres`
  listeners on the `Message.Battle.*` channels, like `moment_fx_rules.tres`.
- **Run and menu sounds:** the sound board (`presentation/demo/sound_board.tscn`) stays the owner of interface and run
  sounds. Its players point at bank entries and play on the `Ui` bus, and it gains listeners for the new run messages
  (`Message.Run.KeyFound`, `LevelUp`/`SkillLearned`, `FloorEntered`, coins, unlock, field use). `UIToastRule.sound` stays
  available and unused.

## 3. Data contracts

N/A for C# DTOs, queues, topics and Redis keys: nothing leaves the client. The data this slice adds, all Godot resources or
files:

### 3.1 The manifest (`presentation/audio/sfx/manifest.json`)
One row per bank entry. Committed; the import tool and the Godot builder both read it.
```json
{ "id": "hit.fire", "pack": "pixel", "file": "DSGNImpt_EXPLOSION-Fire Hit_HY_PC-001.wav",
  "takes": ["...-001.wav", "...-002.wav", "...-003.wav"], "category": "impact",
  "trim_ms": 400, "fade_ms": 120, "stereo": false, "pitch_random": 1.05, "volume_random_db": 1.0,
  "measured": { "loudness": -16.2, "peak_db": -2.1 } }
```
`pack` names a row in a packs table at the top of the file (folder, title, author, licence, URL, `reserved: true` for
Retro Anime). An unknown pack, a pack under `do_not_include`, or a licence outside CC0 / CC BY 3.0 / CC BY 4.0 is refused by
the tool and by the validator.

### 3.2 Loudness targets (the balance)
Loudness is measured as the **maximum momentary loudness** (EBU R128, 400 ms window, `ffmpeg ebur128`), because integrated
loudness means little on a 90 ms sound. A true-peak ceiling of −1 dBTP applies to every file. The tool gain-adjusts each
file to its category target:

| Category | Target (LUFS-M) | Examples |
|---|---|---|
| `ui` | −22 | cursor, confirm, back, refused, pop-ups |
| `run` | −20 | item get, gold, key, unlock, level up, room move, floor |
| `cast` | −19 | a move's cast or swing |
| `impact` | −17 | hits by type, crit, weakness, break |
| `status` | −23 | status applied, DoT tick, cleanse, buff and debuff |
| `moment` | −19 | death, revive, Downed, phase change, One More |
| `signature` | −15 | ult signatures, boss ults |

The targets are starting values for tuning by ear. Bus volumes add the player's choice on top. A **hard limiter**
(`AudioEffectHardLimiter`, ceiling −1 dB) on Master stops many overlapping sounds (an AoE hitting four enemies) from
clipping. The `sound_cue.gd` cue gains `min_interval` (default 0.04 s): the same cue tag plays at most once per interval on
one unit, and at most `max_voices` (default 3) at once across units, so a four-target hit is one impact layered at most three
deep, not four stacked at full level.

### 3.3 Buses and settings
- `client-godot/default_bus_layout.tres`: `Master` (hard limiter) → `Sfx` (moves, cues, battle moments) and `Ui` (the sound
  board). No `Music` bus (no music).
- `game/audio/audio_settings.gd` (`AudioSettings`, like `GraphicsSettings`): `volume_master`, `volume_sfx`, `volume_ui`,
  each 0–100 (default 100), saved in `user://game_main.cfg` `[settings]`, applied at boot by `GameMain` with
  `AudioServer.set_bus_volume_db(bus, linear_to_db(v / 100.0))`; 0 mutes the bus. `RPG_MUTE` still mutes Master on top.
- The Audio screen (`presentation/demo/ui/audio_settings.tscn`) gets three slider rows on the FF7 theme (Master, Effects,
  Interface). Moving the Interface or Effects slider plays a sample on that bus, so the player hears the level.

### 3.4 Moves: categories, then signatures
The builder (`game/tools/build_audio_pass.tscn`) classifies every ability and writes its animation's audio track:

| Ability | Cast sound (on its animation) | Impact (message route) |
|---|---|---|
| Damage, Physical | a weapon swing chosen by its family (slash, blunt, shot, bite) | `hit.physical` |
| Damage, Fire / Ice | a cast of that element | `hit.fire` / `hit.ice` |
| Debuff, statuses | a dark cast | the status's own apply sound |
| Heal, Revive, RestoreMP | a soft holy cast | `heal` / `revive` cue on the effect |
| Buff, Guard, taunt | a rising cast | the buff apply sound |
| Cleanse, Dispel | a bright cast | `cleanse` on the removal |
| Ultimate (party and enemy) | its own **signature** sound (24 ults, no two alike) | as its damage type |
| Boss move (non-ult) | a heavier variant of its category | as its type |
| Passive (not a follow-up) | **none** (B21: passives do not animate; a proc blip on every trigger would be noise) | its effects' cues |
| Follow-up | its category's cast | as its type |

Classification reads, in order: the ability's `Ability.Role.*` asset tags (on every party ability), its damage effects'
`Damage.Type.*`, the statuses it applies, `Ability.Type.Ultimate`, `Enemy.Boss` on its owner; an ability it cannot classify
is listed in the report as `unclassified` and gets the generic cast. Shared animations (45 abilities share another's) keep
one sound; an ult that shares an animation is reported, since an ult needs its own signature.

**Reserved: Retro Anime.** Its sounds run 4–8 s and are only for over-the-top ults (user, 2026-11-15: "only for silly over
the top stuff"): the Lich's **Death Ray** and the Nameless's **Oblivion** (the black hole). Any further use needs the user's
OK. The manifest marks the pack `reserved`, and the validator's `sfx_reserved_source` fails any other ability, cue or board
entry that uses it. A signature is cut to its animation's length plus 0.5 s at most, faded, so it never runs into the next
action.

The builder **only** adds, replaces or removes audio tracks (`type = "audio"`) and the `Audio:volume_db` value tracks
(volume now comes from the bank). It never changes an animation's length, method (`execute`) tracks or any other track. It
writes `build/audio_pass_report.md`: every ability, its class, the chosen entry and why, and what changed. The user reviews
the report and the result by ear and tunes afterwards (`design:` commit).

### 3.5 Events and the interface: the full list
Sound cues (`Cue.Sfx.*`, scene per tag in `presentation/demo/cues/sfx/`, registered in `godot_gas/cue_registry.tres`):
`Hit.Physical`, `Hit.Fire`, `Hit.Ice`, `Hit.Crit`, `Hit.Weakness`, `Hit.Resisted`, `Hit.Drained`, `Break`, `Recovered`,
`Tick.Poison`, `Tick.Bleed`, `Tick.Burn`, `Status.Control` (Freeze, Stun, Entangle, Slow on apply), `Apply.Buff`,
`Apply.Debuff`, `Cleanse`, `Heal`, `Revive`, `Death`, `Downed`, `PhaseShift`, `OneMore`, `Resisted` (a status resisted),
`Overtime` (the first overtime turn of a boss). The old `Cue.Sfx.Hit` and `hit_cue.tscn` are removed.

Sound board (bus `Ui`), with the user's picks delegated to Claude (user, 2026-11-15: "just add the sounds and I can tell you
if I don't like something later"):

| Board name | When | Bank entry ← pack file |
|---|---|---|
| `Hover` | a button is hovered (the cursor) | `ui.cursor` ← Retro Menu `Select_Up - Softer` |
| `Confirm` | a button is pressed | `ui.confirm` ← `Select_Confirm - Softer` |
| `Back` | a back button | `ui.back` ← `Select_GoBack - Softer` |
| `Refused` | `Message.Ui.Refused` | `ui.refused` ← `Select_Unable - Softer` |
| `PopupOpen` / `PopupNo` (new) | `UIManager.confirm` opens / its No | `ui.popup` ← `Select_AreYouSure - Softer`, `ui.decline` ← `Select_Decline - Softer` |
| `MenuOpen` / `MenuClose` (new) | the run menu opens / closes | `ui.menu_open` ← `Select_Pause - Softer`, `ui.menu_close` ← `Select_Unpause - Softer` |
| `Advance` (new) | an event's next step | `ui.advance` ← `Select_Advance - Softer` |
| `Item` | item taken, chest opened, gift given, gear equipped | `run.item` ← `Select_ConfirmBIG - Softer` |
| `Coin` (new) | coins gained or spent | `run.coin` ← Pixel `DSGNTonl_USABLE-Magic Coin` |
| `Key` (new) | `Message.Run.KeyFound`, a locked room opened | `run.key` ← Pixel `UIMisc_INTERFACE-Lock` |
| `LevelUp` (new) | `Message.Run.LevelUp` / `SkillLearned` (once per level-up, not once per message) | `run.level_up` ← Pixel `DSGNSynth_BUFF-Stats Up` |
| `Use` (new) | a field item use, food eaten on pickup | `run.use` ← Pixel `DSGNTonl_USABLE-Generic Consume` |
| `Move` | a room entered | `run.move` ← Pixel `FEETMisc_STEP-Boots on Concrete Dungeon` |
| `Floor` (new) | `Message.Run.FloorEntered` | `run.floor` ← Pixel `DSGNMisc_MOVEMENT-Whoosh Sweep` |
| `BattleStart` | `Message.Battle.Started` | `battle.start` ← Pixel `DSGNMisc_MOVEMENT-Phase Swish` |
| `Death` | moved to the `Cue.Sfx.Death` cue (on the unit, bus Sfx) | ← Pixel, picked in the pass |

No sound plays for ult charge gained or an ult becoming ready; battle won, battle lost and run won/lost have no stinger
(decision D3). Interface sounds are capped short: `ui` entries ≤ 0.35 s, `run` entries ≤ 0.6 s (the import tool trims and
fades to the manifest's `trim_ms`).

### 3.6 Credits
`CREDITS.md` at the repo root (named in spec `cube-style` 3.7, created now): one section per pack (title, author(s), URL,
licence and its link, what was changed), generated from the manifest. CC BY needs the credit where the sounds reach people,
so the shipped game shows it too: a **Credits** button on the main menu opens a screen listing the same text (decision D4).

## 4. Failure modes

N/A for idempotency, retries and dead letters (no server path). None of the root acceptance scenarios 1–7 apply. Client-side
failures and how each is handled:

| Failure | Handling | Check |
|---|---|---|
| A bank entry's file is missing or fails to import | the sound is silent, never an error in play | validator `sfx_file_missing` (error) |
| An active ability has no cast sound | silent | validator `sfx_missing` (error; a deliberate silence is listed in the manifest's `silent` list) |
| Something references a `.wav` directly instead of a bank entry (incl. the old `presentation/audio/rtp/` path after the move) | | validator `sfx_direct_stream` |
| A reserved (Retro Anime) sound used outside the allow-list | | validator `sfx_reserved_source` |
| A manifest row's licence or pack is not allowed, or names `do_not_include` | the import tool refuses | validator `sfx_licence` |
| A file drifts from its category target by more than 1.5 dB (re-export, hand edit) | | validator `sfx_loudness` (warning), `tools/audio_import.py --check` |
| `CREDITS.md` misses a pack the bank uses | | validator `sfx_credit_missing` |
| A bus named by a player does not exist (layout edited) | Godot falls back to Master | validator `sfx_bus_unknown` |
| Many identical sounds at once (AoE, multi-hit) | `min_interval` and `max_voices` on the cue, the Master limiter | `test_audio_pass` |
| fx quality `off` | sounds still play (separate cues) | `test_audio_pass` |
| Headless (verifier, tests) | cues suppressed, Master muted; no audio scene is loaded by the verifier | existing `suppress_cues` test plus a new one |

The validator codes run in `validate_content.tscn` beside the `fx_*` and `style_*` ones (an `AudioValidator` in `game/dev/`).

## 5. Observability

N/A for Prometheus (client-only; no server metric changes). Dev parity instead (memory `dev-tools-claude-parity`), a console
command `audio`:
- `audio` / `audio buses`: each bus with its volume, mute and the saved setting.
- `audio volume <master|sfx|ui> <0-100>`: sets and saves (like the Audio screen).
- `audio play <bank id>` and `audio cue <Cue.Sfx tag>`: plays one (refused headless unless `--force`, for tests).
- `audio list [category]`: the bank with each entry's pack, length and measured loudness.
- `audio check`: the `sfx_*` validator rules now.
- `audio stats`: voices playing per bus, cue plays and throttled plays since start.

## 6. Test plan

All new Godot tests in `tests/game/test_audio_pass.gd` unless named; both suites must pass and **no golden moves** (the
slice is presentation-only; combat replays, run goldens and state hashes must be byte-identical).

1. **Everything through the bank:** no `.tres`/`.tscn` outside the bank points at a `.wav` (`sfx_direct_stream`); the EasyRPG
   files the bank uses live under `presentation/audio/sfx/easyrpg/`, and `presentation/audio/rtp/` is gone (D0).
2. **Every active ability sounds:** every non-passive ability in `content/demo/` (party, enemies, bosses, items with battle
   use) has an audio track whose stream is a bank entry, or is in the manifest's `silent` list; the four silent boss ults and
   `devour` / `gnaw` are covered.
3. **Animation guard:** for every animation the builder touched, all non-audio tracks, `length`, and every `execute` key
   are identical to before (compared against the pre-pass copy the builder keeps in `build/audio_pass_backup/`); and the combat
   goldens replay to the same final hashes.
4. **Bank integrity:** every manifest row has its WAV (mono, 16-bit, 44.1 kHz; stereo only where `stereo: true`) and its
   bank `.tres`; every bank `.tres` is an `AudioStreamRandomizer` whose streams exist; nothing outside the bank points at a WAV.
5. **Balance:** every row's measured loudness is within ±1.5 dB of its category target and its peak ≤ −1 dBTP; `ui` rows
   ≤ 0.35 s and `run` rows ≤ 0.6 s long.
6. **Licences and credits:** every pack row has an allowed licence; no row names `do_not_include`; `CREDITS.md` and the
   Credits screen list every pack the bank uses; Retro Anime is used only by the Death Ray and Oblivion animations.
7. **Cue coverage:** every `Cue.Sfx.*` tag in section 3.5 is in the cue registry with a scene that plays a bank entry on
   bus `Sfx`; `damage.tres` no longer lists `Cue.Sfx.Hit`; each status effect lists its apply / tick / removal sound cue.
8. **Message routing:** on a scripted battle (fixtures), a Fire hit plays `Cue.Sfx.Hit.Fire`, a crit adds `Hit.Crit`, a
   DoT tick plays its tick cue, Downed, break, phase change and One More each play once; ult charge gained plays nothing.
9. **Throttle:** four simultaneous identical hits play at most `max_voices`, and a repeat inside `min_interval` on one unit
   does not play.
10. **Independent of visuals:** at fx quality `off`, the battle in 8 still plays every sound.
11. **Settings:** the three volumes round-trip through `user://game_main.cfg`, apply to the buses at boot, 0 mutes, the
    sliders on the Audio screen change the bus at once; the bus layout has exactly Master, Sfx, Ui with the limiter on
    Master.
12. **Sound board:** each board name plays its bank entry on bus `Ui` for its trigger; a level-up that sends both
    `LevelUp` and `SkillLearned` plays one sound.
13. **Headless:** a headless run loads no `Cue.Sfx` scene (`suppress_cues`) and the verifier's step runner never opens an
    audio file.
14. **Console:** `audio`, `audio volume`, `audio list`, `audio check`, `audio stats` (in `test_dev_commands`-style cases).
15. **Import tool:** `tools/audio_import.py --check` passes on the committed bank (run in `tools/godot_tests.sh`'s
    pre-checks if Python and ffmpeg are present, else skipped with a note); it refuses a `do_not_include` path and an unknown
    licence (a small fixture manifest under `tests/fixtures/audio/`).

## 7. Decisions (made: the user took every recommendation, 2026-11-15)

D3 is decided as written: no end-of-battle or end-of-run sound (the option of a short win sound is not taken).

- **D0. The EasyRPG RTP sounds stay a source.** They are the most RPG Maker–like sounds we have, so the builder may pick them
  for any category beside Pixel Combat and Retro Menu FX. Like every pack they go through the import (loudness-matched, into
  `presentation/audio/sfx/easyrpg/`), and files the bank does not use are removed from the repo (they stay available in the
  EasyRPG repo). Every author who has a file in the bank is named in `CREDITS.md`, with the CC BY ones (lumiscosity) as
  required. *Recommended.* Alternative: keep all 96 as they are, unbalanced, only credited.
- **D1. Separate sound cues, not sound layers in effects.** Sounds are `Cue.Sfx.*` cues and sound-board entries so the fx
  quality setting (which stops every effect at `off`) never mutes the game. `FxSoundLayer` stays for an effect that wants a
  sound tied to its visual, unused in the demo. *Recommended.*
- **D2. Passives stay silent** (no proc blip), follow-ups sound like their category. *Recommended:* procs fire often and
  would turn into noise; their effects' cues (heal, buff, status) already sound.
- **D3. No end-of-battle or end-of-run sound.** The user ruled out fanfares and stingers. *Option:* a single short pack
  sound on battle won (e.g. `Select_ConfirmBIG - Softer`), nothing on a loss.
- **D4. A Credits screen on the main menu** to satisfy CC BY in the shipped build (the repo's `CREDITS.md` alone does not
  reach players). *Recommended;* the alternative is a credits line in the Settings screen.
- **D5. Retro Anime allow-list:** Death Ray and Oblivion now; other ults (Supernova, Meteor, Black Mass, Absolute Zero…) only
  if the user asks after hearing them.
- **D6. Interface picks** as in 3.5, delegated to Claude; the user swaps any by naming it. Retro Menu FX: the **Softer** version of every sound (user, 2026-11-15).
- **D7. Bank as Godot's `AudioStreamRandomizer`** (built-in random pitch and volume, several takes) rather than a new
  `SfxEntry` resource type. *Recommended* (GAS-first / engine-first; memory `design-with-gas`).
- **D8. The import tool is Python + ffmpeg** (already on this machine), outside Godot, because Godot cannot measure loudness
  or resample at edit time. It runs only when the bank changes; the committed WAVs are what the game uses.

## 8. Order of work

1. Manifest and `tools/audio_import.py`; import the picked files; `CREDITS.md`. (`chore:` / `feat:`)
2. Bus layout, `AudioSettings`, the Audio screen sliders, the console `audio` command. (`feat:`)
3. `sound_cue.gd` throttle; `Cue.Sfx.*` tags, scenes and `sfx_rules.tres`; the sound board rewired. (`feat:`, with the
   presentation files created by the builder)
4. `build_audio_pass.tscn` over `content/demo/animations/` and the status effects; the report. (`feat:` for the tool; the
   resulting content and presentation edits committed as `design:` after the user listens)
5. Move the EasyRPG files the bank uses into `presentation/audio/sfx/easyrpg/` (through the import, so they are loudness-matched
   too) and remove the rest of `presentation/audio/rtp/` (D0); validator rules; tests; the state table in `CLAUDE.md`; mark 5e in the roadmap.

## 9. As built (2026-11-15), and where it differs from the text above (for the user's review)

Built on `feat/audio-pass`: the manifest (96 entries, 128 takes, 11 MB) and `tools/audio_import.py`; `game/audio/` (`AudioSettings`,
`SfxCue`, `SfxBank`); `game/tools/build_audio_bank.tscn` (bank `.tres`, the 24 `Cue.Sfx.*` scenes, `sfx_rules.tres`, the bus
layout) and `game/tools/build_audio_pass.tscn` (228 files patched: 168 animations, 60 effects; report in `build/audio_pass_report.md`);
`AudioValidator` in `validate_content.tscn`; the console `audio`; the Audio sliders; the Credits screen; `CREDITS.md`;
`tests/game/test_audio_pass.gd` (30 tests); `tools/godot_tests.sh` also runs `audio_import.py --check` beside the shards. The EasyRPG files left the repo except the 48 the bank uses (converted copies).

Differences from sections 1–8:
1. **The `Audio:volume_db` key is set to 0 dB, not removed** (3.4). Removing a track would renumber the ones after it; a 0 dB key
   is the same sound and a one-line change.
2. **No backup folder.** The guard (3.4) reloads the original and the patched text in memory and compares length and every
   non-audio track before writing; a file that fails is left alone. Test plan item 3 tests the guard on a probe animation.
3. **The overtime clock plays on every overtime turn** (each application of `enrage.tres`), not only the first (3.5).
4. **The audio pass is the one builder that edits existing design files** (user's go-ahead, 2026-11-15), as narrow text patches
   only; recorded in `client-godot/CLAUDE.md` section 0 beside the other approved builders.
5. **The Credits screen reads the manifest**, so the player and dev export presets now include
   `presentation/audio/sfx/manifest.json` (they included no JSON before).
6. **Unit death moved from the sound board to `Cue.Sfx.Death`** (on the unit, bus Sfx), as 3.5's table says; the board has no
   `Death` player any more.
7. **Three new run messages** (user, 2026-11-15, after review round 3): `RunController` sends `Message.Run.CoinsGained`
   (`add_coins` when coins rise; magnitude = how many), `Message.Run.RoomUnlocked` (`enter_room` opening a lock; magnitude = the
   cell, data `key`), and `Message.Run.LevelsGained` once per action that raised any level (magnitude = levels gained in all;
   `LevelUp` and `SkillLearned` still come per member). The board plays Coin, Key (instead of Move for that room) and LevelUp
   from them; it no longer reads coins, the run log or a time window. PopupOpen comes from `UIManager.confirm_opened`,
   MenuOpen / MenuClose from `UIManager.stack_changed`, PopupNo from the confirm dialog's `%No` button, Advance from
   `event_page_shown` after page 0 (no Use sound: see item 12). Key also plays on `Message.Run.KeyFound`.
8. **Classification** reads the move's own name first (Silence is dark even with ice damage), then its role tags, then its damage
   type, then its effects' names; the keyword lists are in `build_audio_pass.gd`. Every party move that already had a sound
   kept it (mapped to `rtp.<name>`); the 24 ults each got their own entry (`ult.<id>`), so ten ults that shared Explosion1,
   Fire2 or Ice5 now sound different.
9. **Cue scenes live in `presentation/demo/cues/sfx/`**; their registration is checked by `AudioValidator` (`sfx_cue_unregistered`),
   since `FxValidator.sync_problems` looks only at the top cue folder.
10. **A sound cue plays on a voice under `/root/SfxVoices`, not under the cue** (review fix): the cue goes back to the pool at
    once and the sound ends on its own `finished`, so a death sound at a battle's end is not cut when the unit's view is freed,
    and no length is guessed from the randomizer (whose `get_length()` is 0 before its first play).
11. **`RunController.announcing`** is true while `announce_resumed` re-sends signals on a Continue, a resume or a rebuild; the
    sound board plays no coin, key or page sound meanwhile. `UIManager.confirm_opened` is the pop-up's signal; the board connects
    to the UI deferred, after `GameMain` builds it.
12. **No `Use` sound on the sound board** (review fix): a field item use sounds through its effect's own cue (`Cue.Sfx.Heal`,
    `Revive`, `Apply.Buff`…; field battles play cues inside an explicit action), so the board's extra sound would have doubled it.
    The `run.use` entry is gone.
13. **`RunController.silent`**: ServerLink's resume replay (`ResumeReplay`) sends no gameplay message, so a server Continue or a
    1103 / 1108 rebuild plays no toast and no sound for the tail it replays.
14. **The audio pass keeps a bank entry that is already on an animation** (the user's tuning after the first pass is never
    overwritten), except on an ult, which always gets its own `ult.<id>` signature back (a rebuild cannot leave it on a plain cast); `--reclassify a,b` classifies those animations again. Classification matches whole words of the move's name; a
    poison, dark or debuff name wins over any damage type, then a physical hit sounds physical (shards, bites, shots, heavy blows),
    then Fire / Ice, then roles and the effects' names. Only Echo Strike changed from the first pass (to the plain strike).
15. `build_demo.gd` (and the builders on it) gives a new move the bank entry `rtp.<name>`, or no sound with a warning when the bank
    does not hold that file; `build_audio_pass` then classifies it. The `sound` extra is `[file, time]`: its old volume argument
    is removed from the API and from all 99 calls (the bank carries the level).
16. Validator `sfx_persistent`: a `Cue.Sfx.*` tag in `persistent_cue_tags` is an error (GodotGAS turns `auto_destroy` off on the
    pooled node for good).
17. **Voices are pooled** per cue tag (at most `max_voices` players under `/root/SfxVoices`, reused when idle): a battle creates
    no player per hit. A voice still marked busy after 10 s counts as free, so one that stopped without `finished` never blocks
    its cue. The Audio screen saves a slider's value if the screen closes mid-drag; `audio play` uses the bus the game uses. Items 7, 15 and 17 close what review round 3 left open (user, 2026-11-15: "let's fix these").
