## Starts a run like the menu does (a play command: the run stays clean).
extends DevCommand


func _init() -> void:
	name = "new"
	usage = "new <character,character,...> [seed] [run=<id>]"
	help = "Starts a run with 1-4 characters (ids, comma separated), a seed (number or code; default 1) and the run (default: the only or default one)."
	cheat = false
	arg_kinds.assign(["character", "seed"])


func run(ctx: DevContext, args: PackedStringArray) -> String:
	if ctx.game == null:
		return ctx.fail("no game scene")
	if args.is_empty():
		return ctx.fail("usage: " + usage)
	var party: Array = []
	for id in args[0].split(",", false):
		party.append(id.strip_edges())
	var rest := args.slice(1)
	var run_id: StringName = &""
	if not rest.is_empty() and rest[rest.size() - 1].begins_with("run="):
		run_id = StringName(rest[rest.size() - 1].trim_prefix("run="))
		rest = rest.slice(0, rest.size() - 1)
	var seed_text := " ".join(rest) if not rest.is_empty() else "1"  # a code may be typed with its space
	var error := ctx.game.start_run(party, seed_text, run_id)
	if error != "":
		return ctx.fail(error)
	if ctx.game.server != null:
		return "starting on the server (the seed is the server's; follow with `wait run`)"  # spec dev-tools E3
	return "run started, seed %s" % RunSeeds.display(RunSeeds.parse(seed_text))
