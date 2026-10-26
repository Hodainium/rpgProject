## The auto-play report (spec playable-demo 2.3, 2.3b): whole runs played headless on a fixed policy, for tuning and
## stress tests. Dev only. RunPlayer drives the run; battles use ScriptedController ("auto") or ChaosController
## ("chaos": bad and illegal moves, each battle checked by InvariantChecker and replayed through ReplayRunner).
## Deterministic: seeds run in order in one process, no wall clock in the result, integers only, keys sorted.
class_name PlayReport
extends RefCounted

const POLICIES: Array[String] = ["auto", "smart", "chaos"]
## chaos: the share of chaotic decisions (percent; the rest are smart) and the first floor (1-based) it plays on.
const DEFAULTS: Dictionary = {"run": "", "party": [], "policy": "auto", "illegal": 20, "check": false,
	"max_steps": 2000, "trace": false, "chaos": 100, "chaos_from": 1, "party_size": 4}


## Plays seeds from..from+count-1. options: DEFAULTS keys ("party" [] = drawn per seed, see party_for();
## "illegal" a percent; "check" = invariants and replay, always on for chaos). The result also holds "failures" (each
## failing battle's request and traces, too big for the report file): take it out before saving; see save_failures().
## `keep_records`: also "records" and "options", for a shard that merge() joins later (spec 2.3d).
## Every script or engine error raised while a seed plays (ScriptErrorLog) goes into that seed's record and the
## report's "errors", so a run that broke the game's code never looks like a normal result.
static func many(content: ContentIndex, host: Node, from: int, count: int, options: Dictionary = {},
		keep_records: bool = false) -> Dictionary:
	var opts := _options(content, options)
	var runs: Array[Dictionary] = []
	var failures: Array = []
	var errors := ScriptErrorLog.new()
	OS.add_logger(errors)
	for seed_value in range(from, from + count):
		_beat("seed %d" % seed_value)  # an error between seeds goes to the next seed's record
		var record := await play_one(content, host, seed_value, opts)
		record["errors"] = errors.take()
		failures.append_array(record["failures"])
		runs.append(record)
	OS.remove_logger(errors)
	var report := summarize(runs, opts, from, count)
	report["failures"] = failures
	if keep_records:
		report["records"] = runs  # per-run records, for merge() (take out before saving the report)
		report["options"] = opts
	return report


## Spec playable-demo 2.3d: one report from shards of the same options (each shard's "records" and "options"),
## exactly as if the seeds had run in one process: the records are joined in seed order and summarized again.
static func merge(shards: Array) -> Dictionary:
	var runs: Array[Dictionary] = []
	for shard in shards:
		for record in shard["records"]:
			runs.append(record)
	runs.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return int(a["seed"]) < int(b["seed"]))
	var from: int = int(runs[0]["seed"]) if not runs.is_empty() else 0
	var opts: Dictionary = shards[0]["options"].duplicate()
	for key in opts:
		if opts[key] is float and opts[key] == floorf(opts[key]):
			opts[key] = int(opts[key])  # whole numbers come back from JSON as floats
	return summarize(runs, opts, from, runs.size())


## One seed: {"seed", "status", "stop", "runnerError", "summary", "bossEntry", "battles", "violations", "runHash",
## "failures", "errors"} (failures: replay requests and traces for violations, kept out of the summary; errors: filled
## by many()).
static func play_one(content: ContentIndex, host: Node, seed_value: int, options: Dictionary) -> Dictionary:
	var opts := _options(content, options)
	var run := RunController.new()
	run.name = "PlayReportRun"
	host.add_child(run)
	var record := {"seed": seed_value, "party": [], "status": "", "stop": "", "runnerError": "", "summary": {}, "bossEntry": [],
		"battles": [], "violations": [], "runHash": "", "failures": [], "errors": []}
	var party := party_for(content, seed_value, opts)
	record["party"] = party
	var error := run.start_run(content, party, str(seed_value), StringName(opts["run"]))
	if error != "":
		record["runnerError"] = error
		run.free()
		return record
	var fight := func(active: RunController) -> void:
		await fight_pending(active, content, host, opts, record)
	record["stop"] = await RunPlayer.play(run, int(opts["max_steps"]), fight)
	record["status"] = run.state.status
	record["runnerError"] = run.runner_error
	record["summary"] = run.run_summary()
	record["runHash"] = run.state.run_hash()
	run.free()
	return record


