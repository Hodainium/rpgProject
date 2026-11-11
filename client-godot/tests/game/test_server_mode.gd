## Spec server-authority Part A, Godot side (section 6): the seed source (local labels unchanged, server streams from
## issued floor seeds), a server run waiting at the stairs for its next floor seed, ServerLink over a fake bridge (no
## network: retries with backoff, a refusal stops the run), and the ruleset version. Fixtures only. Every golden
## still matching (test_local_mode_unchanged in the spec) is the rest of the suite.
extends TestCase

const PARTY: Array = ["fixture.character.knight", "fixture.character.medic"]
const RUN_ID: String = "019a2b3c-4d5e-7f60-8a7b-8c9d0e1f2a3b"


## Stands in for the C# ServerBridge: same methods, same Completed signal, answers from a queue (the last one repeats).
## Methods without answers (or at an answer "default"): a dev token, uploads acknowledged up to their last seq, the
## heartbeat's 204, an end answered Won. `offline`: every call gets no answer (status 0).
class FakeBridge:
	extends RefCounted
	signal Completed(request_id: int, ok: bool, json: String)

	var calls: Array = []
	## Method name → Array of [ok, body Dictionary].
	var answers: Dictionary = {}
	var token: String = ""
	var offline: bool = false
	var _next: int = 0

	func SetToken(access_token: String) -> void:
		token = access_token

	func GetDevToken(json: String) -> int:
		return _answer("GetDevToken", [json])

	func SendActions(run_id: String, json: String) -> int:
		return _answer("SendActions", [run_id, json])

	func EndRun(run_id: String, json: String) -> int:
		return _answer("EndRun", [run_id, json])

	func Resume(run_id: String) -> int:
		return _answer("Resume", [run_id])

	func GetBattle(run_id: String, seq: int) -> int:
		return _answer("GetBattle", [run_id, seq])

	func GetWallet() -> int:
		return _answer("GetWallet", [])

	func GetSteps(run_id: String) -> int:
		return _answer("GetSteps", [run_id])

	func GetCardCatalog() -> int:
		return _answer("GetCardCatalog", [])

	func GetPacks() -> int:
		return _answer("GetPacks", [])

	func GetCollection() -> int:
		return _answer("GetCollection", [])

	func OpenPack(pack_id: String, json: String) -> int:
		return _answer("OpenPack", [pack_id, json])

	func DustCard(card_id: String, json: String) -> int:
		return _answer("DustCard", [card_id, json])

	func CraftCard(card_id: String, json: String) -> int:
		return _answer("CraftCard", [card_id, json])

	func AbandonRun(run_id: String) -> int:
		return _answer("AbandonRun", [run_id])

	func PutPackType(json: String) -> int:
		return _answer("PutPackType", [json])

	func ListPackTypes() -> int:
		return _answer("ListPackTypes", [])

	func PutCardRate(json: String) -> int:
		return _answer("PutCardRate", [json])

	func ListCardRates() -> int:
		return _answer("ListCardRates", [])

	func PutRewardRule(json: String) -> int:
		return _answer("PutRewardRule", [json])

	func ListRewardRules() -> int:
		return _answer("ListRewardRules", [])

	func ResetRewardCycle(json: String) -> int:
		return _answer("ResetRewardCycle", [json])

	func Heartbeat(json: String) -> int:
		return _answer("Heartbeat", [json])

	func StartRun(json: String) -> int:
		return _answer("StartRun", [json])

	func GetFloorSeed(run_id: String, floor_index: int, json: String) -> int:
		return _answer("GetFloorSeed", [run_id, floor_index, json])

	func GetRun(run_id: String) -> int:
		return _answer("GetRun", [run_id])

	func GetCurrentRun() -> int:
		return _answer("GetCurrentRun", [])

	func count(method: String) -> int:
		return calls.filter(func(call: Array) -> bool: return call[0] == method).size()

	func _answer(method: String, args: Array) -> int:
		_next += 1
		calls.append([method] + args)
		var answer: Variant = "default"
		if answers.has(method):
			var queue: Array = answers[method]
			answer = queue.pop_front() if queue.size() > 1 else queue[0]
		if answer is String:
			answer = _default(method, args)
		if offline:
			answer = [false, {"status": 0, "errorCode": null, "title": "HttpRequestException", "detail": "offline"}]
		Completed.emit.call_deferred(_next, answer[0], JSON.stringify(answer[1]))
		return _next

	static func _default(method: String, args: Array) -> Array:
		match method:
			"GetDevToken":
				return [true, {"accessToken": "fake-token", "expiresAt": "2026-10-28T00:00:00+00:00", "playerId": "p"}]
			"SendActions":
				var batch: Dictionary = JSON.parse_string(args[1])
				return [true, {"lastSeq": int(batch["actions"][-1]["seq"])}]
			"Heartbeat":
				return [true, null]
			"EndRun":
				return [true, {"runId": args[0], "status": "Won"}]
		return [false, {"status": 0, "errorCode": null, "title": "no answer for %s" % method, "detail": ""}]

	## The calls to `method`, in order.
	func of(method: String) -> Array:
		return calls.filter(func(call: Array) -> bool: return call[0] == method)


