## The playable client shell (spec game-skeleton 3.7): owns the content root and the RunController, and hosts the
## UI and the 3D room view. The UI is data (spec ui-framework): a UIPolicy (default
## res://presentation/demo/ui/ui_policy.tres) names the layout, the screens and the panels, and a UIManager shows them
## by UI state; screens get a UIContext instead of this node. The room view, unit view and sound board are your scenes
## with `setup(main: GameMain)` (defaults in res://presentation/demo/).
##
## Holds no game rules: every change goes through RunController. Battles are fought here with an ActionRecorder (the
## battle panel submits the player's picks) and a ViewGate (the room view plays the animations). Spec
## gameplay-messages: lines for the player go out on the GameplayMessages bus (Message.Notification), and each battle
## fought here gets a BattleMessages bridge (Message.Battle.*); the replay and trace runners never make one.
class_name GameMain
extends Node

## "menu", "run" or "end". Screens show or hide themselves.
signal mode_changed(mode: String)
## A new RunController exists (before its run starts): connect to its signals here.
signal run_changed(run: RunController)
## A battle is about to start: the battle panel drives `recorder`, the room view animates through `gate`.
signal battle_prepared(recorder: ActionRecorder, gate: ViewGate)
signal content_changed(content: ContentIndex)
## A sandbox run (spec dev-tools 2.2) was left through the run-end screen.
signal sandbox_closed
## Spec playtest-fixes B10: server mode switched on (a new link) or off (null).
signal server_changed(link: ServerLink)

const VIEW_DIR: String = "res://presentation/demo/"
const UI_POLICY: String = "res://presentation/demo/ui/ui_policy.tres"
const FX_REGISTRY: String = "res://presentation/demo/fx/fx_registry.tres"
const SETTINGS_PATH: String = "user://game_main.cfg"
const CONTENT_ROOTS: Array[String] = ["res://content/", "res://tests/fixtures/"]

## Spec ui-framework: every screen and panel, as data. Empty: res://presentation/demo/ui/ui_policy.tres.
@export var ui_policy: UIPolicy
## Spec vfx-content-pass 2.2: "when this happens in a battle, play that effect" as data (damage numbers, per-type hits, heal glows,
## cast rings). Empty: the rule sets of res://presentation/demo/fx/fx_registry.tres. Not attached headless (no effects to play).
@export var fx_rules: Array[FxRuleSet] = []
## Spec playtest-fixes B9: what the connecting pop-up says while a server run starts or resumes.
@export var wait_start_text: String = "Starting the run…"
@export var wait_resume_text: String = "Resuming your run…"
## Spec card-collection 3.6: shown when the player tries to leave a won run the server has not accepted yet.
@export var leaving_blocked_text: String = "The run is being verified. You can leave once the server accepts it."
## Spec playtest-fixes B11: the message line once the server answers again after a server problem was shown.
@export var reconnected_text: String = "Connected to the server as %s"
## Spec main-menu M4: the mode line of the main menu and Settings.
@export var local_mode_text: String = "Local mode (offline)"
@export var server_mode_format: String = "Server mode: %s as %s"
## The 3D room (a Node3D with setup(main)); not UI.
@export var room_view: PackedScene
@export var unit_view: PackedScene
## UI sounds and stingers (a Node with setup(main)); ability and hit sounds come from animations and GameplayCues.
@export var sound_board: PackedScene

