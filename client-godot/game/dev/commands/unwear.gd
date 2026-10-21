## Takes a piece off and puts it in the armor inventory (spec item-pass 3.5): the party panel's Unequip button, headless.
extends DevCommand


func _init() -> void:
	name = "unwear"
	usage = "unwear <slot> <equipment slot tag>"
	help = "Takes off what party member <slot> wears in <equipment slot tag> (e.g. Equipment.Slot.Head); map only."
	cheat = false
	arg_kinds.assign(["slot", "text"])


func run(ctx: DevContext, args: PackedStringArray) -> String:
	if ctx.need_run() != "":
		return ctx.fail(ctx.need_run())
	var slot: Variant = ctx.arg_int(args, 0, -1)
	if slot == null or slot < 1 or args.size() < 2:
		return ctx.fail("usage: " + usage)
	var error := ctx.run.unequip(slot, StringName(args[1]))
	return ctx.fail(error) if error != "" else "P%d took off %s" % [slot, args[1]]
