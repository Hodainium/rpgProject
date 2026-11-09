## Spec dev-tools E3: waits for something the server drives (a run starting, a floor seed arriving, a refusal), so
## scripts can cross the stairs in server mode. A play command: it only waits.
extends DevCommand

const DEFAULT_SECONDS: float = 30.0


func _init() -> void:
	name = "wait"
	usage = "wait run | floor <n> | epoch <n> | stopped | ended | verdict all|<seq> | gems <n> | notice <text> [seconds]"
	help = "Waits (default 30 s) until a run is playable, floor n is entered, the run is at epoch n or later (the verifier rolled it back and the client rebuilt it, spec run-verify), the run stopped, the run ended (a win only once the server says Won), the verifier decided the battles (verdict all, or one battle's seq: Verified or Rejected, polled from the server), the wallet holds at least n gems (spec settlement-outbox, polled from the server), or a notice arrived."
	cheat = false
	arg_kinds.assign(["text", "text", "int"])


func run(ctx: DevContext, args: PackedStringArray) -> String:
	if args.is_empty() or not ["run", "floor", "epoch", "stopped", "ended", "verdict", "gems", "notice"].has(args[0]):
		return ctx.fail("usage: " + usage)
	var kind := args[0]
	var rest := args.slice(1)
	var target := ""
	if kind == "floor" or kind == "epoch" or kind == "notice" or kind == "verdict" or kind == "gems":
		if rest.is_empty():
			return ctx.fail("usage: " + usage)
		target = rest[0]
		rest = rest.slice(1)
		if (kind == "floor" or kind == "epoch") and not target.is_valid_int():
			return ctx.fail("%s takes a number" % kind)
		if kind == "gems" and not target.is_valid_int():
			return ctx.fail("gems takes a number")
		if kind == "verdict" and target != "all" and not (target.is_valid_int() and int(target) >= 1):
			return ctx.fail("verdict takes all or a battle's seq")
	var seconds := DEFAULT_SECONDS
	if not rest.is_empty():
		if not rest[0].is_valid_float():
			return ctx.fail("usage: " + usage)
		seconds = float(rest[0])
	var deadline := Time.get_ticks_msec() + int(seconds * 1000.0)
	if kind == "verdict":
		return await _verdicts(ctx, target, deadline, seconds)
	if kind == "gems":
		return await _gems(ctx, int(target), deadline, seconds)
	var check := func() -> bool: return _holds(ctx, kind, target)
	while not check.call():
		if Time.get_ticks_msec() > deadline:
			return ctx.fail("waited %s s for %s: %s" % [seconds, " ".join(args.slice(0, 2 if target != "" else 1)),
				_state(ctx)])
		Watchdog.beat("wait " + kind)
		await ctx.console.tree.process_frame
	return "%s: %s" % [" ".join(args.slice(0, 2 if target != "" else 1)), _state(ctx)]


## One polling loop for the waits that ask the server (spec settlement-outbox): `probe` (awaited) returns true when the
## wait is over. The deadline is checked after every probe and the sleep never runs past it, so a wait overshoots its
## limit by at most one request (the link's own timeout bounds that). False when the deadline passed first.
static func _poll(ctx: DevContext, deadline: int, label: String, interval: float, probe: Callable) -> bool:
	while true:
		if await probe.call():
			return true
		var remaining := deadline - Time.get_ticks_msec()
		if remaining <= 0:
			return false
		Watchdog.beat(label)
		await ctx.console.tree.create_timer(minf(interval, remaining / 1000.0)).timeout
	return false


## Spec settlement-outbox: polls GET /wallet until it holds at least `wanted` gems (the worker grants them after the
## verdict, so this waits on the worker, the outbox and the cache).
func _gems(ctx: DevContext, wanted: int, deadline: int, seconds: float) -> String:
	if ctx.game == null or ctx.game.server == null:
		return ctx.fail("wait gems needs server mode")
	var state := {"last": "no answer", "wallet": {}}
	var enough := func() -> bool:
		var answer: Dictionary = await ctx.game.server.get_wallet()
		if not answer["ok"]:
			state["last"] = ServerLink.describe(answer["error"])
			return false
		state["last"] = "%d gems" % int(answer["data"].get("gems", 0))
		state["wallet"] = answer["data"]
		return int(answer["data"].get("gems", 0)) >= wanted
	if not await _poll(ctx, deadline, "wait gems", 0.5, enough):
		return ctx.fail("waited %s s for %d gems: %s" % [seconds, wanted, state["last"]])
	return "gems: %s" % ServerLink.describe_wallet(state["wallet"])