var content_root: String = CONTENT_ROOTS[0]
var content: ContentIndex
var run: RunController
## Spec server-authority 3.7: the link to the server (server mode), or null (local mode: no server url in the Settings,
## or headless). use_server() sets it.
var server: ServerLink
var mode: String = "menu"
## The current battle's recorder (the party's input), for the dev console's battle commands.
var recorder: ActionRecorder
## The current battle's presentation gate (a battle panel created after battle_prepared reads it here).
var gate: ViewGate
## Abilities resolve without waiting for their animations (the dev script runner).
var skip_animations: bool = false
## Spec ui-framework: shows the policy's screens; null when the policy failed to load (see the error label).
var ui: UIManager
## Spec gameplay-messages: the current battle's bridge to Message.Battle.* (null between battles).
var battle_messages: BattleMessages
## Spec vfx-content-pass: the registry's tag cues (State.Broken, State.Dead...) watching this battle's units.
var battle_tag_cues: FxTagCues
## Spec auto-battle (A1): Auto plays the party's decisions for the rest of this run (the battle panel's Auto, the
## console's `auto`). Presentation state: never in RunState, a log or a hash. Each new run starts from the Settings
## default `auto_battle` (headless runs always start with Auto off, so a saved setting can't change tests or reports).
var auto_battle: bool = false:
	set(value):
		auto_battle = value
		_apply_auto()
## Spec auto-battle (A2): Auto casts ults worth casting (Settings `auto_ults`).
var auto_ults: bool = true:
	set(value):
		auto_ults = value
		_apply_auto()

var _error_label: Label
## Spec playtest-fixes B11: a server problem stays on the message line until something replaces it; once the link
## answers again (the same link, or a new one from the console's `server <url>`), the line says so.
var _server_problem_shown: bool = false
## Spec main-menu M5 (D2): local-mode runs are saved after every action. Off headless (tests turn it on with their own
## `local_save_path`).
var local_saves: bool = DisplayServer.get_name() != "headless"
## Set before the scene enters the tree: play locally even in a window, ignoring the Settings' server url (dev_run --local).
var force_local: bool = false
var local_save_path: String = LocalSave.DEFAULT_PATH
## While a save loads: a run that stops then keeps its file (the menu offers "Delete save").
var _loading_save: bool = false


func _ready() -> void:
	add_to_group("game_main")
	var settings := ConfigFile.new()
	if settings.load(SETTINGS_PATH) == OK:
		content_root = settings.get_value("game", "content_root", content_root)
	if not content_roots().has(content_root):
		content_root = CONTENT_ROOTS[0]  # e.g. the fixtures, saved in the editor, are not in an export
	var world := Node3D.new()
	world.name = "World"
	add_child(world)
	var canvas := CanvasLayer.new()
	canvas.name = "UI"
	add_child(canvas)
	var missing := PackedStringArray()
	unit_view = _view(unit_view, "unit_view", missing)
	var room := _view(room_view, "room_view_3d", missing)
	if room != null:
		_add_view(room.instantiate(), world)
	_attach_fx_rules()
	var sounds := _view(sound_board, "sound_board", missing)
	if sounds != null:
		_add_view(sounds.instantiate(), canvas)
	var problem := _build_ui(canvas)
	if not missing.is_empty():
		problem += ("\n" if problem != "" else "") + "Missing views: %s (res://presentation/demo/)." % ", ".join(missing)
	if problem != "":
		_error_label = Label.new()
		_error_label.name = "UIError"
		_error_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		_error_label.text = problem
		canvas.add_child(_error_label)
		_error_label.set_anchors_preset(Control.PRESET_TOP_WIDE)
		push_warning("GameMain: " + problem)
	load_content()
	if DisplayServer.get_name() != "headless" and not force_local:
		use_server(ServerLink.from_settings())  # headless runs (tests, tools, the verifier) stay local
	set_mode("menu")  # spec main-menu D1: nothing resumes on its own; the main menu's Continue does


## Spec server-authority: plays in server mode through `link`, or in local mode when null.
func use_server(link: ServerLink) -> void:
	if server != null and server != link:
		server.queue_free()
	var changed := server != link
	server = link
	if server != null and server.get_parent() == null:
		add_child(server)
	if changed and server != null:
		server.connection_changed.connect(_on_server_connection.bind(server))
	if changed:
		server_changed.emit(server)



## Spec main-menu M7: links the server `url` as `player_name` and remembers both (only once linked). "" or why not.
func connect_server(url: String, player_name: String = "dev") -> String:
	url = url.strip_edges()
	if url == "":
		return "Enter the server url"
	player_name = player_name.strip_edges()
	if player_name == "":
		player_name = "dev"
	var link := ServerLink.create(url, player_name)
	if link == null:
		return "can't link (is the C# assembly built? nothing was saved)"
	save_setting(ServerLink.SETTINGS_SECTION, "url", url)
	save_setting(ServerLink.SETTINGS_SECTION, "player", player_name)
	use_server(link)
	return ""


