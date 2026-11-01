# Spec: main-menu (a proper main menu: Continue, New run, Settings with the server switch, Quit)

Status: ✅ Built (`de0d485` system, `50b776f` UI), awaiting playtest · 2026-11-01. Remaining: the visual check (section 6), a
refused-Connect test, an e2e scenario for offline Continue against a newer server copy, Q1.

Decided with the user (2026-11-01) before writing:
- **D1. Continue only, no auto-resume.** The game no longer drops the player into their server run at app start. The
  main menu asks the server for the player's current run, and Continue resumes it on click.
- **D2. Local saves.** Local-mode runs are saved after every action (`user://saves/local/run.json`), so Continue works
  offline and after a restart.
- **D3. The mode is shown and switchable.** The main menu shows Local mode or Server mode; Settings gets a Server
  section (url, player name, Connect, Disconnect). The console's `server` command stays and runs the same code.
- **D4. Seed field: disabled with a note in server mode** ("Seed: issued by the server"), now updated live when the
  mode changes (today it only updates when the screen opens; a link made from the console left it editable).
- **D5. Continue says where the save lives** (asked during the review, 2026-11-01). A tag next to Continue reads
  "Local" or "Synced", and pressing Continue opens a pop-up naming the kind of save before anything loads.
- **D6. Continue works offline in server mode** (asked after the first playtest, 2026-11-01), like Steam Cloud. When
  the server can't be reached but the player's server-mode save exists, Continue plays that save, tagged "Not synced",
  after a pop-up saying the save hasn't been synced and that the server will deny it if its copy of the run is newer.
  This replaces "greyed: Can't reach the server" (M3, M6) whenever a save exists.

## 1. Purpose & enterprise mapping
Today the app opens on the class-pick screen ("Run demo": content root, run picker, party, seed, Start run). There is
no Continue, no visible mode and no way to switch modes without the console. This spec puts a main menu in front of
it:

```
┌──────────────────────────────────────┐
│  rpgDemo                             │
│                                      │
│  [ Continue ]  LOCAL                 │   or SYNCED (server mode)
│    The Descent · floor 3 · Warrior,  │   greyed: "No run to continue",
│    Cleric, Arcanist · 12 min ago     │   "Checking the server…", "Can't reach the server"
│  [ New run ]                         │   → the class-pick screen (today's title menu), Back returns
│  [ Settings ]                        │   → settings, now with a Server section
│  [ Quit ]                            │
│                                      │
│  Server mode: http://localhost:5000  │   or "Local mode (offline)"
│  as Hodain                           │
└──────────────────────────────────────┘
```

