## Spec server-authority Part B, Godot side (section 6): RunSnapshot round trips and resume equivalence on the
## scripted runs, checkpoints, the action queue (order, batches, retries, offline play), the local save, resume from
## the save and from the server's log, a 1103 conflict, and a won run waiting for the verdict. Fixtures only, the
## FakeBridge from test_server_mode (no network).
extends TestCase

const ServerMode := preload("res://tests/game/test_server_mode.gd")
const PARTY: Array = ["fixture.character.knight", "fixture.character.medic"]
const SCRIPTED_PARTY: Array = ["fixture.character.knight", "fixture.character.medic", "fixture.character.rogue"]
const TWO_FLOORS: StringName = &"fixture.run.two_floors"
const RUN_ID: String = "019a2b3c-4d5e-7f60-8a7b-8c9d0e1f2a3b"
const FLOOR_SEEDS: Array = [5150, 777]

var _nodes: Array[Node] = []


func after_each() -> void:
	# queue_free: a test can end inside a link's own signal (its last await resumed from there), where free() fails.
	for node in _nodes:
		if is_instance_valid(node):
			node.queue_free()
	_nodes.clear()
	super()


func _add(node: Node) -> Node:
	host.add_child(node)
	_nodes.append(node)
	return node


## A local run with its journal on: every request it logs goes through JSON (as the server stores it) into `sink`.
func _journaled(content: ContentIndex, sink: Array, run_id: StringName = &"") -> RunController:
	var run: RunController = _add(RunController.new())
	run.journal = true
	run.actions_committed.connect(func(requests: Array) -> void: sink.append_array(_through_json(requests)))
	eq(run.start_run(content, SCRIPTED_PARTY, "7", run_id), "", "the journaled run starts")
	return run


static func _through_json(value: Variant) -> Variant:
	return JSON.parse_string(WireJson.stringify(value))


## Stop at every checkpoint, load its snapshot, play the rest of the log: the same final hash (and summary).
func _check_resume_equivalence(content: ContentIndex, run_id: StringName, label: String) -> void:
	var requests: Array = []
	var original := _journaled(content, requests, run_id)
	await RunPlayer.play(original)
	eq(original.runner_error, "", "%s: no runner error" % label)
	var final_hash := original.state.run_hash()
	var final_summary := WireJson.stringify(original.run_summary())
	eq(requests.map(func(request) -> int: return int(request["seq"])), range(1, requests.size() + 1),
		"%s: one request per seq, in order" % label)
	eq(requests.size(), original.run_log.size() - (1 if original.state.status == RunState.WON else 0),
		"%s: every log entry is a request" % label)
	var checkpoints := 0
	for index in requests.size():
		var request: Dictionary = requests[index]
		if not request.has("snapshot"):
			continue
		checkpoints += 1
		var resumed: RunController = _add(RunController.new())
		eq(resumed.load_snapshot(content, request["snapshot"]), "", "%s: seq %d loads" % [label, request["seq"]])
		eq(resumed.state.run_hash(), request["stateHash"], "%s: seq %d loads to its state hash" % [label, request["seq"]])
		eq(WireJson.stringify(resumed.snapshot()), WireJson.stringify(request["snapshot"]),
			"%s: seq %d: the snapshot round trips" % [label, request["seq"]])
		var problem := ""
		for later in requests.slice(index + 1):
			problem = await RunWire.apply(resumed, later["action"])
			if problem == "" and resumed.state.run_hash() != later["stateHash"]:
				problem = "hash differs after seq %d" % later["seq"]
			if problem != "":
				break
		eq(problem, "", "%s: replay from seq %d" % [label, request["seq"]])
		eq(resumed.state.run_hash(), final_hash, "%s: from seq %d, the same final hash" % [label, request["seq"]])
		eq(WireJson.stringify(resumed.run_summary()), final_summary, "%s: and the same summary" % label)
		resumed.free()
	check(checkpoints >= 4, "%s: several checkpoints (%d)" % [label, checkpoints])


func test_resume_equivalence() -> void:
	await _check_resume_equivalence(fixtures(), &"", "scripted run")
	await _check_resume_equivalence(KeysWorld.content(), KeysWorld.RUN_ID, "keyed run")


