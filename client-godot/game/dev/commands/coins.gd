## Cheat: adds (or removes) coins.
extends DevCommand


func _init() -> void:
	name = "coins"
	usage = "coins <n>"
	help = "Adds <n> coins (negative removes; never below 0)."
	cheat = true
	arg_kinds.assign(["int"])


func run(ctx: DevContext, args: PackedStringArray) -> String:
	if ctx.need_run() != "":
		return ctx.fail(ctx.need_run())
	var amount: Variant = ctx.arg_int(args, 0, 0)
	if args.is_empty() or amount == null:
		return ctx.fail("usage: " + usage)
	var error := ctx.run.dev_coins(amount)
	return ctx.fail(error) if error != "" else "coins: %d" % ctx.run.state.coins
