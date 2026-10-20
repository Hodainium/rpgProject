## Cheat: replaces the floor with one room (a sandbox), keeping the party; no run → a new sandbox run.
extends DevCommand


func _init() -> void:
	name = "room"
	usage = "room <room id or path>"
	help = "Plays one room now (keeps the party; without a run, starts a sandbox)."
	cheat = true
	arg_kinds.assign(["room"])


func run(ctx: DevContext, args: PackedStringArray) -> String:
	if ctx.game == null:
		return ctx.fail("no game scene")
	var room: RoomDefinition = ctx.console.grid_rooms.get(args[0] if args.size() > 0 else "", null)
	if room == null:
		room = ctx.find("room", args[0] if args.size() > 0 else "")
	if room == null:
		return ctx.fail(ctx.error)
	var request := SandboxRequest.new()
	request.room = room
	if ctx.need_run() != "":
		request.party = PlayRequest.party_for(ctx.game.content, PlayRequest.settings()["party"])
		var error := ctx.game.start_sandbox(request)
		return ctx.fail(error) if error != "" else "sandbox: %s" % room.id
	request.seed = ctx.run.state.run_seed
	request.depth = ctx.run.state.floor_index
	var error := ctx.run.dev_sandbox(request)
	return ctx.fail(error) if error != "" else "room %s" % room.id
