## Spec dev-tools E3: waits for something the server drives (a run starting, a floor seed arriving, a refusal), so
## scripts can cross the stairs in server mode. A play command: it only waits.
extends DevCommand

const DEFAULT_SECONDS: float = 30.0


func _init() -> void:
	name = "wait"
	usage = "wait run | floor <n> | stopped | ended | notice <text> [seconds]"
	help = "Waits (default 30 s) until a run is playable, floor n is entered, the run stopped, the run ended (a win only once the server says Won), or a notice arrived."
	cheat = false
	arg_kinds.assign(["text", "text", "int"])


func run(ctx: DevContext, args: PackedStringArray) -> String:
	if args.is_empty() or not ["run", "floor", "stopped", "ended", "notice"].has(args[0]):
		return ctx.fail("usage: " + usage)
	var kind := args[0]
	var rest := args.slice(1)
	var target := ""
	if kind == "floor" or kind == "notice":
		if rest.is_empty():
			return ctx.fail("usage: " + usage)
		target = rest[0]
		rest = rest.slice(1)
		if kind == "floor" and not target.is_valid_int():
			return ctx.fail("floor takes a number")
	var seconds := DEFAULT_SECONDS
	if not rest.is_empty():
		if not rest[0].is_valid_float():
			return ctx.fail("usage: " + usage)
		seconds = float(rest[0])
	var check := func() -> bool: return _holds(ctx, kind, target)
	var deadline := Time.get_ticks_msec() + int(seconds * 1000.0)
	while not check.call():
		if Time.get_ticks_msec() > deadline:
			return ctx.fail("waited %s s for %s: %s" % [seconds, " ".join(args.slice(0, 2 if target != "" else 1)),
				_state(ctx)])
		Watchdog.beat("wait " + kind)
		await ctx.console.tree.process_frame
	return "%s: %s" % [" ".join(args.slice(0, 2 if target != "" else 1)), _state(ctx)]


static func _holds(ctx: DevContext, kind: String, target: String) -> bool:
	var game := ctx.game
	var run: RunController = game.run if game != null else null
	var live := run != null and run.state != null
	match kind:
		"run":
			return live and run.state.status == RunState.ACTIVE and run.runner_error == "" and run.waiting_for_floor() < 0
		"floor":
			return live and run.state.floor_index == int(target) and run.waiting_for_floor() < 0
		"stopped":
			return live and run.runner_error != ""
		"ended":
			# Spec server-authority 2.3: the end screen, which a won server run reaches only after the verdict; a
			# linked run also has its whole log uploaded (a death's end action included).
			var uploaded: bool = game.server == null or not run.journal \
				or (game.server.queued().is_empty() and not game.server.uploading())
			return live and run.state.status != RunState.ACTIVE and game.mode == "end" and uploaded
		"notice":
			return ctx.console.recent_notices().any(func(text: String) -> bool: return text.contains(target))
	return false


static func _state(ctx: DevContext) -> String:
	var run: RunController = ctx.game.run if ctx.game != null else null
	if run == null or run.state == null:
		return "no run"
	return "status %s, floor %d, waiting %d%s" % [run.state.status, run.state.floor_index, run.waiting_for_floor(),
		", stopped: " + run.runner_error if run.runner_error != "" else ""]
