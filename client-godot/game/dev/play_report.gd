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
	return await many_seeds(content, host, range(from, from + count), options, keep_records)


## Spec skill-points D16: plays the given seeds in order (the balance gate plays a committed list, see load_seeds()).
## Same options and result as many(); "from" is the first seed and "count" the number played.
static func many_seeds(content: ContentIndex, host: Node, seeds: Array, options: Dictionary = {},
		keep_records: bool = false) -> Dictionary:
	var opts := _options(content, options)
	var runs: Array[Dictionary] = []
	var failures: Array = []
	var errors := ScriptErrorLog.new()
	OS.add_logger(errors)
	var from: int = int(seeds[0]) if not seeds.is_empty() else 0
	var count := seeds.size()
	for seed_value in seeds:
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
	record["features"] = party_features(content, party)
	var error := run.start_run(content, party, str(seed_value), StringName(opts["run"]))
	if error != "":
		record["runnerError"] = error
		run.free()
		return record
	var fight := func(active: RunController) -> void:
		await fight_pending(active, content, host, opts, record)
	# Spec keys-and-gear 3.5: chaos also tries run actions that must be refused (keys, chests, swaps, moves).
	var run_chaos := {}
	if opts["policy"] == "chaos":
		run_chaos = {"rng": RunSeeds.rng(seed_value, "dev/chaos/run"), "illegal_x100": int(opts["illegal"]) * 100,
			"violations": record["violations"], "refused": record.get_or_add("runRefused", {})}
	record["stop"] = await RunPlayer.play(run, int(opts["max_steps"]), fight, run_chaos)
	record["status"] = run.state.status
	record["runnerError"] = run.runner_error
	record["summary"] = run.run_summary()
	record["runHash"] = run.state.run_hash()
	# Spec skill-points 5: the level skills each member had reached when the run ended.
	var learned := {}
	for member in run.state.party:
		var character: UnitDefinition = content.units.get(member["character"])
		if character == null:
			continue
		var tags: Array = []
		for row in character.level_skills:
			if row != null and row.ability != null and row.level <= int(member["level"]):
				tags.append(String(SkillTags.tag_of(row.ability)))
		learned[String(member["character"]).trim_prefix("demo.character.")] = tags
	record["learned"] = learned
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
			controller.base = AutoPolicy.new(AutoPolicy.Options.new(), content)
			controller.chaos_x100 = int(opts["chaos"]) * 100
			controller.active = run.state.floor_index + 1 >= int(opts["chaos_from"])
	elif opts["policy"] == "smart":
		# Spec auto-battle: the player's Auto, through the same recorder path as the battle panel.
		controller = ActionRecorder.new()
		controller.autopilot = AutoPolicy.new(AutoPolicy.Options.new(), content)
	else:
		controller = ScriptedController.new()
	var seen := {"battle": null, "checker": null, "turns": 0, "mismatch": {}, "health": {}}
	var on_start := func(battle: Battle) -> void:
		seen["battle"] = battle
		if check:
			seen["checker"] = InvariantChecker.new(bool(opts["trace"]))
			battle.trace = seen["checker"]
		seen["health"] = _party_health(battle, run.state.floor_index + 1, encounter)
		# Spec skill-points 5: the SP rhythm per class, from the battle's read-only activation signal, and enemies'
		# secret skills (battles fought at or above their level, and uses).
		var secret: Dictionary = record.get_or_add("secret", {})
		for unit in battle.units():
			if not unit.is_party():
				for row in unit.definition.level_skills:
					if row != null and row.ability != null and row.level <= unit.level:
						var key := "%s:%s" % [String(unit.definition.id).trim_prefix("demo.enemy."), SkillTags.tag_of(row.ability)]
						secret.get_or_add(key, {"battles": 0, "uses": 0})["battles"] += 1
		battle.ability_activated.connect(func(unit_id: StringName, tag: StringName, _target: StringName) -> void:
			_count_sp(battle, unit_id, tag, record.get_or_add("sp", {}))
			var actor := battle.unit_by_id(unit_id)
			if actor != null and not actor.is_party():
				var key := "%s:%s" % [String(actor.definition.id).trim_prefix("demo.enemy."), tag]
				if secret.has(key):
					secret[key]["uses"] += 1)
		if boss:
			record["bossEntry"].append(seen["health"])
		battle.battle_ended.connect(func(_outcome, _hash):
			seen["turns"] = battle.turn
			seen["mismatch"] = battle.mismatch.duplicate())
	run.battle_started.connect(on_start, CONNECT_ONE_SHOT)
	await run.fight(controller)
	if run.battle_started.is_connected(on_start):
		run.battle_started.disconnect(on_start)
	var entry := _last_battle(run)
	# Spec skill-points 4.3/4.4: where the battle is, what the party held (the mirror's count) and how it arrived.
	var battle_record := {"encounter": encounter, "floor": run.state.floor_index + 1, "boss": boss,
		"outcome": entry.get("outcome", "") if not entry.is_empty() else "", "turns": seen["turns"],
		"chapter": String(run.state.chapter_id), "held": held_count(snapshot), "level": _average_level(snapshot),
		"hpPercent": int(seen["health"].get("hpPercent", 0)), "mpPercent": int(seen["health"].get("mpPercent", 0))}
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
## turn cap verifies as TurnLimit (spec skill-points D15); the invariant checker still reports it as turn_limit.
static func _replay_disagrees(result: Dictionary, entry: Dictionary) -> bool:
	if result["finalStateHash"] != entry["finalHash"]:
		return true
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


