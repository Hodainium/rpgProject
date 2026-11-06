## Re-runs a battle from a ReplayRequest and returns a ReplayResult (spec "Replay mode (verify)").
##
## Exit codes for the headless entry point: 0 Verified, 2 Rejected (errorCode 2002), 1 runner error.
## A runner error is never a verdict: malformed input or broken content (slice 3 routes it to retry / DLQ).
class_name ReplayRunner
extends RefCounted

## The only ActionLog version the runner reads (spec atomic-battles: v2 entries carry no checkpoint).
const ACTION_LOG_SCHEMA_VERSION: int = 2
## ReplayResult's own version (unchanged by atomic-battles).
const RESULT_SCHEMA_VERSION: int = 1
## Every key an action entry may carry; any other (a leftover "checkpoint") is a runner error.
const ENTRY_KEYS: Array[String] = ["turn", "actor", "ability", "target", "extra", "interrupt"]
## Snapshot schema versions the runner accepts (spec game-skeleton 3.5: v2 adds the run fields).
const SNAPSHOT_SCHEMA_VERSIONS: Array[int] = [1, 2]
const EXIT_VERIFIED: int = 0
const EXIT_RUNNER_ERROR: int = 1
const EXIT_REJECTED: int = 2
const BOSS_TAG: StringName = &"Enemy.Boss"
const REPLAY_MISMATCH_CODE: int = 2002
const REPLAY_MISMATCH_NAME: String = "ReplayMismatch"

var exit_code: int = EXIT_RUNNER_ERROR
## Spec atomic-battles: attached to the replayed battle when set (trace_main, tests); gets the verdict and reason.
var trace: BattleTrace = null
## Set on a runner error; the result is then {"runnerError": ...} instead of a ReplayResult.
var runner_error: String = ""
## The content the replay runs on, kept so `_completions` can read the challenges of the encounter.
var _content: ContentIndex = null


## Runs the replay under `host` (a node inside the scene tree). Returns the ReplayResult JSON shape (field order
## matching the C# record) or {"runnerError": ...}.
func run(request: Dictionary, content_root: String, host: Node) -> Dictionary:
	return await run_on(request, ContentIndex.new(content_root), host)


## run() on a content index already loaded (spec playable-demo 2.3b: the play report replays every battle of a run on
## the index the run used, so dev overlays and in-memory content replay as recorded).
func run_on(request: Dictionary, content: ContentIndex, host: Node) -> Dictionary:
	var problem := _validate_request(request)
	if problem != "":
		return _error(problem)
	var snapshot: Dictionary = request["snapshot"]
	var action_log: Dictionary = request["actionLog"]
	_content = content

	var battle := Battle.new()
	battle.name = "ReplayBattle"
	host.add_child(battle)
	var setup_error := battle.setup(snapshot, content, HeadlessGate.new())
	if setup_error != "":
		battle.queue_free()
		return _error(setup_error)

	var controller := ReplayController.new(action_log["actions"])
	battle.trace = trace
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
	var result := _result(battle, snapshot)
	if trace != null:
		trace.verdict = result["verdict"]
		trace.reason = result["mismatch"]["reason"] if result["mismatch"] != null else null
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
	# Spec skill-points D15: a TurnLimit battle is a legal loss and verifies like any other outcome (the wire's
	# TurnLimitExceeded reason is no longer produced).
	if controller.remaining() > 0:
		battle.reject("TrailingActions", "%d log entries left after the battle ended" % controller.remaining())
	elif str(action_log["claimedOutcome"]) != battle.outcome:
		battle.reject("OutcomeMismatch", "claimed %s, simulated %s" % [action_log["claimedOutcome"], battle.outcome])
	elif str(action_log["claimedFinalHash"]) != battle.final_hash:
		battle.reject("FinalHashMismatch", "claimed %s, simulated %s" % [action_log["claimedFinalHash"], battle.final_hash])