var _nodes: Array[Node] = []


func after_each() -> void:
	for node in _nodes:
		if is_instance_valid(node):
			node.free()
	_nodes.clear()
	super()


static func _structure_id() -> StringName:
	return &"fixture.run.two_floors"


func _server_run(floor_seed: int, run_id: String = RUN_ID) -> RunController:
	var run := RunController.new()
	host.add_child(run)
	_nodes.append(run)
	eq(run.start_server_run(fixtures(), PARTY, run_id, floor_seed, _structure_id()), "", "the server run starts")
	return run


func _local_run(seed_text: String) -> RunController:
	var run := RunController.new()
	host.add_child(run)
	_nodes.append(run)
	eq(run.start_run(fixtures(), PARTY, seed_text, _structure_id()), "", "the local run starts")
	return run


func _link(bridge: FakeBridge) -> ServerLink:
	var link := ServerLink.new(bridge)
	link.retry_base_seconds = 0.01
	link.retry_max_seconds = 0.02
	link.saves_dir = "user://test_server_mode/saves_%d_%d" % [OS.get_process_id(), Time.get_ticks_usec()]
	host.add_child(link)
	_nodes.append(link)
	return link


static func _floor_answer(floor_index: int, floor_seed: int) -> Array:
	return [true, {"runId": RUN_ID, "floor": floor_index, "floorSeed": str(floor_seed)}]


static func _error(status: int, error_code: Variant = null, title: String = "") -> Array:
	return [false, {"status": status, "errorCode": error_code, "title": title, "detail": "", "retryAfterSeconds": null}]


## Waits (frames, at most ~2 s) until `condition` holds.
func _until(condition: Callable) -> bool:
	for frame in 240:
		if condition.call():
			return true
		await host.get_tree().process_frame
	return condition.call()


static func _draws(stream: RandomNumberGenerator) -> Array[int]:
	var values: Array[int] = []
	for index in 4:
		values.append(stream.randi())
	return values


func test_seed_source_local_keeps_todays_labels() -> void:
	var seeds := SeedSource.local(42)
	check(not seeds.server_mode(), "local mode")
	eq(_draws(seeds.floor_rng(2, "layout")), _draws(RunSeeds.rng(42, "floor/2/layout")), "floor streams: floor/<n>/<label>")
	eq(seeds.floor_derive(3, "combat/5"), RunSeeds.derive(42, "floor/3/combat/5"), "derived seeds too")
	eq(_draws(seeds.run_rng("chest/3")), _draws(RunSeeds.rng(42, "chest/3")), "run-wide streams: the bare label")
	check(seeds.has_floor(9), "local mode has every floor")


func test_seed_source_server_streams() -> void:
	var seeds := SeedSource.new(0, {0: 1111, 1: 2222})
	check(seeds.server_mode(), "server mode")
	eq(_draws(seeds.floor_rng(1, "layout")), _draws(RunSeeds.rng(2222, "layout")), "a floor's streams: its issued seed")
	eq(seeds.floor_derive(0, "field/0"), RunSeeds.derive(1111, "field/0"), "derived seeds from the floor seed")
	eq(_draws(seeds.run_rng("chapter/x/bosses")), _draws(RunSeeds.rng(1111, "run/chapter/x/bosses")),
		"run-wide streams: floor 0's seed under run/")
	check(not seeds.has_floor(2), "a floor without an issued seed is missing")