## Spec skill-points D16: the seeds of a committed seed list ({"seeds": [...]}), `offset` and `limit` slicing it
## (limit 0 = to the end); [] when the file can't be read.
static func load_seeds(path: String, offset: int = 0, limit: int = 0) -> Array:
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	if not parsed is Dictionary or not parsed.get("seeds") is Array:
		return []
	var seeds: Array = []
	for value in parsed["seeds"]:
		seeds.append(int(value))
	var end := seeds.size() if limit <= 0 else mini(offset + limit, seeds.size())
	return seeds.slice(offset, end)


## Spec skill-points 4.4: the pieces the party carries into a battle (held items, worn equipment, use items), the
## count a mirror boss's per-item effect uses.
static func held_count(snapshot: Dictionary) -> int:
	var count := 0
	for member in snapshot.get("party", []):
		for key in ["items", "equipmentIds", "useSlots"]:
			var list: Variant = member.get(key)
			if list is Array:
				count += list.size()
	return count


@warning_ignore("integer_division")
static func _average_level(snapshot: Dictionary) -> int:
	var members: Array = snapshot.get("party", [])
	var total := 0
	for member in members:
		total += int(member.get("level", 1))
	return total / members.size() if not members.is_empty() else 0


## Spec skill-points D26: what a party can do, read from its classes' abilities (role and damage-type tags, never
## ids): {"heal", "revive", "cleanse", "dispel", "buff", "debuff", "areaDamage": bool, "damageTypes": int,
## "sound": heal and two or more damage types}.
static func party_features(content: ContentIndex, party: Array) -> Dictionary:
	var features := {"heal": false, "revive": false, "cleanse": false, "dispel": false, "buff": false, "debuff": false,
		"areaDamage": false, "damageTypes": 0, "sound": false}
	var types := {}
	for id in party:
		var character: CharacterDefinition = content.characters.get(StringName(str(id)))
		if character == null:
			continue
		var scenes: Array = character.abilities.duplicate()
		if character.default_loadout != null:
			scenes.append_array(character.default_loadout.skills)
		for scene in scenes:
			var ability := (scene as PackedScene).instantiate() as BattleAbility if scene is PackedScene else null
			if ability == null:
				continue
			if not ability.is_triggered():
				for pair in [["heal", AutoPolicy.ROLE_HEAL], ["revive", AutoPolicy.ROLE_REVIVE],
						["cleanse", AutoPolicy.ROLE_CLEANSE], ["dispel", AutoPolicy.ROLE_DISPEL],
						["buff", AutoPolicy.ROLE_BUFF], ["debuff", AutoPolicy.ROLE_DEBUFF]]:
					if ability.asset_tags.has(pair[1]):
						features[pair[0]] = true
				if ability.asset_tags.has(AutoPolicy.ROLE_DAMAGE):
					if ability.targeting == BattleAbility.Targeting.ALL_ENEMIES:
						features["areaDamage"] = true
					for row in ability.executions:
						for tag in row.tags:
							if String(tag).begins_with("Damage.Type."):
								types[String(tag)] = true
			ability.free()
	features["damageTypes"] = types.size()
	features["sound"] = features["heal"] and types.size() >= 2
	return features


