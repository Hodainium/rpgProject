## Spec server-authority 3.7: shows or sets the server link (server mode vs local mode), saved in the Settings.
extends DevCommand


func _init() -> void:
	name = "server"
	usage = "server [<url> [player] | off | ruleset | check | verdict [seq] | wallet | reward [...] | reward-reset ... | pack-type [...] | card-rate [...] | resume | forget | conflict]"
	help = "No argument: the mode, server, floor seeds and upload queue. <url> [player]: server mode. off: local mode. ruleset: the version. check: the server agrees with the run. steps: the run's verification steps and their state (a Development server; spec run-verify). verdict [seq]: the verifier's verdict on the run's battles (spec battle-verify). wallet: the player's gems and last ledger rows (spec settlement-outbox). reward: list the server's reward ladders; reward <challenge id> <amount> [cycle=once|weekly] [ends=<UTC ISO>]: set a challenge's reward (a new version; 0 retires it); reward boss <boss id> <amount>: the same for the challenge boss/<boss id> (needs the economy-admin role, which only a Development server gives, spec economy-challenges). reward-reset [boss] <id> [player=me|<player id>] [reason]: the next clear pays the ladder again, for everyone or one player. pack-type: list the server's pack types; pack-type <id> [price=<gems>] [cards=<n>] [odds=common:7210,rare:2200,...] [sets=descent,...] [pity=epic:10,legendary:20,...] [first=epic:5,...] [min=rare|none] [retired=true|false]: a new version (fields you leave out keep the latest version's value; a new pack needs price, cards, odds and sets). card-rate: list the dust value and craft cost per rarity; card-rate <rarity> <dust value> <craft cost>: a new version (spec card-collection 2.7; both need the economy-admin role). resume: continue the server's current run (local save or the server's log), checking the state hash. forget: delete the local save. conflict: resend an acknowledged action with another hash (a 1103)."
	cheat = false


func run(ctx: DevContext, args: PackedStringArray) -> String:
	if args.size() > 0 and args[0] == "ruleset":
		return RulesetVersion.current()
	if args.size() > 0 and args[0] == "check":
		return await _check(ctx)
	if args.size() > 0 and args[0] == "steps":
		return await _steps(ctx)
	if args.size() > 0 and args[0] == "verdict":
		return await _verdict(ctx, args)
	if args.size() > 0 and args[0] == "wallet":
		return await _wallet(ctx)
	if args.size() > 0 and args[0] == "reward":
		return await _reward(ctx, args)
	if args.size() > 0 and args[0] == "reward-reset":
		return await _reward_reset(ctx, args)
	if args.size() > 0 and args[0] == "pack-type":
		return await _pack_type(ctx, args)
	if args.size() > 0 and args[0] == "card-rate":
		return await _card_rate(ctx, args)
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


## Spec run-verify 3.7: the steps the server cut the run's log into and where each stands (the log drains first). A Development
## server only; read-only.
func _steps(ctx: DevContext) -> String:
	if ctx.game == null or ctx.game.server == null:
		return ctx.fail("not in server mode")
	var run := ctx.run
	if run == null or run.state == null or not run.state.seeds().server_mode():
		return ctx.fail("no server run")
	var link: ServerLink = ctx.game.server
	await link.drained()
	var answer: Dictionary = await link.get_steps(run.state.run_id)
	if not answer["ok"]:
		return ctx.fail("GET steps: " + ServerLink.describe(answer["error"]))
	var lines := PackedStringArray(["epoch %d, verified up to seq %d" % [link.epoch, link.verified_seq]])
	for step in answer["data"]:
		lines.append("step %d (epoch %d): seq %d to %d, %s, %s%s" % [int(step["stepNo"]), int(step["epoch"]), int(step["fromSeq"]),
			int(step["toSeq"]), str(step["kind"]).to_lower(), step["status"], " (%s)" % step["reason"] if step.get("reason") != null else ""])
	return "
".join(lines)