## Spec main-menu M7: back to local mode (new runs only; the url is forgotten).
func disconnect_server() -> void:
	save_setting(ServerLink.SETTINGS_SECTION, "url", "")
	use_server(null)


func _on_server_connection(link: ServerLink) -> void:
	if link != server:
		return
	if not link.connected():
		_server_problem_shown = true
		return
	if _server_problem_shown:
		_server_problem_shown = false
		show_message(reconnected_text % link.player)


## Spec ui-framework 2.1: the UI policy's layout under `canvas`. "" or why it failed (the game still runs headless and
## from the console).
func _build_ui(canvas: CanvasLayer) -> String:
	var policy := ui_policy
	if policy == null and ResourceLoader.exists(UI_POLICY):
		policy = load(UI_POLICY) as UIPolicy
	if policy == null:
		return "No UI policy: set GameMain.ui_policy or create %s." % UI_POLICY
	ui = UIManager.new()
	ui.name = "UIManager"
	add_child(ui)
	var problem: String = ui.setup(self, policy, canvas)
	if problem != "":
		ui.queue_free()
		ui = null
		return "UI policy %s: %s" % [policy.resource_path, problem]
	return ""


## The content roots this build has: an export leaves tests/ out (spec playable-demo D5), so only res://content/.
static func content_roots() -> Array[String]:
	var roots: Array[String] = []
	roots.assign(CONTENT_ROOTS.filter(func(path: String): return DirAccess.dir_exists_absolute(path)))
	return roots


## Switches the content root (res://content/ or the test fixtures) and remembers it.
func set_content_root(path: String) -> void:
	content_root = path
	var settings := ConfigFile.new()
	settings.load(SETTINGS_PATH)
	settings.set_value("game", "content_root", path)
	settings.save(SETTINGS_PATH)
	load_content()


func load_content() -> void:
	content = ContentIndex.new(content_root)
	prepare_effects(BOOT_PREPARE_PER_FRAME, "boot")
	# The console's dev stat items (spec dev-tools 3.3), only while cheats are allowed; never in a pool.
	var dev := get_node_or_null("/root/Dev")
	if dev != null and dev.cheats_allowed() and DirAccess.dir_exists_absolute(RunController.DEV_CONTENT):
		content.add_root(RunController.DEV_CONTENT)
	if not content.problems.is_empty():
		show_message("Content problems in %s: %s" % [content_root, "; ".join(content.problems)])
	content_changed.emit(content)


## Spec card-collection 3.6: the local test collection (the console's `cards local`): the item pool local runs start with, or
## null (everything, today's behaviour). Not ownership and never sent anywhere: a server run takes only the server's pool.
var local_card_pool: Variant = null


## Starts a run with the chosen characters (ids) and a seed typed as a decimal string. "" or the error.
## `run_id` picks the RunStructure (spec playable-demo 2.2); empty = the only or the default one.
## In server mode the seed is ignored: the server opens the run and issues every floor seed; "" returns at once and the
## run starts when the server answers ("Connecting…" meanwhile; a refusal shows as a Notification).
## Spec vfx-stencil 3.4: compile the effect shader copies every battle of the content can need, before any battle: at boot (the
## main menu, a few copies a frame, `BOOT_PREPARE_PER_FRAME`) and again at run start (whatever boot has not finished). Inert
## headless, with stencil off or before the room view's camera exists.
const BOOT_PREPARE_PER_FRAME := 2


func prepare_effects(per_frame: int, label: String) -> void:
	var camera := get_viewport().get_camera_3d() if is_inside_tree() else null
	if content == null or camera == null:
		return
	var largest := 0
	for encounter in content.encounters.values():
		largest = maxi(largest, (encounter as EncounterDefinition).slots.size())
	FxManager.prepare_stencil(camera, StencilIds.values_for(largest), per_frame, label)


