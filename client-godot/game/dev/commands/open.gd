## Opens a chest in the current room (spec floor-chests 2.2): the pickup panel's OPEN, headless.
extends DevCommand


func _init() -> void:
	name = "open"
	usage = "open <serial>"
	help = "Opens this room's chest <serial> (from `chests`); a Gilded Chest spends a key. Its items and armor land beside it (`take`)."
	cheat = false
	arg_kinds.assign(["int"])


func run(ctx: DevContext, args: PackedStringArray) -> String:
	if ctx.need_run() != "":
		return ctx.fail(ctx.need_run())
	var serial: Variant = ctx.arg_int(args, 0, -1)
	if serial == null or serial < 0:
		return ctx.fail("usage: " + usage)
	var error := ctx.run.open_chest(serial)
	if error != "":
		return ctx.fail(error)
	var placements := PackedStringArray()
	for pickup in ctx.run.chest_pickups(ctx.run.state.current_cell, serial):
		placements.append("%d %s" % [pickup["placement"], pickup["item"]])
	return "opened chest %d · keys %d%s" % [serial, ctx.run.state.keys,
		" · beside it: " + ", ".join(placements) if not placements.is_empty() else ""]