## Spec battle-verify 2.2: what the verifier decided about each battle of the run (the log drains first, so every
## battle is on the server). Read-only; a pending or rejected battle is reported, not an error.
func _verdict(ctx: DevContext, args: PackedStringArray) -> String:
	if ctx.game == null or ctx.game.server == null:
		return ctx.fail("not in server mode")
	var run := ctx.run
	if run == null or run.state == null or not run.state.seeds().server_mode():
		return ctx.fail("no server run")
	if args.size() > 1 and not args[1].is_valid_int():
		return ctx.fail("verdict takes a seq number")
	var link: ServerLink = ctx.game.server
	await link.drained()
	var entries := await link.battle_verdicts(run, int(args[1]) if args.size() > 1 else -1)
	if entries.is_empty():
		return ctx.fail("no battle%s in this run" % (" at seq " + args[1] if args.size() > 1 else ""))
	var lines := PackedStringArray()
	for entry in entries:
		lines.append(ServerLink.describe_verdict(entry))
	var unreadable := entries.any(func(entry: Dictionary) -> bool: return entry["error"] != "")
	return ctx.fail("\n".join(lines)) if unreadable else "\n".join(lines)


## Spec settlement-outbox: GET /wallet. Read-only; the gems are decided by the verifier worker, never by the client.
func _wallet(ctx: DevContext) -> String:
	if ctx.game == null or ctx.game.server == null:
		return ctx.fail("not in server mode")
	var answer: Dictionary = await ctx.game.server.get_wallet()
	if not answer["ok"]:
		return ctx.fail("GET wallet: " + ServerLink.describe(answer["error"]))
	return ServerLink.describe_wallet(answer["data"])


## Spec economy-challenges: lists the reward ladders, or sets one. The amounts live on the server; this only drives its admin path.
func _reward(ctx: DevContext, args: PackedStringArray) -> String:
	if ctx.game == null or ctx.game.server == null:
		return ctx.fail("not in server mode")
	if args.size() == 1:
		var listed: Dictionary = await ctx.game.server.request("ListRewardRules", [])
		if not listed["ok"]:
			return ctx.fail("GET reward-rules: " + ServerLink.describe(listed["error"]))
		var rules: Array = listed["data"].get("rules", [])
		if rules.is_empty():
			return "no reward rules"
		return "\n".join(PackedStringArray(rules.map(func(rule: Dictionary) -> String: return _describe_rule(rule))))
	var usage := "usage: server reward [boss] <id> <amount> [cycle=once|weekly] [ends=<UTC ISO>]"
	var rest := args.slice(1)
	var is_boss := rest.size() > 0 and rest[0] == "boss"
	if is_boss:
		rest = rest.slice(1)
	if rest.size() < 2:
		return ctx.fail(usage)
	var challenge := _challenge_id(rest[0], is_boss)
	if not rest[1].is_valid_int() or int(rest[1]) < 0:
		return ctx.fail(usage + " (the amount is a whole number; 0 retires)")
	var body := {"challengeId": challenge, "currency": "gems", "amount": int(rest[1])}
	for option in rest.slice(2):
		if option.begins_with("cycle="):
			body["cycle"] = option.trim_prefix("cycle=")
		elif option.begins_with("ends="):
			body["endsAt"] = option.trim_prefix("ends=")
		else:
			return ctx.fail(usage + " (unknown option %s)" % option)
	var answer: Dictionary = await ctx.game.server.request("PutRewardRule", [WireJson.stringify(body)])
	if not answer["ok"]:
		return ctx.fail("PUT reward-rules: " + ServerLink.describe(answer["error"]))
	return _describe_rule(answer["data"])


## The challenge id of a boss is "boss/" + its id, the same rule the server uses (spec economy-challenges 1.1).
static func _challenge_id(id: String, is_boss: bool) -> String:
	return "boss/" + id if is_boss else id