## Spec skill-points 5: one party action into record["sp"][class]: basics (and the SP they give, the part lost at the
## cap), costed abilities and the SP they cost. Read before the action resolves; never changes the battle.
@warning_ignore("integer_division")
static func _count_sp(battle: Battle, unit_id: StringName, tag: StringName, by_class: Dictionary) -> void:
	var unit := battle.unit_by_id(unit_id)
	if unit == null or not unit.is_party():
		return
	var ability := unit.ability_by_tag(tag)
	if ability == null:
		return
	var tally: Dictionary = by_class.get_or_add(String(unit.definition.id).trim_prefix("demo.character."),
		{"basics": 0, "abilities": 0, "spGained": 0, "spSpent": 0, "capWaste": 0})
	var mp := unit.stat(BattleUnit.MP) if unit.asc.has_attribute(BattleUnit.MP) else 0
	if ability.asset_tags.has(&"Ability.Type.Basic"):
		tally["basics"] += 1
		var gain := AutoPolicy.basic_gain(unit)
		var room := maxi(unit.stat(BattleUnit.MAX_MP) - mp, 0) if unit.asc.has_attribute(BattleUnit.MAX_MP) else 0
		tally["spGained"] += mini(gain, room) / 100
		tally["capWaste"] += maxi(gain - room, 0) / 100
	else:
		var cost := CostReader.sp_cost(ability, unit.asc)
		if cost > 0:
			tally["abilities"] += 1
			tally["spSpent"] += cost / 100


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
	var boss_sp := {}  # spec skill-points 5: the party's SP% entering each boss, beside its HP%
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
			if summary.has("keysFound"):
				# Spec keys-and-gear 5: totals over the runs, only when the run uses keys.
				var totals: Dictionary = report.get_or_add("keys", {"found": 0, "spent": 0, "chestsOpened": 0,
					"chestsLeft": 0, "lockedLeft": 0})
				for pair in [["found", "keysFound"], ["spent", "keysSpent"], ["chestsOpened", "chestsOpened"],
						["chestsLeft", "chestsLeft"], ["lockedLeft", "lockedLeft"]]:
					totals[pair[0]] += int(summary.get(pair[1], 0))
		for entry in record["bossEntry"]:
			var key := "floor %d" % entry["floor"]
			if not boss_hp.has(key):
				var values: Array[int] = []
				boss_hp[key] = values
			boss_hp[key].append(int(entry["hpPercent"]))
			if not boss_sp.has(key):
				var sp_values: Array[int] = []
				boss_sp[key] = sp_values
			boss_sp[key].append(int(entry.get("mpPercent", 0)))
		for battle in record["battles"]:
			if not turns.has(battle["encounter"]):
				var values: Array[int] = []
				turns[battle["encounter"]] = values
			turns[battle["encounter"]].append(int(battle["turns"]))
			for case in battle.get("refused", {}):
				report["refused"][case] = report["refused"].get(case, 0) + battle["refused"][case]
		for case in record.get("runRefused", {}):
			report["refused"][case] = report["refused"].get(case, 0) + record["runRefused"][case]
		report["violations"].append_array(record["violations"])
		for text in record.get("errors", []):
			report["errors"].append({"seed": record["seed"], "error": text})
		report["runs"].append({"seed": record["seed"], "status": record["status"], "stop": record["stop"],
			"runnerError": record["runnerError"], "party": record["party"], "floorReached": summary.get("floorReached", 0),
			"battles": record["battles"].size(), "violations": record["violations"].size(), "runHash": record["runHash"]})
	report["winPercentX100"] = report["won"] * 10000 / count if count > 0 else 0
	for key in boss_hp:
		report["bossEntryHpPercent"][key] = spread(boss_hp[key])
	var boss_sp_spread := {}
	for key in boss_sp:
		boss_sp_spread[key] = spread(boss_sp[key])
	report["bossEntrySpPercent"] = SeedReport._sorted(boss_sp_spread)
	for key in turns:
		report["turnsPerBattle"][key] = spread(turns[key])
	report["coinsSpent"] = spread(coins)
	for key in ["deaths", "floorReached", "bossEntryHpPercent", "turnsPerBattle", "refused", "bySize", "byCharacter",
			"byParty"]:
		report[key] = SeedReport._sorted(report[key])
	report["seedSet"] = str(opts.get("seed_set", ""))
	var sp := {}
	for record in runs:
		var by_class: Dictionary = record.get("sp", {})
		for id in by_class:
			var total: Dictionary = sp.get_or_add(id, {"basics": 0, "abilities": 0, "spGained": 0, "spSpent": 0, "capWaste": 0})
			for key in total:
				total[key] += int(by_class[id].get(key, 0))
	for id in sp:
		sp[id]["basicsPerAbilityX100"] = sp[id]["basics"] * 100 / maxi(sp[id]["abilities"], 1)
	report["sp"] = SeedReport._sorted(sp)
	# Spec skill-points 5: per class, the runs that reached each level skill; per enemy secret skill, battles and uses.
	var learned := {}
	var secret := {}
	for record in runs:
		var by_class: Dictionary = record.get("learned", {})
		for id in by_class:
			var tally: Dictionary = learned.get_or_add(id, {"runs": 0})
			tally["runs"] += 1
			for tag in by_class[id]:
				tally[tag] = int(tally.get(tag, 0)) + 1
		var by_skill: Dictionary = record.get("secret", {})
		for key in by_skill:
			var total: Dictionary = secret.get_or_add(key, {"battles": 0, "uses": 0})
			total["battles"] += int(by_skill[key]["battles"])
			total["uses"] += int(by_skill[key]["uses"])
	report["levelSkills"] = SeedReport._sorted(learned)
	report["secretSkills"] = SeedReport._sorted(secret)
	report["analysis"] = analyze(runs, report["byCharacter"])
	return report


