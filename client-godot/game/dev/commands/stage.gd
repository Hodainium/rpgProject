## Cheat: jumps to a floor of the run structure (0-based), keeping the party.
extends DevCommand


func _init() -> void:
	name = "stage"
	usage = "stage <floor>"
	help = "Jumps to floor <floor> (0 = the first)."
	cheat = true
	arg_kinds.assign(["int"])


func run(ctx: DevContext, args: PackedStringArray) -> String:
	if ctx.need_run() != "":
		return ctx.fail(ctx.need_run())
	var floor_index: Variant = ctx.arg_int(args, 0, -1)
	if floor_index == null or floor_index < 0:
		return ctx.fail("usage: " + usage)
	var error := ctx.run.dev_stage(floor_index)
	return ctx.fail(error) if error != "" else "floor %d" % floor_index