func test_server_seed_source() -> void:
	var a := _server_run(5150)
	var b := _server_run(5150, "another-run-id")
	eq(a.state.canonical_lines(), b.state.canonical_lines(), "same floor seed, same floor (and the same hash)")
	check(a.state.canonical_lines().has("floor_seed=5150"), "the run hash holds the current floor's seed")
	check(not _local_run("5150").state.canonical_lines().has("floor_seed=5150"), "a local run's hash doesn't")
	eq(a.state.run_id, RUN_ID, "the run id is the server's")
	eq(a.run_log[0].get("floorSeed"), "5150", "the start entry carries the issued seed")
	check(not a.allow_dev, "no dev decisions in battle while connected")
	var differs := false
	for floor_seed in [1, 2, 3, 4, 5, 6, 7, 8]:
		if _rooms(_server_run(floor_seed)) != _rooms(a):
			differs = true
	check(differs, "floor content follows the issued floor seed")


## The floor's rooms by cell, in cell order.
static func _rooms(run: RunController) -> Array:
	var cells: Array = run.state.map.cells.keys()
	cells.sort()
	return cells.map(func(cell) -> String: return "%s:%s" % [cell, run.state.map.cells[cell]["room"]])


func test_stairs_wait_for_the_floor_seed() -> void:
	var run := _server_run(5150)
	var asked: Array[int] = []
	run.floor_seed_needed.connect(func(floor_index: int) -> void: asked.append(floor_index))
	run.state.boss_cleared = true
	eq(run.next_floor(), "", "the stairs")
	eq(asked, [1], "the next floor's seed is asked for at next_floor, once")
	eq(run.waiting_for_floor(), 1, "the floor waits for its seed")
	eq(run.state.floor_index, 0, "still on floor 0")
	check(run.next_floor() != "", "nothing goes on while waiting")
	eq(run.provide_floor_seed(1, 777), "", "the seed arrives")
	eq(run.state.floor_index, 1, "and the floor starts")
	eq(run.waiting_for_floor(), -1, "nothing waits any more")
	eq(asked, [1], "never asked twice")
	eq(run.provide_floor_seed(1, 999), "", "a late repeat is ignored")
	eq(int(run.state.floor_seeds[1]), 777, "the first seed stays")
	# The same seed given before the stairs builds the same floor.
	var early := _server_run(5150)
	early.provide_floor_seed(1, 777)
	early.state.boss_cleared = true
	eq(early.next_floor(), "", "the stairs with the seed already in")
	eq(early.state.canonical_lines(), run.state.canonical_lines(), "the floor is the seed's, not the timing's")


## Review fix: a run start refused with 503 (the server is still loading its card catalog) is asked again; other errors are not.
func test_a_run_start_refused_while_the_catalog_loads_is_asked_again() -> void:
	var bridge := FakeBridge.new()
	bridge.answers = {
		"StartRun": [_error(503, null, "Card catalog loading"), [true, {"runId": RUN_ID, "floor": 0, "floorSeed": "5150",
			"startedAt": "2026-10-27T12:00:00+00:00"}]],
	}
	var link := _link(bridge)
	var started: Dictionary = await link.start_run("4.7.2.stable.mono+0123456789abcdef", "fixture.run.two_floors", PARTY)
	check(started["ok"], "the run starts once the server is ready")
	eq(bridge.count("StartRun"), 2, "after one refused attempt")
	await host.get_tree().process_frame  # the fake bridge's Completed emission ends before the link is freed


## A start with no answer is not repeated: it is not idempotent (only a 503, which started nothing, is).
func test_a_run_start_with_no_answer_is_not_repeated() -> void:
	var bridge := FakeBridge.new()
	bridge.answers = {"StartRun": [_error(0, null, "HttpRequestException")]}
	var link := _link(bridge)
	var failed: Dictionary = await link.start_run("4.7.2.stable.mono+0123456789abcdef", "fixture.run.two_floors", PARTY)
	check(not failed["ok"], "no answer is an error")
	eq(bridge.count("StartRun"), 1, "and is not repeated")
	await host.get_tree().process_frame  # the fake bridge's Completed emission ends before the link is freed


