## Spec event-items: gives the item waiting for its holder to the member in <slot>, like clicking them on the Give to
## panel (a play command).
extends DevCommand


func _init() -> void:
	name = "giveto"
	usage = "giveto <slot>"
	help = "Gives the waiting item (from an event or a chest) to party member <slot>."
	cheat = false
	arg_kinds.assign(["slot"])


func run(ctx: DevContext, args: PackedStringArray) -> String:
	if ctx.need_run() != "":
		return ctx.fail(ctx.need_run())
	var gift := ctx.run.pending_gift()
	if gift == null:
		return ctx.fail("nothing is waiting for a holder")
	var slot: Variant = ctx.arg_int(args, 0, -1)
	if slot == null or slot <= 0:
		return ctx.fail("usage: " + usage)
	var error := ctx.run.give_to(slot)
	return ctx.fail(error) if error != "" else "gave %s to slot %d" % [gift.id, slot]
