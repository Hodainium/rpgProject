## Template for a new console command (spec dev-tools 3.2): copy this file, rename it and fill it in. Files starting with "_" are not loaded.
extends DevCommand


func _init() -> void:
	name = "example"
	usage = "example <item> [slot]"
	help = "What it does, in one line."
	cheat = false
	arg_kinds.assign(["item", "slot"])


func run(ctx: DevContext, args: PackedStringArray) -> String:
	if ctx.need_run() != "":
		return ctx.fail(ctx.need_run())
	var item: ItemDefinition = ctx.find("item", args[0] if args.size() > 0 else "")
	if item == null:
		return ctx.fail(ctx.error)
	# A cheat changes the run through RunController (its dev_* methods, or ctx.run.dev_log() first).
	return "did something with %s" % item.id