func start_run(character_ids: Array, seed_text: String, run_id: StringName = &"") -> String:
	prepare_effects(8, "run start")
	if server != null:
		_start_server_run(character_ids, run_id)
		return ""
	_new_run()
	var error := run.start_run(content, character_ids, seed_text, run_id, local_card_pool)
	if error != "":
		set_mode("end")
	return error


## Spec server-authority 2.1: POST /runs, then the run plays floor 0 from the issued seed; later floors ask the link.
func _start_server_run(character_ids: Array, run_id: StringName) -> void:
	var picked := RunController.pick_run(content, run_id)
	if picked["error"] != "":
		show_message(picked["error"])
		return
	var structure_id := String(picked["run"].id)
	show_message("Connecting…")
	var link := server
	link.begin_wait(&"start", wait_start_text)
	var result := await link.start_run(RulesetVersion.current(), structure_id, character_ids)
	link.end_wait(&"start")
	if not result["ok"]:
		_server_problem_shown = true
		show_message("Server: " + ServerLink.describe(result["error"]))
		return
	var server_run_id := str(result["data"]["runId"])
	_new_run()
	server.link(run, server_run_id)
	var error := run.start_server_run(content, character_ids, server_run_id, str(result["data"]["floorSeed"]).to_int(),
		StringName(structure_id), result["data"].get("cardPool"))  # spec card-collection 2.5: the server's pool, or none
	if error != "":
		set_mode("end")


## Spec server-authority 2.4: continues the player's current server run, if there is one: from the local save when
## it is this run's and up to date, else rebuilt from the server's log. "" (resumed, or nothing to resume) or the
## error (also shown as a Notification).
func resume_server_run() -> String:
	if server == null:
		return "not in server mode"
	var link := server
	link.begin_wait(&"resume", wait_resume_text)
	var error := await _resume_server_run(link)
	link.end_wait(&"resume")
	return error


func _resume_server_run(link: ServerLink) -> String:
	var current := await link.get_current_run()
	if not current["ok"]:
		_server_problem_shown = true
		show_message("Server: " + ServerLink.describe(current["error"]))
		return ServerLink.describe(current["error"])
	if current["data"] == null:
		return ""
	_new_run()
	var error := await link.resume_into(run, content, current["data"])
	if error != "":
		show_message("Server: " + error)
		set_mode("menu")
	return error


## Plays one room or hand-made floor (spec dev-tools 2.2). "" or the error.
func start_sandbox(request: SandboxRequest) -> String:
	_new_run()
	var error := run.start_sandbox(content, request)
	if error != "":
		set_mode("end")
	return error


## The content root's runs for a picker, sorted by id: [{"id", "name", "default"}] (default = what an empty id starts).
func runs() -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	if content == null:
		return result
	var default_id: StringName = &""
	var picked := RunController.pick_run(content)
	if picked["error"] == "":
		default_id = picked["run"].id
	var ids := content.runs.keys()
	ids.sort_custom(func(a, b) -> bool: return String(a) < String(b))
	for id in ids:
		var structure: RunStructure = content.runs[id]
		result.append({"id": id, "name": structure.display_name if structure.display_name != "" else String(id),
			"default": id == default_id})
	return result


func _new_run() -> void:
	if run != null:
		run.queue_free()
	run = RunController.new()
	run.name = "Run"
	add_child(run)
	run.stopped.connect(_on_run_stopped)
	run.action_committed.connect(save_local_run)
	run.battle_requested.connect(_on_battle_requested)
	run.battle_started.connect(_on_battle_started)
	run.battle_finished.connect(func(_outcome): battle_messages = null)
	run.run_ended.connect(func(_status):
		delete_local_save()
		set_mode("end"))
	var windowed := DisplayServer.get_name() != "headless"
	auto_ults = load_setting("settings", "auto_ults", true)
	auto_battle = windowed and load_setting("settings", "auto_battle", false)
	show_message("")
	run_changed.emit(run)
	set_mode("run")