func test_snapshot_round_trip() -> void:
	var requests: Array = []
	var run := _journaled(fixtures(), requests)
	await RunPlayer.play(run, 12)
	var direct := run.snapshot()
	var loaded: RunController = _add(RunController.new())
	eq(loaded.load_snapshot(fixtures(), _through_json(direct)), "", "a snapshot through JSON loads")
	eq(loaded.state.canonical_lines(), run.state.canonical_lines(), "into the same state")
	eq(loaded.state.run_hash(), run.state.run_hash(), "with the same hash")
	eq(loaded.pending_battle.is_empty(), run.pending_battle.is_empty(), "and the same pending battle")
	eq(int(direct["schemaVersion"]), 1, "schemaVersion 1")
	check(loaded.load_snapshot(fixtures(), {"schemaVersion": 2}) != "", "another schema is refused")


## Snapshots exactly on start_run, battle, next_floor and the action that left a battle pending.
func test_checkpoints_attached() -> void:
	var requests: Array = []
	var run := _journaled(fixtures(), requests)
	await RunPlayer.play(run)
	var types := {}
	var since := 0
	for index in requests.size():
		var request: Dictionary = requests[index]
		var type := str(request["action"]["type"])
		types[type] = true
		since += 1
		var next_is_battle: bool = index + 1 < requests.size() and requests[index + 1]["action"]["type"] == "battle"
		var expected: bool = RunWire.CHECKPOINTS.has(type) or next_is_battle or since >= RunWire.CHECKPOINT_EVERY
		eq(request.has("snapshot"), expected, "seq %d (%s): a snapshot only at a checkpoint" % [request["seq"], type])
		if request.has("snapshot"):
			since = 0
	for type in ["start_run", "enter_room", "battle"]:
		check(types.has(type), "the run has a %s" % type)
	var battle: Dictionary = requests.filter(func(request) -> bool: return request["action"]["type"] == "battle")[0]
	eq(battle["action"]["battle"]["conditions"]["battleId"], battle["action"]["battle"]["battleId"],
		"a battle carries its conditions")
	eq(int(battle["action"]["battle"]["actionLog"]["schemaVersion"]), 2, "and its action log")
	check(not run.run_log.any(func(entry: Dictionary) -> bool: return entry.has("conditions")),
		"the conditions travel only in the queue, never in run_log")


## Spec run-verify 2.2: a snapshot also goes up once CHECKPOINT_EVERY actions have passed since the last one, so steps stay short.
func test_a_snapshot_every_n_actions() -> void:
	var requests: Array = []
	var run := _journaled(fixtures(), requests)
	run._since_checkpoint = RunWire.CHECKPOINT_EVERY - 1
	await RunPlayer.play(run)
	var second: Dictionary = requests[1]
	check(not RunWire.CHECKPOINTS.has(str(second["action"]["type"])), "the next action is not a checkpoint type")
	check(second.has("snapshot"), "but it carries a snapshot, being the %dth since the last" % RunWire.CHECKPOINT_EVERY)
	var other: RunController = _add(RunController.new())
	eq(other.load_snapshot(fixtures(), second["snapshot"]), "", "which loads")
	eq(other.state.run_hash(), second["stateHash"], "to the state hash the action claimed")


# --- Linked runs (FakeBridge) ---------------------------------------------------------------------------------------

func _link(bridge: ServerMode.FakeBridge, saves: String = "") -> ServerLink:
	var link := ServerLink.new(bridge)
	link.retry_base_seconds = 0.01
	link.retry_max_seconds = 0.02
	link.poll_seconds = 0.01
	link.player = "tester"
	link.saves_dir = saves if saves != "" else "user://test_saves/%d/%s" % [OS.get_process_id(), Time.get_ticks_usec()]
	_add(link)
	return link


func _server_run(link: ServerLink) -> RunController:
	var run: RunController = _add(RunController.new())
	link.link(run, RUN_ID)
	eq(run.start_server_run(fixtures(), PARTY, RUN_ID, FLOOR_SEEDS[0], TWO_FLOORS), "", "the linked run starts")
	return run


static func _bridge() -> ServerMode.FakeBridge:
	var bridge := ServerMode.FakeBridge.new()
	bridge.answers = {"GetFloorSeed": [[true, {"runId": RUN_ID, "floor": 1, "floorSeed": str(FLOOR_SEEDS[1])}]]}
	return bridge


