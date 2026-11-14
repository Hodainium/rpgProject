## Playtest-fixes B18: the battle pacing (ViewGate): the minimum time an action stays on screen and the pause after it, in
## seconds of game time at 1× (the battle speed scales both). Saved in the Settings; the current battle takes it at once.
extends DevCommand


func _init() -> void:
	name = "pace"
	usage = "pace [<min action seconds> [<pause seconds>]]"
	help = "Shows or sets the battle pacing: an action's minimum time on screen and the pause after it (0 = off)."
	cheat = false


func run(ctx: DevContext, args: PackedStringArray) -> String:
	if args.size() > 2:
		return ctx.fail("usage: " + usage)
	var values: Array[float] = []
	for arg in args:
		if not arg.is_valid_float() or float(arg) < 0.0:
			return ctx.fail("'%s' is not a number of seconds (0 or more)" % arg)
		values.append(float(arg))
	if values.size() > 0:
		GameMain.save_setting("settings", ViewGate.SETTING_MIN_ACTION, values[0])
	if values.size() > 1:
		GameMain.save_setting("settings", ViewGate.SETTING_PAUSE, values[1])
	var shown := ViewGate.new()
	ViewGate.apply_settings(shown)
	if ctx.game != null and ctx.game.gate != null:
		ViewGate.apply_settings(ctx.game.gate)
	return "battle pace: an action at least %.2f s, then a %.2f s pause (at 1×)" % [shown.min_action_seconds,
		shown.pause_seconds]
