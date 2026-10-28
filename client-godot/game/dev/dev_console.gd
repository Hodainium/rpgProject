## The console's brain (spec dev-tools 3.2): the command registry, line parsing, autocomplete, history, the open room
## grids and auto battles. No UI: the Dev autoload draws it, the script runner (game/tools/dev_run.tscn) and tests
## drive it directly.
class_name DevConsole
extends RefCounted

## Spec gameplay-messages 2.4: one line of the message log (`messages on`), for the overlay.
signal message_logged(line: String)

const COMMANDS_DIR: String = "res://game/dev/commands/"
## Throwaway commands (debug builds only); they can't replace a built-in name.
const USER_COMMANDS_DIR: String = "user://dev_commands/"
const HISTORY_PATH: String = "user://dev_console_history.txt"
const HISTORY_SIZE: int = 50
## Lines `messages` keeps (the oldest go first).
const MESSAGE_LOG_SIZE: int = 1000

## name -> DevCommand
var commands: Dictionary = {}
var warnings := PackedStringArray()
var history := PackedStringArray()
## False while connected to a server (slice 2): cheat commands are refused.
var cheats_allowed: bool = true
## Battles pick party actions on their own (first usable ability, first valid target).
var auto_battle: bool = false
## Rooms opened with `grid`: target (id or path) -> the edited copy (saved with `grid <room> save`).
var grid_rooms: Dictionary = {}
## Lines are saved to HISTORY_PATH (off for the script runner and tests).
var keep_history: bool = true
## Where `shot` saves screenshots.
var shots_dir: String = "user://shots/"
## Spec atomic-battles: `trace on` attaches a determinism trace (with lines) to the next battles and writes
## <battleId>.record.json and <battleId>.request.json here when each ends.
var trace_battles: bool = false
var traces_dir: String = "user://traces/"
## Spec gameplay-messages 2.4: the channel `messages on` logs (with its children); &"" while off.
var message_channel: StringName = &""
## "[msg] <channel> <describe()>" lines, oldest first (the script runner writes them to its JSON as "messages").
var message_log: Array[String] = []
var _message_handle: GameplayMessageHandle
var tree: SceneTree
var _attached: Array[GameMain] = []


func _init(scene_tree: SceneTree = null) -> void:
	tree = scene_tree


## Loads every DevCommand file: built-in ones, then (debug builds) throwaway ones.
func load_commands(debug_build: bool = OS.is_debug_build()) -> void:
	commands.clear()
	warnings.clear()
	_load_dir(COMMANDS_DIR, false)
	if debug_build:
		_load_dir(USER_COMMANDS_DIR, true)


func _load_dir(directory: String, throwaway: bool) -> void:
	if not DirAccess.dir_exists_absolute(directory):
		return
	var files := Array(DirAccess.get_files_at(directory))
	files.sort()
	for file in files:
		var file_name: String = file.trim_suffix(".remap")
		if not file_name.ends_with(".gd") or file_name.begins_with("_"):
			continue
		var path := directory.path_join(file_name)
		var script: GDScript = load(path) if throwaway == false else ResourceLoader.load(path, "", ResourceLoader.CACHE_MODE_IGNORE)
		var command: Variant = script.new() if script != null and script.can_instantiate() else null
		if not command is DevCommand:
			warnings.append("%s is not a DevCommand (does it compile? extends DevCommand?)" % path)
			continue
		if command.name == "" or commands.has(command.name):
			warnings.append("%s: the name '%s' is empty or already used by %s" % [path, command.name,
				commands[command.name].get_script().resource_path if commands.has(command.name) else "-"])
			continue
		commands[command.name] = command


func sorted_names() -> Array:
	var names := commands.keys()
	names.sort()
	return names


## Runs one line. {"ok": bool, "text": String}. Awaits commands that take time (battles, field actions).
func execute(line: String) -> Dictionary:
	var tokens := tokenize(line)
	if tokens.is_empty():
		return {"ok": true, "text": ""}
	_remember(line)
	var command: DevCommand = commands.get(tokens[0].to_lower())
	if command == null:
		return {"ok": false, "text": "unknown command '%s'%s; try help" % [tokens[0], closest(commands.keys(), tokens[0])]}
	if command.cheat and not cheats_allowed:
		return {"ok": false, "text": "cheats are off while connected to the server"}
	var game := find_game()
	if game != null:
		attach(game)
	var ctx := DevContext.new(self, game)
	if command.cheat and ctx.run != null and ctx.run.state != null and ctx.run.state.seeds().server_mode():
		return {"ok": false, "text": "cheats are off while connected to the server"}  # spec server-authority 0
	var text: Variant = await command.run(ctx, tokens.slice(1))
	return {"ok": not ctx.failed, "text": str(text) if text != null else ""}