## The requests the server acknowledged: every SendActions batch that got through, deduplicated by seq.
static func _uploaded(bridge: ServerMode.FakeBridge) -> Array:
	var by_seq := {}
	for call in bridge.of("SendActions"):
		for request in JSON.parse_string(call[2])["actions"]:
			by_seq[int(request["seq"])] = request
	var seqs := by_seq.keys()
	seqs.sort()
	return seqs.map(func(seq) -> Dictionary: return by_seq[seq])


## A RunResumeResponse for `log` (the server's accepted actions).
static func _resume_answer(log: Array, floors: int) -> Array:
	var checkpoint := 0
	for index in log.size():
		if log[index].has("snapshot"):
			checkpoint = index
	var seeds: Array = []
	for floor_index in floors:
		seeds.append({"runId": RUN_ID, "floor": floor_index, "floorSeed": str(FLOOR_SEEDS[floor_index])})
	var tail: Array = log.slice(checkpoint + 1).map(func(request: Dictionary) -> Dictionary:
		var copy := request.duplicate(true)
		copy.erase("snapshot")
		return copy)
	return [true, {"runId": RUN_ID, "status": "Active", "floorSeeds": seeds, "checkpointSeq": int(log[checkpoint]["seq"]),
		"snapshot": log[checkpoint]["snapshot"], "tail": tail}]


func _until(condition: Callable, frames: int = 600) -> bool:
	for frame in frames:
		if condition.call():
			return true
		await host.get_tree().process_frame
	return condition.call()


func test_actions_sent_in_order() -> void:
	var bridge := _bridge()
	var link := _link(bridge)
	var run := _server_run(link)
	await RunPlayer.play(run)
	check(await _until(func() -> bool: return run.state.floor_index == 1), "the stairs open floor 1")
	await RunPlayer.play(run, 20)
	await link.drained()
	var seqs: Array = []
	for call in bridge.of("SendActions"):
		var batch: Array = JSON.parse_string(call[2])["actions"]
		check(batch.size() >= 1 and batch.size() <= ServerLink.BATCH_SIZE, "1 to 50 actions per batch")
		for request in batch:
			seqs.append(int(request["seq"]))
	eq(seqs, range(1, seqs.size() + 1), "every action uploaded once, in seq order")
	eq(seqs.size(), run.run_log.size(), "the whole log")
	eq(link.last_acked_seq(), run.run_log.size(), "everything acknowledged")
	eq(bridge.of("SendActions")[0][1], RUN_ID, "to this run")
	var next_floor := _uploaded(bridge).filter(func(request) -> bool: return request["action"]["type"] == "next_floor")
	eq(JSON.parse_string(bridge.of("GetFloorSeed")[0][3])["afterSeq"], int(next_floor[0]["seq"]),
		"the stairs ask after the floor's last seq (the next_floor)")
	eq(bridge.token, "fake-token", "with the dev token")
	check(bridge.of("Heartbeat").size() >= 2, "heartbeats on link and battles")


func test_offline_floor_then_sync() -> void:
	var bridge := _bridge()
	bridge.offline = true
	var link := _link(bridge)
	var run := _server_run(link)
	eq(await RunPlayer.play(run), "waiting for floor 1's seed", "floor 0 plays offline up to the stairs")
	eq(run.state.floor_index, 0, "still on floor 0")
	eq(link.last_acked_seq(), 0, "nothing acknowledged")
	eq(link.queued().size(), run.run_log.size(), "the whole floor waits in the queue")
	var saved := link.load_save()
	eq(saved.get("queue", []).size(), run.run_log.size(), "and in the local save")
	eq(ServerLink.save_seq(saved), run.run_log.size(), "the save is as far as the run")
	bridge.offline = false
	check(await _until(func() -> bool: return run.state.floor_index == 1), "back online: the queue drains, the floor opens")
	eq(link.last_acked_seq(), _uploaded(bridge).size(), "everything acknowledged")
	eq(JSON.parse_string(bridge.of("GetFloorSeed")[-1][3])["afterSeq"], link.last_acked_seq(),
		"the seed was asked after the whole floor")


