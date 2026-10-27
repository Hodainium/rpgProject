## Swaps a worn piece between two characters (spec keys-and-gear 2.4): the gear screen's SWAP, headless.
extends DevCommand


func _init() -> void:
	name = "swap"
	usage = "swap <equipment> <slot>"
	help = "Puts <equipment>, worn by another member, on party member <slot>; that member gets <slot>'s piece back."
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
	var error := ctx.run.swap_gear(slot, piece.id)
	return ctx.fail(error) if error != "" else "P%d wears %s" % [slot, piece.id]
