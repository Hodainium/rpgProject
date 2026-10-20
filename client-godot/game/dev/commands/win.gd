## Cheat: ends the run as won (tests the run-end screen).
extends DevCommand


func _init() -> void:
	name = "win"
	usage = "win"
	help = "Ends the run as won."
	cheat = true
	arg_kinds.assign([])


func run(ctx: DevContext, _args: PackedStringArray) -> String:
	if ctx.need_run() != "":
		return ctx.fail(ctx.need_run())
	var error := ctx.run.dev_win()
	return ctx.fail(error) if error != "" else "won"