func test_action_queue_retries_in_order() -> void:
	var bridge := _bridge()
	bridge.answers["SendActions"] = [ServerMode._error(0, null, "HttpRequestException"),
		ServerMode._error(503, null, "Database unavailable"), ServerMode._error(429, 1201, "Too many requests"), "default"]
	var link := _link(bridge)
	var run := _server_run(link)
	await RunPlayer.play(run, 6)
	await link.drained()
	var firsts: Array = bridge.of("SendActions").map(func(call) -> int:
		return int(JSON.parse_string(call[2])["actions"][0]["seq"]))
	eq(firsts.slice(0, 4), [1, 1, 1, 1], "no answer, a 503 and a 429: the same batch again")
	eq(_uploaded(bridge).map(func(request) -> int: return int(request["seq"])), range(1, run.run_log.size() + 1),
		"then every action, in order")
	eq(run.runner_error, "", "the map kept working")


func test_refusal_stops_the_run() -> void:
	var bridge := _bridge()
	bridge.answers["SendActions"] = [ServerMode._error(400, null, "Bad request")]
	var link := _link(bridge)
	var run := _server_run(link)
	check(await _until(func() -> bool: return run.runner_error != ""), "a refusal (not 1101 or 1103) stops the run")
	check(run.runner_error.contains("400 Bad request"), "naming it: " + run.runner_error)
	eq(run.state.status, RunState.ACTIVE, "a stop, not a loss")
	eq(link.queued().size(), 1, "the action stays queued")


## Two windows on one player: the other one ended the run, so this one's uploads get 409 1101. The player is told
## plainly, and the save of a run that can't continue is deleted.
func test_run_ended_elsewhere() -> void:
	var bridge := _bridge()
	var link := _link(bridge)
	var run := _server_run(link)
	await link.drained()
	check(FileAccess.file_exists(link.save_path()), "a save while the run goes on")
	bridge.answers["SendActions"] = [ServerMode._error(409, 1101, "Run not active")]
	await RunPlayer.play(run, 1)
	check(await _until(func() -> bool: return run.runner_error != ""), "the refused upload stops the run")
	check(run.runner_error.contains(ServerLink.ENDED_ELSEWHERE), "in plain words: " + run.runner_error)
	check(not run.runner_error.contains("1101"), "not the raw code")
	check(not FileAccess.file_exists(link.save_path()), "the save of the ended run is gone")
	eq(link.queued().size(), 0, "and nothing waits to upload")
	eq(run.state.status, RunState.ACTIVE, "a stop, not a loss")


func test_conflict_discards_save() -> void:
	var bridge := _bridge()
	var link := _link(bridge)
	var run := _server_run(link)
	await RunPlayer.play(run, 1)
	await link.drained()
	var accepted := _uploaded(bridge)
	var accepted_hash := run.state.run_hash()
	var accepted_entries := run.run_log.size()
	bridge.answers["SendActions"] = [ServerMode._error(409, 1103, "Sequence conflict"), "default"]
	bridge.answers["Resume"] = [_resume_answer(accepted, 1)]
	var sources: Array[String] = []
	link.resumed.connect(func(source: String) -> void: sources.append(source))
	await RunPlayer.play(run, 2)  # played here, refused there: another device got in first
	check(run.run_log.size() > accepted_entries, "the client played on")
	check(await _until(func() -> bool: return not sources.is_empty() or run.runner_error != ""),
		"the 1103 rebuilds the run")
	eq(run.runner_error, "", "no stop while rebuilding")
	eq(sources, ["server"], "from the server's log")
	eq(bridge.of("Resume").size(), 1, "through GET /resume")
	eq(run.state.run_hash(), accepted_hash, "back to what the server accepted")
	eq(run.run_log.size(), accepted_entries, "the refused actions are gone")
	eq(link.queued().size(), 0, "and so is their queue")
	eq(ServerLink.save_seq(link.load_save()), accepted_entries, "the save was replaced by the server's state")
	eq(run.runner_error, "", "and the run goes on")
	eq(run.enter_room(-1), "can't enter that room now", "still playable")


