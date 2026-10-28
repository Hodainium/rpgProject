## Spec server-authority 3.7: shows or sets the server link (server mode vs local mode), saved in the Settings.
extends DevCommand


func _init() -> void:
	name = "server"
	usage = "server [<url> [player] | off | ruleset]"
	help = "No argument: the mode, server and floor seeds. <url> [player]: server mode. off: local mode. ruleset: the version."
	cheat = false


func run(ctx: DevContext, args: PackedStringArray) -> String:
	if args.size() > 0 and args[0] == "ruleset":
		return RulesetVersion.current()
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
