## Prints the run: seed, floor, coins, the party read through GAS, items, open event or battle.
extends DevCommand


func _init() -> void:
	name = "state"
	usage = "state [json]"
	help = "Prints the run state (json: as JSON, like the script runner writes)."
	cheat = false
	arg_kinds.assign(["on_off"])


func run(ctx: DevContext, args: PackedStringArray) -> String:
	if args.size() > 0 and args[0] == "json":
		return JSON.stringify(DevReport.state_of(ctx.run), "  ")
	return DevReport.state_text(ctx.run)
