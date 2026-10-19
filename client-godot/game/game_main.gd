## The playable client shell (spec game-skeleton 3.7): owns the content root and the RunController, and hosts the
## screens. The screens are your scenes (defaults in res://presentation/demo/); each one's root script has
## `setup(main: GameMain)` and wires itself to the signals below and to `main.run`'s signals.
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

const VIEW_DIR: String = "res://presentation/demo/"
const SETTINGS_PATH: String = "user://game_main.cfg"
const CONTENT_ROOTS: Array[String] = ["res://content/", "res://tests/fixtures/"]

@export var menu_view: PackedScene
@export var map_view: PackedScene
@export var room_view: PackedScene
@export var unit_view: PackedScene
@export var battle_panel: PackedScene
@export var event_panel: PackedScene
@export var pickup_panel: PackedScene
@export var party_panel: PackedScene
@export var run_end_view: PackedScene

var content_root: String = CONTENT_ROOTS[0]
var content: ContentIndex
var run: RunController
var mode: String = "menu"

var _message: Label


func _ready() -> void:
	var settings := ConfigFile.new()
	if settings.load(SETTINGS_PATH) == OK:
		content_root = settings.get_value("game", "content_root", content_root)
	var world := Node3D.new()
	world.name = "World"
	add_child(world)
	var ui := CanvasLayer.new()
	ui.name = "UI"
	add_child(ui)
	var missing := PackedStringArray()
	unit_view = _view(unit_view, "unit_view", missing)
	var room := _view(room_view, "room_view_3d", missing)
	if room != null:
		_add_view(room.instantiate(), world)
	for pair in [[menu_view, "menu"], [map_view, "map_view"], [battle_panel, "battle_panel"], [event_panel, "event_panel"],
			[pickup_panel, "pickup_panel"], [party_panel, "party_panel"], [run_end_view, "run_end_view"]]:
		var scene := _view(pair[0], pair[1], missing)
		if scene != null:
			_add_view(scene.instantiate(), ui)
	_message = Label.new()
	_message.name = "Message"
	_message.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_WIDE)
	_message.offset_top = -28
	_message.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	ui.add_child(_message)
	if not missing.is_empty():
		show_message("Missing screens: %s. Run res://game/tools/build_demo.tscn once, or set them on GameMain."
			% ", ".join(missing))
	load_content()
	set_mode("menu")


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
	if not content.problems.is_empty():
		show_message("Content problems in %s: %s" % [content_root, "; ".join(content.problems)])
	content_changed.emit(content)


## Starts a run with the chosen characters (ids) and a seed typed as a decimal string. "" or the error.
func start_run(character_ids: Array, seed_text: String) -> String:
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
	var error := run.start_run(content, character_ids, seed_text)
	if error != "":
		set_mode("end")
	return error


func back_to_menu() -> void:
	set_mode("menu")


func set_mode(new_mode: String) -> void:
	mode = new_mode
	mode_changed.emit(mode)


func show_message(text: String) -> void:
	if _message != null:
		_message.text = text
	if run != null and run.runner_error != "" and mode == "run":
		set_mode("end")


func _on_battle_requested(_snapshot: Dictionary) -> void:
	var recorder := ActionRecorder.new()
	var gate := ViewGate.new()
	battle_prepared.emit(recorder, gate)
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