## Splits on spaces; "quoted text" stays one argument.
static func tokenize(line: String) -> PackedStringArray:
	var tokens := PackedStringArray()
	var current := ""
	var quoted := false
	for character in line.strip_edges():
		if character == "\"":
			quoted = not quoted
		elif character == " " and not quoted:
			if current != "":
				tokens.append(current)
			current = ""
		else:
			current += character
	if current != "":
		tokens.append(current)
	return tokens


## Completions for the line as typed: whole lines, sorted. One → Tab fills it in; several → listed and cycled.
func complete(line: String) -> Array[String]:
	var tokens := tokenize(line)
	var ends_with_space := line.ends_with(" ")
	var result: Array[String] = []
	if tokens.is_empty() or (tokens.size() == 1 and not ends_with_space):
		var prefix := tokens[0].to_lower() if not tokens.is_empty() else ""
		for name in sorted_names():
			if name.begins_with(prefix):
				result.append(name + " ")
		return result
	var command: DevCommand = commands.get(tokens[0].to_lower())
	if command == null:
		return result
	var position := tokens.size() - 1 if not ends_with_space else tokens.size()
	var prefix := "" if ends_with_space else tokens[tokens.size() - 1]
	var kind: String = command.arg_kinds[position - 1] if position - 1 < command.arg_kinds.size() else ""
	var head := " ".join(tokens.slice(0, position)) + " "
	for candidate in candidates(kind):
		if candidate.begins_with(prefix):
			result.append(head + candidate)
	return result


## Possible values for an argument kind, sorted.
func candidates(kind: String) -> Array[String]:
	var values: Array[String] = []
	var ctx := DevContext.new(self, find_game())
	match kind:
		"command":
			values.assign(sorted_names())
		"slot":
			if ctx.run != null:
				for member in ctx.run.state.party:
					values.append(str(member["slot"]))
		"attribute":
			for id in ctx.table_of("item"):
				if String(id).begins_with("dev.up."):
					values.append(String(id).trim_prefix("dev.up."))
		"play_kind":
			values.assign(PlayRequest.KINDS)
		"type":
			values.assign(ContentTemplates.TYPES.keys())
		"grid_op":
			values.assign(["paint", "erase", "door", "show", "save"])
		"place":
			values.assign(RoomGridOps.KINDS.keys())
		"side":
			values.assign(["n", "e", "s", "w"])
		"target":
			values.assign(["enemies", "party", "1", "2", "3", "4"])
		"on_off":
			values.assign(["on", "off"])
		"messages_op":
			values.assign(["on", "off", "last"])
		"channel":
			for channel in GameplayMessageRouter.CHANNELS:
				var parts := String(channel).split(".")
				for depth in range(1, parts.size() + 1):
					var name := ".".join(parts.slice(0, depth))
					if not values.has(name):
						values.append(name)
		"ability":
			if ctx.battle != null and ctx.recorder != null and ctx.recorder.waiting_for != &"":
				for ability in ctx.battle.unit_by_id(ctx.recorder.waiting_for).action_abilities():
					values.append(String(ability.ability_tag))
		"ult":
			if ctx.battle != null:
				for unit in ctx.battle.units():
					if unit.is_party():
						for ability in unit.ultimate_abilities():
							if not values.has(String(ability.ability_tag)):
								values.append(String(ability.ability_tag))
		_:
			for id in ctx.table_of(kind):
				values.append(String(id))
	values.sort()
	return values


## " (did you mean: a, b, c?)" for the ids closest to `typed`, or "".
static func closest(ids: Array, typed: String) -> String:
	var scored: Array = []
	for id in ids:
		var text := String(id)
		var score := text.similarity(typed)
		if text.contains(typed) or typed.contains(text.get_slice(".", text.get_slice_count(".") - 1)):
			score += 1.0
		scored.append([score, text])
	scored.sort_custom(func(a, b) -> bool: return a[0] > b[0] or (a[0] == b[0] and a[1] < b[1]))
	var best: Array = []
	for entry in scored.slice(0, 3):
		if entry[0] > 0.3:
			best.append(entry[1])
	return " (did you mean: %s?)" % ", ".join(best) if not best.is_empty() else ""


## Logs every message on `channel` and its children (spec gameplay-messages 2.4); &"" stops. Prints each line.
func log_messages(channel: StringName) -> void:
	if _message_handle != null:
		_message_handle.unregister()
		_message_handle = null
	message_channel = channel
	if channel != &"":
		_message_handle = GameplayMessages.listen(channel, _on_message, GameplayMessageRouter.Match.PARTIAL)