| ID | Change |
|---|---|
| M1 | `main_menu.tscn` is the screen for `UI.State.Menu` (the policy rule that shows `title_menu.tscn` today shows it instead). Buttons Continue, New run, Settings, Quit; a title; a mode line. Built from the shared parts (FF7 window theme, `UIPushButton`). |
| M2 | **New run** pushes today's `title_menu.tscn` (class pick) onto the Menu layer; Back (Esc, a Back button top left) returns to the main menu. Starting a run while a run can be continued asks first: "Start a new run? Your current run will be abandoned." (in server mode the server abandons it, `server-authority` 2.1: a new run abandons the active one). |
| M3 | **Continue** is enabled when the current mode has a run to continue: local mode, a local save; server mode, `GET /runs/current` answered with an Active run. Its subtitle says which run. Greyed otherwise, with the reason; except that with the server unreachable and a server-mode save present it is enabled as an offline Continue (M12). Clicking it continues the run (M5, M6). |
| M4 | **Mode line** under the buttons: "Local mode (offline)", or "Server mode: <url> as <player>" in the server status colours (green answering, yellow not), the B10 line's text included. |
| M5 | **Local saves** (D2): `GameMain` saves the local run's `RunSnapshot` after every player action, at the start and when a battle starts; deletes the save when the run is won, lost or stopped; never saves sandbox runs or headless runs (unless a test turns it on). Continue loads it (`RunController.load_snapshot` + `announce_resumed`, as a resume from a server save does). |
| M6 | **Server Continue** (D1): `GameMain._ready` stops calling `resume_server_run()`. Continue calls it. The main menu asks `GET /runs/current` when it shows, when the link changes and when the link answers again (`connection_changed`); `playtest-fixes` B12's retry-on-reconnect is replaced by this refresh (the menu re-asks; nothing resumes without a click). |
| M7 | **Settings → Server** (D3): a url field, a player name field, Connect and Disconnect, and the mode line. Connect links (saved in the Settings only once linked, as the console does today); Disconnect returns to local mode. Both go through new `GameMain.connect_server(url, player)` / `disconnect_server()`, which the console's `server <url> [player]` / `server off` now call. Editable only on the main menu (no run playing); during a run the section shows the mode, read-only, with "Switch modes from the main menu". |
| M8 | **Seed field** (D4): `title_menu.gd` listens to `GameMain.server_changed` and refreshes the seed row at once. |
| M9 | **The run menu's Abandon becomes two buttons:** "Save and quit" (back to the main menu; the run stays saved, local or on the server, and Continue picks it up) and, in local mode only, "Abandon run" (confirm, delete the local save, back to the main menu). Server-mode abandon needs a server endpoint and is left out (section 4, open question Q1). Today's Abandon only goes back to the title and leaves the run as it was, which with Continue would read as a lie. |
| M11 | **Local or synced** (D5): a tag beside Continue, "Local" (local save; muted gold) or "Synced" (the server holds the run; the server status green), shown whenever Continue shows a run. Pressing Continue opens the shared confirm dialog (`ctx.ui.confirm`) first: local, "This is a local save, played offline and not synced with the server. Continue it?"; server, "This run is synced with the server as <player>. Continue it?". Yes continues; No stays on the main menu. The texts are `@export`s on `main_menu.gd`. A third tag, "Not synced" (yellow), belongs to M12. |
| M12 | **Offline Continue** (D6): in server mode, when `GET /runs/current` gets no answer and `ServerLink.load_save()` holds a save, `GameMain.can_continue()` returns an enabled "Not synced" entry (subtitle from the save). The confirm reads "This save hasn't been synced with the server. You can play it offline, but the server will deny it if its copy of the run is newer. Continue it?". Yes calls `GameMain.continue_server_offline()` → `ServerLink.resume_offline(run, content)`: the run loads from the save with the link attached, queued actions upload when the server answers, and a 1103 rebuilds from the server's log or stops the run, as Part B does. |
| M10 | **Quit** asks nothing (the run is already saved) and quits the app. |

Enterprise mapping: client-side. In server mode the menu uses only what Part B already built: `GET /runs/current`
(`run:current:{player}` cache-aside in Redis, Postgres behind it), `GET /runs/{id}/resume`, and `POST /runs`, which
already abandons the player's previous active run. No new endpoint, record, queue, topic or Redis key. The local save
is a client file, like Part B's server-mode save (`user://saves/<player>/run.json`).

## 2. Sequence flow

**App start (either mode)**
1. `GameMain._ready` builds the UI, links the server if the Settings name a url (as today), and sets mode `menu`. It no
   longer resumes anything (M6).
2. The main menu activates: local mode reads `user://saves/local/run.json` (M5); server mode shows "Checking the
   server…" and asks:
   ```
   Godot (ServerLink) ──GET /api/v1/runs/current──▶ GameServerApi ──▶ Redis run:current:{player} ──miss──▶ Postgres runs
                      ◀── 200 RunSummaryResponse (Active) │ 204 (none) │ no answer / 5xx
   ```
   200 Active → Continue enabled; 204 or another status → "No run to continue"; no answer → the offline Continue
   (M12) when a save exists, else "Can't reach the server" (greyed). When the link answers again (`connection_changed`), or the mode changes, the menu asks again.

