## Headless replay entry point (spec "Replay mode (verify)"):
##   godot --headless --path client-godot res://combat/headless/replay_main.tscn -- --in request.json --out result.json
##         [--content-root res://content/]
## Exit code 0 = Verified, 2 = Rejected (2002), 1 = runner error.
extends Node

const DEFAULT_CONTENT_ROOT: String = "res://content/"


func _ready() -> void:
	var args := _parse_args(OS.get_cmdline_user_args())
	if not args.has("in") or not args.has("out"):
		printerr("usage: -- --in <request.json> --out <result.json> [--content-root res://content/]")
		get_tree().quit(ReplayRunner.EXIT_RUNNER_ERROR)
		return
	var runner := ReplayRunner.new()
	var code: int = await runner.run_files(args["in"], args["out"], args.get("content-root", DEFAULT_CONTENT_ROOT), self)
	if runner.runner_error != "":
		printerr("replay runner error: ", runner.runner_error)
	get_tree().quit(code)


static func _parse_args(raw: PackedStringArray) -> Dictionary:
	var args := {}
	var index := 0
	while index < raw.size():
		var key := raw[index]
		if key.begins_with("--") and index + 1 < raw.size():
			args[key.trim_prefix("--")] = raw[index + 1]
			index += 2
		else:
			index += 1
	return args