## Spec skill-points 4.3, 4.4, D26: the death map (where runs end), party composition (pairs, features, sound
## parties) and the bosses' win rates by pieces held. Whole numbers; rates are percents ×100.
@warning_ignore("integer_division")
static func analyze(runs: Array[Dictionary], by_character: Dictionary) -> Dictionary:
	var lost_runs := 0
	var by_floor := {}         # floor -> losses
	var reached := {}          # floor -> runs that entered it
	var by_chapter := {}       # chapter -> losses
	var encounters := {}       # encounter -> {"battles", "losses", "won"}
	var end_hp: Array[int] = []
	var end_mp: Array[int] = []
	var end_level: Array[int] = []
	var turn_limits := {}
	var by_route := {}         # chapter of floor 9 -> {"runs", "won"}
	var held_by_boss := {}     # boss encounter -> held -> {"battles", "won"}
	var pairs := {}
	var features := {}
	var sound := {"runs": 0, "won": 0}
	for record in runs:
		if record["runnerError"] != "" or record["stop"] != "":
			continue
		var won_run := 1 if record["status"] == RunState.WON else 0
		var battles: Array = record["battles"]
		var floor_reached := int(record["summary"].get("floorReached", 0))
		for floor_number in range(1, floor_reached + 1):
			reached[floor_number] = int(reached.get(floor_number, 0)) + 1
		var route := ""
		for battle in battles:
			var name := str(battle["encounter"])
			var tally: Dictionary = encounters.get_or_add(name, {"battles": 0, "losses": 0, "won": 0})
			tally["battles"] += 1
			if battle["outcome"] == Battle.VICTORY:
				tally["won"] += 1
			if battle["outcome"] == Battle.TURN_LIMIT_OUTCOME:
				turn_limits[name] = int(turn_limits.get(name, 0)) + 1
			if int(battle["floor"]) == 9 and route == "":
				route = str(battle.get("chapter", ""))
			if bool(battle["boss"]) and battle.has("held"):
				var buckets: Dictionary = held_by_boss.get_or_add(name, {})
				var bucket: Dictionary = buckets.get_or_add(int(battle["held"]), {"battles": 0, "won": 0})
				bucket["battles"] += 1
				bucket["won"] += 1 if battle["outcome"] == Battle.VICTORY else 0
		if route != "":
			var routed: Dictionary = by_route.get_or_add(route, {"runs": 0, "won": 0})
			routed["runs"] += 1
			routed["won"] += won_run
		if record["status"] == RunState.LOST and not battles.is_empty():
			lost_runs += 1
			var last: Dictionary = battles.back()
			by_floor[int(last["floor"])] = int(by_floor.get(int(last["floor"]), 0)) + 1
			var chapter := str(last.get("chapter", ""))
			by_chapter[chapter] = int(by_chapter.get(chapter, 0)) + 1
			encounters[str(last["encounter"])]["losses"] += 1
			if last.has("hpPercent"):
				end_hp.append(int(last["hpPercent"]))
				end_mp.append(int(last["mpPercent"]))
				end_level.append(int(last["level"]))
		var party: Array = record["party"].duplicate()
		party.sort()
		for i in party.size():
			for j in range(i + 1, party.size()):
				var key := "%s+%s" % [str(party[i]).trim_prefix("demo.character."), str(party[j]).trim_prefix("demo.character.")]
				var pair: Dictionary = pairs.get_or_add(key, {"runs": 0, "won": 0, "a": str(party[i]), "b": str(party[j])})
				pair["runs"] += 1
				pair["won"] += won_run
		var traits: Dictionary = record.get("features", {})
		for feature in traits:
			var value: Variant = traits[feature]
			var label := "%s %d" % [feature, int(value)] if feature == "damageTypes" else ("%s %s" % [feature, "yes" if value else "no"])
			var tally: Dictionary = features.get_or_add(label, {"runs": 0, "won": 0})
			tally["runs"] += 1
			tally["won"] += won_run
		if bool(traits.get("sound", false)):
			sound["runs"] += 1
			sound["won"] += won_run
	# The death map.
	var losses_by_encounter := {}
	var shares: Array = []
	for name in encounters:
		var tally: Dictionary = encounters[name]
		if tally["losses"] == 0:
			continue
		losses_by_encounter[name] = {"losses": tally["losses"], "battles": tally["battles"],
			"shareX100": tally["losses"] * 10000 / maxi(lost_runs, 1), "lossPerAttemptX100": tally["losses"] * 10000 / tally["battles"]}
		shares.append([tally["losses"], name])
	shares.sort_custom(func(a, b) -> bool: return a[0] > b[0] or (a[0] == b[0] and a[1] < b[1]))
	var top3 := 0
	for entry in shares.slice(0, 3):
		top3 += int(entry[0])
	var loss_rate_by_floor := {}
	for floor_number in by_floor:
		loss_rate_by_floor[str(floor_number)] = by_floor[floor_number] * 10000 / maxi(int(reached.get(floor_number, 0)), 1)
	var worst_floor := ""
	for floor_number in loss_rate_by_floor:
		if worst_floor == "" or loss_rate_by_floor[floor_number] > loss_rate_by_floor[worst_floor]:
			worst_floor = floor_number
	var floors := {}
	for floor_number in by_floor:
		floors[str(floor_number)] = {"losses": by_floor[floor_number], "entered": int(reached.get(floor_number, 0)),
			"lossRateX100": loss_rate_by_floor[str(floor_number)]}
	var death_map := {"lostRuns": lost_runs, "byFloor": SeedReport._sorted(floors), "byChapter": SeedReport._sorted(by_chapter),
		"byEncounter": SeedReport._sorted(losses_by_encounter), "turnLimits": SeedReport._sorted(turn_limits),
		"concentration": {"top": shares[0][1] if not shares.is_empty() else "",
			"topShareX100": int(shares[0][0]) * 10000 / maxi(lost_runs, 1) if not shares.is_empty() else 0,
			"top3ShareX100": top3 * 10000 / maxi(lost_runs, 1), "worstFloor": worst_floor},
		"endEntry": {"hpPercent": spread(end_hp), "mpPercent": spread(end_mp), "level": spread(end_level)}}
	# Pairs: the pair's win rate minus the mean of its two classes' rates (lift).
	for key in pairs:
		var pair: Dictionary = pairs[key]
		var rate: int = pair["won"] * 10000 / pair["runs"]
		var expected := 0
		for side in ["a", "b"]:
			var tally: Dictionary = by_character.get(pair[side], {"runs": 1, "won": 0})
			expected += int(tally["won"]) * 10000 / maxi(int(tally["runs"]), 1)
		pairs[key] = {"runs": pair["runs"], "won": pair["won"], "winX100": rate, "liftX100": rate - expected / 2}
	# Bosses by pieces held: the crossing point is the smallest count from which every pooled rate (that count and
	# up) is at least 50%; -1 when there is none.
	var held := {}
	for name in held_by_boss:
		var buckets: Dictionary = held_by_boss[name]
		var counts: Array = buckets.keys()
		counts.sort()
		var crossing := -1
		for index in range(counts.size() - 1, -1, -1):
			var battles := 0
			var won := 0
			for later in counts.slice(index):
				battles += buckets[later]["battles"]
				won += buckets[later]["won"]
			if won * 2 >= battles:
				crossing = counts[index]
			else:
				break
		var table := {}
		for count in counts:
			table[str(count)] = buckets[count]
		held[name] = {"byHeld": table, "crossing": crossing}
	return {"deathMap": death_map, "byRoute": SeedReport._sorted(by_route), "byPair": SeedReport._sorted(pairs),
		"byFeature": SeedReport._sorted(features), "sound": sound, "heldByBoss": SeedReport._sorted(held)}


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
	if str(report.get("seedSet", "")) != "":
		lines[0] = lines[0].split(", seeds ")[0] + ", %d seeds from %s" % [report["count"], report["seedSet"]]
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
	for key in report.get("bossEntrySpPercent", {}):
		var sp_entry: Dictionary = report["bossEntrySpPercent"][key]
		lines.append("  boss entry SP %%, %s: min %d  median %d  max %d" % [key, sp_entry["min"], sp_entry["median"],
			sp_entry["max"]])
	for key in report["turnsPerBattle"]:
		var spread_entry: Dictionary = report["turnsPerBattle"][key]
		lines.append("  turns, %s: median %d  max %d" % [key, spread_entry["median"], spread_entry["max"]])
	if not report["coinsSpent"].is_empty():
		lines.append("  coins spent per run: median %d  max %d" % [report["coinsSpent"]["median"], report["coinsSpent"]["max"]])
	if report.has("keys"):
		var keys: Dictionary = report["keys"]
		lines.append("  keys found %d  spent %d  ·  chests opened %d, left %d  ·  locked rooms left %d (all runs)" % [
			keys["found"], keys["spent"], keys["chestsOpened"], keys["chestsLeft"], keys["lockedLeft"]])
	if report["policy"] == "chaos":
		lines.append("  illegal moves refused: %s" % _pairs(report["refused"]))
	if not report.get("sp", {}).is_empty():
		var parts := PackedStringArray()
		for id in report["sp"]:
			var tally: Dictionary = report["sp"][id]
			parts.append("%s %.1f (%d SP gained, %d spent, %d lost at the cap)" % [id, tally["basicsPerAbilityX100"] / 100.0,
				tally["spGained"], tally["spSpent"], tally["capWaste"]])
		lines.append("  basics per costed ability: %s" % ", ".join(parts))
	for id in report.get("levelSkills", {}):
		var tally: Dictionary = report["levelSkills"][id]
		var parts := PackedStringArray()
		for tag in tally:
			if tag != "runs":
				parts.append("%s %d" % [String(tag).trim_prefix("Ability.").trim_prefix("Passive."), tally[tag]])
		if not parts.is_empty():
			lines.append("  %s reached (of %d runs): %s" % [id, tally["runs"], ", ".join(parts)])
	var secrets := PackedStringArray()
	for key in report.get("secretSkills", {}):
		secrets.append("%s %d battles, %d uses" % [key, report["secretSkills"][key]["battles"], report["secretSkills"][key]["uses"]])
	if not secrets.is_empty():
		lines.append("  secret skills: %s" % ", ".join(secrets))
	if report.has("analysis"):
		lines.append_array(analysis_text(report["analysis"]))
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


