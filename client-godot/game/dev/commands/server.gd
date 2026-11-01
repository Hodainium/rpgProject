## Spec server-authority 3.7: shows or sets the server link (server mode vs local mode), saved in the Settings.
extends DevCommand


func _init() -> void:
	name = "server"
	usage = "server [<url> [player] | off | ruleset | check | resume | forget | conflict]"
	help = "No argument: the mode, server, floor seeds and upload queue. <url> [player]: server mode. off: local mode. ruleset: the version. check: the server agrees with the run. resume: continue the server's current run (local save or the server's log), checking the state hash. forget: delete the local save. conflict: resend an acknowledged action with another hash (a 1103)."
	cheat = false


func run(ctx: DevContext, args: PackedStringArray) -> String:
	if args.size() > 0 and args[0] == "ruleset":
		return RulesetVersion.current()
	if args.size() > 0 and args[0] == "check":
		return await _check(ctx)
	if args.size() > 0 and args[0] in ["resume", "forget", "conflict"]:
		return await _part_b(ctx, args[0])
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
			var link: ServerLink = ctx.game.server
			if link != null:
				lines.append("queue: %d action(s) waiting, last acknowledged seq %d%s, %d resume(s)" % [
					link.queued().size(), link.last_acked_seq(), ", uploading" if link.uploading() else "", link.resumes])
		return "\n".join(lines)
	if args[0] == "off":
		ctx.game.disconnect_server()
		return "local mode (new runs only; the current run keeps its seeds)"
	# Saved only once the link exists: a saved url is linked again at every windowed start (spec main-menu M7).
	var player_name: String = args[1] if args.size() > 1 else "dev"
	var error: String = ctx.game.connect_server(args[0], player_name)
	if error != "":
		return ctx.fail(error)
	return "server mode: %s as %s (new runs only)" % [args[0], player_name]


## Spec dev-tools E9 (Part B): resume (the state hash before and after must match), forget, conflict.
func _part_b(ctx: DevContext, action: String) -> String:
	if ctx.game == null or ctx.game.server == null:
		return ctx.fail("not in server mode")
	var link: ServerLink = ctx.game.server
	match action:
		"forget":
			link.forget_save()
			return "local save deleted (%s)" % link.save_path()
		"conflict":
			var problem := link.dev_conflict()
			if problem != "":
				return ctx.fail(problem)
			return "resent the last acknowledged action with another hash"
	# resume: drop the current run as an app restart would, then continue it from the server.
	var before := ""
	var before_lines := PackedStringArray()
	if ctx.run != null and ctx.run.state != null and ctx.run.state.status == RunState.ACTIVE:
		await link.drained()
		if not await _floor_open(ctx, ctx.run):
			return ctx.fail("the run still waits for floor %d's seed" % ctx.run.waiting_for_floor())
		before = ctx.run.state.run_hash()
		before_lines = ctx.run.state.canonical_lines()
	var source := [""]
	var on_resumed := func(from: String) -> void: source[0] = from
	link.resumed.connect(on_resumed)
	var error: String = await ctx.game.resume_server_run()
	link.resumed.disconnect(on_resumed)
	if error != "":
		return ctx.fail("resume: " + error)
	if ctx.game.run == null or ctx.game.run.state == null or source[0] == "":
		return ctx.fail("no run to resume")
	if not await _floor_open(ctx, ctx.game.run):
		return ctx.fail("the resumed run still waits for floor %d's seed" % ctx.game.run.waiting_for_floor())
	var after: String = ctx.game.run.state.run_hash()
	if before != "" and after != before:
		var lines := ctx.game.run.state.canonical_lines()
		var first := 0
		while first < mini(lines.size(), before_lines.size()) and lines[first] == before_lines[first]:
			first += 1
		return ctx.fail("resumed from the %s with another state hash (%s, was %s); first difference: %s → %s" % [
			source[0], after, before, before_lines[first] if first < before_lines.size() else "(none)",
			lines[first] if first < lines.size() else "(none)"])
	return "resumed run %s from the %s at seq %d, state hash %s" % [ctx.game.run.state.run_id, source[0],
		link.last_acked_seq(), after]


## Waits (up to 30 s) until `run` isn't waiting at the stairs for a floor seed, so hashes compare whole floors.
static func _floor_open(ctx: DevContext, run: RunController) -> bool:
	var deadline := Time.get_ticks_msec() + 30000
	while run.waiting_for_floor() >= 0 and Time.get_ticks_msec() < deadline:
		Watchdog.beat("server resume: floor seed")
		await ctx.console.tree.process_frame
	return run.waiting_for_floor() < 0


## Spec dev-tools E3: the server agrees with the run: GET /runs/{id} is Active on the client's floor, and asking for
## the current floor again (a free retry) returns the client's seed. Read-only for the run.
func _check(ctx: DevContext) -> String:
	if ctx.game == null or ctx.game.server == null:
		return ctx.fail("not in server mode")
	var run := ctx.run
	if run == null or run.state == null or not run.state.seeds().server_mode():
		return ctx.fail("no server run")
	var link: ServerLink = ctx.game.server
	await link.drained()  # spec Part B: the log is all in first, so lastSeq can be compared
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
	if run.journal and int(summary["data"]["lastSeq"]) != run.run_log.size():
		problems.append("server lastSeq %d, client log %d" % [int(summary["data"]["lastSeq"]), run.run_log.size()])
	var again: Dictionary = await link.floor_seed(run_id, floor_index)
	if not again["ok"]:
		problems.append("floor %d again: %s" % [floor_index, ServerLink.describe(again["error"])])
	elif str(again["data"]["floorSeed"]).to_int() != int(run.state.floor_seeds.get(floor_index, -1)):
		problems.append("floor %d seed: server %s, client %s" % [floor_index, again["data"]["floorSeed"],
			run.state.floor_seeds.get(floor_index, "none")])
	if not problems.is_empty():
		return ctx.fail("server disagrees: " + "; ".join(problems))
	return "server agrees: run %s Active on floor %d, seed %s, %d action(s)" % [run_id, floor_index,
		again["data"]["floorSeed"], int(summary["data"]["lastSeq"])]
