## Spec run-verify 6 (Godot side): the step runner on the committed scripted runs. A server-mode run is played with its
## journal on, its log is cut into steps exactly as the server cuts it (at every snapshot-bearing action), and each step goes
## through StepRunner as the worker would send it. Fixtures only.
##   G1 every step of both runs verifies, and the steps link (a step's end hash is the next one's start hash), also with every
##      object key reversed (the verifier reads data jsonb has reordered);
##   G2 one tampered copy per reason, naming the first divergent action;
##   G3 the floor digest; G4 which snapshot fields run_hash() covers; G5 a floor seed that reaches the client late.
extends TestCase

const PARTY: Array = ["fixture.character.knight", "fixture.character.medic", "fixture.character.rogue"]
const TWO_FLOORS: StringName = &"fixture.run.two_floors"
const RUN_ID: String = "019a2b3c-4d5e-7f60-8a7b-8c9d0e1f2a3b"
const SEEDS: Array = [5150, 777]

var _nodes: Array[Node] = []


func after_each() -> void:
	for node in _nodes:
		if is_instance_valid(node):
			node.queue_free()
	_nodes.clear()
	super()


# --- Building a run and its steps ---------------------------------------------------------------------------------------

## A server-mode run played to the end of its floors, the way a linked client does it: the journal on, every logged request
## through JSON as the server stores it, a floor's seed handed over the moment it is asked for (`late`: held back until
## `provide_late()` so the run waits at the stairs).
func _play(content: ContentIndex, structure: StringName, late: bool = false, steps: int = 400, seeds: Array = SEEDS,
		pool: Variant = null) -> Dictionary:
	var requests: Array = []
	var ends: Array = []
	var run: RunController = RunController.new()
	host.add_child(run)
	_nodes.append(run)
	run.journal = true
	run.actions_committed.connect(func(sent: Array) -> void: requests.append_array(JSON.parse_string(WireJson.stringify(sent))))
	run.run_verifying.connect(func(end_request: Dictionary) -> void: ends.append(JSON.parse_string(WireJson.stringify(end_request))))
	if not late:
		run.floor_seed_needed.connect(func(floor_index: int) -> void: run.provide_floor_seed(floor_index, seeds[floor_index]))
	eq(run.start_server_run(content, PARTY, RUN_ID, seeds[0], structure, pool), "", "the run starts")
	var stopped: String = await RunPlayer.play(run, steps)
	return {"run": run, "requests": requests, "stopped": stopped, "end": ends[0] if not ends.is_empty() else {}, "pool": pool}


## The server's cut: a genesis step (0 to 1), then one step per snapshot-bearing action after seq 1; a won run's end request
## adds the End step (the last battle's checkpoint to the end's seq). Every StepRequest goes through JSON, so numbers are floats and keys are as the worker would send them.
func _steps(_content: ContentIndex, structure: StringName, played: Dictionary) -> Array[Dictionary]:
	var requests: Array = played["requests"]
	var run: RunController = played["run"]
	var seeds := {}
	for floor_index in run.state.floor_seeds:
		seeds[str(floor_index)] = str(run.state.floor_seeds[floor_index])
	var base := {"schemaVersion": 1, "runId": RUN_ID, "runStructureId": String(structure), "characterIds": PARTY, "floorSeeds": seeds}
	if played.get("pool") != null:
		base["cardPool"] = played["pool"].map(func(id: Variant) -> String: return String(id))  # the server's own, from `runs`
	var steps: Array[Dictionary] = []
	var genesis := base.duplicate()
	genesis.merge({"fromSeq": 0, "toSeq": 1, "kind": "Genesis", "startSnapshot": null, "startStateHash": null, "actions": [],
		"endRunHash": null})
	steps.append(_wire(genesis))
	var checkpoints: Array = []
	for request in requests:
		if request.has("snapshot"):
			checkpoints.append(int(request["seq"]))
	for index in range(1, checkpoints.size()):
		var from_seq: int = checkpoints[index - 1]
		var to_seq: int = checkpoints[index]
		var start: Dictionary = requests[from_seq - 1]
		var end: Dictionary = requests[to_seq - 1]
		var step := base.duplicate()
		step.merge({"fromSeq": from_seq, "toSeq": to_seq, "kind": "Battle" if end["action"]["type"] == "battle" else "Segment",
			"startSnapshot": start["snapshot"], "startStateHash": start["stateHash"],
			"actions": requests.slice(from_seq, to_seq).map(_without_snapshot), "endRunHash": null})
		steps.append(_wire(step))
	var end_request: Dictionary = played["end"]
	if not end_request.is_empty():
		var from_seq: int = checkpoints[-1]
		var start: Dictionary = requests[from_seq - 1]
		var end := base.duplicate()
		var end_action := {"seq": int(end_request["seq"]), "action": {"type": "end", "floor": run.state.floor_index},
			"stateHash": end_request["runHash"], "playedAt": "2026-11-08T12:00:00Z"}
		end.merge({"fromSeq": from_seq, "toSeq": int(end_request["seq"]), "kind": "End", "startSnapshot": start["snapshot"],
			"startStateHash": start["stateHash"], "actions": requests.slice(from_seq).map(_without_snapshot) + [end_action],
			"endRunHash": end_request["runHash"]})
		steps.append(_wire(end))
	return steps