## Fights the pending battle with the policy's controller, then records it and (check) verifies it.
static func fight_pending(run: RunController, content: ContentIndex, host: Node, opts: Dictionary, record: Dictionary) -> void:
	var snapshot := run.battle_snapshot()
	_beat("seed %d battle %s" % [record["seed"], snapshot["battleId"]])
	var encounter := String(run.pending_battle["encounter"])
	var boss: bool = run.state.map.cells[run.pending_battle["cell"]]["role"] == FloorMap.ROLE_BOSS
	var chaos: bool = opts["policy"] == "chaos"
	var check: bool = chaos or opts["check"]
	var controller: Object
	if chaos:
		controller = ChaosController.new(RunSeeds.rng(run.state.run_seed, "dev/chaos/%s" % snapshot["battleId"]),
			int(opts["illegal"]) * 100)
		# Spec playable-demo 3.9: chaos on top of the smart policy, at a rate and from a floor.
		if int(opts["chaos"]) < 100 or int(opts["chaos_from"]) > 1:
			controller.base = SmartController.new()
			controller.chaos_x100 = int(opts["chaos"]) * 100
			controller.active = run.state.floor_index + 1 >= int(opts["chaos_from"])
	elif opts["policy"] == "smart":
		controller = SmartController.new()
	else:
		controller = ScriptedController.new()
	var seen := {"battle": null, "checker": null, "turns": 0, "mismatch": {}}
	var on_start := func(battle: Battle) -> void:
		seen["battle"] = battle
		if check:
			seen["checker"] = InvariantChecker.new(bool(opts["trace"]))
			battle.trace = seen["checker"]
		if boss:
			record["bossEntry"].append(_party_health(battle, run.state.floor_index + 1, encounter))
		battle.battle_ended.connect(func(_outcome, _hash):
			seen["turns"] = battle.turn
			seen["mismatch"] = battle.mismatch.duplicate())
	run.battle_started.connect(on_start, CONNECT_ONE_SHOT)
	await run.fight(controller)
	if run.battle_started.is_connected(on_start):
		run.battle_started.disconnect(on_start)
	var entry := _last_battle(run)
	var battle_record := {"encounter": encounter, "floor": run.state.floor_index + 1, "boss": boss,
		"outcome": entry.get("outcome", "") if not entry.is_empty() else "", "turns": seen["turns"]}
	if chaos:
		battle_record["refused"] = controller.refused.duplicate()
	record["battles"].append(battle_record)
	if not check or entry.is_empty():
		return
	var where := {"seed": record["seed"], "floor": battle_record["floor"], "battle": record["battles"].size(),
		"battleId": snapshot["battleId"], "encounter": encounter}
	var found: Array[Dictionary] = []
	if not seen["mismatch"].is_empty():
		found.append({"invariant": "record_rejected", "detail": "%s: %s" % [seen["mismatch"]["reason"], seen["mismatch"]["detail"]]})
	if seen["checker"] != null:
		found.append_array(seen["checker"].violations)
	if chaos:
		for violation in controller.violations:
			found.append({"invariant": violation["kind"], "turn": violation["turn"], "unit": violation["unit"],
				"case": violation["case"], "detail": violation["detail"]})
	# Record → replay: the log the client would upload, through JSON as the verifier gets it.
	var request: Dictionary = JSON.parse_string(WireJson.stringify({"snapshot": snapshot, "actionLog": entry["actionLog"]}))
	var runner := ReplayRunner.new()
	var result: Dictionary = await runner.run_on(request, content, host)
	if result.has("runnerError"):
		found.append({"invariant": "replay_runner_error", "detail": str(result["runnerError"])})
	elif _replay_disagrees(result, entry):
		var reason: Variant = result["mismatch"]["reason"] if result["mismatch"] != null else null
		found.append({"invariant": "replay_mismatch", "detail": "verdict %s (%s), hash %s vs %s, outcome %s vs %s" % [
			result["verdict"], reason, result["finalStateHash"], entry["finalHash"], result["outcome"], entry["outcome"]]})
	if found.is_empty():
		return
	for violation in found:
		var full := where.duplicate()
		full.merge(violation)
		record["violations"].append(full)
	var replay_trace := ReplayRunner.new()
	replay_trace.trace = BattleTrace.new(true)
	await replay_trace.run_on(request, content, host)
	record["failures"].append({"where": where, "request": request, "replayTrace": replay_trace.trace.to_json(),
		"recordTrace": seen["checker"].to_json() if seen["checker"] != null and opts["trace"] else null})