func test_resume_from_server_log() -> void:
	var bridge := _bridge()
	var link := _link(bridge)
	var run := _server_run(link)
	await RunPlayer.play(run)
	check(await _until(func() -> bool: return run.state.floor_index == 1), "on floor 1")
	await RunPlayer.play(run, 4)
	await link.drained()
	var accepted := _uploaded(bridge)
	var fresh := _bridge()
	fresh.answers["Resume"] = [_resume_answer(accepted, 2)]
	var other := _link(fresh)  # another device: no local save
	var resumed: RunController = _add(RunController.new())
	var summary := {"runId": RUN_ID, "status": "Active", "lastSeq": accepted.size()}
	eq(await other.resume_into(resumed, fixtures(), summary), "", "resume without a save")
	eq(resumed.state.run_hash(), run.state.run_hash(), "the snapshot plus the replayed tail reach the server's hash")
	eq(resumed.state.run_hash(), str(accepted[-1]["stateHash"]), "the hash at lastSeq")
	eq(other.last_acked_seq(), accepted.size(), "continuing after lastSeq")
	eq(resumed.run_log.size(), accepted.size(), "the next action gets the next seq")
	check(resumed.journal and resumed.verify_wins, "linked")


func test_resume_from_save() -> void:
	var bridge := _bridge()
	bridge.offline = true
	var link := _link(bridge)
	var run := _server_run(link)
	await RunPlayer.play(run, 8)
	var hash := run.state.run_hash()
	var queued := link.queued().size()
	var restarted := _bridge()  # the app restarts with the same save; the server has nothing yet
	var again := _link(restarted, link.saves_dir)
	var resumed: RunController = _add(RunController.new())
	eq(await again.resume_into(resumed, fixtures(), {"runId": RUN_ID, "status": "Active", "lastSeq": 0}), "",
		"resume with the save")
	eq(resumed.state.run_hash(), hash, "the save's state")
	eq(restarted.of("Resume").size(), 0, "no download needed")
	check(await _until(func() -> bool: return again.last_acked_seq() == queued), "the saved queue uploads")
	var other_run := {"runId": "another-run", "status": "Active", "lastSeq": 0}
	var mismatch := _link(_bridge(), link.saves_dir)
	mismatch.bridge.answers["Resume"] = [ServerMode._error(404, null, "Run not found")]
	check(await mismatch.resume_into(_add(RunController.new()), fixtures(), other_run) != "",
		"another run's save is not used")


func test_win_waits_for_verdict() -> void:
	var bridge := _bridge()
	var verifying := {"runId": RUN_ID, "status": "Verifying", "currentFloor": 1, "lastSeq": 0,
		"rulesetVersion": "x", "startedAt": "2026-10-27T12:00:00+00:00", "endedAt": null}
	var won := verifying.duplicate()
	won["status"] = "Won"
	bridge.answers["EndRun"] = [[true, {"runId": RUN_ID, "status": "Verifying"}]]
	bridge.answers["GetRun"] = [[true, verifying], [true, verifying], [true, won]]
	var link := _link(bridge)
	var run := _server_run(link)
	var ended: Array[String] = []
	run.run_ended.connect(func(status: String) -> void: ended.append(status))
	await RunPlayer.play(run, 4)
	# The last floor's boss falls (the fixture run's floors are short; this is the end, not the way there).
	run.state.floor_index = 1
	run._clear_room(run.state.map.boss, false)
	run._commit_after("")
	eq(run.state.status, RunState.WON, "the run is won")
	eq(ended, [], "no victory before the server's verdict")
	check(await _until(func() -> bool: return not ended.is_empty()), "the verdict arrives")
	eq(ended, [RunState.WON], "then run_ended(Won), once")
	var end: Dictionary = JSON.parse_string(bridge.of("EndRun")[0][2])
	eq(int(end["seq"]), run.run_log.size(), "the end is the next seq")
	eq(end["status"], "Won", "a win")
	eq(end["runHash"], run.state.run_hash(), "with the final hash")
	eq(int(end["snapshot"]["schemaVersion"]), 1, "and the final snapshot")
	eq(link.last_acked_seq(), run.run_log.size() - 1, "the log was uploaded first")
	eq(bridge.of("GetRun").size(), 3, "polled until Won")
	check(not FileAccess.file_exists(link.save_path()), "a finished run leaves no save")


func test_token_refreshed_on_401() -> void:
	var bridge := _bridge()
	bridge.answers["GetRun"] = [ServerMode._error(401, null, "Unauthorized"), [true, {"runId": RUN_ID}]]
	var link := _link(bridge)
	var result := await link.get_run(RUN_ID)
	check(result["ok"], "a 401 fetches a fresh token and tries once more")
	eq(bridge.of("GetDevToken").size(), 2, "two tokens")
	eq(JSON.parse_string(bridge.of("GetDevToken")[0][1]), {"playerName": "tester"}, "for the player's name")


