## Determinism trace on or off (spec atomic-battles): the next battles record the state hash after every action and
## save the trace plus the request to user://traces/, to diff against a replay with trace_main.
extends DevCommand


func _init() -> void:
	name = "trace"
	usage = "trace [on|off]"
	help = "Determinism trace for the next battles (no argument: toggle); files in user://traces/."
	cheat = false
	arg_kinds.assign(["on_off"])


func run(ctx: DevContext, args: PackedStringArray) -> String:
	ctx.console.trace_battles = (args[0] == "on") if args.size() > 0 else not ctx.console.trace_battles
	if not ctx.console.trace_battles:
		return "trace off"
	return "trace on: battles from the next one save %s<battleId>.record.json and .request.json" % ctx.console.traces_dir