static func _without_snapshot(request: Dictionary) -> Dictionary:
	var copy := request.duplicate(true)
	copy.erase("snapshot")
	return copy


static func _wire(value: Dictionary) -> Dictionary:
	return JSON.parse_string(WireJson.stringify(value))


static func _reversed(value: Variant) -> Variant:
	if value is Dictionary:
		var keys: Array = value.keys()
		keys.reverse()
		var result := {}
		for key in keys:
			result[key] = _reversed(value[key])
		return result
	if value is Array:
		return value.map(func(item: Variant) -> Variant: return _reversed(item))
	return value


func _verify(content: ContentIndex, step: Dictionary) -> Dictionary:
	var runner := StepRunner.new()
	var verdict := await runner.run_on(step.duplicate(true), content, host)
	verdict["_exit"] = runner.exit_code
	return verdict


func _all_verify(content: ContentIndex, steps: Array[Dictionary], label: String) -> Array[Dictionary]:
	var verdicts: Array[Dictionary] = []
	for step in steps:
		var verdict := await _verify(content, step)
		eq(verdict.get("status"), "Verified", "%s: step %s..%s (%s) verifies: %s" % [label, step["fromSeq"], step["toSeq"], step["kind"],
			verdict.get("mismatch", verdict)])
		eq(verdict["_exit"], StepRunner.EXIT_VERIFIED, "%s: exit 0" % label)
		verdicts.append(verdict)
	return verdicts


# --- G1: the goldens ----------------------------------------------------------------------------------------------------

func _check_links(content: ContentIndex, structure: StringName, label: String) -> void:
	var played := await _play(content, structure)
	var run: RunController = played["run"]
	eq(run.runner_error, "", "%s: no runner error" % label)
	var steps := _steps(content, structure, played)
	check(steps.size() >= 5, "%s: several steps (%d)" % [label, steps.size()])
	var verdicts := await _all_verify(content, steps, label)
	var requests: Array = played["requests"]
	eq(verdicts[0]["endHash"], requests[0]["stateHash"], "%s: the server's own start hashes as the client's seq 1" % label)
	eq(WireJson.stringify(verdicts[0]["endSnapshot"]["map"]), WireJson.stringify(requests[0]["snapshot"]["map"]),
		"%s: with the same floor map" % label)
	for index in range(1, verdicts.size()):
		eq(verdicts[index]["startHash"], verdicts[index - 1]["endHash"], "%s: step %d starts where step %d ended" % [label, index, index - 1])
	var last: Dictionary = verdicts[-1]
	eq(last["endHash"], str(requests[int(steps[-1]["toSeq"]) - 1]["stateHash"]), "%s: the last verified hash is the log's" % label)
	# The verifier reads data that jsonb has reordered: every key order must verify the same.
	for index in [1, steps.size() - 1]:
		var reordered: Dictionary = _reversed(steps[index])
		var verdict := await _verify(content, reordered)
		eq(verdict.get("status"), "Verified", "%s: step %d verifies with every key reversed" % [label, index])
		eq(verdict.get("endHash"), verdicts[index]["endHash"], "%s: to the same hash" % label)