# --- Spec run-verify: epoch, the stairs gate, rollback, a resume before the first upload -------------------------------

func _answer_with(base: Array, extra: Dictionary) -> Array:
	var answer: Array = base.duplicate(true)
	answer[1].merge(extra, true)
	return answer


func test_the_epoch_travels_on_every_request_and_is_saved() -> void:
	var bridge := _bridge()
	bridge.answers["SendActions"] = ["default"]
	var link := _link(bridge)
	var run := _server_run(link)
	await RunPlayer.play(run, 3)
	await link.drained()
	eq(JSON.parse_string(bridge.of("SendActions")[0][2]).get("epoch"), 0, "epoch 0 until a rollback")
	link.epoch = 2   # as an acknowledgement or a resume leaves it
	await RunPlayer.play(run, 3)
	await link.drained()
	var last: Array = bridge.of("SendActions")[-1]
	eq(int(JSON.parse_string(last[2]).get("epoch")), 2, "batches carry the epoch the client last saw")
	eq(int(link.load_save().get("epoch", -1)), 2, "and the local save keeps it")
	# An acknowledgement that reports a newer epoch and the verified prefix updates both.
	bridge.answers["SendActions"] = [[true, {"lastSeq": run.run_log.size() + 50, "epoch": 3, "verifiedSeq": 9}]]
	await RunPlayer.play(run, 2)
	await link.drained()
	eq([link.epoch, link.verified_seq], [3, 9], "acks bring the epoch and the verified prefix")


func test_the_stairs_wait_for_the_previous_floor_to_verify() -> void:
	var bridge := _bridge()
	var blocked := ServerMode._error(409, 1107, "Previous floor not verified")
	bridge.answers["GetFloorSeed"] = [blocked, blocked, [true, {"runId": RUN_ID, "floor": 1, "floorSeed": str(FLOOR_SEEDS[1])}]]
	var link := _link(bridge)
	var run := _server_run(link)
	await RunPlayer.play(run)
	check(await _until(func() -> bool: return run.state.floor_index == 1), "the stairs open floor 1 once the floor is verified")
	eq(bridge.of("GetFloorSeed").size(), 3, "asked again after each 1107, then issued")
	eq(run.runner_error, "", "a 1107 never stops the run")
	check(JSON.parse_string(bridge.of("GetFloorSeed")[2][3]).has("epoch"), "and every ask carries the epoch")


func test_a_rollback_rebuilds_the_run_from_the_server() -> void:
	var bridge := _bridge()
	bridge.offline = true   # play on offline: the queue grows
	var link := _link(bridge)
	var run := _server_run(link)
	await RunPlayer.play(run, 14)
	var played := link.queued()
	var kept := played.filter(func(request: Dictionary) -> bool: return int(request["seq"]) <= 6)   # what the server kept
	check(played.size() > kept.size() and kept.any(func(request: Dictionary) -> bool: return request.has("snapshot")),
		"the run went past a verified checkpoint")
	bridge.offline = false
	bridge.answers["SendActions"] = [ServerMode._error(409, 1108, "Run rolled back"), "default"]
	bridge.answers["Resume"] = [_answer_with(_resume_answer(kept, 1), {"epoch": 1, "verifiedSeq": 5})]
	var messages: Array[String] = []
	GameplayMessages.listen(GameplayMessageRouter.NOTIFICATION, func(_channel: StringName, message: NotificationMessage) -> void: messages.append(message.text),
		GameplayMessageRouter.Match.EXACT, NotificationMessage, link)
	link._pump()
	check(await _until(func() -> bool: return link.epoch == 1), "the run is rebuilt from the server")
	eq(bridge.of("Resume").size(), 1, "from GET /resume")
	eq(run.state.run_hash(), str(kept[-1]["stateHash"]), "at the kept log's last state")
	eq(link.queued(), [], "what the server rolled back is gone from the queue")
	eq(link.verified_seq, 5, "the verified prefix is the server's")
	check(messages.has(link.rollback_text), "and the player is told")
	check(not FileAccess.file_exists(link.save_path()) or int(link.load_save().get("epoch", 0)) == 1, "no stale save")
	await RunPlayer.play(run, 2)
	await link.drained()
	eq(int(JSON.parse_string(bridge.of("SendActions")[-1][2]).get("epoch")), 1, "later uploads carry the new epoch")


