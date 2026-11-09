## Replays one STEP of a run (spec run-verify 2.2): a segment of out-of-battle actions, a battle (the pending checkpoint and the
## `battle` action), the win, or the genesis step that rebuilds the starting state from the server's own inputs. The server
## cuts the client's log at its claimed snapshots; this restores the claimed snapshot a step starts from, plays the logged
## actions through the same RunController methods as play (a battle through the verifier's ReplayController, so a battle is
## simulated once, here), and checks every claim on the way. The game rules exist only in GDScript: this is the only place the
## server's run verification runs them (root CLAUDE.md, "Single combat implementation").
##
## Input: a StepRequest (`Rpg.Contracts.Runs.StepRequest`, camelCase). Output: a StepVerdict. Exit codes (3.6): 0 Verified,
## 2 Rejected (2002), 3 Malformed (a request it refuses; also a Rejected verdict), 1 runner error (broken content, a bug: retried).
class_name StepRunner
extends RefCounted

const REQUEST_SCHEMA_VERSION: int = 1
const EXIT_VERIFIED: int = 0
const EXIT_RUNNER_ERROR: int = 1
const EXIT_REJECTED: int = 2
const EXIT_MALFORMED: int = 3
const KINDS: Array[String] = ["Genesis", "Segment", "Battle", "End"]
const REQUEST_KEYS: Array[String] = ["schemaVersion", "runId", "runStructureId", "characterIds", "floorSeeds", "fromSeq", "toSeq",
	"kind", "startSnapshot", "startStateHash", "actions", "endRunHash"]

var exit_code: int = EXIT_RUNNER_ERROR
## Set on a runner error; the result file is then {"runnerError": ...} instead of a StepVerdict.
var runner_error: String = ""

var _content: ContentIndex
var _host: Node
var _run: RunController
var _server_seeds: Dictionary = {}
# What the battles of the step reported, and the one being played.
var _battles: Array = []
var _observer: ReplayRunner
var _current_battle: Battle
var _current_controller: ReplayRunner.ReplayController
var _current_conditions: Dictionary = {}
var _current_log: Dictionary = {}
var _digest: Dictionary = {}


## Reads the request file, runs it and writes the verdict file. Returns the exit code.
func run_files(in_path: String, out_path: String, content_root: String, host: Node) -> int:
	var text := FileAccess.get_file_as_string(in_path)
	var parsed: Variant = JSON.parse_string(text) if text != "" else null
	var result: Dictionary
	if parsed is Dictionary:
		result = await run(parsed, content_root, host)
	else:
		result = _error("could not read a JSON object from %s" % in_path)
	var file := FileAccess.open(out_path, FileAccess.WRITE)
	if file == null:
		push_error("StepRunner: cannot write %s" % out_path)
		return EXIT_RUNNER_ERROR
	file.store_string(WireJson.stringify(result))
	file.close()
	return exit_code


func run(request: Dictionary, content_root: String, host: Node) -> Dictionary:
	return await run_on(request, ContentIndex.new(content_root), host)


## run() on a content index already loaded (the tests, and the dev tools' report).
func run_on(request: Dictionary, content: ContentIndex, host: Node) -> Dictionary:
	var problem := validate(request)
	if problem != "":
		return _malformed(problem)
	if not content.problems.is_empty():
		return _error("content problems: " + "; ".join(content.problems))   # a broken deploy, not the request's fault
	_content = content
	_host = host
	_server_seeds = {}
	for floor_key in request["floorSeeds"]:
		_server_seeds[str(floor_key).to_int()] = str(request["floorSeeds"][floor_key]).to_int()
	_battles = []
	_digest = {}
	_run = RunController.new()
	_run.name = "StepRun"
	host.add_child(_run)
	_run.allow_dev = false
	_run.floor_entered.connect(func(_floor: int) -> void: _digest = _run.floor_digest())
	_run.battle_started.connect(_on_battle_started)
	_run.battle_finished.connect(_on_battle_finished)
	var result: Dictionary
	if str(request["kind"]) == "Genesis":
		result = _genesis(request)
	else:
		result = await _replay(request)
	_run.queue_free()
	_run = null
	return result


