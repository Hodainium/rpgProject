## Picks an event choice (0-based), like clicking it.
extends DevCommand


func _init() -> void:
	name = "choose"
	usage = "choose <choice>"
	help = "Picks event choice <choice> (0 = the first)."
	cheat = false
	arg_kinds.assign(["int"])


func run(ctx: DevContext, args: PackedStringArray) -> String:
	if ctx.need_run() != "":
		return ctx.fail(ctx.need_run())
	var index: Variant = ctx.arg_int(args, 0, -1)
	if index == null or index < 0:
		return ctx.fail("usage: " + usage)
	var error := ctx.run.choose(index)
	return ctx.fail(error) if error != "" else "chose %d" % index
