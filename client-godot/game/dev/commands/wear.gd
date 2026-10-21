## Equips a piece from the armor inventory (spec item-pass 3.5): the party panel's Equip button, headless.
extends DevCommand


func _init() -> void:
	name = "wear"
	usage = "wear <equipment> <slot>"
	help = "Equips <equipment> from the armor inventory on party member <slot> (map only); the piece it replaces goes back."
	cheat = false
	arg_kinds.assign(["equipment", "slot"])


func run(ctx: DevContext, args: PackedStringArray) -> String:
	if ctx.need_run() != "":
		return ctx.fail(ctx.need_run())
	var piece: EquipmentDefinition = ctx.find("equipment", args[0] if args.size() > 0 else "")
	var slot: Variant = ctx.arg_int(args, 1, -1)
	if piece == null:
		return ctx.fail(ctx.error)
	if slot == null or slot < 1:
		return ctx.fail("usage: " + usage)
	var error := ctx.run.equip(slot, piece.id)
	return ctx.fail(error) if error != "" else "P%d wears %s" % [slot, piece.id]