## Spec battle-verify 2.2: polls the server until every wanted battle has a verdict (Verified or Rejected). The
## player's log drains first; a verdict is what the verifier worker writes, so this waits on the worker too.
func _verdicts(ctx: DevContext, target: String, deadline: int, seconds: float) -> String:
	var run: RunController = ctx.game.run if ctx.game != null else null
	if ctx.game == null or ctx.game.server == null or run == null or run.state == null or not run.state.seeds().server_mode():
		return ctx.fail("wait verdict needs a server run")
	var link: ServerLink = ctx.game.server
	# The wait covers the upload too: a log that never drains (the server is down) fails here, not in the Watchdog.
	var drained := func() -> bool: return link.queued().is_empty() and not link.uploading()
	if not await _poll(ctx, deadline, "wait verdict: upload", 0.1, drained):
		return ctx.fail("waited %s s for the upload queue to drain (%d action(s) waiting)" % [seconds, link.queued().size()])
	var only := int(target) if target != "all" else -1
	var entries: Array[Dictionary] = await link.battle_verdicts(run, only)
	if entries.is_empty():
		return ctx.fail("no battle%s in this run" % (" at seq " + target if only >= 0 else ""))
	var decided := func() -> bool: return entries.all(func(entry: Dictionary) -> bool: return entry["status"] in ["Verified", "Rejected"])
	# Only the battles still pending are asked again; a decided one never changes.
	var refresh := func() -> bool:
		for index in entries.size():
			if not (entries[index]["status"] in ["Verified", "Rejected"]):
				var again := await link.battle_verdicts(run, int(entries[index]["seq"]))
				if not again.is_empty():
					entries[index] = again[0]
		return decided.call()
	if not await _poll(ctx, deadline, "wait verdict", 0.5, refresh):
		var states := PackedStringArray()
		for entry in entries:
			states.append(ServerLink.describe_verdict(entry))
		return ctx.fail("waited %s s for the verdicts: %s" % [seconds, "; ".join(states)])
	var lines := PackedStringArray()
	for entry in entries:
		lines.append(ServerLink.describe_verdict(entry))
	return "verdicts: " + "; ".join(lines)


static func _holds(ctx: DevContext, kind: String, target: String) -> bool:
	var game := ctx.game
	var run: RunController = game.run if game != null else null
	var live := run != null and run.state != null
	match kind:
		"run":
			return live and run.state.status == RunState.ACTIVE and run.runner_error == "" and run.waiting_for_floor() < 0
		"floor":
			return live and run.state.floor_index == int(target) and run.waiting_for_floor() < 0
		"epoch":
			return live and game.server != null and game.server.epoch >= int(target)
		"stopped":
			return live and run.runner_error != ""
		"ended":
			# Spec server-authority 2.3: the end screen, which a won server run reaches only after the verdict; a
			# linked run also has its whole log uploaded (a death's end action included).
			if not live or run.state.status == RunState.ACTIVE or game.mode != "end":
				return false
			return game.server == null or not run.journal \
				or (game.server.queued().is_empty() and not game.server.uploading())
		"notice":
			return ctx.console.recent_notices().any(func(text: String) -> bool: return text.contains(target))
	return false


static func _state(ctx: DevContext) -> String:
	var run: RunController = ctx.game.run if ctx.game != null else null
	if run == null or run.state == null:
		return "no run"
	return "status %s, floor %d, waiting %d%s" % [run.state.status, run.state.floor_index, run.waiting_for_floor(),
		", stopped: " + run.runner_error if run.runner_error != "" else ""]