## Spec auto-battle: the player's Auto policy with the current options (the content root tells consumables apart).
func make_autopilot() -> AutoPolicy:
	var options := AutoPolicy.Options.new()
	options.ults = auto_ults
	return AutoPolicy.new(options, content)


## Gives the current battle's recorder an autopilot while Auto is on, or takes it away.
func _apply_auto() -> void:
	if recorder == null:
		return
	if auto_battle:
		recorder.autopilot = make_autopilot()
	elif recorder.autopilot != null:
		recorder.autopilot = null


## A player setting from user://game_main.cfg (the menu's last party, battle speed…); `fallback` when unset.
static func load_setting(section: String, key: String, fallback: Variant) -> Variant:
	var settings := ConfigFile.new()
	settings.load(SETTINGS_PATH)
	return settings.get_value(section, key, fallback)


static func save_setting(section: String, key: String, value: Variant) -> void:
	var settings := ConfigFile.new()
	settings.load(SETTINGS_PATH)
	settings.set_value(section, key, value)
	settings.save(SETTINGS_PATH)


# --- Local saves and Continue (spec main-menu) --------------------------------------------------------------------

## Whether the run in memory is a local-mode run that gets a save (not a sandbox, not a server run, not ended).
func _saves_this_run() -> bool:
	return local_saves and run != null and run.state != null and not run.journal and not run.state.sandbox \
		and not run.state.seeds().server_mode() and run.state.status == RunState.ACTIVE and run.runner_error == ""


## Rewrites the local save from the run in memory (after every player action, and on Save and quit).
func save_local_run() -> void:
	if _saves_this_run():
		LocalSave.write(local_save_path, run, content)


func delete_local_save() -> void:
	if local_saves and not _loading_save:
		LocalSave.delete(local_save_path)


## Spec main-menu M4: "Local mode (offline)" or "Server mode: <url> as <player>".
func mode_line() -> String:
	return local_mode_text if server == null else server_mode_format % [server.url, server.player]


static func _no_continue(reason: String) -> Dictionary:
	return {"enabled": false, "reason": reason, "tag": "", "subtitle": "", "older": false}


## What the main menu's Continue shows (spec main-menu M3, M11): {"enabled", "reason", "tag", "subtitle", "older"}.
## reason: "" (enabled), "none", "unreadable", "unreachable", "verifying". tag: "Local" or "Synced". Server mode asks
## GET /runs/current (so this awaits); local mode reads the save file.
func can_continue() -> Dictionary:
	if server == null:
		var read := LocalSave.read(local_save_path)
		if read["state"] != "ok":
			return _no_continue("none" if read["state"] == "none" else "unreadable")
		var saved: Dictionary = read["data"]
		var summary: Dictionary = saved["summary"]
		return {"enabled": true, "reason": "", "tag": "Local", "older": saved.get("rulesetVersion", "") != RulesetVersion.current(),
			"subtitle": "%s · floor %d · %s · %s" % [summary.get("runName", "?"), int(summary.get("floor", 1)),
				", ".join(PackedStringArray(summary.get("party", []))), ago(str(saved.get("savedAt", "")))]}
	var link := server
	var current := await link.get_current_run()
	if link != server:
		return _no_continue("unreachable")
	if not current["ok"]:
		# No answer: the server-mode save can still be played offline (it syncs once the server answers).
		var offline := _offline_continue(link)
		return offline if not offline.is_empty() and ServerLink.retryable(current["error"]) else _no_continue("unreachable")
	if current["data"] == null:
		return _no_continue("none")
	var data: Dictionary = current["data"]
	var status := str(data.get("status", ""))
	if status == "Verifying":
		# Spec card-collection 3.6: a won run waiting for its verdict is continued into the same "Verifying the run…" wait, from
		# the save that holds its end request (the player may have closed the game meanwhile); without it there is nothing to show.
		var waiting := link.load_save()
		if not waiting.is_empty() and str(waiting.get("runId", "")) == str(data.get("runId", "")) and not waiting.get("end", {}).is_empty() \
				and ServerLink.save_seq(waiting) >= int(data.get("lastSeq", 0)):  # the same test resume_into applies to a save
			return {"enabled": true, "reason": "", "tag": "Synced", "subtitle": "won run · waiting for the server to accept it", "older": false}
	if status != "Active":
		return _no_continue("verifying" if status == "Verifying" else "none")
	var text := "floor %d · started %s" % [int(data.get("currentFloor", 0)) + 1, ago(str(data.get("startedAt", "")))]
	var local := link.load_save()
	if not local.is_empty() and str(local.get("runId", "")) == str(data.get("runId", "")):
		text = _server_save_text(local) + " · started " + ago(str(data.get("startedAt", "")))
	return {"enabled": true, "reason": "", "tag": "Synced", "subtitle": text, "older": false}


