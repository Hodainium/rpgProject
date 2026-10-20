## Starts a run like the menu does (a play command: the run stays clean).
extends DevCommand


func _init() -> void:
	name = "new"
	usage = "new <character,character,...> [seed]"
	help = "Starts a run with 1-4 characters (ids, comma separated) and a seed (number or code; default 1)."
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
	var seed_text := " ".join(args.slice(1)) if args.size() > 1 else "1"  # a code may be typed with its space
	var error := ctx.game.start_run(party, seed_text)
	return ctx.fail(error) if error != "" else "run started, seed %s" % RunSeeds.display(RunSeeds.parse(seed_text))
