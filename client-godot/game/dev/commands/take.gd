## Takes or buys a pickup in the current room (the placement number from map).
extends DevCommand


func _init() -> void:
	name = "take"
	usage = "take <placement> <slot>"
	help = "Takes or buys pickup <placement> for party member <slot> (armor goes to the armor inventory; slot ignored)."
	cheat = false
	arg_kinds.assign(["int", "slot"])


func run(ctx: DevContext, args: PackedStringArray) -> String:
	if ctx.need_run() != "":
		return ctx.fail(ctx.need_run())
	var placement: Variant = ctx.arg_int(args, 0, -1)
	var slot: Variant = ctx.arg_int(args, 1, 1)
	if placement == null or slot == null or placement < 0:
		return ctx.fail("usage: " + usage)
	var error := ctx.run.take(placement, slot)
	return ctx.fail(error) if error != "" else "taken"
