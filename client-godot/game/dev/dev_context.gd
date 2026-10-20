## What a console command can reach (spec dev-tools 3.2), plus argument helpers that return a value or set a ready-made
## error reply.
class_name DevContext
extends RefCounted

var console: DevConsole
## The running GameMain (first node in group "game_main"), or null.
var game: GameMain
## The current run, or null.
var run: RunController
## The run's content index (with any sandbox overlay), else the game's.
var content: ContentIndex
## The battle being fought, or null.
var battle: Battle
## Its recorder (the party's input), or null.
var recorder: ActionRecorder
## Set by fail(): the command did not do what was asked (the script runner exits 2).
var failed: bool = false
## Why find() returned null.
var error: String = ""


func _init(owner: DevConsole, game_main: GameMain) -> void:
	console = owner
	game = game_main
	if game == null:
		return
	run = game.run if is_instance_valid(game.run) and game.run.state != null else null
	content = run.content if run != null else game.content
	recorder = game.recorder
	if run != null and not run.pending_battle.is_empty():
		battle = run.get_node_or_null("RunBattle") as Battle


## Marks the command failed and returns the message as the reply.
func fail(message: String) -> String:
	failed = true
	return message


## "" when a run is active, else why not (use as `if ctx.need_run(): return ctx.fail(ctx.need_run())`).
func need_run() -> String:
	if game == null:
		return "no game scene (open the game first)"
	if run == null:
		return "no run (start one with: new <character ids> [seed])"
	if run.state.status != RunState.ACTIVE:
		return "the run has ended (%s)" % run.state.status
	return ""


## Argument `index` as an int, `fallback` when missing; null when it isn't a whole number.
func arg_int(args: PackedStringArray, index: int, fallback: int) -> Variant:
	if index >= args.size():
		return fallback
	return args[index].to_int() if args[index].is_valid_int() else null


## A content resource by id (or by res:// / user:// path), or null; `error` then holds the reply with close ids.
func find(kind: String, id: String) -> Resource:
	error = ""
	if id == "":
		error = "which %s?" % kind
		return null
	if id.begins_with("res://") or id.begins_with("user://"):
		var loaded: Resource = load(id) if ResourceLoader.exists(id) else null
		if loaded == null:
			error = "no file %s" % id
		return loaded
	var table := table_of(kind)
	var found: Resource = table.get(StringName(id))
	if found == null:
		error = "no %s '%s'%s" % [kind, id, console.closest(table.keys(), id)]
	return found


## The content table for a kind (item, equipment, encounter, event, room, layout, character, unit, chapter).
func table_of(kind: String) -> Dictionary:
	if content == null:
		return {}
	match kind:
		"item":
			return content.items
		"equipment":
			return content.equipment
		"encounter":
			return content.encounters
		"event":
			return content.events
		"room":
			return content.rooms
		"layout":
			return content.layouts
		"character":
			return content.characters
		"unit", "enemy":
			return content.units
		"chapter":
			return content.chapters
	return {}