## True when the verifier's result is not the recording's: another verdict, hash or outcome. A battle that hit the
## turn cap is recorded as TurnLimit and verified as Rejected (TurnLimitExceeded, spec combat-replay-core) with the same
## hash; that is consistent, and the invariant checker already reports it as turn_limit.
static func _replay_disagrees(result: Dictionary, entry: Dictionary) -> bool:
	if result["finalStateHash"] != entry["finalHash"]:
		return true
	if entry["outcome"] == Battle.TURN_LIMIT_OUTCOME:
		return result["mismatch"] == null or result["mismatch"]["reason"] != "TurnLimitExceeded"
	return result["verdict"] != "Verified" or result["outcome"] != entry["outcome"]


## Progress for the headless watchdog (spec dev-tools, "Headless safeguards"); nothing outside headless runs.
static func _beat(label: String) -> void:
	var tree := Engine.get_main_loop() as SceneTree
	var watchdog: Node = tree.root.get_node_or_null("Watchdog") if tree != null else null
	if watchdog != null:
		watchdog.beat(label)


## Party HP and MP at a battle's start as whole percents of their maximum (×100 values summed over living members).
@warning_ignore("integer_division")
static func _party_health(battle: Battle, floor_number: int, encounter: String) -> Dictionary:
	var totals := {BattleUnit.HP: 0, BattleUnit.MAX_HP: 0, BattleUnit.MP: 0, BattleUnit.MAX_MP: 0}
	var alive := 0
	for unit in battle.units():
		if not unit.is_party():
			continue
		if unit.alive:
			alive += 1
		for attribute_name in totals:
			if unit.asc.has_attribute(attribute_name):
				totals[attribute_name] += unit.stat(attribute_name)
	return {"floor": floor_number, "encounter": encounter, "alive": alive,
		"hpPercent": totals[BattleUnit.HP] * 100 / totals[BattleUnit.MAX_HP] if totals[BattleUnit.MAX_HP] > 0 else 0,
		"mpPercent": totals[BattleUnit.MP] * 100 / totals[BattleUnit.MAX_MP] if totals[BattleUnit.MAX_MP] > 0 else 0}


static func _last_battle(run: RunController) -> Dictionary:
	for index in range(run.run_log.size() - 1, -1, -1):
		if run.run_log[index]["type"] == "battle":
			return run.run_log[index]
	return {}


static func _options(_content: ContentIndex, options: Dictionary) -> Dictionary:
	var opts := DEFAULTS.duplicate(true)
	opts.merge(options, true)
	return opts


## Spec playable-demo 3.10 (D24): the seed's party. A fixed "party" is used as given; otherwise "party_size" (1-4, or
## "mixed": a size of 1 to 4 per seed) different selectable characters, drawn from the stream dev/party (sorted ids).
static func party_for(content: ContentIndex, seed_value: int, opts: Dictionary) -> Array:
	if not opts["party"].is_empty():
		return opts["party"]
	var ids: Array = []
	for id in content.characters:
		if content.characters[id].selectable:
			ids.append(String(id))
	ids.sort()
	var draw := RunSeeds.rng(seed_value, "dev/party")
	var size: int = draw.randi_range(1, 4) if str(opts["party_size"]) == "mixed" else int(opts["party_size"])
	size = clampi(size, 1, mini(4, ids.size()))
	for index in range(ids.size() - 1, 0, -1):
		var other := draw.randi_range(0, index)
		var held: Variant = ids[index]
		ids[index] = ids[other]
		ids[other] = held
	var party := ids.slice(0, size)
	party.sort()
	return party


