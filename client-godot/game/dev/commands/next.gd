## Goes to the next floor after the boss (a play command).
extends DevCommand


func _init() -> void:
	name = "next"
	usage = "next [chapter]"
	help = "Next floor after the boss; [chapter] picks the route where the stairs offer a choice."
	cheat = false
	arg_kinds.assign(["chapter"])


func run(ctx: DevContext, args: PackedStringArray) -> String:
	if ctx.need_run() != "":
		return ctx.fail(ctx.need_run())
	var error := ctx.run.next_floor(StringName(args[0]) if args.size() > 0 else &"")
	return ctx.fail(error) if error != "" else "floor %d" % ctx.run.state.floor_index
