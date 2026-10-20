## Cheat: shows every room on the map.
extends DevCommand


func _init() -> void:
	name = "reveal"
	usage = "reveal"
	help = "Shows the whole map."
	cheat = true
	arg_kinds.assign([])


func run(ctx: DevContext, _args: PackedStringArray) -> String:
	if ctx.need_run() != "":
		return ctx.fail(ctx.need_run())
	var error := ctx.run.dev_reveal()
	return ctx.fail(error) if error != "" else "map revealed"
