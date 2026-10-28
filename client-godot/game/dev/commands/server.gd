## Spec server-authority 3.7: shows or sets the server link (server mode vs local mode), saved in the Settings.
extends DevCommand


func _init() -> void:
	name = "server"
	usage = "server [<url> [player] | off | ruleset | check]"
	help = "No argument: the mode, server and floor seeds. <url> [player]: server mode. off: local mode. ruleset: the version. check: the server agrees with the run."
	cheat = false


func run(ctx: DevContext, args: PackedStringArray) -> String:
	if args.size() > 0 and args[0] == "ruleset":
		return RulesetVersion.current()
	if args.size() > 0 and args[0] == "check":
		return await _check(ctx)
	if ctx.game == null:
		return ctx.fail("no game")
	if args.is_empty():
		var lines := PackedStringArray()
		var url := str(GameMain.load_setting(ServerLink.SETTINGS_SECTION, "url", ""))
		lines.append("server mode: %s, player %s" % [url, GameMain.load_setting(ServerLink.SETTINGS_SECTION, "player", "")]
			if ctx.game.server != null else "local mode" + (" (saved url %s not linked)" % url if url != "" else ""))
		if ctx.run != null and ctx.run.state != null and ctx.run.state.seeds().server_mode():
			var floors := ctx.run.state.floor_seeds.keys()
			floors.sort()
			lines.append("run %s, floor seeds %s%s" % [ctx.run.state.run_id,
				", ".join(floors.map(func(floor_index) -> String: return "%d=%d" % [floor_index, ctx.run.state.floor_seeds[floor_index]])),
				", waiting for floor %d" % ctx.run.waiting_for_floor() if ctx.run.waiting_for_floor() >= 0 else ""])
		return "\n".join(lines)
	if args[0] == "off":
		GameMain.save_setting(ServerLink.SETTINGS_SECTION, "url", "")
		ctx.game.use_server(null)
		return "local mode (new runs only; the current run keeps its seeds)"
	GameMain.save_setting(ServerLink.SETTINGS_SECTION, "url", args[0])
	GameMain.save_setting(ServerLink.SETTINGS_SECTION, "player", args[1] if args.size() > 1 else "dev")
	var link := ServerLink.from_settings()
	if link == null:
		return ctx.fail("can't link (is the C# assembly built?)")
	ctx.game.use_server(link)
	return "server mode: %s as %s (new runs only)" % [args[0], args[1] if args.size() > 1 else "dev"]


## Spec dev-tools E3: the server agrees with the run: GET /runs/{id} is Active on the client's floor, and asking for
## the current floor again (a free retry) returns the client's seed. Read-only for the run.
func _check(ctx: DevContext) -> String:
	if ctx.game == null or ctx.game.server == null:
		return ctx.fail("not in server mode")
	var run := ctx.run
	if run == null or run.state == null or not run.state.seeds().server_mode():
		return ctx.fail("no server run")
	var link: ServerLink = ctx.game.server
	var run_id := run.state.run_id
	var floor_index := run.state.floor_index
	var summary: Dictionary = await link.get_run(run_id)
	if not summary["ok"]:
		return ctx.fail("GET run: " + ServerLink.describe(summary["error"]))
	var problems := PackedStringArray()
	if str(summary["data"]["status"]) != "Active":
		problems.append("server status %s" % summary["data"]["status"])
	if int(summary["data"]["currentFloor"]) != floor_index:
		problems.append("server floor %d, client floor %d" % [int(summary["data"]["currentFloor"]), floor_index])
	var again: Dictionary = await link.floor_seed(run_id, floor_index)
	if not again["ok"]:
		problems.append("floor %d again: %s" % [floor_index, ServerLink.describe(again["error"])])
	elif str(again["data"]["floorSeed"]).to_int() != int(run.state.floor_seeds.get(floor_index, -1)):
		problems.append("floor %d seed: server %s, client %s" % [floor_index, again["data"]["floorSeed"],
			run.state.floor_seeds.get(floor_index, "none")])
	if not problems.is_empty():
		return ctx.fail("server disagrees: " + "; ".join(problems))
	return "server agrees: run %s Active on floor %d, seed %s" % [run_id, floor_index, again["data"]["floorSeed"]]
