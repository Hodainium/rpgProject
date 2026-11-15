## Lists the current room's chests (spec floor-chests 3.5), with keys and the golden key: `open` takes the serial.
extends DevCommand


func _init() -> void:
	name = "chests"
	usage = "chests"
	help = "Lists this room's chests (serial, name, closed or open with how many pickups are left beside it, whether it can open now), keys and the golden key."
	cheat = false


func run(ctx: DevContext, _args: PackedStringArray) -> String:
	if ctx.need_run() != "":
		return ctx.fail(ctx.need_run())
	var lines := PackedStringArray(["keys: %d%s" % [ctx.run.state.keys, " + golden key" if ctx.run.state.golden_key else ""]])
	var chests := ctx.run.room_chests()
	for chest in chests:
		if chest["opened"]:
			lines.append("%d. %s open, %d inside" % [chest["serial"], chest["name"], chest["inside"]])
			continue
		lines.append("%d. %s closed%s%s" % [chest["serial"], chest["name"],
			" (1 key)" if chest["needs_key"] and not chest["free"] else "", "" if chest["can_open"] else " · " + chest["why"]])
	if chests.is_empty():
		lines.append("no chests here")
	return "\n".join(lines)
