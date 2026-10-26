## Cheat: walks straight into any room of the floor (enter only reaches rooms next to visited ones); it plays as if
## entered. The room: a cell index (see `map`), `boss`, or the end of a special room's tag (Shop, Treasure, Altar…).
extends DevCommand


func _init() -> void:
	name = "goto"
	usage = "goto <cell | boss | special tag>"
	help = "Moves into any room of the floor: a cell index, boss, or a special room by the end of its tag."
	cheat = true
	arg_kinds.assign(["text"])


func run(ctx: DevContext, args: PackedStringArray) -> String:
	if ctx.need_run() != "":
		return ctx.fail(ctx.need_run())
	if args.is_empty():
		return ctx.fail("usage: " + usage)
	var map := ctx.run.state.map
	var cell := -1
	if args[0].is_valid_int():
		cell = args[0].to_int()
	else:
		for index in map.sorted_indices():
			var data: Dictionary = map.cells[index]
			var matches: bool = data["role"] == FloorMap.ROLE_BOSS if args[0].to_lower() == "boss" \
				else String(data["special_tag"]).to_lower().ends_with(args[0].to_lower())
			if matches:
				cell = index
				break
		if cell < 0:
			return ctx.fail("no room matching '%s' on this floor" % args[0])
	var error := ctx.run.dev_goto(cell)
	if error != "":
		return ctx.fail(error)
	var content: Dictionary = map.cells[cell]["content"]
	return "in cell %d (%s)" % [cell, "battle" if not ctx.run.pending_battle.is_empty() else
		"event" if not ctx.run.state.event.is_empty() else String(content.get("kind", "room"))]
