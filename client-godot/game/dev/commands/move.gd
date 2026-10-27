## Moves a use item between characters (spec keys-and-gear 2.5): the gear screen's Item Slot MOVE HERE / SWAP.
extends DevCommand


func _init() -> void:
	name = "move"
	usage = "move <item> <to slot> [swap item]"
	help = "Moves use item <item> from its holder to party member <to slot> (a free item slot), or swaps it for [swap item]."
	cheat = false
	arg_kinds.assign(["item", "slot", "item"])


func run(ctx: DevContext, args: PackedStringArray) -> String:
	if ctx.need_run() != "":
		return ctx.fail(ctx.need_run())
	var item: ItemDefinition = ctx.find("item", args[0] if args.size() > 0 else "")
	var to: Variant = ctx.arg_int(args, 1, -1)
	if item == null:
		return ctx.fail(ctx.error)
	if to == null or to < 1:
		return ctx.fail("usage: " + usage)
	var swap: StringName = &""
	if args.size() > 2:
		var other: ItemDefinition = ctx.find("item", args[2])
		if other == null:
			return ctx.fail(ctx.error)
		swap = other.id
	var from := ctx.run.state.holder_of(item.id)
	if from == 0:
		return ctx.fail("nobody holds %s" % item.id)
	var error := ctx.run.move_item(from, item.id, to, swap)
	return ctx.fail(error) if error != "" else "P%d holds %s" % [to, item.id]
