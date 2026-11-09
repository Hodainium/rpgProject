## Spec card-collection 2.3: cancels the active run on the server (the path the dust pop-up offers).
extends DevCommand


func _init() -> void:
	name = "abandon"
	usage = "abandon [run id]"
	help = "Server mode. Cancels the player's active run (abandoned, not a death), which frees the cards it locked. Without an id: the run on screen. A won run waiting for its verdict can't be cancelled (1410)."
	cheat = false


func run(ctx: DevContext, args: PackedStringArray) -> String:
	if ctx.game == null or ctx.game.server == null:
		return ctx.fail("not in server mode")
	var run_id := args[0] if args.size() > 0 else ""
	if run_id == "":
		if ctx.run == null or ctx.run.state == null or not ctx.run.state.seeds().server_mode():
			return ctx.fail("no server run on screen; pass a run id")
		run_id = ctx.run.state.run_id
	var answer: Dictionary = await ctx.game.server.abandon_run(run_id)
	if not answer["ok"]:
		return ctx.fail("POST runs/%s/abandon: %s" % [run_id, ServerLink.describe(answer["error"])])
	var link: ServerLink = ctx.game.server
	link.release_cancelled(run_id)  # no more uploads for it, and no save to continue
	if ctx.run != null and ctx.run.state != null and ctx.run.state.run_id == run_id and ctx.game.mode == "run":
		ctx.game.back_to_menu()
	return "run %s abandoned" % run_id
