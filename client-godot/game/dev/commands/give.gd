## Cheat: gives an item to a party member, as if picked up.
extends DevCommand


func _init() -> void:
	name = "give"
	usage = "give <item> [slot]"
	help = "Gives <item> to <slot> (default: the first who can hold it)."
	cheat = true
	arg_kinds.assign(["item", "slot"])


func run(ctx: DevContext, args: PackedStringArray) -> String:
	if ctx.need_run() != "":
		return ctx.fail(ctx.need_run())
	var item: ItemDefinition = ctx.find("item", args[0] if args.size() > 0 else "")
	var slot: Variant = ctx.arg_int(args, 1, 0)
	if item == null or slot == null:
		return ctx.fail(ctx.error if item == null else "usage: " + usage)
	var error := ctx.run.dev_give(item, slot)
	if error != "":
		return ctx.fail(error)
	return "gave %s%s" % [item.id, " (from the next battle on)" if ctx.battle != null else ""]