## The shape checks (spec run-verify 3.6): a request that fails one is Malformed, a verdict at once and never retried.
static func validate(request: Dictionary) -> String:
	for key in request:
		if not str(key) in REQUEST_KEYS:
			return "unknown field \"%s\"" % key
	if int(request.get("schemaVersion", 0)) != REQUEST_SCHEMA_VERSION:
		return "unsupported schemaVersion %s (expected %d)" % [request.get("schemaVersion"), REQUEST_SCHEMA_VERSION]
	for key in ["runId", "runStructureId", "kind"]:
		if not request.get(key) is String or str(request[key]) == "":
			return "%s must be a non-empty string" % key
	if not str(request["kind"]) in KINDS:
		return "unknown kind \"%s\"" % request["kind"]
	if not request.get("characterIds") is Array or request["characterIds"].is_empty():
		return "characterIds must be a non-empty array"
	if not request.get("floorSeeds") is Dictionary or not request["floorSeeds"].has("0"):
		return "floorSeeds must be an object that holds floor 0"
	for key in ["fromSeq", "toSeq"]:
		if not request.get(key) is float and not request.get(key) is int:
			return "%s must be a number" % key
	if not request.get("actions") is Array:
		return "actions must be an array"
	if str(request["kind"]) == "Genesis":
		return ""
	if not request.get("startSnapshot") is Dictionary or not request.get("startStateHash") is String:
		return "a step needs startSnapshot (an object) and startStateHash"
	var shape := RunSnapshot.shape_problem(request["startSnapshot"])
	if shape != "":
		return "startSnapshot: " + shape

	if request["actions"].is_empty():
		return "a step needs at least one action"
	for index in request["actions"].size():
		var item: Variant = request["actions"][index]
		if not item is Dictionary or not item.get("action") is Dictionary or not item.get("stateHash") is String \
				or not (item.get("seq") is float or item.get("seq") is int) or not item["action"].get("type") is String:
			return "action %d needs seq, stateHash and an action with a type" % index
		if item["action"]["type"] == "battle" and (not item["action"].get("battle") is Dictionary \
				or not item["action"]["battle"].get("conditions") is Dictionary or not item["action"]["battle"].get("actionLog") is Dictionary 				or not item["action"]["battle"]["actionLog"].get("actions") is Array 				or not item["action"]["battle"].get("battleId") is String):
			return "action %d is a battle without its conditions, id and action log" % index
	if str(request["kind"]) == "End" and not request.get("endRunHash") is String:
		return "an End step needs endRunHash"
	return ""


# --- The genesis step (2.0) -----------------------------------------------------------------------------------------------

## The start the server's inputs produce: nothing of the client's goes in. Returns the verdict with the rebuilt snapshot.
func _genesis(request: Dictionary) -> Dictionary:
	var error := _run.start_server_run(_content, _names(request["characterIds"]), str(request["runId"]),
		int(_server_seeds.get(0, 0)), StringName(str(request["runStructureId"])))
	if error == "" and _run.runner_error != "":
		error = _run.runner_error
	if error != "":
		return _malformed("the start can't be rebuilt: " + error)   # an unknown structure or character
	return _verified("", _run.state.run_hash(), _run.snapshot(), _digest)


# --- Any other step (2.2) -----------------------------------------------------------------------------------------------