## The aggregate over played runs (per-run lines kept compact, failures left out).
@warning_ignore("integer_division")
static func summarize(runs: Array[Dictionary], opts: Dictionary, from: int, count: int) -> Dictionary:
	var party_label: Variant = opts["party"] if not opts["party"].is_empty() else "size %s" % opts["party_size"]
	var report := {"run": opts["run"], "policy": opts["policy"], "party": party_label, "from": from, "count": count,
		"illegalPercent": opts["illegal"] if opts["policy"] == "chaos" else 0,
		"chaosPercent": opts["chaos"] if opts["policy"] == "chaos" else 0,
		"chaosFrom": opts["chaos_from"] if opts["policy"] == "chaos" else 0, "won": 0, "lost": 0, "stopped": 0,
		"winPercentX100": 0, "deaths": {}, "floorReached": {}, "bossEntryHpPercent": {}, "turnsPerBattle": {},
		"coinsSpent": {}, "refused": {}, "bySize": {}, "byCharacter": {}, "byParty": {}, "violations": [], "errors": [],
		"runs": []}
	var boss_hp := {}
	var turns := {}
	var coins: Array[int] = []
	for record in runs:
		var summary: Dictionary = record["summary"]
		# Spec playable-demo 3.10: runs and wins by party size, by character and by party.
		var won_run := 1 if record["status"] == RunState.WON else 0
		for pair in [["bySize", str(record["party"].size())], ["byParty", ",".join(record["party"])]]:
			var tally: Dictionary = report[pair[0]].get(pair[1], {"runs": 0, "won": 0})
			tally["runs"] += 1
			tally["won"] += won_run
			report[pair[0]][pair[1]] = tally
		for id in record["party"]:
			var tally: Dictionary = report["byCharacter"].get(id, {"runs": 0, "won": 0})
			tally["runs"] += 1
			tally["won"] += won_run
			report["byCharacter"][id] = tally
		if record["runnerError"] != "" or record["stop"] != "":
			report["stopped"] += 1
		elif record["status"] == RunState.WON:
			report["won"] += 1
		elif record["status"] == RunState.LOST:
			report["lost"] += 1
			SeedReport._count(report["deaths"], summary["endedIn"]["encounter"])
		if not summary.is_empty():
			SeedReport._count(report["floorReached"], str(int(summary["floorReached"])))  # merged records come through JSON
			coins.append(int(summary["coinsSpent"]))
		for entry in record["bossEntry"]:
			var key := "floor %d" % entry["floor"]
			if not boss_hp.has(key):
				var values: Array[int] = []
				boss_hp[key] = values
			boss_hp[key].append(int(entry["hpPercent"]))
		for battle in record["battles"]:
			if not turns.has(battle["encounter"]):
				var values: Array[int] = []
				turns[battle["encounter"]] = values
			turns[battle["encounter"]].append(int(battle["turns"]))
			for case in battle.get("refused", {}):
				report["refused"][case] = report["refused"].get(case, 0) + battle["refused"][case]
		report["violations"].append_array(record["violations"])
		for text in record.get("errors", []):
			report["errors"].append({"seed": record["seed"], "error": text})
		report["runs"].append({"seed": record["seed"], "status": record["status"], "stop": record["stop"],
			"runnerError": record["runnerError"], "party": record["party"], "floorReached": summary.get("floorReached", 0),
			"battles": record["battles"].size(), "violations": record["violations"].size(), "runHash": record["runHash"]})
	report["winPercentX100"] = report["won"] * 10000 / count if count > 0 else 0
	for key in boss_hp:
		report["bossEntryHpPercent"][key] = spread(boss_hp[key])
	for key in turns:
		report["turnsPerBattle"][key] = spread(turns[key])
	report["coinsSpent"] = spread(coins)
	for key in ["deaths", "floorReached", "bossEntryHpPercent", "turnsPerBattle", "refused", "bySize", "byCharacter",
			"byParty"]:
		report[key] = SeedReport._sorted(report[key])
	return report


## min, median (lower middle), average ×100 and max of whole numbers; {} when empty.
@warning_ignore("integer_division")
static func spread(values: Array[int]) -> Dictionary:
	if values.is_empty():
		return {}
	var sorted := values.duplicate()
	sorted.sort()
	var result := SeedReport._spread(values)
	result["median"] = sorted[(sorted.size() - 1) / 2]
	return result