## Spec card-collection 2.7: lists the pack types, or writes a new version of one. Fields left out keep the latest version's.
func _pack_type(ctx: DevContext, args: PackedStringArray) -> String:
	if ctx.game == null or ctx.game.server == null:
		return ctx.fail("not in server mode")
	var listed: Dictionary = await ctx.game.server.request("ListPackTypes", [])
	if not listed["ok"]:
		return ctx.fail("GET pack-types: " + ServerLink.describe(listed["error"]))
	var current := {}
	for pack in listed["data"].get("packTypes", []):
		current[str(pack["packId"])] = pack
	if args.size() == 1:
		if current.is_empty():
			return "no pack types"
		var ids := current.keys()
		ids.sort()
		return "\n".join(PackedStringArray(ids.map(func(id: String) -> String: return _describe_pack(current[id]))))
	var usage := "usage: server pack-type <id> [price=<gems>] [cards=<n>] [odds=common:7210,...] [sets=a,b] [pity=epic:10,...] [first=epic:5,...] [min=rare|none] [retired=true|false]"
	var id := args[1]
	var body: Dictionary = {}
	if current.has(id):
		var latest: Dictionary = current[id]
		body = {"packId": id, "name": latest.get("name", id), "priceGems": latest["priceGems"], "cardCount": latest["cardCount"],
			"oddsPer10000": latest["oddsPer10000"], "setIds": latest["setIds"], "retired": latest.get("retired", false),
			"pityPacks": latest.get("pityPacks", {}), "firstGuarantees": latest.get("firstGuarantees", {})}
		if latest.get("minRarityPerPack") != null:
			body["minRarityPerPack"] = latest["minRarityPerPack"]
	else:
		body = {"packId": id, "name": id, "retired": false, "pityPacks": {}, "firstGuarantees": {}}
	for option in args.slice(2):
		var key := option.get_slice("=", 0)
		var value := option.get_slice("=", 1)
		match key:
			"price":
				body["priceGems"] = int(value)
			"cards":
				body["cardCount"] = int(value)
			"odds":
				body["oddsPer10000"] = _int_map(value)
			"pity":
				body["pityPacks"] = _int_map(value)
			"first":
				body["firstGuarantees"] = _int_map(value)
			"sets":
				body["setIds"] = Array(value.split(",", false))
			"min":
				if value == "none":
					body.erase("minRarityPerPack")
				else:
					body["minRarityPerPack"] = value
			"retired":
				body["retired"] = value == "true"
			_:
				return ctx.fail(usage + " (unknown option %s)" % option)
	for needed in ["priceGems", "cardCount", "oddsPer10000", "setIds"]:
		if not body.has(needed):
			return ctx.fail(usage + " (a new pack type needs price, cards, odds and sets)")
	var answer: Dictionary = await ctx.game.server.request("PutPackType", [WireJson.stringify(body)])
	if not answer["ok"]:
		return ctx.fail("PUT pack-types: " + ServerLink.describe(answer["error"]))
	return _describe_pack(answer["data"])


## `common:7210,rare:2200` → {"common": 7210, "rare": 2200}.
static func _int_map(text: String) -> Dictionary:
	var result := {}
	for part in text.split(",", false):
		result[part.get_slice(":", 0)] = int(part.get_slice(":", 1))
	return result


static func _describe_pack(pack: Dictionary) -> String:
	var odds: Dictionary = pack["oddsPer10000"]
	var parts := PackedStringArray()
	for rarity in odds:
		parts.append("%s %d" % [rarity, int(odds[rarity])])
	var pity: Dictionary = pack.get("pityPacks", {})
	var pity_parts := PackedStringArray()
	for rarity in pity:
		pity_parts.append("%s %d" % [rarity, int(pity[rarity])])
	var first: Dictionary = pack.get("firstGuarantees", {})
	var first_parts := PackedStringArray()
	for rarity in first:
		first_parts.append("%s %d" % [rarity, int(first[rarity])])
	return "%s v%d: %d gems, %d cards, odds/10000 [%s], sets %s, pity [%s], first [%s], min %s%s" % [pack["packId"],
		int(pack["version"]), int(pack["priceGems"]), int(pack["cardCount"]), ", ".join(parts), ",".join(PackedStringArray(pack["setIds"])),
		", ".join(pity_parts), ", ".join(first_parts), pack.get("minRarityPerPack", "none"), " [retired]" if pack.get("retired", false) else ""]


