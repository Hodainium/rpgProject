## Cheat: removes an item from whoever holds it.
extends DevCommand


func _init() -> void:
	name = "remove"
	usage = "remove <item>"
	help = "Removes <item> from its holder."
	cheat = true
	arg_kinds.assign(["item"])


func run(ctx: DevContext, args: PackedStringArray) -> String:
	if ctx.need_run() != "":
		return ctx.fail(ctx.need_run())
	var item: ItemDefinition = ctx.find("item", args[0] if args.size() > 0 else "")
	if item == null:
		return ctx.fail(ctx.error)
	var error := ctx.run.dev_remove(item)
	return ctx.fail(error) if error != "" else "removed %s" % item.id
