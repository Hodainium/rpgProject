## Turns auto battles on or off: the first usable ability on the first valid target, like the battle panel.
extends DevCommand


func _init() -> void:
	name = "auto"
	usage = "auto [on|off]"
	help = "Auto battles on/off (no argument: toggle)."
	cheat = false
	arg_kinds.assign(["on_off"])


func run(ctx: DevContext, args: PackedStringArray) -> String:
	ctx.console.auto_battle = (args[0] == "on") if args.size() > 0 else not ctx.console.auto_battle
	if ctx.console.auto_battle and ctx.recorder != null and ctx.recorder.waiting_for != &"":
		ctx.console._auto_pick(ctx.game, ctx.recorder, ctx.recorder.waiting_for)
	return "auto battles " + ("on" if ctx.console.auto_battle else "off")
