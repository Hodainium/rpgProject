## Script runner (spec dev-tools 2.6): plays a text file of console commands without a window and writes the final
## state as JSON. One command per line; blank lines and lines starting with # are skipped. Battles run on auto unless
## --manual (then use `act`). Exit 0 ok, 2 when a command failed (the line is named), 1 tool error.
##   godot --headless --path client-godot --quit-after 100000 res://game/tools/dev_run.tscn -- --script run.txt
##     [--out state.json] [--content-root res://content/] [--commands <folder of throwaway commands>] [--manual]
##     [--window --shots <folder>]   (--window: run without --headless so `shot <name>` can capture the screen)
extends Node

const GAME := preload("res://game/game_main.tscn")
## Frames to wait for a battle or field action to settle after a command.
const SETTLE_FRAMES: int = 20000

var console: DevConsole
var game: GameMain


func _ready() -> void:
	var args := OS.get_cmdline_user_args()
	var script_path := _arg(args, "--script", "")
	if script_path == "" or not FileAccess.file_exists(script_path):
		print("dev_run: --script <file> is required (got '%s')" % script_path)
		get_tree().quit(1)
		return
	if _arg(args, "--commands", "") != "":
		_copy_commands(_arg(args, "--commands", ""))
	game = GAME.instantiate()
	game.skip_animations = true
	add_child(game)
	var root := _arg(args, "--content-root", "")
	if root != "":
		game.content_root = root
		game.load_content()
	console = DevConsole.new(get_tree())
	console.keep_history = false
	console.load_commands()
	console.attach(game)
	console.auto_battle = not args.has("--manual")
	if _arg(args, "--shots", "") != "":
		console.shots_dir = _arg(args, "--shots", "")
	for warning in console.warnings:
		print("warning: ", warning)

	var results: Array = []
	var failed_lines := PackedStringArray()
	var number := 0
	for line in FileAccess.get_file_as_string(script_path).split("\n"):
		number += 1
		var text := line.strip_edges()
		if text == "" or text.begins_with("#"):
			continue
		print("> ", text)
		var result: Dictionary = await console.execute(text)
		await _settle()
		print(result["text"])
		results.append({"line": number, "command": text, "ok": result["ok"], "reply": result["text"]})
		if not result["ok"]:
			failed_lines.append("line %d: %s" % [number, text])
	var report := DevReport.state_of(game.run)
	report["commands"] = results
	report["failed"] = Array(failed_lines)
	var out := _arg(args, "--out", "")
	if out != "":
		var file := FileAccess.open(out, FileAccess.WRITE)
		file.store_string(JSON.stringify(report, "  ", false))
		file.close()
	print("dev_run: %d command(s), %d failed%s" % [results.size(), failed_lines.size(),
		("\n  " + "\n  ".join(failed_lines)) if not failed_lines.is_empty() else ""])
	get_tree().quit(2 if not failed_lines.is_empty() else 0)


## Waits until no battle is being fought (auto plays it) or a party member waits for `act`.
func _settle() -> void:
	for frame in SETTLE_FRAMES:
		var run := game.run
		if run == null or run.state == null or run.pending_battle.is_empty():
			return
		if not console.auto_battle and game.recorder != null and game.recorder.waiting_for != &"":
			return
		await get_tree().process_frame


func _copy_commands(folder: String) -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(DevConsole.USER_COMMANDS_DIR))
	for file in DirAccess.get_files_at(folder):
		if file.ends_with(".gd"):
			DirAccess.copy_absolute(folder.path_join(file), ProjectSettings.globalize_path(DevConsole.USER_COMMANDS_DIR.path_join(file)))


static func _arg(args: PackedStringArray, name: String, fallback: String) -> String:
	var at := args.find(name)
	return args[at + 1] if at >= 0 and at + 1 < args.size() else fallback
