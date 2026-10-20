## Enters a room on the map, like clicking it (a play command).
extends DevCommand


func _init() -> void:
	name = "enter"
	usage = "enter <cell index>"
	help = "Enters a room (the index from map)."
	cheat = false
	arg_kinds.assign(["int"])


func run(ctx: DevContext, args: PackedStringArray) -> String:
	if ctx.need_run() != "":
		return ctx.fail(ctx.need_run())
	var index: Variant = ctx.arg_int(args, 0, -1)
	if index == null or index < 0:
		return ctx.fail("usage: " + usage)
	var error := ctx.run.enter_room(index)
	return ctx.fail(error) if error != "" else "entered %d" % index
