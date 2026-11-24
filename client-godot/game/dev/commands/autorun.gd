## Plays the rest of the run on the play report's policy (spec playable-demo 2.3, 2.3b), without the battle screens.
## A play command: the moves are ordinary choices, logged as such. With policy=chaos every battle is also checked
## (invariants, illegal moves refused, record → replay) and the violations are listed.
extends DevCommand


func _init() -> void:
	name = "autorun"
	usage = "autorun [max_steps] [policy=auto|smart|chaos] [illegal=<percent>] [chaos=<percent>] [from=<floor>] [bot=smart|<res://profile.tres>]"
	help = "Plays the rest of the run on a policy: auto, smart, or chaos (bad and illegal moves on top of smart; every battle checked)."
	cheat = false
	arg_kinds.assign(["int", "text", "text"])


func run(ctx: DevContext, args: PackedStringArray) -> String:
	if ctx.need_run() != "":
		return ctx.fail(ctx.need_run())
	var run := ctx.run
	if not run.pending_battle.is_empty():
		return ctx.fail("finish the current battle first")
	var options := {"policy": "auto", "illegal": 20, "max_steps": 2000}
	for arg in args:
		if arg.is_valid_int():
			options["max_steps"] = int(arg)
		elif arg.begins_with("policy="):
			options["policy"] = arg.trim_prefix("policy=")
		elif arg.begins_with("illegal=") and arg.trim_prefix("illegal=").is_valid_int():
			options["illegal"] = int(arg.trim_prefix("illegal="))
		elif arg.begins_with("chaos=") and arg.trim_prefix("chaos=").is_valid_int():
			options["chaos"] = int(arg.trim_prefix("chaos="))
		elif arg.begins_with("from=") and arg.trim_prefix("from=").is_valid_int():
			options["chaos_from"] = int(arg.trim_prefix("from="))
		elif arg.begins_with("bot="):
			# Spec bot-play 2.1: the smart run bot, opt-in here so the e2e scenarios' runs stay as they were.
			var path := arg.trim_prefix("bot=")
			options["bot_profile"] = PlayReport.SMART_PROFILE if path == "smart" else path
			if not ResourceLoader.exists(options["bot_profile"]) or not load(options["bot_profile"]) is BotProfile:
				return ctx.fail("bot= names no BotProfile: %s" % path)
		else:
			return ctx.fail("usage: " + usage)
	if not PlayReport.POLICIES.has(options["policy"]):
		return ctx.fail("policy is one of %s" % ", ".join(PlayReport.POLICIES))
	if options.has("bot_profile") and options["policy"] == "auto":
		return ctx.fail("bot= needs policy=smart or policy=chaos (auto plays without the bot)")
	var opts := PlayReport._options(run.content, options)
	var record := {"seed": run.state.run_seed, "bossEntry": [], "battles": [], "violations": [], "failures": []}
	var fight := func(active: RunController) -> void:
		await PlayReport.fight_pending(active, active.content, ctx.game, opts, record)
	# The screens fight requested battles with the player's recorder; here the policy fights them instead.
	var game_fights: bool = ctx.game != null and run.battle_requested.is_connected(ctx.game._on_battle_requested)
	if game_fights:
		run.battle_requested.disconnect(ctx.game._on_battle_requested)
	var events := EventScorer.POLICY_SMART if options["policy"] == "smart" else EventScorer.POLICY_RANDOM
	var results := run.event_results
	run.event_results = false  # review fix: no result dialog per event while the bot plays (and no receipt battles)
	# Spec bot-play 2.1: with bot= (smart or chaos policy) the run decisions are the smart run bot's, like the play report.
	var bot: BotProfile = PlayReport.bot_for(PlayReport.DEFAULTS.merged(options, true)) if options.has("bot_profile") else null
	var stop := await RunPlayer.play(run, int(options["max_steps"]), fight, {}, events, bot, {})
	run.event_results = results
	if game_fights and is_instance_valid(run):
		run.battle_requested.connect(ctx.game._on_battle_requested)
	var summary := run.run_summary()
	var lines := PackedStringArray(["%s: %s, floor %d, %d battles (%d won)%s" % [options["policy"], summary["status"],
		summary["floorReached"], record["battles"].size(), summary["battlesWon"], ", " + stop if stop != "" else ""]])
	if options["policy"] == "chaos":
		lines.append("violations: %d" % record["violations"].size())
		for violation in record["violations"].slice(0, 10):
			lines.append("  battle %d (%s): %s %s" % [violation["battle"], violation["encounter"], violation["invariant"],
				violation.get("detail", "")])
	return "\n".join(lines)
