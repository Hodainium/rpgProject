## Cheat (spec keys-and-gear 3.2): puts a chest in the chest inventory.
extends DevCommand


func _init() -> void:
	name = "chest"
	usage = "chest <chest>"
	help = "Puts <chest> (an id or res:// path) in the party's chest inventory; open it with `open`."
	cheat = true
	arg_kinds.assign(["chest"])


func run(ctx: DevContext, args: PackedStringArray) -> String:
	if ctx.need_run() != "":
		return ctx.fail(ctx.need_run())
	var chest: ChestDefinition = ctx.find("chest", args[0] if args.size() > 0 else "") as ChestDefinition
	if chest == null:
		return ctx.fail(ctx.error if ctx.error != "" else "not a chest")
	var error := ctx.run.dev_chest(chest)
	return ctx.fail(error) if error != "" else "chest %d: %s" % [ctx.run.state.chests.size(), chest.id]
