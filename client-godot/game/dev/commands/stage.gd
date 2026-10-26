## Cheat: jumps to a floor of the run structure (0-based), keeping the party.
extends DevCommand


func _init() -> void:
	name = "stage"
	usage = "stage <floor> [chapter]"
	help = "Jumps to floor <floor> (0 = the first); [chapter] picks a choice or route floor's chapter."
	cheat = true
	arg_kinds.assign(["int", "chapter"])


func run(ctx: DevContext, args: PackedStringArray) -> String:
	if ctx.need_run() != "":
		return ctx.fail(ctx.need_run())
	var floor_index: Variant = ctx.arg_int(args, 0, -1)
	if floor_index == null or floor_index < 0:
		return ctx.fail("usage: " + usage)
	var error := ctx.run.dev_stage(floor_index, StringName(args[1]) if args.size() > 1 else &"")
	return ctx.fail(error) if error != "" else "floor %d" % floor_index