func test_a_win_rolled_back_while_verifying_is_rebuilt_not_stopped() -> void:
	var bridge := _bridge()
	var verifying := {"runId": RUN_ID, "status": "Verifying", "currentFloor": 1, "lastSeq": 0, "rulesetVersion": "x",
		"startedAt": "2026-10-27T12:00:00+00:00", "endedAt": null}
	var rolled := verifying.duplicate()
	rolled["status"] = "Active"
	rolled["epoch"] = 1
	bridge.answers["EndRun"] = [[true, {"runId": RUN_ID, "status": "Verifying"}]]
	bridge.answers["GetRun"] = [[true, verifying], [true, rolled]]
	var link := _link(bridge)
	var run := _server_run(link)
	await RunPlayer.play(run, 4)
	await link.drained()
	var accepted := _uploaded(bridge)
	bridge.answers["Resume"] = [_answer_with(_resume_answer(accepted, 1), {"epoch": 1})]
	var ended: Array[String] = []
	run.run_ended.connect(func(status: String) -> void: ended.append(status))
	run.state.floor_index = 1
	run._clear_room(run.state.map.boss, false)
	run._commit_after("")
	check(await _until(func() -> bool: return link.epoch == 1), "the poll showed a rollback: the run is rebuilt")
	eq(ended, [], "no victory")
	eq(run.runner_error, "", "and the run was not stopped")


func test_a_resume_before_the_first_upload_starts_again_from_the_servers_snapshot() -> void:
	var reference: Array = []
	var sender := _bridge()
	var first := _link(sender)
	var original := _server_run(first)
	await RunPlayer.play(original, 2)
	await first.drained()
	reference = _uploaded(sender)
	var start: Dictionary = reference[0]
	var bridge := _bridge()
	var answer := [true, {"runId": RUN_ID, "status": "Active", "floorSeeds": [{"runId": RUN_ID, "floor": 0,
		"floorSeed": str(FLOOR_SEEDS[0])}], "checkpointSeq": 0, "snapshot": null, "tail": []}]
	var ready := answer.duplicate(true)
	ready[1]["snapshot"] = start["snapshot"]
	bridge.answers["Resume"] = [answer, ready]   # the genesis job has not finished on the first ask
	var link := _link(bridge)
	var resumed: RunController = _add(RunController.new())
	eq(await link.resume_into(resumed, fixtures(), {"runId": RUN_ID, "status": "Active", "lastSeq": 0}), "", "resumes")
	eq(bridge.of("Resume").size(), 2, "asked again while the server had no start state yet")
	eq(resumed.state.run_hash(), str(start["stateHash"]), "at the server's own start state")
	check(await _until(func() -> bool: return link.last_acked_seq() == 1), "start_run goes up as seq 1")
	var sent: Dictionary = JSON.parse_string(bridge.of("SendActions")[0][2])["actions"][0]
	eq([int(sent["seq"]), sent["action"]["type"], sent["stateHash"]], [1, "start_run", str(start["stateHash"])], "an ordinary upload")
	check(sent.has("snapshot"), "carrying the snapshot")
	eq(WireJson.stringify(sent["snapshot"]["run"]["party"]), WireJson.stringify(start["snapshot"]["run"]["party"]), "which is the start state")
	eq(resumed.run_log.size(), 1, "the next action is seq 2")


func test_a_resume_that_finds_no_start_state_in_time_fails_loudly() -> void:
	var bridge := _bridge()
	bridge.answers["Resume"] = [[true, {"runId": RUN_ID, "status": "Active", "floorSeeds": [], "checkpointSeq": 0,
		"snapshot": null, "tail": []}]]
	var link := _link(bridge)
	link.resume_attempts = 3
	var error: String = await link.resume_into(_add(RunController.new()), fixtures(), {"runId": RUN_ID, "status": "Active", "lastSeq": 0})
	check(error.contains("no start state"), "it says so: %s" % error)
	eq(bridge.of("Resume").size(), 3, "after the attempts it was given")
