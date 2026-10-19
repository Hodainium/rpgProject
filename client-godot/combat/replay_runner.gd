## Re-runs a battle from a ReplayRequest and returns a ReplayResult (spec "Replay mode (verify)").
##
## Exit codes for the headless entry point: 0 Verified, 2 Rejected (errorCode 2002), 1 runner error.
## A runner error is never a verdict: malformed input or broken content (slice 3 routes it to retry / DLQ).
class_name ReplayRunner
extends RefCounted

const SCHEMA_VERSION: int = 1
## Snapshot schema versions the runner accepts (spec game-skeleton 3.5: v2 adds the run fields).
const SNAPSHOT_SCHEMA_VERSIONS: Array[int] = [1, 2]
const EXIT_VERIFIED: int = 0
const EXIT_RUNNER_ERROR: int = 1
const EXIT_REJECTED: int = 2
const REPLAY_MISMATCH_CODE: int = 2002
const REPLAY_MISMATCH_NAME: String = "ReplayMismatch"

var exit_code: int = EXIT_RUNNER_ERROR
## Set on a runner error; the result is then {"runnerError": ...} instead of a ReplayResult.
var runner_error: String = ""


## Runs the replay under `host` (a node inside the scene tree). Returns the ReplayResult JSON shape (field order
## matching the C# record) or {"runnerError": ...}.
func run(request: Dictionary, content_root: String, host: Node) -> Dictionary:
	var problem := _validate_request(request)
	if problem != "":
		return _error(problem)
	var snapshot: Dictionary = request["snapshot"]
	var action_log: Dictionary = request["actionLog"]

	var battle := Battle.new()
	battle.name = "ReplayBattle"
	host.add_child(battle)
	var setup_error := battle.setup(snapshot, ContentIndex.new(content_root), HeadlessGate.new())
	if setup_error != "":
		battle.queue_free()
		return _error(setup_error)

	var controller := ReplayController.new(action_log["actions"])
	var frames_before := Engine.get_process_frames()
	await battle.run(controller)
	if Engine.get_process_frames() != frames_before:
		battle.queue_free()
		return _error("ContentAwaitedFrame: an ability awaited something other than the presentation gate")
	if battle.runner_error != "":
		battle.queue_free()
		return _error(battle.runner_error)

	if battle.mismatch.is_empty():
		_check_claims(battle, controller, action_log)
	var result := _result(battle)
	battle.queue_free()
	return result


## Reads the request file, runs it and writes the result file. Returns the exit code.
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
		push_error("ReplayRunner: cannot write %s" % out_path)
		return EXIT_RUNNER_ERROR
	file.store_string(WireJson.stringify(result))
	file.close()
	return exit_code


func _check_claims(battle: Battle, controller: ReplayController, action_log: Dictionary) -> void:
	if battle.outcome == Battle.TURN_LIMIT_OUTCOME:
		battle.reject("TurnLimitExceeded", "no outcome after %d turns" % Battle.TURN_LIMIT)
	elif controller.remaining() > 0:
		battle.reject("TrailingActions", "%d log entries left after the battle ended" % controller.remaining())
	elif str(action_log["claimedOutcome"]) != battle.outcome:
		battle.reject("OutcomeMismatch", "claimed %s, simulated %s" % [action_log["claimedOutcome"], battle.outcome])
	elif str(action_log["claimedFinalHash"]) != battle.final_hash:
		battle.reject("FinalHashMismatch", "claimed %s, simulated %s" % [action_log["claimedFinalHash"], battle.final_hash])


func _result(battle: Battle) -> Dictionary:
	var rejected := not battle.mismatch.is_empty()
	exit_code = EXIT_REJECTED if rejected else EXIT_VERIFIED
	var mismatch: Variant = null
	if rejected:
		mismatch = {
			"reason": battle.mismatch["reason"],
			"turn": int(battle.mismatch["turn"]),
			"detail": battle.mismatch["detail"],
		}
	return {
		"schemaVersion": SCHEMA_VERSION,
		"battleId": battle.battle_id,
		"verdict": "Rejected" if rejected else "Verified",
		"errorCode": REPLAY_MISMATCH_CODE if rejected else null,
		"error": REPLAY_MISMATCH_NAME if rejected else null,
		"mismatch": mismatch,
		"outcome": battle.outcome,
		"turns": battle.turn,
		"finalStateHash": battle.final_hash,
		"engineVersion": engine_version(),
	}