func _on_message(channel: StringName, message: GameplayMessage) -> void:
	var line := "[msg] %s %s" % [channel, message.describe()]
	message_log.append(line)
	if message_log.size() > MESSAGE_LOG_SIZE:
		message_log = message_log.slice(message_log.size() - MESSAGE_LOG_SIZE)
	print(line)
	message_logged.emit(line)


func find_game() -> GameMain:
	return tree.get_first_node_in_group("game_main") as GameMain if tree != null else null


## Listens to a GameMain's battles (auto battles). Safe to call again.
func attach(game: GameMain) -> void:
	if _attached.has(game):
		return
	_attached.append(game)
	game.battle_prepared.connect(_on_battle_prepared.bind(game))


func _on_battle_prepared(recorder: ActionRecorder, _gate: ViewGate, game: GameMain) -> void:
	recorder.action_requested.connect(_on_action_requested.bind(game, recorder))
	if trace_battles and game.run != null:
		game.run.battle_started.connect(_trace_battle.bind(game.run, recorder), CONNECT_ONE_SHOT)


## Attaches a trace before the battle runs; when it ends, writes the client's trace and the request to replay it.
func _trace_battle(battle: Battle, run: RunController, recorder: ActionRecorder) -> void:
	var trace := BattleTrace.new(true)
	battle.trace = trace
	var snapshot := run.battle_snapshot()
	battle.battle_ended.connect(func(outcome: String, final_hash: String) -> void:
		var request := {"snapshot": snapshot, "actionLog": ActionRecorder.build_log(recorder.entries, outcome, final_hash)}
		var base := traces_dir.path_join(battle.battle_id.replace("/", "_"))
		DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(traces_dir))
		_store(base + ".record.json", WireJson.stringify(trace.to_json()))
		_store(base + ".request.json", WireJson.stringify(request)), CONNECT_ONE_SHOT)


static func _store(path: String, text: String) -> void:
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file != null:
		file.store_string(text)
		file.close()


func _on_action_requested(unit_id: StringName, _turn: int, game: GameMain, recorder: ActionRecorder) -> void:
	if auto_battle:
		_auto_pick.call_deferred(game, recorder, unit_id)


## The first usable ability on the first valid target (the battle panel's Auto rule). Before that, every member's ult
## that can fire is pressed (spec ult-interrupts: it fires at once, in this DECISION window, and the member is asked again).
func _auto_pick(game: GameMain, recorder: ActionRecorder, unit_id: StringName) -> void:
	if not auto_battle or recorder.waiting_for != unit_id or game.run == null:
		return
	var battle := game.run.get_node_or_null("RunBattle") as Battle
	var unit := battle.unit_by_id(unit_id) if battle != null else null
	if unit == null:
		return
	if DevConsole.press_ready_ults(battle, recorder):
		return
	for ability in unit.action_abilities():
		if not unit.asc.can_activate_ability(ability):
			continue
		var target: StringName = &""
		if ability.needs_target():
			var targets := battle.target_candidates(unit, ability)
			if targets.is_empty():
				continue
			target = targets[0].unit_id
		recorder.submit_action(ability.ability_tag, target)
		return


## Presses the first ult that can fire for each living party member (Auto rule). True when one was pressed.
static func press_ready_ults(battle: Battle, recorder: ActionRecorder) -> bool:
	var pressed := false
	for unit in battle.units():
		if not unit.is_party() or not unit.alive:
			continue
		for ability in unit.ultimate_abilities():
			if not unit.asc.can_activate_ability(ability):
				continue
			var target: StringName = &""
			if ability.needs_target():
				var targets := battle.target_candidates(unit, ability)
				if targets.is_empty():
					continue
				target = targets[0].unit_id
			recorder.submit_ult(unit.unit_id, ability.ability_tag, target)
			pressed = true
			break
	return pressed


func load_history() -> void:
	history.clear()
	if FileAccess.file_exists(HISTORY_PATH):
		history = FileAccess.get_file_as_string(HISTORY_PATH).split("\n", false)


func _remember(line: String) -> void:
	if not history.is_empty() and history[history.size() - 1] == line:
		return
	history.append(line)
	if history.size() > HISTORY_SIZE:
		history = history.slice(history.size() - HISTORY_SIZE)
	if not keep_history:
		return
	var file := FileAccess.open(HISTORY_PATH, FileAccess.WRITE)
	if file != null:
		file.store_string("\n".join(history))
