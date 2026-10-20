## The room grid without a window (spec dev-tools 3.8): edit a copy of a room, show it as text, save it.
extends DevCommand


func _init() -> void:
	name = "grid"
	usage = "grid <room id or path> <paint|erase|door|show|save> ..."
	help = "paint <x> <y> <player|enemy|prop|pedestal|shop> [slot] · erase <x> <y> · door <n|e|s|w> · show · save [path]"
	cheat = false
	arg_kinds.assign(["room", "grid_op", "text", "text", "place", "int"])


func run(ctx: DevContext, args: PackedStringArray) -> String:
	if args.size() < 2:
		return ctx.fail("usage: grid <room> paint <x> <y> <kind> [slot] | erase <x> <y> | door <n|e|s|w> | show | save [path]")
	var target := args[0]
	var room: RoomDefinition = ctx.console.grid_rooms.get(target)
	if room == null:
		var original: RoomDefinition = ctx.find("room", target)
		if original == null:
			return ctx.fail(ctx.error)
		room = original.duplicate(true)
		room.resource_path = ""
		ctx.console.grid_rooms[target] = room
		ctx.console.grid_rooms[target + "#path"] = original.resource_path
	match args[1]:
		"paint":
			var x: Variant = ctx.arg_int(args, 2, -1)
			var y: Variant = ctx.arg_int(args, 3, -1)
			var slot: Variant = ctx.arg_int(args, 5, 1)
			if x == null or y == null or args.size() < 5 or not RoomGridOps.KINDS.has(args[4]) or slot == null:
				return ctx.fail("paint <x> <y> <%s> [slot]" % "|".join(RoomGridOps.KINDS.keys()))
			if not RoomGridOps.inside(Vector2i(x, y)):
				return ctx.fail("(%d, %d) is outside the %s grid" % [x, y, RoomDefinition.GRID])
			RoomGridOps.paint(room, Vector2i(x, y), RoomGridOps.KINDS[args[4]], slot)
		"erase":
			var x: Variant = ctx.arg_int(args, 2, -1)
			var y: Variant = ctx.arg_int(args, 3, -1)
			if x == null or y == null:
				return ctx.fail("erase <x> <y>")
			RoomGridOps.erase(room, Vector2i(x, y))
		"door":
			if args.size() < 3 or not RoomGridOps.SIDES.has(args[2]):
				return ctx.fail("door <n|e|s|w>")
			RoomGridOps.toggle_door(room, RoomGridOps.SIDES[args[2]])
		"save":
			var path: String = args[2] if args.size() > 2 else ctx.console.grid_rooms[target + "#path"]
			if path == "":
				return ctx.fail("save <path>: this room has no file yet")
			var error := ResourceSaver.save(room, path)
			if error != OK:
				return ctx.fail("could not save %s (%s)" % [path, error_string(error)])
			room.take_over_path(path)
			ctx.console.grid_rooms.erase(target)
			ctx.console.grid_rooms.erase(target + "#path")
			if ctx.game != null:
				ctx.game.load_content()
			return "saved " + path
		"show":
			pass
		_:
			return ctx.fail("unknown grid operation '%s'" % args[1])
	var issues := ContentValidator.check_room(room, ctx.content)
	var lines := PackedStringArray([RoomGridOps.text(room), "(unsaved copy of %s; play it with: play room %s)" % [target, target]])
	for issue in issues:
		lines.append(str(issue))
	return "\n".join(lines)
