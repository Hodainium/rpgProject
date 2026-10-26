## Shows the run's seed (and copies it), or starts a new run with the same party and another seed.
extends DevCommand


func _init() -> void:
	name = "seed"
	usage = "seed [seed]"
	help = "No argument: shows and copies the seed. With one: a new run, same party, that seed."
	cheat = false
	arg_kinds.assign(["seed"])


func run(ctx: DevContext, args: PackedStringArray) -> String:
	if ctx.run == null:
		return ctx.fail("no run")
	if args.is_empty():
		var shown := RunSeeds.display(ctx.run.state.run_seed)
		if DisplayServer.get_name() != "headless":
			DisplayServer.clipboard_set(shown)
		return "seed %s (%d)" % [shown, ctx.run.state.run_seed]
	var seed_text := " ".join(args)  # a code may be typed with its space
	if RunSeeds.parse(seed_text) < 0:
		return ctx.fail("not a seed: %s" % seed_text)
	var error := ctx.game.start_run(ctx.run.state.party_characters(), seed_text, ctx.run.state.run_structure_id)
	return ctx.fail(error) if error != "" else "new run, seed %s" % RunSeeds.display(RunSeeds.parse(seed_text))