func _replay(request: Dictionary) -> Dictionary:
	var from_seq := int(request["fromSeq"])
	var error := _run.load_snapshot(_content, request["startSnapshot"])
	if error != "":
		return _reject("SnapshotHashMismatch", from_seq, "the start snapshot can't be restored: " + error)
	var wrong := _wrong_setup(request)
	if wrong != "":
		return _reject("WrongSetup", from_seq, wrong)
	var start_hash := _run.state.run_hash()
	if start_hash != str(request["startStateHash"]):
		return _reject("SnapshotHashMismatch", from_seq, "the start snapshot is %s, the log claims %s" % [start_hash,
			request["startStateHash"]])
	var foreign := _foreign_seed()
	if foreign != "":
		return _reject("ForeignSeed", from_seq, foreign)
	_digest = {}
	for item in request["actions"]:
		var seq := int(item["seq"])
		var wire: Dictionary = item["action"]
		# A client that acted on a floor it was waiting for had its seed: hand it over before the action.
		RunWire.provide_waiting(_run, _server_seeds)
		var failure := await _apply(wire, seq)
		if not failure.is_empty():
			return failure
		if _run.runner_error != "":
			return _error("the run stopped at seq %d: %s" % [seq, _run.runner_error])
		if not RunWire.hash_matches(_run, str(item["stateHash"]), _server_seeds):
			return _reject("StateHashMismatch", seq, "the replay reaches %s, the log claims %s" % [_run.state.run_hash(),
				item["stateHash"]])
	var last_seq := int(request["actions"][-1]["seq"])
	if str(request["kind"]) == "End":
		if _run.state.status != RunState.WON:
			return _reject("NotWon", last_seq, "the run is %s, not won" % _run.state.status)
		if _run.state.run_hash() != str(request["endRunHash"]):
			return _reject("NotWon", last_seq, "the run ends at %s, the end claims %s" % [_run.state.run_hash(), request["endRunHash"]])
	# The run hash covers everything that decides play, so the next step's check of its restored start against the hash claimed
	# here binds the claimed snapshot to this replay: no separate comparison of snapshots is needed.
	return _verified(start_hash, _run.state.run_hash(), {}, _digest)


## Plays one logged action. {} or the rejection verdict.
func _apply(wire: Dictionary, seq: int) -> Dictionary:
	if str(wire["type"]) == "battle":
		return await _apply_battle(wire, seq)
	var problem := await RunWire.apply(_run, wire)
	if problem != "":
		return _reject("ActionRefused", seq, problem)
	return {}


## A logged battle: its claimed conditions must be what this state produces, its party decisions are replayed by the verifier's
## controller, and the outcome and final hash it claims must be what the simulation reached. The ReplayResult comes out of the
## same simulation the run needed anyway (spec run-verify 2.2: a battle is replayed once).
func _apply_battle(wire: Dictionary, seq: int) -> Dictionary:
	var battle: Dictionary = wire["battle"]
	if _run.pending_battle.is_empty():
		return _reject("ActionRefused", seq, "no battle is waiting")
	var mine := _run.battle_snapshot()
	if _canonical(mine) != _canonical(battle["conditions"]) or str(mine["battleId"]) != str(battle["battleId"]):
		return _reject("ConditionsMismatch", seq, "the battle's claimed conditions are not what the run produces at this point")
	_current_conditions = mine
	_current_log = battle["actionLog"]
	_current_controller = RunWire.LoggedBattle.new(battle["actionLog"]["actions"])
	var problem: String = await _run.fight(_current_controller)
	if problem != "" or _run.runner_error != "":
		return _error("the battle at seq %d: %s" % [seq, problem if problem != "" else _run.runner_error])
	if _battles.is_empty():
		return _error("the battle at seq %d reported no result" % seq)
	var result: Dictionary = _battles[-1]
	if str(result["verdict"]) == "Rejected":
		return _reject("BattleMismatch", seq, "%s: %s" % [result["mismatch"]["reason"], result["mismatch"]["detail"]])
	return {}


func _on_battle_started(battle: Battle) -> void:
	_current_battle = battle
	_observer = ReplayRunner.new()
	_observer.begin_observing(battle, _content, _current_conditions)


func _on_battle_finished(_outcome: String) -> void:
	if _current_battle == null:
		return
	_battles.append(_observer.finish_observing(_current_battle, _current_controller, _current_conditions, _current_log))
	_current_battle = null