## Spec card-collection 2.7: lists the dust value and craft cost per rarity, or writes a new version of one rarity.
func _card_rate(ctx: DevContext, args: PackedStringArray) -> String:
	if ctx.game == null or ctx.game.server == null:
		return ctx.fail("not in server mode")
	if args.size() == 1:
		var listed: Dictionary = await ctx.game.server.request("ListCardRates", [])
		if not listed["ok"]:
			return ctx.fail("GET card-rates: " + ServerLink.describe(listed["error"]))
		var rates: Array = listed["data"].get("rates", [])
		if rates.is_empty():
			return "no card rates"
		return "\n".join(PackedStringArray(rates.map(func(rate: Dictionary) -> String: return _describe_rate(rate))))
	if args.size() != 4 or not args[2].is_valid_int() or not args[3].is_valid_int():
		return ctx.fail("usage: server card-rate <rarity> <dust value> <craft cost>")
	var body := {"rarity": args[1], "dustValue": int(args[2]), "craftCost": int(args[3])}
	var answer: Dictionary = await ctx.game.server.request("PutCardRate", [WireJson.stringify(body)])
	if not answer["ok"]:
		return ctx.fail("PUT card-rates: " + ServerLink.describe(answer["error"]))
	return _describe_rate(answer["data"])


static func _describe_rate(rate: Dictionary) -> String:
	return "%s: dust %d, craft %d (version %d, by %s)" % [rate["rarity"], int(rate["dustValue"]), int(rate["craftCost"]),
		int(rate["version"]), rate.get("createdBy", "?")]


## Spec economy-challenges 2.2: `server reward-reset [boss] <id> [player=me|<player id>] [reason...]`.
func _reward_reset(ctx: DevContext, args: PackedStringArray) -> String:
	if ctx.game == null or ctx.game.server == null:
		return ctx.fail("not in server mode")
	var usage := "usage: server reward-reset [boss] <id> [player=me|<player id>] [reason...]"
	var rest := args.slice(1)
	var is_boss := rest.size() > 0 and rest[0] == "boss"
	if is_boss:
		rest = rest.slice(1)
	if rest.is_empty():
		return ctx.fail(usage)
	var body := {"challengeId": _challenge_id(rest[0], is_boss)}
	var reason := PackedStringArray()
	for word in rest.slice(1):
		if word.begins_with("player=") and not body.has("playerId") and reason.is_empty():
			var who := word.trim_prefix("player=")
			if who == "me":
				who = ctx.game.server.player_id
				if who.is_empty():
					return ctx.fail("not signed in: no player id yet")
			body["playerId"] = who
		else:
			reason.append(word)
	if not reason.is_empty():
		body["reason"] = " ".join(reason)
	var answer: Dictionary = await ctx.game.server.request("ResetRewardCycle", [WireJson.stringify(body)])
	if not answer["ok"]:
		return ctx.fail("POST reward-cycles/reset: " + ServerLink.describe(answer["error"]))
	var data: Dictionary = answer["data"]
	return "reset %s for %s: generation %d (by %s)" % [data.get("challengeId", "?"),
		"everyone" if not data.has("playerId") else str(data["playerId"]), int(data.get("generation", 0)), data.get("resetBy", "?")]


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


static func _describe_rule(rule: Dictionary) -> String:
	var amount := int(rule.get("amount", 0))
	var ends := " ends %s" % rule["endsAt"] if rule.has("endsAt") else ""
	return "%s: %d %s %s%s (version %d, generation %d, by %s)%s" % [rule.get("challengeId", "?"), amount,
		rule.get("currency", "?"), rule.get("cycle", "?"), ends, int(rule.get("version", 0)), int(rule.get("generation", 0)),
		rule.get("createdBy", "?"), " [retired: pays nothing]" if amount == 0 else ""]