## Spec skill-points 4.3, 4.4, D26: the analysis as text lines.
@warning_ignore("integer_division")
static func analysis_text(analysis: Dictionary) -> PackedStringArray:
	var lines := PackedStringArray()
	var death: Dictionary = analysis["deathMap"]
	var concentration: Dictionary = death["concentration"]
	lines.append("  death map (%d lost runs): top %s %s, top three %s, worst floor %s" % [death["lostRuns"],
		concentration["top"], _pct(concentration["topShareX100"]), _pct(concentration["top3ShareX100"]),
		concentration["worstFloor"]])
	var floors := PackedStringArray()
	for floor_number in death["byFloor"]:
		var entry: Dictionary = death["byFloor"][floor_number]
		floors.append("%s: %d/%d (%s)" % [floor_number, entry["losses"], entry["entered"], _pct(entry["lossRateX100"])])
	lines.append("    losses/entered by floor: %s" % ", ".join(floors))
	lines.append("    losses by chapter: %s" % _pairs(death["byChapter"], true))
	var ranked: Array = death["byEncounter"].keys()
	ranked.sort_custom(func(a, b) -> bool: return death["byEncounter"][a]["losses"] > death["byEncounter"][b]["losses"] 		or (death["byEncounter"][a]["losses"] == death["byEncounter"][b]["losses"] and a < b))
	for name in ranked.slice(0, 10):
		var entry: Dictionary = death["byEncounter"][name]
		lines.append("    %s: %d losses (%s of losses), %d battles, %s lost per attempt" % [name, entry["losses"],
			_pct(entry["shareX100"]), entry["battles"], _pct(entry["lossPerAttemptX100"])])
	var end: Dictionary = death["endEntry"]
	if not end["hpPercent"].is_empty():
		lines.append("    entering the last battle: HP%% median %d, MP%% median %d, level median %d" % [
			end["hpPercent"]["median"], end["mpPercent"]["median"], end["level"]["median"]])
	if not death["turnLimits"].is_empty():
		lines.append("    turn limits: %s" % _pairs(death["turnLimits"], true))
	var routes := PackedStringArray()
	for route in analysis["byRoute"]:
		routes.append("%s %d/%d" % [route, analysis["byRoute"][route]["won"], analysis["byRoute"][route]["runs"]])
	if not routes.is_empty():
		lines.append("  won/runs by floor-9 chapter: %s" % ", ".join(routes))
	var sound: Dictionary = analysis["sound"]
	lines.append("  sound parties (a healer and 2+ damage types): %d/%d (%s)" % [sound["won"], sound["runs"],
		_pct(sound["won"] * 10000 / maxi(sound["runs"], 1))])
	var features := PackedStringArray()
	for label in analysis["byFeature"]:
		var tally: Dictionary = analysis["byFeature"][label]
		features.append("%s %d/%d" % [label, tally["won"], tally["runs"]])
	lines.append("  won/runs by feature: %s" % ", ".join(features))
	var pairs: Array = analysis["byPair"].keys()
	pairs.sort_custom(func(a, b) -> bool: return analysis["byPair"][a]["liftX100"] > analysis["byPair"][b]["liftX100"] 		or (analysis["byPair"][a]["liftX100"] == analysis["byPair"][b]["liftX100"] and a < b))
	var best := PackedStringArray()
	for key in pairs.slice(0, 5):
		best.append("%s %s (%+.1f)" % [key, _pct(analysis["byPair"][key]["winX100"]), analysis["byPair"][key]["liftX100"] / 100.0])
	var worst := PackedStringArray()
	for key in pairs.slice(maxi(pairs.size() - 5, 0)):
		worst.append("%s %s (%+.1f)" % [key, _pct(analysis["byPair"][key]["winX100"]), analysis["byPair"][key]["liftX100"] / 100.0])
	if not pairs.is_empty():
		lines.append("  best pairs by lift: %s" % ", ".join(best))
		lines.append("  worst pairs by lift: %s" % ", ".join(worst))
	for name in analysis["heldByBoss"]:
		var boss: Dictionary = analysis["heldByBoss"][name]
		var cells := PackedStringArray()
		for count in boss["byHeld"]:
			cells.append("%s: %d/%d" % [count, boss["byHeld"][count]["won"], boss["byHeld"][count]["battles"]])
		lines.append("  %s won/fought by pieces held: %s; crossing %s" % [name, ", ".join(cells),
			str(boss["crossing"]) if int(boss["crossing"]) >= 0 else "none"])
	return lines


