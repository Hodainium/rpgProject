## Goes to the next floor after the boss (a play command).
extends DevCommand


func _init() -> void:
	name = "next"
	usage = "next"
	help = "Next floor after the boss."
	cheat = false
	arg_kinds.assign([])


func run(ctx: DevContext, _args: PackedStringArray) -> String:
	if ctx.need_run() != "":
		return ctx.fail(ctx.need_run())
	var error := ctx.run.next_floor()
	return ctx.fail(error) if error != "" else "floor %d" % ctx.run.state.floor_index
