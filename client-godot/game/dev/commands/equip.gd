## Cheat: gives a piece of equipment to a party member.
extends DevCommand


func _init() -> void:
	name = "equip"
	usage = "equip <equipment> [slot]"
	help = "Equips <equipment> on <slot> (default: slot 1)."
	cheat = true
	arg_kinds.assign(["equipment", "slot"])


func run(ctx: DevContext, args: PackedStringArray) -> String:
	if ctx.need_run() != "":
		return ctx.fail(ctx.need_run())
	var piece: EquipmentDefinition = ctx.find("equipment", args[0] if args.size() > 0 else "")
	var slot: Variant = ctx.arg_int(args, 1, 0)
	if piece == null or slot == null:
		return ctx.fail(ctx.error if piece == null else "usage: " + usage)
	var error := ctx.run.dev_equip(piece, slot)
	return ctx.fail(error) if error != "" else "equipped %s" % piece.id