## The exact Godot build, as Godot prints it at startup: "4.7.2.stable.mono.official.ed1daf0bf". The client and the
## verifier must run the identical build (root CLAUDE.md, "RNG"); ruleset_version (slice 2) will include it.
static func engine_version() -> String:
	var info := Engine.get_version_info()
	var parts := PackedStringArray(["%d.%d.%d" % [info["major"], info["minor"], info["patch"]], str(info["status"])])
	if ClassDB.class_exists(&"CSharpScript"):
		parts.append("mono")
	parts.append(str(info["build"]))
	parts.append(str(info["hash"]).left(9))
	return ".".join(parts)


func _validate_request(request: Dictionary) -> String:
	if not request.get("snapshot") is Dictionary or not request.get("actionLog") is Dictionary:
		return "request needs snapshot and actionLog objects"
	var snapshot: Dictionary = request["snapshot"]
	var action_log: Dictionary = request["actionLog"]
	if int(action_log.get("schemaVersion", 0)) != SCHEMA_VERSION:
		return "unsupported actionLog schemaVersion %s (expected %d)" % [action_log.get("schemaVersion"), SCHEMA_VERSION]
	if not int(snapshot.get("schemaVersion", 0)) in SNAPSHOT_SCHEMA_VERSIONS:
		return "unsupported snapshot schemaVersion %s (expected one of %s)" % [snapshot.get("schemaVersion"), SNAPSHOT_SCHEMA_VERSIONS]
	if not action_log.get("actions") is Array or not snapshot.get("party") is Array:
		return "actionLog.actions and snapshot.party must be arrays"
	for entry in action_log["actions"]:
		if not entry is Dictionary or not entry.has("turn") or not entry.has("actor") or not entry.has("ability") \
				or not entry.has("checkpoint"):
			return "every action needs turn, actor, ability and checkpoint"
	return ""


func _error(message: String) -> Dictionary:
	runner_error = message
	exit_code = EXIT_RUNNER_ERROR
	return {"runnerError": message}


## Feeds the log's entries to the battle and checks each one (spec section 3.2, MismatchReason).
class ReplayController:
	extends RefCounted

	var _entries: Array
	var _next: int = 0

	func _init(entries: Array) -> void:
		_entries = entries

	func remaining() -> int:
		return _entries.size() - _next

	func choose(battle: Battle, unit: BattleUnit) -> Dictionary:
		if _next >= _entries.size():
			battle.reject("LogExhausted", "%s must act on turn %d but the log has no entries left" % [unit.unit_id, battle.turn])
			return {}
		var entry: Dictionary = _entries[_next]
		if int(entry["turn"]) != battle.turn:
			battle.reject("TurnMismatch", "log entry says turn %d, %s acts on turn %d" % [int(entry["turn"]), unit.unit_id, battle.turn])
			return {}
		if StringName(str(entry["actor"])) != unit.unit_id:
			battle.reject("ActorMismatch", "log entry says %s, but it is %s's turn" % [entry["actor"], unit.unit_id])
			return {}
		var target: Variant = entry.get("target")
		return {"ability": StringName(str(entry["ability"])), "target": &"" if target == null else StringName(str(target))}

	func on_invalid(_battle: Battle, _unit: BattleUnit, _reason: String, _detail: String) -> bool:
		return false

	func after_party_turn(battle: Battle, _unit: BattleUnit, _action: Dictionary, checkpoint: String) -> void:
		var entry: Dictionary = _entries[_next]
		_next += 1
		if str(entry["checkpoint"]) != checkpoint:
			battle.reject("CheckpointMismatch", "state hash after turn %d is %s, log says %s" % [battle.turn, checkpoint, entry["checkpoint"]])
