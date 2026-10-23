## Determinism trace tool (spec atomic-battles 2.C). Tests and dev only; the verifier never runs it.
##   Trace: godot --headless --path client-godot res://combat/headless/trace_main.tscn -- --in request.json
##          --out trace.json [--lines] [--content-root res://content/]
##          Replays like replay_main with a BattleTrace attached and writes the trace file. Exit codes as replay_main:
##          0 Verified, 2 Rejected (2002), 1 runner error (the trace is still written when the request could be read).
##   Diff:  ... trace_main.tscn -- --diff a.trace.json b.trace.json
##          Prints the first divergent point. Exit 0 the traces match, 3 they diverge, 1 bad input.
extends Node

const EXIT_DIVERGED: int = 3
const ReplayMain := preload("res://combat/headless/replay_main.gd")


func _ready() -> void:
	var raw := OS.get_cmdline_user_args()
	var diff_at := raw.find("--diff")
	if diff_at >= 0:
		get_tree().quit(_diff(raw, diff_at))
		return
	var lines := raw.has("--lines")
	var rest := PackedStringArray()
	for arg in raw:
		if arg != "--lines":  # a flag without a value; the key/value parser would pair it with the next argument
			rest.append(arg)
	var args := ReplayMain._parse_args(rest)
	if not args.has("in") or not args.has("out"):
		printerr("usage: -- --in <request.json> --out <trace.json> [--lines] [--content-root res://content/]  |  -- --diff <a> <b>")
		get_tree().quit(ReplayRunner.EXIT_RUNNER_ERROR)
		return
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(args["in"]))
	if not parsed is Dictionary:
		printerr("trace_main: could not read a JSON object from ", args["in"])
		get_tree().quit(ReplayRunner.EXIT_RUNNER_ERROR)
		return
	var runner := ReplayRunner.new()
	runner.trace = BattleTrace.new(lines)
	await runner.run(parsed, args.get("content-root", ReplayMain.DEFAULT_CONTENT_ROOT), self)
	if runner.runner_error != "":
		printerr("replay runner error: ", runner.runner_error)
	var file := FileAccess.open(args["out"], FileAccess.WRITE)
	if file == null:
		printerr("trace_main: cannot write ", args["out"])
		get_tree().quit(ReplayRunner.EXIT_RUNNER_ERROR)
		return
	file.store_string(WireJson.stringify(runner.trace.to_json()))
	file.close()
	get_tree().quit(runner.exit_code)


func _diff(raw: PackedStringArray, at: int) -> int:
	if at + 2 >= raw.size():
		printerr("usage: -- --diff <a.trace.json> <b.trace.json>")
		return ReplayRunner.EXIT_RUNNER_ERROR
	var traces: Array[Dictionary] = []
	for path in [raw[at + 1], raw[at + 2]]:
		var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
		if not parsed is Dictionary:
			printerr("trace_main: could not read a trace from ", path)
			return ReplayRunner.EXIT_RUNNER_ERROR
		traces.append(parsed)
	var divergence := BattleTrace.diff(traces[0], traces[1])
	print(BattleTrace.describe(divergence))
	return 0 if divergence.is_empty() else EXIT_DIVERGED