func _result(battle: Battle, snapshot: Dictionary) -> Dictionary:
	var rejected := not battle.mismatch.is_empty()
	exit_code = EXIT_REJECTED if rejected else EXIT_VERIFIED
	var mismatch: Variant = null
	if rejected:
		mismatch = {
			"reason": battle.mismatch["reason"],
			"turn": int(battle.mismatch["turn"]),
			"detail": battle.mismatch["detail"],
		}
	var result := {
		"schemaVersion": RESULT_SCHEMA_VERSION,
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
	# Spec settlement-outbox 3.1: what the server may pay for, decided here and never in C#. Only a verified replay
	# has facts, and they are not hashed.
	if not rejected:
		result["facts"] = _facts(battle, str(snapshot.get("encounterId", "")))
	return result


## The encounter id, the distinct Enemy.Boss definitions BEATEN (empty unless the party won, so a lost battle never reads
## as a boss kill) and the party's character ids (spec settlement-outbox).
func _facts(battle: Battle, encounter_id: String) -> Dictionary:
	var bosses: Array = []
	var party: Array = []
	var won: bool = battle.outcome == "Victory"
	for unit in battle.units():
		var unit_id := str(unit.definition.id)
		if unit.side == BattleUnit.Side.ENEMY:
			if won and unit.definition.tags.has(BOSS_TAG) and not bosses.has(unit_id):
				bosses.append(unit_id)
		elif not party.has(unit_id):
			party.append(unit_id)
	var facts := {"encounterId": encounter_id, "bossIds": bosses, "partyCharacterIds": party}
	# Spec economy-challenges 3.1: challenges the battle completed, with the tier (stars) reached. Absent when there are
	# none, so every fact and golden written before this stays byte-identical.
	var completions: Array = _completions(battle, encounter_id) if won else []
	if not completions.is_empty():
		facts["completions"] = completions
	return facts


## The challenges `battle` completed, as `completion_fact` entries: each `ChallengeDefinition` of the encounter that the
## finished battle reached a tier of (spec economy-challenges). Empty when the content defines none, so every fact written
## before challenges stays byte-identical. Only called for a won battle, and never hashed.
func _completions(battle: Battle, encounter_id: String) -> Array:
	var completions: Array = []
	if _content == null:
		return completions
	for challenge in _content.challenges_for(encounter_id):
		var tier := challenge.tier_for(battle)
		if tier > 0:
			completions.append(completion_fact(str(challenge.id), tier))
	return completions


## One completion on the wire: the server's `CompletionFact(ChallengeId, Tier)`. A tier is the number of stars reached
## (1 or more); what each is worth is the server's rule.
static func completion_fact(challenge_id: String, tier: int) -> Dictionary:
	return {"challengeId": challenge_id, "tier": tier}


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
	if int(action_log.get("schemaVersion", 0)) != ACTION_LOG_SCHEMA_VERSION:
		return "unsupported actionLog schemaVersion %s (expected %d)" % [action_log.get("schemaVersion"), ACTION_LOG_SCHEMA_VERSION]
	if not int(snapshot.get("schemaVersion", 0)) in SNAPSHOT_SCHEMA_VERSIONS:
		return "unsupported snapshot schemaVersion %s (expected one of %s)" % [snapshot.get("schemaVersion"), SNAPSHOT_SCHEMA_VERSIONS]
	if not action_log.get("actions") is Array or not snapshot.get("party") is Array:
		return "actionLog.actions and snapshot.party must be arrays"
	var actions: Array = action_log["actions"]
	for index in actions.size():
		var entry: Variant = actions[index]
		if not entry is Dictionary or not entry.has("turn") or not entry.has("actor") or not entry.has("ability"):
			return "every action needs turn, actor and ability"
		for key in entry:
			if not str(key) in ENTRY_KEYS:
				return "unknown field \"%s\" in action %d" % [key, index]
	return ""


func _error(message: String) -> Dictionary:
	runner_error = message
	exit_code = EXIT_RUNNER_ERROR
	if trace != null:
		trace.verdict = "RunnerError"
		trace.reason = message
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
		# Spec ult-interrupts, DECISION window: an interrupt logged for this turn fires before the action.
		if bool(entry.get("interrupt", false)):
			if int(entry["turn"]) != battle.turn:
				battle.reject("TurnMismatch", "log entry is an ult interrupt on turn %d, but %s must act on turn %d" % [
					int(entry["turn"]), unit.unit_id, battle.turn])
				return {}
			return _interrupt_choice(battle, entry)
		if int(entry["turn"]) != battle.turn:
			battle.reject("TurnMismatch", "log entry says turn %d, %s acts on turn %d" % [int(entry["turn"]), unit.unit_id, battle.turn])
			return {}
		if StringName(str(entry["actor"])) != unit.unit_id:
			battle.reject("ActorMismatch", "log entry says %s, but it is %s's turn" % [entry["actor"], unit.unit_id])
			return {}
		# Spec item-pass 3.2: a One More turn must be logged as one, and only then.
		if bool(entry.get("extra", false)) != battle.extra_action:
			battle.reject("TurnMismatch", "log entry on turn %d %s a One More action, the simulation %s" % [battle.turn,
				"claims" if bool(entry.get("extra", false)) else "doesn't claim",
				"has one" if battle.extra_action else "has none"])
			return {}
		var target: Variant = entry.get("target")
		return {"ability": StringName(str(entry["ability"])), "target": &"" if target == null else StringName(str(target))}

	## Spec ult-interrupts, BETWEEN window: the next entry fires here when it is an interrupt for this window's turn.
	## One for an earlier turn was skipped by the simulation (TurnMismatch); one for a later turn waits.
	func interrupt(battle: Battle) -> Dictionary:
		if _next >= _entries.size():
			return {}
		var entry: Dictionary = _entries[_next]
		if not bool(entry.get("interrupt", false)) or int(entry["turn"]) > battle.turn:
			return {}
		if int(entry["turn"]) < battle.turn:
			battle.reject("TurnMismatch", "ult interrupt logged on turn %d never had a window (the simulation is past turn %d)" % [
				int(entry["turn"]), battle.turn])
			return {}
		return _interrupt_choice(battle, entry)

	func _interrupt_choice(battle: Battle, entry: Dictionary) -> Dictionary:
		if bool(entry.get("extra", false)):
			battle.reject("TurnMismatch", "log entry on turn %d claims both an ult interrupt and a One More" % battle.turn)
			return {}
		var target: Variant = entry.get("target")
		return {"interrupt": true, "unit": StringName(str(entry["actor"])), "ability": StringName(str(entry["ability"])),
			"target": &"" if target == null else StringName(str(target))}

	func after_interrupt(battle: Battle, unit: BattleUnit, action: Dictionary) -> void:
		after_party_turn(battle, unit, action)

	func on_invalid(_battle: Battle, _unit: BattleUnit, _reason: String, _detail: String) -> bool:
		return false

	## Spec atomic-battles: the entry was checked when it was chosen; nothing is compared per action, only at the end.
	func after_party_turn(_battle: Battle, _unit: BattleUnit, _action: Dictionary) -> void:
		_next += 1