func test_steps_verify_and_link_on_the_scripted_run() -> void:
	await _check_links(fixtures(), TWO_FLOORS, "scripted run")


func test_steps_verify_and_link_on_the_keyed_run() -> void:
	await _check_links(KeysWorld.content(), KeysWorld.RUN_ID, "keyed run")


func test_a_battle_is_simulated_once_and_its_result_comes_with_the_step() -> void:
	var content := fixtures()
	var played := await _play(content, TWO_FLOORS)
	var steps := _steps(content, TWO_FLOORS, played)
	var battle_steps := steps.filter(func(step: Dictionary) -> bool: return step["kind"] == "Battle")
	check(not battle_steps.is_empty(), "the run has a battle step")
	for step in battle_steps:
		var verdict := await _verify(content, step)
		eq(verdict["battles"].size(), 1, "one result for the one battle")
		var result: Dictionary = verdict["battles"][0]
		var logged: Dictionary = step["actions"][-1]["action"]["battle"]
		eq(result["verdict"], "Verified", "the battle verifies")
		eq(result["battleId"], logged["battleId"], "it is that battle")
		# The same request through the replay runner alone gives the same result: this is the verdict slice 3 gave.
		var alone: Dictionary = await ReplayRunner.new().run({"snapshot": logged["conditions"], "actionLog": logged["actionLog"]},
			TestCase.FIXTURES, host)
		eq(result["finalStateHash"], alone["finalStateHash"], "the final hash is the replay runner's")
		eq(result["outcome"], alone["outcome"], "and so is the outcome")
		eq(WireJson.stringify(result.get("facts")), WireJson.stringify(alone.get("facts")), "and the facts")


func test_a_won_run_verifies_its_end_step_and_nothing_else_is_a_win() -> void:
	var content := fixtures()
	var played := {}
	for attempt in 16:   # a few floor-seed pairs until the scripted party wins
		for node in _nodes:
			node.queue_free()
		_nodes.clear()
		played = await _play(content, TWO_FLOORS, false, 400, [5150 + attempt * 13, 777 + attempt * 7])
		if played["run"].state.status == RunState.WON:
			break
	var run: RunController = played["run"]
	eq(run.state.status, RunState.WON, "a scripted run is won")
	var steps := _steps(content, TWO_FLOORS, played)
	eq(steps[-1]["kind"], "End", "the win adds an End step")
	var verdicts := await _all_verify(content, steps, "won run")
	eq(verdicts[-1]["endHash"], str(played["end"]["runHash"]), "the end step ends at the run hash the client sent")
	# A step that ends with the run still active is no win, whatever the client calls it.
	var segment := steps[1].duplicate(true)
	segment["kind"] = "End"
	segment["endRunHash"] = segment["actions"][-1]["stateHash"]
	var unwon := await _verify(content, segment)
	eq(unwon["mismatch"]["reason"], "NotWon", "a step that ends with the run still active is not a win")
	eq(unwon["_exit"], StepRunner.EXIT_REJECTED, "exit 2")
	# A real End step with another run hash is not the win the log shows either.
	var forged := steps[-1].duplicate(true)
	forged["endRunHash"] = "f".repeat(64)
	await _expect(content, forged, "NotWon", int(forged["toSeq"]), "a forged end hash")


# --- G2: tampering, one reason at a time -------------------------------------------------------------------------------

func _tamper_base() -> Dictionary:
	var content := fixtures()
	var played := await _play(content, TWO_FLOORS)
	return {"content": content, "steps": _steps(content, TWO_FLOORS, played)}


func _expect(content: ContentIndex, step: Dictionary, reason: String, seq: int, message: String) -> void:
	var verdict := await _verify(content, step)
	eq(verdict.get("status"), "Rejected", "%s: rejected" % message)
	eq(verdict.get("errorCode"), 2002, "%s: 2002" % message)
	eq(verdict["mismatch"]["reason"], reason, "%s: the reason (%s)" % [message, verdict["mismatch"]])
	if seq >= 0:
		eq(int(verdict["mismatch"]["seq"]), seq, "%s: the first divergent action" % message)
	eq(verdict["_exit"], StepRunner.EXIT_REJECTED, "%s: exit 2" % message)