func test_server_link_starts_and_retries_the_stairs() -> void:
	var bridge := FakeBridge.new()
	bridge.answers = {
		"StartRun": [[true, {"runId": RUN_ID, "floor": 0, "floorSeed": "5150", "startedAt": "2026-10-27T12:00:00+00:00"}]],
		"GetFloorSeed": [_error(0, null, "HttpRequestException"), _error(503, null, "Database unavailable"),
			_floor_answer(1, 777)],
	}
	var link := _link(bridge)
	var started: Dictionary = await link.start_run("4.7.2.stable.mono+0123456789abcdef", "fixture.run.two_floors", PARTY)
	check(started["ok"], "the run starts on the server")
	var sent: Dictionary = JSON.parse_string(bridge.of("StartRun")[0][1])
	eq(sent.keys(), ["rulesetVersion", "runStructureId", "characterIds"], "RunStartRequest in the record's field order")
	eq(sent["characterIds"], PARTY, "with the party")
	var run := _server_run(str(started["data"]["floorSeed"]).to_int(), str(started["data"]["runId"]))
	link.link(run, RUN_ID)
	run.state.boss_cleared = true
	eq(run.next_floor(), "", "the stairs")
	check(await _until(func() -> bool: return run.state.floor_index == 1), "the floor starts once the seed is in")
	eq(bridge.count("GetFloorSeed"), 3, "no answer and a 503 were retried")
	eq(bridge.of("GetFloorSeed")[0].slice(1, 3), [RUN_ID, 1], "for this run's floor 1")
	eq(int(run.state.floor_seeds[1]), 777, "with the issued seed")
	eq(run.runner_error, "", "and the run goes on")


func test_server_refusal_stops_the_run() -> void:
	var bridge := FakeBridge.new()
	bridge.answers = {"GetFloorSeed": [_error(409, 1105, "Floor not reachable")]}
	var link := _link(bridge)
	var run := _server_run(5150)
	var stopped: Array[String] = []
	run.stopped.connect(func(error: String) -> void: stopped.append(error))
	link.link(run, RUN_ID)
	run.state.boss_cleared = true
	run.next_floor()
	check(await _until(func() -> bool: return not stopped.is_empty()), "a refusal stops the run")
	eq(bridge.count("GetFloorSeed"), 1, "a 4xx is never retried")
	check(stopped[0].contains("1105"), "with the error code: " + (stopped[0] if not stopped.is_empty() else ""))
	eq(run.state.status, RunState.ACTIVE, "a stop, not a loss")


func test_server_link_errors() -> void:
	check(ServerLink.retryable({"status": 0}), "no answer is retried")
	check(ServerLink.retryable({"status": 503}), "a 5xx is retried")
	check(ServerLink.retryable({"status": 429}), "rate limiting is retried")
	check(not ServerLink.retryable({"status": 409}), "a refusal is not")
	eq(ServerLink.describe({"status": 409, "errorCode": 1001, "title": "Ruleset not accepted"}),
		"409 Ruleset not accepted (1001)", "one line for the player")


func test_ruleset_version_stable() -> void:
	if skip_in_export():
		return
	var version := RulesetVersion.compute()
	eq(RulesetVersion.compute(), version, "the same tree gives the same version")
	eq(RulesetVersion.current(), version, "computed live outside an export")
	var pattern := RegEx.create_from_string("^\\d+\\.\\d+\\.\\d+\\.[a-z0-9]+(\\.mono)?\\+[0-9a-f]{16}$")
	check(pattern.search(version) != null, "<godot version>+<16 hex>: " + version)
	var files := RulesetVersion.files()
	check(files.has("res://game/run_controller.gd") and files.has("res://combat/battle.gd"), "the rule roots are hashed")
	check(not Array(files).any(func(path: String) -> bool: return path.begins_with("res://tests/")), "tests are not")
	check(not Array(files).any(func(path: String) -> bool: return path.begins_with("res://game/tools/")),
		"the player preset's exclusions are not")
	check(not Array(files).any(func(path: String) -> bool: return path.get_extension() in ["uid", "import"]),
		"nor Godot's side files")
	check(not Array(files).any(func(path: String) -> bool: return path.contains("/.")),
		"nor dot-files and dot-folders (.gitkeep is listed on Windows but hidden on Linux: the version must not depend on it)")
	var sorted := files.duplicate()
	sorted.sort()
	eq(files, sorted, "in path order")
	# What export.sh stamps is what a pack reads, and the stamp never changes the version itself.
	var stamp := RulesetStamp.new()
	stamp.version = version
	eq(ResourceSaver.save(stamp, RulesetVersion.STAMP_PATH), OK, "the stamp is written")
	eq(RulesetVersion.stamped(), version, "and read back")
	eq(RulesetVersion.compute(), version, "the stamp is not hashed")
	DirAccess.remove_absolute(RulesetVersion.STAMP_PATH)  # here, not in after_each: shards run tests in parallel


