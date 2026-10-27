## Opens a chest from the chest inventory (spec keys-and-gear 2.3): the Use Item screen's OPEN, headless.
extends DevCommand


func _init() -> void:
	name = "open"
	usage = "open <number>"
	help = "Opens chest <number> (from `chests`) on the map; a Gilded Chest spends a key."
	cheat = false
	arg_kinds.assign(["int"])


func run(ctx: DevContext, args: PackedStringArray) -> String:
	if ctx.need_run() != "":
		return ctx.fail(ctx.need_run())
	var number: Variant = ctx.arg_int(args, 0, 1)
	if number == null:
		return ctx.fail("usage: " + usage)
	var error := ctx.run.open_chest(number - 1)
	return ctx.fail(error) if error != "" else "opened chest %d · keys %d" % [number, ctx.run.state.keys]