**Continue** (after the M11 pop-up's Yes)
- Local: `GameMain.continue_local_run()` → a new `RunController`, `load_snapshot(content, save.snapshot)`,
  `announce_resumed()`, mode `run`. A snapshot that doesn't load (content changed so far that an id is gone) shows the
  error on the menu and offers "Delete save".
- Server: `GameMain.resume_server_run()`, unchanged (local server save or the server's log, the connecting pop-up
  meanwhile, `playtest-fixes` B9).
- Server, unreachable (M12): `GameMain.continue_server_offline()` → `ServerLink.resume_offline`, from the save only.

**New run → Start run** (class pick, unchanged except M2's confirm and M8): local mode starts a run and writes its
first save; server mode `POST /api/v1/runs` (the server abandons the previous active run, as built).

**During a local run** every player action ends in `RunController._commit_after`; it now emits `action_committed`
(journal or not), and `GameMain` rewrites the local save from `run.snapshot()`.

## 3. Data contracts
N/A for the wire: no new DTO in `Rpg.Contracts`, no queue, topic or Redis key. Used as built: `RunSummaryResponse`,
`RunStartRequest`/`Response`, `RunResumeResponse`.

**Local save file** (client only, not a contract; `user://saves/local/run.json`, rewritten whole on every save,
written to `run.json.tmp` then renamed so a crash never leaves half a file):
```json
{
  "schemaVersion": 1,
  "rulesetVersion": "4.7.2.stable.mono+0123456789abcdef",
  "savedAt": "2026-11-01T14:03:12Z",
  "summary": { "runName": "The Descent", "floor": 3, "party": ["Warrior", "Cleric", "Arcanist"] },
  "snapshot": { "...": "RunSnapshot v1, as Part B's server-mode save holds it" }
}
```
`summary` exists so the menu never loads the run to draw the Continue subtitle. A save from another ruleset version
still loads (the editor changes the content hash on every edit); the subtitle then adds "(older version)".

**Server-mode subtitle:** from `RunSummaryResponse` ("floor N · started 12 min ago"); when the player's server-mode
save (`ServerLink.load_save()`) is for the same `runId`, its snapshot adds the run name and party.

## 4. Failure modes
| Case | Behaviour | Test |
|---|---|---|
| Server mode, server off at app start | The mode line is yellow. With no server save, Continue is greyed "Can't reach the server"; with one, it is the offline Continue (M12, tag "Not synced", confirm first). The heartbeat (quicker while offline, B12; `test_server_ui::test_heartbeat_quicker_while_offline`) notices the server's return, `connection_changed` re-asks, Continue becomes "Synced". Nothing resumes on its own (D1). | `test_main_menu::test_server_continue_follows_connection`, `test_server_offline_continue_from_the_save` |
| Server mode, offline Continue, the server holds a newer copy | The queued actions meet a 1103 and the run rebuilds from the server's log or stops, as Part B. | **Not tested end to end yet** (no e2e scenario) |
| Server mode, no active run (204) | Continue greyed "No run to continue". | same file, `test_server_no_run_and_verifying` |
| Server run is Verifying | Continue greyed "The run is being verified" (resume needs an Active run; Part B 2.3 keeps polling in the run that sent it). | same test |
| Local save unreadable or wrong schema | Treated as no save; the file is kept (renamed `run.json.bad`) so nothing is lost silently, and the menu says "The saved run couldn't be read". | `test_local_save_unreadable` |
| Local save won't load (content changed) | Continue shows the error and a "Delete save" button; nothing else changes. | `test_local_save_wont_load` |
| Crash while saving | The tmp-then-rename write keeps the previous save whole. | `test_local_save_atomic` (a leftover `.tmp` is ignored and replaced) |
| New run while a run can be continued | Confirm first (M2); local: the old save is replaced by the new run's; server: `POST /runs` abandons the old run (built, `StartRun_AbandonsPrevious`). | `test_new_run_confirms` |
| Switching modes with a run in memory | Not possible: Settings → Server is read-only during a run (M7); on the main menu no run is playing (Save and quit left it saved). | `test_settings_server_section` |
| Connect fails (no C# assembly, bad url) | The Settings show the reason; nothing is saved (as the console today). | **Not tested** (a real Connect or Disconnect writes the real `user://game_main.cfg`) |

Idempotency, retries and dead letters: N/A beyond what `ServerLink` already does (retries with backoff, the action
queue). Acceptance scenarios: none is changed; scenario 4 (Redis flushed → Postgres) still covers `GET /runs/current`
behind Continue.

**Open question Q1 (for review):** abandoning a *server* run. There is no abandon endpoint; a server run ends only by
death, a win, or a new run abandoning it. M9 therefore offers only Save and quit in server mode. A later server slice
could add `POST /runs/{id}/abandon` (Active → Abandoned, idempotent) and the button with it.

## 5. Observability
N/A: no new server code or metrics. `GET /runs/current` is already counted by the request metrics and
`rpg_cache_reads_total`.

## 6. Test plan
New `tests/game/test_main_menu.gd` (headless, the demo UI policy, fixtures as content, `ServerLink` on the fake bridge
from `test_server_mode`; local saves turned on with a per-test folder):
- **M1, M4:** in local mode the Menu layer shows the main menu with Continue, New run, Settings, Quit and "Local mode
  (offline)"; with a link, "Server mode: <url> as tester".
- **M2:** New run pushes the class pick; Back returns to the main menu with Continue as it was; Start run with a save
  present asks first, and No starts nothing.
- **M3, M5:** no save → Continue greyed; play a local run a few actions (console `new`, `enter`, a battle), Save and
  quit → Continue enabled with "<run> · floor 1 · <party>"; Continue → the run's state hash equals the hash before
  quitting; a fresh `GameMain` (an app restart) does the same from the file. A won, lost or stopped run deletes the
  save; a sandbox run writes none.
- **M12:** server mode with the bridge down and a server save: Continue is enabled, tagged "Not synced", the confirm
  names the unsynced save, and Yes loads the run from the save (`test_server_offline_continue_from_the_save`).
- **M11:** the tag reads "Local" with a local save and "Synced" with an Active server run, and is hidden when Continue is
  greyed; pressing Continue opens the confirm with the local or the synced text; No leaves the menu as it was and loads
  nothing; Yes continues.
- **M6:** server mode: `_ready` sends no `GetCurrentRun` resume of its own (the fake bridge sees only the menu's query);
  an Active run enables Continue and Continue calls `GET /resume` or uses the server save (the existing
  `test_run_authority` resume paths); 204 greys it; offline greys it, then an answer re-asks and enables it.
- **M7:** Settings → Server: Connect with the fake bridge links and saves url and player; Disconnect returns to local
  mode and clears the url; read-only during a run; the console's `server` and `server off` still pass
  `test_e2e_tools` and the dev console tests (they now call the same `GameMain` methods).
- **M8:** with the class pick open, linking a server disables the seed field and shows "Seed: issued by the server";
  unlinking re-enables it.
- **M9:** the run menu shows Save and quit and, in local mode only, Abandon run; Abandon run deletes the save.
- **Unchanged:** `test_demo_ui_policy` (updated for the new Menu screen), `validate_content.tscn` (`UIPolicyCheck`),
  every run and battle golden (saving reads state and never changes it), `tools/e2e.sh` scenarios (they drive the run
  through the console, never the menu).
- **Visual check:** a window run (`dev_run --window --shots`) with screenshots of the main menu in local mode, in
  server mode with and without a run to continue, the class pick in server mode, and Settings → Server, in
  `H:\claudeOutShots\<date> main-menu\`.
- Both suites (`tools/godot_tests.sh`, `tools/dotnet_test.sh`) pass.

## 7. Files (for the build)
| File | Owner | Change |
|---|---|---|
| `presentation/demo/ui/main_menu.tscn` / `.gd` | user (new) | M1, M3, M4, M10, M11 |
| `presentation/demo/ui/ui_policy.tres` | user (edit, asked first) | the `UI.State.Menu` rule shows `main_menu.tscn` |
| `presentation/demo/ui/title_menu.tscn` / `.gd` | user (edit, asked first) | a Back button top left; M2's confirm; M8 |
| `presentation/demo/ui/settings.tscn` / `.gd` | user (edit, asked first) | M7's Server section |
| `presentation/demo/ui/run_menu.tscn` / `.gd` | user (edit, asked first) | M9 |
| `game/game_main.gd` | system | no resume in `_ready`; `continue_local_run()`, the local save (`local_saves`, `local_save_path`), `connect_server()` / `disconnect_server()`, `can_continue()` (what Continue shows) |
| `game/run_controller.gd` | system | `action_committed` from `_commit_after` in every mode |
| `game/local_save.gd` | system (new) | `LocalSave.write/read/delete` (section 3) |
| `game/server_link.gd` | system | `url`, `_load_save_into` (shared with `resume_into`), `resume_offline` (M12) |
| `game/dev/commands/server.gd` | system | through `GameMain.connect_server()` / `disconnect_server()` |
| `tests/game/test_main_menu.gd` | system (new) | section 6 |