func _first_segment(steps: Array[Dictionary], min_actions: int = 2) -> Dictionary:
	for step in steps:
		if step["kind"] == "Segment" and step["actions"].size() >= min_actions:
			return step.duplicate(true)
	return {}


func test_a_flipped_state_hash_is_named_at_its_action() -> void:
	var base := await _tamper_base()
	var step := _first_segment(base["steps"])
	var target: Dictionary = step["actions"][0]
	target["stateHash"] = "0".repeat(64)
	await _expect(base["content"], step, "StateHashMismatch", int(target["seq"]), "a flipped hash")


func test_a_dropped_action_is_refused_or_hashes_wrong() -> void:
	var base := await _tamper_base()
	var step := _first_segment(base["steps"], 3)
	var dropped: Dictionary = step["actions"].pop_front()
	var verdict := await _verify(base["content"], step)
	eq(verdict.get("status"), "Rejected", "a missing action is rejected (%s)" % dropped["seq"])
	check(verdict["mismatch"]["reason"] in ["ActionRefused", "StateHashMismatch"], "as a refused action or a wrong hash: %s" % verdict["mismatch"])


func test_a_snapshot_that_is_not_its_claimed_hash() -> void:
	var base := await _tamper_base()
	var step := _first_segment(base["steps"])
	step["startSnapshot"]["run"]["coins"] = int(step["startSnapshot"]["run"]["coins"]) + 500   # a richer start, the same claimed hash
	await _expect(base["content"], step, "SnapshotHashMismatch", int(step["fromSeq"]), "a forged start snapshot")


func test_a_start_that_differs_in_what_the_hash_used_to_miss_is_a_hash_mismatch() -> void:
	var base := await _tamper_base()
	# Spec run-verify: the run hash covers everything that decides play, so a gift, an open event or a pending battle smuggled into a
	# claimed start state changes the hash and is named at the step's start, with no separate snapshot comparison.
	var gift := _first_segment(base["steps"])
	gift["startSnapshot"]["run"]["pendingGifts"] = ["fixture.item.potion"]
	await _expect(base["content"], gift, "SnapshotHashMismatch", int(gift["fromSeq"]), "a gift the replay never made")
	var event := _first_segment(base["steps"])
	event["startSnapshot"]["run"]["event"] = {"cell": 0, "event": "fixture.event.none", "page": 0}
	await _expect(base["content"], event, "SnapshotHashMismatch", int(event["fromSeq"]), "an event page that was never opened")
	var battle: Dictionary = base["steps"].filter(func(candidate: Dictionary) -> bool: return candidate["kind"] == "Battle")[0].duplicate(true)
	battle["startSnapshot"]["pendingBattle"]["enemies"] = []
	await _expect(base["content"], battle, "SnapshotHashMismatch", int(battle["fromSeq"]), "a pending battle with its enemies removed")


func test_a_foreign_floor_seed_is_named() -> void:
	var base := await _tamper_base()
	var step: Dictionary = base["steps"][-1].duplicate(true)   # the last step: the run is on floor 1, so its snapshot holds floor 1's seed
	step["startSnapshot"]["run"]["floorSeeds"]["0"] = "12345"   # floor 0's seed is not in the hash once the run is on floor 1
	await _expect(base["content"], step, "ForeignSeed", int(step["fromSeq"]), "a seed the server did not issue")


func test_another_party_or_run_is_wrong_setup() -> void:
	var base := await _tamper_base()
	var step := _first_segment(base["steps"])
	step["characterIds"] = ["fixture.character.knight"]
	await _expect(base["content"], step, "WrongSetup", int(step["fromSeq"]), "another party")
	step = _first_segment(base["steps"])
	step["runId"] = "another-run"
	await _expect(base["content"], step, "WrongSetup", int(step["fromSeq"]), "another run id")


