## A Play button without a window: plays a room, encounter, enemy, character or layout (spec dev-tools 2.4).
extends DevCommand


func _init() -> void:
	name = "play"
	usage = "play <room|encounter|enemy|character|layout> <id or path>"
	help = "Plays the asset in a sandbox (rooms opened with grid play their unsaved copy)."
	cheat = false
	arg_kinds.assign(["play_kind", "text"])


func run(ctx: DevContext, args: PackedStringArray) -> String:
	if ctx.game == null:
		return ctx.fail("no game scene")
	if args.size() < 2:
		return ctx.fail("usage: " + usage)
	# A room opened with `grid` plays its unsaved copy.
	var grid_room: RoomDefinition = ctx.console.grid_rooms.get(args[1]) if args[0] == "room" else null
	var target: String = ctx.console.grid_rooms[args[1] + "#path"] if grid_room != null else args[1]
	var built := PlayRequest.build(ctx.game.content, args[0], target)
	if built["error"] != "":
		return ctx.fail(built["error"])
	if grid_room != null:
		built["sandbox"].room = grid_room
	var error: String
	if built["run"].is_empty():
		error = ctx.game.start_sandbox(built["sandbox"])
	else:
		error = ctx.game.start_run(built["run"]["party"], built["run"]["seed"])
	return ctx.fail(error) if error != "" else "playing %s %s" % [args[0], args[1]]
