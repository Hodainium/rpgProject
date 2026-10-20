## Cheat: replaces the floor with a hand-made layout, keeping the party.
extends DevCommand


func _init() -> void:
	name = "layout"
	usage = "layout <layout id or path>"
	help = "Plays a hand-made floor now (keeps the party)."
	cheat = true
	arg_kinds.assign(["layout"])


func run(ctx: DevContext, args: PackedStringArray) -> String:
	if ctx.need_run() != "":
		return ctx.fail(ctx.need_run())
	var layout: FloorLayout = ctx.find("layout", args[0] if args.size() > 0 else "")
	if layout == null:
		return ctx.fail(ctx.error)
	var request := SandboxRequest.new()
	request.layout = layout
	request.seed = ctx.run.state.run_seed
	request.depth = ctx.run.state.floor_index
	var error := ctx.run.dev_sandbox(request)
	return ctx.fail(error) if error != "" else "layout %s" % layout.id