func test_fabricated_battle_conditions_are_named() -> void:
	var base := await _tamper_base()
	var step: Dictionary = base["steps"].filter(func(candidate: Dictionary) -> bool: return candidate["kind"] == "Battle")[0].duplicate(true)
	var conditions: Dictionary = step["actions"][-1]["action"]["battle"]["conditions"]
	conditions["enemies"] = conditions["enemies"].slice(0, 0)   # an easy battle: nobody to fight
	await _expect(base["content"], step, "ConditionsMismatch", int(step["actions"][-1]["seq"]), "fabricated conditions")


func test_a_flipped_battle_outcome_rejects_the_step_and_the_battle() -> void:
	var base := await _tamper_base()
	var step: Dictionary = base["steps"].filter(func(candidate: Dictionary) -> bool: return candidate["kind"] == "Battle")[0].duplicate(true)
	var log: Dictionary = step["actions"][-1]["action"]["battle"]["actionLog"]
	log["claimedOutcome"] = "Defeat" if log["claimedOutcome"] != "Defeat" else "Victory"
	var verdict := await _verify(base["content"], step)
	eq(verdict["mismatch"]["reason"], "BattleMismatch", "the step is rejected for the battle")
	eq(verdict["battles"].size(), 1, "and the battle's own result comes with it")
	eq(verdict["battles"][0]["verdict"], "Rejected", "rejected")
	eq(verdict["battles"][0]["mismatch"]["reason"], "OutcomeMismatch", "with the replay runner's reason")


func test_malformed_requests_are_exit_3_never_a_runner_error() -> void:
	var base := await _tamper_base()
	var good := _first_segment(base["steps"])
	var unknown_field := good.duplicate(true)
	unknown_field["surprise"] = 1
	var bad_schema := good.duplicate(true)
	bad_schema["schemaVersion"] = 9
	var no_actions := good.duplicate(true)
	no_actions["actions"] = []
	var bad_kind := good.duplicate(true)
	bad_kind["kind"] = "Teleport"
	var no_snapshot := good.duplicate(true)
	no_snapshot.erase("startSnapshot")
	var unknown_structure: Dictionary = base["steps"][0].duplicate(true)
	unknown_structure["runStructureId"] = "no.such.run"
	var thin_snapshot: Dictionary = good.duplicate(true)
	thin_snapshot["startSnapshot"] = {"schemaVersion": 1}
	var no_party_field: Dictionary = good.duplicate(true)
	no_party_field["startSnapshot"]["run"]["party"][0].erase("hp")
	var no_log_actions: Dictionary = base["steps"].filter(func(step: Dictionary) -> bool: return step["kind"] == "Battle")[0].duplicate(true)
	no_log_actions["actions"][-1]["action"]["battle"]["actionLog"].erase("actions")
	for request in [unknown_field, bad_schema, no_actions, bad_kind, no_snapshot, unknown_structure, thin_snapshot, no_party_field,
			no_log_actions]:
		var runner := StepRunner.new()
		var verdict := await runner.run_on(request, base["content"], host)
		eq(verdict.get("status"), "Rejected", "a refused request is a rejection: %s" % verdict)
		eq(verdict["mismatch"]["reason"], "MalformedRequest", "MalformedRequest")
		eq(runner.exit_code, StepRunner.EXIT_MALFORMED, "exit 3")
		eq(runner.runner_error, "", "and not a runner error")


func test_the_files_entry_writes_the_verdict_and_the_exit_code() -> void:
	var base := await _tamper_base()
	var folder := "user://test_step_%d" % Time.get_ticks_usec()
	DirAccess.make_dir_recursive_absolute(folder)
	var in_path := folder.path_join("request.json")
	var out_path := folder.path_join("verdict.json")
	var file := FileAccess.open(in_path, FileAccess.WRITE)
	file.store_string(WireJson.stringify(base["steps"][0]))
	file.close()
	var runner := StepRunner.new()
	var code: int = await runner.run_files(in_path, out_path, TestCase.FIXTURES, host)
	eq(code, StepRunner.EXIT_VERIFIED, "the genesis step of the fixtures verifies")
	var written: Variant = JSON.parse_string(FileAccess.get_file_as_string(out_path))
	check(written is Dictionary and written.get("status") == "Verified", "the verdict file is written")
	eq(await runner.run_files(folder.path_join("missing.json"), out_path, TestCase.FIXTURES, host), StepRunner.EXIT_RUNNER_ERROR,
		"an unreadable request file is a runner error (the worker wrote it, so that is not the client's fault)")
	DirAccess.remove_absolute(in_path)
	DirAccess.remove_absolute(out_path)
	DirAccess.remove_absolute(folder)