## The Continue info for the player's server-mode save when the server can't be reached, or {} when there is no
## continuable save (none, ended, or another schema).
func _offline_continue(link: ServerLink) -> Dictionary:
	var saved := link.load_save()
	if saved.is_empty() or str(saved.get("snapshot", {}).get("run", {}).get("status", "")) != RunState.ACTIVE:
		return {}
	return {"enabled": true, "reason": "", "tag": "Offline", "older": false,
		"subtitle": "%s · not synced" % _server_save_text(saved)}


## "The Descent · floor 3 · Warrior, Cleric" from a ServerLink save.
func _server_save_text(saved: Dictionary) -> String:
	var in_save: Dictionary = saved.get("snapshot", {}).get("run", {})
	var names := PackedStringArray()
	for member in in_save.get("party", []):
		var character = content.characters.get(StringName(member["character"])) if content != null else null
		names.append(character.display_name if character != null and character.display_name != "" else str(member["character"]))
	var structure = content.runs.get(StringName(in_save.get("structure", ""))) if content != null else null
	return "%s · floor %d · %s" % [structure.display_name if structure != null and structure.display_name != ""
		else str(in_save.get("structure", "?")), int(in_save.get("floor", 0)) + 1, ", ".join(names)]


## "12 min ago" for an ISO UTC time ("" when unknown).
static func ago(iso: String) -> String:
	if iso == "":
		return ""
	var then := Time.get_unix_time_from_datetime_string(iso.left(19))
	var seconds := maxi(int(Time.get_unix_time_from_system() - then), 0)
	if seconds < 60:
		return "just now"
	if seconds < 3600:
		return "%d min ago" % (seconds / 60)
	if seconds < 86400:
		return "%d h ago" % (seconds / 3600)
	return "%d d ago" % (seconds / 86400)


## Spec main-menu (offline Continue): plays the server-mode save without asking the server. Its actions upload when the
## server answers; a save the server has moved past is refused then (rebuilt from the server, or the run stops).
func continue_server_offline() -> String:
	if server == null:
		return "not in server mode"
	_new_run()
	var error := server.resume_offline(run, content)
	if error != "":
		show_message("Server: " + error)
		set_mode("menu")
	return error


## Continues the local save in a new RunController (like a resume from a server save). "" or the error; on an error
## the save stays and the mode goes back to "menu".
func continue_local_run() -> String:
	var read := LocalSave.read(local_save_path)
	if read["state"] != "ok":
		return "The saved run couldn't be read" if read["state"] == "bad" else "No saved run"
	var damaged := RunState.save_pool_problem(read["data"])
	if damaged != "":
		return damaged + "; it can't be continued"  # a local test pool is not recoverable from anywhere else
	_loading_save = true
	_new_run()
	var error := run.load_snapshot(content, read["data"]["snapshot"], read["data"].get("cardPool"))
	_loading_save = false
	if error != "":
		set_mode("menu")
		return error
	run.announce_resumed()
	return ""


## Spec card-collection 3.6: a won server run waits for the server to accept it (the "Verifying the run…" wait) and the player
## cannot leave to the main menu until it has: the verdict decides what the win is worth, and a rolled-back run goes on playing.
## Closing the game is allowed; Continue brings the same wait back. True from the win until the run-end screen.
func leaving_blocked() -> bool:
	return server != null and mode == "run" and run != null and run.state != null and run.state.status == RunState.WON