# --- Checks ---------------------------------------------------------------------------------------------------------------

## "" or what in the restored snapshot is not this run's: its id, its structure, its party.
func _wrong_setup(request: Dictionary) -> String:
	var state := _run.state
	if state.run_id != str(request["runId"]):
		return "the snapshot is run %s, the step is run %s" % [state.run_id, request["runId"]]
	if str(state.run_structure_id) != str(request["runStructureId"]):
		return "the snapshot plays %s, the run plays %s" % [state.run_structure_id, request["runStructureId"]]
	var party := state.party_characters().map(func(id: StringName) -> String: return String(id))
	if party != Array(request["characterIds"]).map(func(id: Variant) -> String: return str(id)):
		return "the snapshot's party is %s, the run's is %s" % [party, request["characterIds"]]
	return ""


## "" or the first floor seed in the snapshot that is not the one the server issued.
func _foreign_seed() -> String:
	for floor_index in _run.state.floor_seeds:
		if not _server_seeds.has(int(floor_index)) or int(_server_seeds[int(floor_index)]) != int(_run.state.floor_seeds[floor_index]):
			return "floor %d: the snapshot holds a seed the server did not issue" % int(floor_index)
	return ""


## Both sides through the same normalisation: JSON numbers are floats, StringNames are Strings, keys come sorted.
static func _canonical(value: Variant) -> String:
	return JSON.stringify(RunSnapshot._ints(RunSnapshot._plain(value)), "", true)


static func _names(values: Array) -> Array:
	return values.map(func(value: Variant) -> StringName: return StringName(str(value)))


# --- The verdict ------------------------------------------------------------------------------------------------------------

func _verified(start_hash: String, end_hash: String, end_snapshot: Dictionary, floor_digest: Dictionary = {}) -> Dictionary:
	exit_code = EXIT_VERIFIED
	runner_error = ""
	var verdict := _base("Verified", null, start_hash, end_hash)
	if not end_snapshot.is_empty():
		verdict["endSnapshot"] = end_snapshot
	verdict["battles"] = _battles
	if not floor_digest.is_empty():
		verdict["floorDigest"] = floor_digest   # the step entered a floor: the server keeps what it looked like (2.7)
	return _finish(verdict)


func _reject(reason: String, seq: int, detail: String) -> Dictionary:
	exit_code = EXIT_REJECTED
	runner_error = ""
	var verdict := _base("Rejected", {"reason": reason, "seq": seq, "detail": detail}, "", "")
	verdict["battles"] = _battles
	return _finish(verdict)


## A request the runner refuses (exit 3): a rejection about the request, like the replay runner's.
func _malformed(detail: String) -> Dictionary:
	exit_code = EXIT_MALFORMED
	runner_error = ""
	var verdict := _base("Rejected", {"reason": "MalformedRequest", "seq": 0, "detail": detail}, "", "")
	verdict["battles"] = []
	return _finish(verdict)


func _error(message: String) -> Dictionary:
	runner_error = message
	exit_code = EXIT_RUNNER_ERROR
	return {"runnerError": message}


func _base(status: String, mismatch: Variant, start_hash: String, end_hash: String) -> Dictionary:
	var rejected := status == "Rejected"
	return {
		"status": status,
		"errorCode": 2002 if rejected else null,
		"error": "ReplayMismatch" if rejected else null,
		"mismatch": mismatch,
		"startHash": start_hash,
		"endHash": end_hash,
	}


## The fields the worker overwrites (its own ruleset version and clock) are left blank here; the engine version is this build's.
func _finish(verdict: Dictionary) -> Dictionary:
	verdict["verifierRulesetVersion"] = ""
	verdict["engineVersion"] = ReplayRunner.engine_version()
	verdict["verifiedAt"] = Time.get_datetime_string_from_system(true) + "Z"
	return verdict