# --- G3: the floor digest -----------------------------------------------------------------------------------------------

func test_a_step_that_enters_a_floor_reports_its_digest() -> void:
	var content := fixtures()
	var played := await _play(content, TWO_FLOORS)
	var steps := _steps(content, TWO_FLOORS, played)
	var verdicts := await _all_verify(content, steps, "digest")
	check(verdicts[0].has("floorDigest"), "the genesis step entered floor 0")
	eq(int(verdicts[0]["floorDigest"]["floor"]), 0, "floor 0")
	var floors: Array = []
	for verdict in verdicts:
		if verdict.has("floorDigest"):
			floors.append(int(verdict["floorDigest"]["floor"]))
	eq(floors, [0, 1], "each floor is reported once, by the step that entered it")
	var first: Dictionary = verdicts[0]["floorDigest"]
	check(first["floorHash"] != "" and first["rooms"].size() > 1, "a hash and the rooms")
	var again := await _verify(content, steps[0])
	eq(WireJson.stringify(again["floorDigest"]), WireJson.stringify(first), "the digest is stable")
	var other := {}
	for verdict in verdicts:
		if verdict.has("floorDigest") and int(verdict["floorDigest"]["floor"]) == 1:
			other = verdict["floorDigest"]
	check(other.get("floorHash", "") != first["floorHash"], "and differs between floors")


# --- G4: what the run hash covers ---------------------------------------------------------------------------------------

## Snapshot paths the run hash deliberately leaves out, with the reason (RunState.canonical_lines): the run's id (identity, compared
## by the step against the run itself), the issued seeds of floors the run is not on (the current floor's is hashed; the server's
## own are the reference), the console-cheat counter, how many attempts the floor generator needed, and the summaries and network
## bookkeeping that no rule reads. Paths use "/" between keys and "[n]" for arrays.
const NOT_HASHED: Array[String] = ["run/runId", "run/devCommands", "map/attempts", "log", "tally", "requestedFloors"]


func _excluded(path: String, snapshot: Dictionary) -> bool:
	if path.begins_with("run/floorSeeds/"):
		return path != "run/floorSeeds/%d" % int(snapshot["run"]["floor"])   # only the current floor's seed is hashed
	for prefix in NOT_HASHED:
		if path == prefix or path.begins_with(prefix + "/") or path.begins_with(prefix + "["):
			return true
	return false


## Every leaf of the snapshot, as a path like "map/cells[3]/pickups[0]/price".
static func _leaves(value: Variant, path: String, found: Array) -> void:
	if value is Dictionary:
		for key in value:
			_leaves(value[key], str(key) if path == "" else "%s/%s" % [path, key], found)
	elif value is Array:
		for index in value.size():
			_leaves(value[index], "%s[%d]" % [path, index], found)
	elif path != "schemaVersion":
		found.append(path)


## The keys and indexes a path walks: "map/cells[3]/room" → ["map", "cells", 3, "room"].
static func _steps_of(path: String) -> Array:
	var steps: Array = []
	for part in path.split("/"):
		var bracket := part.find("[")
		steps.append(part if bracket < 0 else part.left(bracket))
		while bracket >= 0:
			var close := part.find("]", bracket)
			steps.append(int(part.substr(bracket + 1, close - bracket - 1)))
			bracket = part.find("[", close)
	return steps


