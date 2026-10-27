## Cheat (spec keys-and-gear 3.2): adds (or removes) keys.
extends DevCommand


func _init() -> void:
	name = "keys"
	usage = "keys <n>"
	help = "Adds <n> keys (negative removes; kept within 0-99)."
	cheat = true
	arg_kinds.assign(["int"])


func run(ctx: DevContext, args: PackedStringArray) -> String:
	if ctx.need_run() != "":
		return ctx.fail(ctx.need_run())
	var amount: Variant = ctx.arg_int(args, 0, 0)
	if args.is_empty() or amount == null:
		return ctx.fail("usage: " + usage)
	var error := ctx.run.dev_keys(amount)
	return ctx.fail(error) if error != "" else "keys: %d" % ctx.run.state.keys
