## Cheat: permanent stat ups (or downs) as stackable dev stat items, granted through GAS every battle.
extends DevCommand


func _init() -> void:
	name = "stat"
	usage = "stat <attribute> [count] [slot]"
	help = "Adds <count> dev stat items for <attribute> (negative = downs)."
	cheat = true
	arg_kinds.assign(["attribute", "int", "slot"])


func run(ctx: DevContext, args: PackedStringArray) -> String:
	if ctx.need_run() != "":
		return ctx.fail(ctx.need_run())
	var count: Variant = ctx.arg_int(args, 1, 1)
	var slot: Variant = ctx.arg_int(args, 2, 0)
	if args.is_empty() or count == null or slot == null:
		return ctx.fail("usage: %s  (attributes: %s)" % [usage, ", ".join(ctx.console.candidates("attribute"))])
	var error := ctx.run.dev_stat(args[0], count, slot)
	if error != "":
		return ctx.fail("%s  (attributes: %s)" % [error, ", ".join(ctx.console.candidates("attribute"))])
	return "%+d %s%s" % [count, args[0], " (from the next battle on)" if ctx.battle != null else ""]