## `snapshot` with the leaf at `path` changed to another valid value, or {} when that leaf can't be changed (null).
static func _change(snapshot: Dictionary, path: String) -> Dictionary:
	var copy: Dictionary = snapshot.duplicate(true)
	var steps := _steps_of(path)
	var holder: Variant = copy
	for index in steps.size() - 1:
		holder = holder[steps[index]]
	var key: Variant = steps[-1]
	var value: Variant = holder[key]
	match typeof(value):
		TYPE_BOOL:
			holder[key] = not value
		TYPE_INT, TYPE_FLOAT:
			holder[key] = int(value) + 1
		TYPE_STRING, TYPE_STRING_NAME:
			holder[key] = str(int(str(value)) + 1) if str(value).is_valid_int() else str(value) + "x"
		_:
			return {}
	return copy


## Changing ANY field of a snapshot (party, inventory, map cell, pickup, enemy, event, pending battle, flags …) changes the run hash,
## except the few listed in NOT_HASHED. A new field fails here until it is hashed or listed with its reason. The same walk covers the
## snapshots of a state with a pending battle and of one inside an event.
func test_snapshot_fields_are_covered() -> void:
	var content := fixtures()
	var played := await _play(content, TWO_FLOORS, false, 400)
	var snapshots: Array = []
	var wanted := {"pendingBattle": false, "event": false}
	for request in played["requests"]:
		if not request.has("snapshot"):
			continue
		var snapshot: Dictionary = request["snapshot"]
		var pending: bool = snapshot["pendingBattle"] != null
		var event: bool = not snapshot["run"]["event"].is_empty()
		if (pending and not wanted["pendingBattle"]) or (event and not wanted["event"]) or snapshots.is_empty():
			snapshots.append(snapshot)
			wanted["pendingBattle"] = wanted["pendingBattle"] or pending
			wanted["event"] = wanted["event"] or event
	check(wanted["pendingBattle"], "one of the snapshots has a pending battle")
	var covered := 0
	var undecided: Array[String] = []
	for snapshot in snapshots:
		var base_probe: RunController = RunController.new()
		host.add_child(base_probe)
		_nodes.append(base_probe)
		eq(base_probe.load_snapshot(content, snapshot), "", "the snapshot loads")
		var base_hash := base_probe.state.run_hash()
		var leaves: Array = []
		_leaves(snapshot, "", leaves)
		for path in leaves:
			var changed := _change(snapshot, path)
			if changed.is_empty():
				undecided.append(path)
				continue
			var probe: RunController = RunController.new()
			host.add_child(probe)
			_nodes.append(probe)
			if probe.load_snapshot(content, changed) != "":
				undecided.append(path)
				continue
			var moved: bool = probe.state.run_hash() != base_hash
			if _excluded(path, snapshot):
				check(not moved, "%s is listed as not hashed but changing it changes the hash" % path)
			else:
				check(moved, "%s is not in run_hash(): hash it (RunState.canonical_lines), or list it in NOT_HASHED with a reason" % path)
				covered += 1
	check(covered > 200, "many leaves were probed (%d)" % covered)
	check(undecided.size() < covered / 10, "few leaves escape the probe (%d): %s" % [undecided.size(), undecided.slice(0, 8)])


# --- G5: a floor seed that reaches the client late ------------------------------------------------------------------

## A client that waited at the stairs for its seed logged the waiting state's hash; the replay must reach the same one, then
## accept the entered floor once the client acts on it.
func test_a_late_floor_seed_verifies() -> void:
	var content := fixtures()
	var played := await _play(content, TWO_FLOORS, true)
	var run: RunController = played["run"]
	eq(run.waiting_for_floor(), 1, "the run waits at the stairs for floor 1's seed")
	var waiting_hash := run.state.run_hash()
	check(run.provide_floor_seed(1, SEEDS[1]) == "", "the seed arrives")
	await RunPlayer.play(run, 12)
	var steps := _steps(content, TWO_FLOORS, played)
	var verdicts := await _all_verify(content, steps, "late seed")
	var last_wait: Dictionary = played["requests"].filter(func(request: Dictionary) -> bool:
		return request["stateHash"] == waiting_hash).back()
	check(not last_wait.is_empty(), "a request carries the waiting state's hash")
	check(verdicts.size() >= 3, "the steps around the wait verified (%d)" % verdicts.size())


# --- Spec card-collection 2.5: the run's item pool is the server's input --------------------------------------------------

