## Spec ui-framework 3.1: what every screen gets in bind(ctx): the game, the current run, the UI manager and the UI
## state tags. `on_run` connects a screen to the current run's signals and moves the connection to each new run, so
## screens never rewire themselves when a run starts.
class_name UIContext
extends RefCounted

## The UI state tags changed (UI.State.*).
signal state_changed(tags: Array[StringName])
## A new run exists (before it starts).
signal run_changed(run: RunController)

var main: GameMain
var ui: UIManager
var run: RunController
var state: Array[StringName] = []

var _links: Array = []  # [owner: Node, signal name, callable]


func _init(game_main: GameMain, manager: UIManager) -> void:
	main = game_main
	ui = manager
	run = game_main.run if game_main != null else null


## Connects `callable` to the current run's signal `signal_name`, now and for every later run, until `owner` leaves.
func on_run(owner: Node, signal_name: StringName, callable: Callable) -> void:
	if not _links.any(func(link) -> bool: return link[0] == owner):
		owner.tree_exiting.connect(_forget.bind(owner), CONNECT_ONE_SHOT)
	_links.append([owner, signal_name, callable])
	if run != null and run.has_signal(signal_name):
		run.connect(signal_name, callable)


## True when the state holds `tag` or one of its children (UI.State.Run matches UI.State.Run.Map).
func has_state(tag: StringName) -> bool:
	return TagMatch.has(state, tag)


func _set_run(new_run: RunController) -> void:
	for link in _links:
		if run != null and is_instance_valid(run) and run.is_connected(link[1], link[2]):
			run.disconnect(link[1], link[2])
	run = new_run
	for link in _links:
		if run != null and run.has_signal(link[1]) and not run.is_connected(link[1], link[2]):
			run.connect(link[1], link[2])
	run_changed.emit(run)


func _forget(owner: Node) -> void:
	var kept: Array = []
	for link in _links:
		if link[0] == owner:
			if run != null and is_instance_valid(run) and run.is_connected(link[1], link[2]):
				run.disconnect(link[1], link[2])
		else:
			kept.append(link)
	_links = kept
