## The playable client shell (spec game-skeleton 3.7): owns the content root and the RunController, and hosts the
## UI and the 3D room view. The UI is data (spec ui-framework): a UIPolicy (default
## res://presentation/demo/ui/ui_policy.tres) names the layout, the screens and the panels, and a UIManager shows them
## by UI state; screens get a UIContext instead of this node. The room view, unit view and sound board are your scenes
## with `setup(main: GameMain)` (defaults in res://presentation/demo/).
##
## Holds no game rules: every change goes through RunController. Battles are fought here with an ActionRecorder (the
## battle panel submits the player's picks) and a ViewGate (the room view plays the animations).
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
## A line for the player (run messages, battle calls, refusals); the policy's message panel shows it.
signal message_shown(text: String)

const VIEW_DIR: String = "res://presentation/demo/"
const UI_POLICY: String = "res://presentation/demo/ui/ui_policy.tres"
const SETTINGS_PATH: String = "user://game_main.cfg"
const CONTENT_ROOTS: Array[String] = ["res://content/", "res://tests/fixtures/"]

## Spec ui-framework: every screen and panel, as data. Empty: res://presentation/demo/ui/ui_policy.tres.
@export var ui_policy: UIPolicy
## The 3D room (a Node3D with setup(main)); not UI.
@export var room_view: PackedScene
@export var unit_view: PackedScene
## UI sounds and stingers (a Node with setup(main)); ability and hit sounds come from animations and GameplayCues.
@export var sound_board: PackedScene

var content_root: String = CONTENT_ROOTS[0]
var content: ContentIndex
var run: RunController
var mode: String = "menu"
## The current battle's recorder (the party's input), for the dev console's battle commands.
var recorder: ActionRecorder
## The current battle's presentation gate (a battle panel created after battle_prepared reads it here).
var gate: ViewGate
## Abilities resolve without waiting for their animations (the dev script runner).
var skip_animations: bool = false
## Spec ui-framework: shows the policy's screens; null when the policy failed to load (see the error label).
var ui: UIManager
## The last message shown (a message panel created later reads it).
var last_message: String = ""

var _error_label: Label


func _ready() -> void:
	add_to_group("game_main")
	var settings := ConfigFile.new()
	if settings.load(SETTINGS_PATH) == OK:
		content_root = settings.get_value("game", "content_root", content_root)
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
	set_mode("menu")


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
	# The console's dev stat items (spec dev-tools 3.3), only while cheats are allowed; never in a pool.
	var dev := get_node_or_null("/root/Dev")
	if dev != null and dev.cheats_allowed() and DirAccess.dir_exists_absolute(RunController.DEV_CONTENT):
		content.add_root(RunController.DEV_CONTENT)
	if not content.problems.is_empty():
		show_message("Content problems in %s: %s" % [content_root, "; ".join(content.problems)])
	content_changed.emit(content)


## Starts a run with the chosen characters (ids) and a seed typed as a decimal string. "" or the error.
## `run_id` picks the RunStructure (spec playable-demo 2.2); empty = the only or the default one.
func start_run(character_ids: Array, seed_text: String, run_id: StringName = &"") -> String:
	_new_run()
	var error := run.start_run(content, character_ids, seed_text, run_id)
	if error != "":
		set_mode("end")
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
	run.message.connect(show_message)
	run.battle_requested.connect(_on_battle_requested)
	run.run_ended.connect(func(_status): set_mode("end"))
	show_message("")
	run_changed.emit(run)
	set_mode("run")


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


func back_to_menu() -> void:
	if run != null and run.state != null and run.state.sandbox:
		sandbox_closed.emit()
	set_mode("menu")


func set_mode(new_mode: String) -> void:
	mode = new_mode
	mode_changed.emit(mode)


func show_message(text: String) -> void:
	last_message = text
	message_shown.emit(text)
	if run != null and run.runner_error != "" and mode == "run":
		set_mode("end")


func _on_battle_requested(_snapshot: Dictionary) -> void:
	recorder = ActionRecorder.new()
	gate = ViewGate.new()
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