## A pool that leaves out some of the fixtures' items, so it matters which one a run is told it has.
func _pool(content: ContentIndex, leave_out: Array = ["fixture.item.ember_charm", "fixture.item.crest"]) -> Array:
	var ids: Array = []
	for table in [content.items, content.equipment]:
		for id in table:
			if not leave_out.has(String(id)):
				ids.append(String(id))
	ids.sort()
	return ids


func test_steps_of_a_run_with_a_card_pool_verify_and_link() -> void:
	var content := fixtures()
	var pool := _pool(content)
	var played := await _play(content, TWO_FLOORS, false, 400, SEEDS, pool)
	eq(played["run"].runner_error, "", "the run with a pool plays")
	check(played["run"].state.card_pool_set, "the run holds the pool")
	var steps := _steps(content, TWO_FLOORS, played)
	check(steps.size() >= 3, "several steps (%d)" % steps.size())
	check(steps[0].has("cardPool"), "the genesis request carries the pool")
	var verdicts := await _all_verify(content, steps, "pool run")
	eq(verdicts[0]["endHash"], played["requests"][0]["stateHash"], "the server's own start hashes as the client's seq 1, pool included")


func test_the_pool_is_part_of_the_run_hash_only_when_set() -> void:
	var content := fixtures()
	var plain := await _play(content, TWO_FLOORS, false, 3)
	var pooled := await _play(content, TWO_FLOORS, false, 3, SEEDS, _pool(content))
	var reordered := await _play(content, TWO_FLOORS, false, 3, SEEDS, _pool(content).duplicate().map(func(id: String) -> String: return id))
	check(plain["requests"][0]["stateHash"] != pooled["requests"][0]["stateHash"], "a run with a pool hashes differently from one without")
	eq(pooled["requests"][0]["stateHash"], reordered["requests"][0]["stateHash"], "the same pool, the same hash")
	check(not "card_pool=" in "\n".join(plain["run"].state.canonical_lines()), "a run without a pool has no card_pool line")
	var shuffled := _pool(content)
	shuffled.reverse()
	var other := await _play(content, TWO_FLOORS, false, 3, SEEDS, shuffled)
	eq(other["requests"][0]["stateHash"], pooled["requests"][0]["stateHash"], "the pool's order does not change the hash")


func test_a_step_with_another_pool_than_the_runs_is_refused() -> void:
	var content := fixtures()
	var pool := _pool(content)
	var played := await _play(content, TWO_FLOORS, false, 400, SEEDS, pool)
	var steps := _steps(content, TWO_FLOORS, played)
	var step: Dictionary = steps[1].duplicate(true)

	var stripped := step.duplicate(true)
	stripped.erase("cardPool")
	var verdict := await _verify(content, stripped)
	eq(verdict.get("status"), "Rejected", "a step that forgets the pool is refused")
	eq(verdict["mismatch"]["reason"], "SnapshotHashMismatch", "named as the start the claim does not reach")

	var widened := step.duplicate(true)
	widened["cardPool"] = _pool(content, [])
	verdict = await _verify(content, widened)
	eq(verdict.get("status"), "Rejected", "a wider pool than the one the run was started with is refused")
	eq(verdict["mismatch"]["reason"], "SnapshotHashMismatch", "the same name")

	var genesis_other: Dictionary = steps[0].duplicate(true)
	genesis_other["cardPool"] = _pool(content, [])
	var rebuilt := await _verify(content, genesis_other)
	eq(rebuilt.get("status"), "Verified", "(sanity) the genesis answers with a verdict")
	check(rebuilt.get("endHash") != (await _verify(content, steps[0])).get("endHash"), "a genesis with another pool rebuilds another start")


func test_a_malformed_pool_is_exit_3() -> void:
	var content := fixtures()
	var played := await _play(content, TWO_FLOORS, false, 3)
	var step: Dictionary = _steps(content, TWO_FLOORS, played)[0].duplicate(true)
	for bad in ["item", 5, [1, 2], [""]]:
		var request := step.duplicate(true)
		request["cardPool"] = bad
		var verdict := await _verify(content, request)
		eq(verdict["_exit"], StepRunner.EXIT_MALFORMED, "cardPool %s is malformed" % [bad])
