## Turns the battle log on or off (spec skill-points): one line per action, triggered passive, skipped turn, Auto pick
## (with its reason) and outcome, printed to the output (the console's log too). Read-only: battles don't change.
extends DevCommand


func _init() -> void:
	name = "battlelog"
	usage = "battlelog [on|off]"
	help = "Prints every battle's actions, triggers and Auto's picks (BattleLog); also RPG_BATTLE_LOG=1 or seed_report --battle-log."
	cheat = false


func run(ctx: DevContext, args: PackedStringArray) -> String:
	if args.size() > 0:
		if args[0] != "on" and args[0] != "off":
			return ctx.fail("usage: " + usage)
		BattleLog.enabled = args[0] == "on"
	return "battle log %s" % ("on" if BattleLog.enabled else "off")
