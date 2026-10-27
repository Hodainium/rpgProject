## Spec auto-battle: the player's Auto (the battle panel's button): the smart AutoPolicy plays the party for the rest of
## the run. `ults=off` keeps ults for manual presses. Turning it on also stops the console's own first-legal auto
## battles (the script runner's default), so the smart policy drives; `off` stops both.
extends DevCommand


func _init() -> void:
	name = "auto"
	usage = "auto [on|off] [ults=on|off]"
	help = "Auto battles on/off (no argument: toggle); ults=off holds ults for manual presses."
	cheat = false
	arg_kinds.assign(["on_off"])


func run(ctx: DevContext, args: PackedStringArray) -> String:
	if ctx.game == null:
		return ctx.fail("no game")
	var on := not ctx.game.auto_battle
	for arg in args:
		if arg in ["on", "off"]:
			on = arg == "on"
		elif arg in ["ults=on", "ults=off"]:
			ctx.game.auto_ults = arg == "ults=on"
		else:
			return ctx.fail("usage: " + usage)
	ctx.console.auto_battle = false
	ctx.game.auto_battle = on
	return "auto battles %s (ults %s)" % ["on" if on else "off", "on" if ctx.game.auto_ults else "off"]