## Spec skill-points D27: what changed between two reports (old → new), as text lines.
@warning_ignore("integer_division")
static func compare_text(old: Dictionary, latest: Dictionary) -> PackedStringArray:
	var lines := PackedStringArray(["compare (old → new):"])
	lines.append("  win rate %s → %s" % [_pct(int(old["winPercentX100"])), _pct(int(latest["winPercentX100"]))])
	if old.has("analysis") and latest.has("analysis"):
		var a: Dictionary = old["analysis"]["sound"]
		var b: Dictionary = latest["analysis"]["sound"]
		lines.append("  sound parties %s → %s" % [_pct(int(a["won"]) * 10000 / maxi(int(a["runs"]), 1)),
			_pct(int(b["won"]) * 10000 / maxi(int(b["runs"]), 1))])
	var classes := PackedStringArray()
	for id in latest["byCharacter"]:
		var after: Dictionary = latest["byCharacter"][id]
		var before: Dictionary = old["byCharacter"].get(id, {"runs": 0, "won": 0})
		classes.append("%s %s → %s" % [String(id).trim_prefix("demo.character."),
			_pct(int(before["won"]) * 10000 / maxi(int(before["runs"]), 1)), _pct(int(after["won"]) * 10000 / maxi(int(after["runs"]), 1))])
	lines.append("  by class: %s" % ", ".join(classes))
	if old.has("analysis") and latest.has("analysis"):
		var before: Dictionary = old["analysis"]["deathMap"]["byEncounter"]
		var after: Dictionary = latest["analysis"]["deathMap"]["byEncounter"]
		var names: Array = before.keys()
		for name in after:
			if not names.has(name):
				names.append(name)
		names.sort()
		for name in names:
			var x: int = int(before.get(name, {}).get("losses", 0))
			var y: int = int(after.get(name, {}).get("losses", 0))
			if x != y:
				lines.append("  losses at %s: %d → %d" % [name, x, y])
	return lines


static func _pct(value_x100: int) -> String:
	return "%.1f%%" % (value_x100 / 100.0)


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