## Spec playtest-fixes B9: what the player waits on. The newest wait shows; ending it shows the one before; a run's own
## waits end when another run is linked.
func test_server_link_waits() -> void:
	var link := _link(FakeBridge.new())
	var seen: Array[String] = []
	link.waiting_changed.connect(func(text: String) -> void: seen.append(text))
	eq(link.waiting_text(), "", "nothing to wait on at first")
	link.begin_wait(&"start", "Starting")
	link.begin_wait(&"floor/r/1", "Floor")
	eq(link.waiting_text(), "Floor", "the newest wait shows")
	link.end_wait(&"floor/r/1")
	eq(link.waiting_text(), "Starting", "then the one before")
	link.end_wait(&"floor/r/1")
	link.begin_wait(&"end/r", "Verifying")
	link.link(_server_run(5150), RUN_ID)
	eq(link.waiting_text(), "Starting", "linking another run ends the old run's waits, not the game's")
	link.end_wait(&"start")
	eq(seen, ["Starting", "Floor", "Starting", "Verifying", "Starting", ""], "each change once")


## Spec playtest-fixes B9: the stairs wait while the floor seed has no answer, and stop waiting once it is in.
func test_stairs_wait_shows_while_offline() -> void:
	var bridge := FakeBridge.new()
	bridge.answers = {"GetFloorSeed": [_error(0, null, "HttpRequestException"), _error(0, null, "HttpRequestException"),
		_floor_answer(1, 777)]}
	var link := _link(bridge)
	var run := _server_run(5150)
	link.link(run, RUN_ID)
	run.state.boss_cleared = true
	run.next_floor()
	eq(link.waiting_text(), link.wait_floor_text, "the stairs wait on the server")
	check(await _until(func() -> bool: return run.state.floor_index == 1), "the floor starts once the seed is in")
	eq(link.waiting_text(), "", "and nothing waits any more")


## The connecting wait starts when the run stands at the missing seed (the rest stop is over), not while the seed is
## only being fetched in the background behind the rest stop.
func test_connecting_wait_starts_after_the_rest_stop() -> void:
	var bridge := FakeBridge.new()
	bridge.answers = {"GetFloorSeed": [_error(0, null, "HttpRequestException")]}
	var link := _link(bridge)
	var run := _server_run(5150)
	var structure: RunStructure = run.structure.duplicate()
	structure.rest_event = fixtures().events.values()[0]
	run.structure = structure
	link.link(run, RUN_ID)
	run.state.boss_cleared = true
	run.next_floor()
	check(run.state.event.has("rest_to"), "the rest stop opens at once")
	eq(link.waiting_text(), "", "and nothing waits yet")
	run.state.event = {}  # the rest stop ends
	run.enter_floor(1)
	eq(link.waiting_text(), link.wait_floor_text, "the wait starts when the run stands at the missing seed")


## Spec playtest-fixes B10: connected once signed in and answered; not when the server stops answering.
func test_server_link_connection() -> void:
	var bridge := FakeBridge.new()
	var link := _link(bridge)
	var changes := [0]
	link.connection_changed.connect(func() -> void: changes[0] += 1)
	check(not link.connected(), "not connected before any request")
	await link.heartbeat()
	check(link.connected(), "connected after an answer")
	eq(link.player_id, "p", "with the player id from the dev token")
	bridge.offline = true
	await link.heartbeat()
	check(not link.connected(), "not connected when the server doesn't answer")
	bridge.offline = false
	await link.heartbeat()
	check(link.connected(), "connected again")
	check(changes[0] >= 3, "each change is announced (%d)" % changes[0])
	await host.get_tree().process_frame  # leave the bridge's Completed emission before after_each frees the link