func _blocked_message() -> void:
	show_message(leaving_blocked_text)


## Spec main-menu M9: leaves the run for the main menu with the run saved (local mode: the file is written now).
func save_and_quit() -> void:
	if leaving_blocked():
		_blocked_message()
		return
	save_local_run()
	back_to_menu()


## Spec main-menu M9 (local mode): the run is dropped with its save.
func abandon_local_run() -> void:
	delete_local_save()
	back_to_menu()


func back_to_menu() -> void:
	if leaving_blocked():
		_blocked_message()
		return
	if run != null and run.state != null and run.state.sandbox:
		sandbox_closed.emit()
	set_mode("menu")


func set_mode(new_mode: String) -> void:
	mode = new_mode
	if new_mode == "menu":
		FxManager.stop_all()  # spec vfx-framework: no looping aura outlives its run
	mode_changed.emit(mode)


## A line for the player (refusals, content problems): broadcast on Message.Notification; the policy's message line
## (and any other listener) shows it. "" clears the line.
func show_message(text: String) -> void:
	GameplayMessages.broadcast(GameplayMessageRouter.NOTIFICATION, NotificationMessage.make(text))


## A player's action was refused: `text` on Message.Notification (the message line) and Message.Ui.Refused (sounds, a
## shake) with Verb.Refuse, `instigator` (who tried) and `data` plus "text". Screens refuse through this, never by
## playing a sound themselves.
func refuse(text: String, instigator: StringName = &"", data: Dictionary = {}) -> void:
	show_message(text)
	var extras := data.duplicate()
	extras["text"] = text
	GameplayMessages.broadcast(GameplayMessageRouter.UI_REFUSED,
		VerbMessage.make(&"Verb.Refuse", instigator, &"", 0, [], extras))


## Spec vfx-content-pass 2.2: the battle effect rules listen on the message bus for as long as the game shell lives.
func _attach_fx_rules() -> void:
	var service := get_node_or_null("/root/FxManager") as FxService
	if service == null or not service.enabled:
		return
	if fx_rules.is_empty() and ResourceLoader.exists(FX_REGISTRY):
		var registry := load(FX_REGISTRY) as FxRegistry
		if registry != null:
			fx_rules.append_array(registry.all_rule_sets())
	for rules in fx_rules:
		rules.attach(self)


## A runner error stopped the run (its text went out as a Notification): show the end screen.
func _on_run_stopped(_error: String) -> void:
	delete_local_save()
	if mode == "run":
		set_mode("end")


func _on_battle_started(battle: Battle) -> void:
	battle_messages = BattleMessages.new()
	battle_messages.attach(battle, StringName(str(run.pending_battle.get("encounter", ""))), GameplayMessages)
	var service := get_node_or_null("/root/FxManager") as FxService
	if battle_tag_cues != null:
		battle_tag_cues.detach()  # the last battle's watchers and looks go before this battle's start
		battle_tag_cues = null
	if service != null and service.enabled and ResourceLoader.exists(FX_REGISTRY):
		battle_tag_cues = FxTagCues.new()
		battle_tag_cues.attach(battle, (load(FX_REGISTRY) as FxRegistry).all_tag_cues())


func _on_battle_requested(_snapshot: Dictionary) -> void:
	recorder = ActionRecorder.new()
	gate = ViewGate.new()
	_apply_auto()
	battle_prepared.emit(recorder, gate)
	if skip_animations:
		gate.skip_all = true
	await get_tree().process_frame
	await run.fight(recorder, gate)


func _view(scene: PackedScene, file_name: String, missing: PackedStringArray) -> PackedScene:
	if scene != null:
		return scene
	var path := VIEW_DIR + file_name + ".tscn"
	if ResourceLoader.exists(path):
		return load(path)
	missing.append(file_name)
	return null


func _add_view(view: Node, parent: Node) -> void:
	parent.add_child(view)
	if view.has_method("setup"):
		view.setup(self)
