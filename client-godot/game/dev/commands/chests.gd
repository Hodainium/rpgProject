## Lists the chest inventory (spec keys-and-gear 3.5), with keys and the golden key: what `open` takes.
extends DevCommand


func _init() -> void:
	name = "chests"
	usage = "chests"
	help = "Lists the party's chests (number, name, whether it needs a key and can open now), keys and the golden key."
	cheat = false


func run(ctx: DevContext, _args: PackedStringArray) -> String:
	if ctx.need_run() != "":
		return ctx.fail(ctx.need_run())
	var lines := PackedStringArray(["keys: %d%s" % [ctx.run.state.keys, " + golden key" if ctx.run.state.golden_key else ""]])
	for chest in ctx.run.chests():
		lines.append("%d. %s%s%s" % [chest["index"] + 1, chest["name"], " (1 key)" if chest["needs_key"] and not chest["free"] else "",
			"" if chest["can_open"] else " · " + chest["why"]])
	if ctx.run.state.chests.is_empty():
		lines.append("no chests")
	return "\n".join(lines)