## The report as text: outcome counts, deaths, boss-entry HP, turns per encounter, violations.
static func text(report: Dictionary) -> String:
	var lines := PackedStringArray(["%s policy%s, run %s, party %s, seeds %d..%d" % [report["policy"],
		" (%d%% of decisions from floor %d, %d%% illegal)" % [report["chaosPercent"], report["chaosFrom"],
			report["illegalPercent"]] if report["policy"] == "chaos" else "",
		report["run"] if report["run"] != "" else "(default)", ",".join(report["party"]) if report["party"] is Array else report["party"], report["from"],
		report["from"] + report["count"] - 1]])
	lines.append("  won %d  lost %d  stopped %d  (win rate %.2f%%)" % [report["won"], report["lost"], report["stopped"],
		report["winPercentX100"] / 100.0])
	lines.append("  floor reached: %s" % _pairs(report["floorReached"]))
	for key in ["bySize", "byCharacter"]:
		var parts := PackedStringArray()
		for id in report[key]:
			var tally: Dictionary = report[key][id]
			parts.append("%s %d/%d" % [String(id).trim_prefix("demo.character."), tally["won"], tally["runs"]])
		if not parts.is_empty():
			lines.append("  won/runs by %s: %s" % ["party size" if key == "bySize" else "class", ", ".join(parts)])
	var parties: Array = report["byParty"].keys()
	parties.sort_custom(func(a, b) -> bool: return report["byParty"][a]["won"] * 1000 / maxi(report["byParty"][a]["runs"], 1) 		> report["byParty"][b]["won"] * 1000 / maxi(report["byParty"][b]["runs"], 1) or (report["byParty"][a]["won"] * 1000 		/ maxi(report["byParty"][a]["runs"], 1) == report["byParty"][b]["won"] * 1000 / maxi(report["byParty"][b]["runs"], 1) and a < b))
	for id in parties.slice(0, 5):
		lines.append("  party %s: %d/%d" % [String(id).replace("demo.character.", ""), report["byParty"][id]["won"],
			report["byParty"][id]["runs"]])
	lines.append("  deaths: %s" % _pairs(report["deaths"], true))
	for key in report["bossEntryHpPercent"]:
		var spread_entry: Dictionary = report["bossEntryHpPercent"][key]
		lines.append("  boss entry HP %%, %s: min %d  median %d  max %d" % [key, spread_entry["min"], spread_entry["median"],
			spread_entry["max"]])
	for key in report["turnsPerBattle"]:
		var spread_entry: Dictionary = report["turnsPerBattle"][key]
		lines.append("  turns, %s: median %d  max %d" % [key, spread_entry["median"], spread_entry["max"]])
	if not report["coinsSpent"].is_empty():
		lines.append("  coins spent per run: median %d  max %d" % [report["coinsSpent"]["median"], report["coinsSpent"]["max"]])
	if report["policy"] == "chaos":
		lines.append("  illegal moves refused: %s" % _pairs(report["refused"]))
	lines.append("  violations: %d" % report["violations"].size())
	for violation in report["violations"].slice(0, 20):
		lines.append("    seed %d, floor %d, battle %d (%s): %s %s" % [violation["seed"], violation["floor"],
			violation["battle"], violation["encounter"], violation["invariant"], violation.get("detail", "")])
	lines.append("  script or engine errors: %d" % report["errors"].size())
	for entry in report["errors"].slice(0, 20):
		lines.append("    seed %d: %s" % [entry["seed"], entry["error"]])
	for record in report["runs"]:
		if record["stop"] != "" or record["runnerError"] != "":
			lines.append("  STOPPED seed %d: %s" % [record["seed"], record["runnerError"] if record["runnerError"] != "" else record["stop"]])
	return "\n".join(lines)


static func _pairs(counts: Dictionary, most_first: bool = false) -> String:
	var keys := counts.keys()
	if most_first:
		keys.sort_custom(func(a, b) -> bool: return counts[a] > counts[b] or (counts[a] == counts[b] and a < b))
	return ", ".join(keys.map(func(key) -> String: return "%s ×%d" % [key, counts[key]])) if not keys.is_empty() else "-"


## Writes each failing battle's request and traces next to `out_path` (<out>.failures/seed-<n>-battle-<k>.*.json),
## ready for replay_main and trace_main --diff. Returns the files written.
static func save_failures(runs_failures: Array, out_path: String) -> PackedStringArray:
	var written := PackedStringArray()
	if runs_failures.is_empty():
		return written
	var directory := out_path.get_basename() + ".failures/"
	DirAccess.make_dir_recursive_absolute(directory if directory.is_absolute_path() else ProjectSettings.globalize_path(directory))
	for failure in runs_failures:
		var stem := directory + "seed-%d-battle-%d" % [failure["where"]["seed"], failure["where"]["battle"]]
		for part in [["request", failure["request"]], ["replay.trace", failure["replayTrace"]], ["record.trace", failure["recordTrace"]]]:
			if part[1] == null:
				continue
			var file := FileAccess.open("%s.%s.json" % [stem, part[0]], FileAccess.WRITE)
			if file == null:
				continue
			file.store_string(WireJson.stringify(part[1]))
			file.close()
			written.append("%s.%s.json" % [stem, part[0]])
	return written
