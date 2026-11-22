## Cheat (spec event-pass 5): opens any event in the current room, so every event can be played headless
## (`event demo.event.gambler`, then `choose <n>`).
extends DevCommand


func _init() -> void:
	name = "event"
	usage = "event <event id>"
	help = "Opens an event in the current room (a cheat); then pick with choose <n>."
	cheat = true
	arg_kinds.assign(["event"])


func run(ctx: DevContext, args: PackedStringArray) -> String:
	if ctx.need_run() != "":
		return ctx.fail(ctx.need_run())
	var event: EventDefinition = ctx.find("event", args[0] if args.size() > 0 else "")
	if event == null:
		return ctx.fail(ctx.error)
	var error := ctx.run.dev_open_event(event)
	if error != "":
		return ctx.fail(error)
	return "event %s opened in cell %d" % [event.id, ctx.run.state.current_cell]
