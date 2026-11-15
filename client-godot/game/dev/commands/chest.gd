## Cheat (spec keys-and-gear 3.2, floor-chests 2.1): drops a chest in the current room.
extends DevCommand


func _init() -> void:
	name = "chest"
	usage = "chest <chest>"
	help = "Drops <chest> (an id or res:// path) in the current room; open it with `open <serial>`."
	cheat = true
	arg_kinds.assign(["chest"])


func run(ctx: DevContext, args: PackedStringArray) -> String:
	if ctx.need_run() != "":
		return ctx.fail(ctx.need_run())
	var chest: ChestDefinition = ctx.find("chest", args[0] if args.size() > 0 else "") as ChestDefinition
	if chest == null:
		return ctx.fail(ctx.error if ctx.error != "" else "not a chest")
	var error := ctx.run.dev_chest(chest)
	return ctx.fail(error) if error != "" else "chest %d: %s" % [ctx.run.state.chest_serial - 1, chest.id]
