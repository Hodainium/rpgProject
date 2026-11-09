## Record ↔ replay, determinism and every MismatchReason (spec section 4, acceptance scenario 5 at runner level).
extends TestCase


func _first_entry(request: Dictionary, ability_tag: String) -> int:
	var actions: Array = request["actionLog"]["actions"]
	for index in actions.size():
		if actions[index]["ability"] == ability_tag:
			return index
	return -1


## Replays twice and checks both runs reject identically (deterministic rejection, scenario 5).
func _expect_rejected(request: Dictionary, reasons: Array, turn: int, label: String) -> void:
	var first := await replay(request)
	var second := await replay(request)
	eq(first.get("verdict"), "Rejected", label + " verdict")
	eq(first.get("errorCode"), 2002, label + " errorCode")
	eq(first.get("error"), "ReplayMismatch", label + " error")
	var mismatch: Dictionary = first.get("mismatch", {}) if first.get("mismatch") is Dictionary else {}
	check(reasons.has(mismatch.get("reason")), "%s reason in %s, got %s" % [label, reasons, mismatch.get("reason")])
	if turn >= 0:
		eq(mismatch.get("turn"), turn, label + " turn")
	eq(WireJson.stringify(second), WireJson.stringify(first), label + " is rejected the same way twice")


func test_determinism_same_process() -> void:
	var a: Dictionary = await record(squad_snapshot())
	var b: Dictionary = await record(squad_snapshot())
	eq(WireJson.stringify(b), WireJson.stringify(a), "same inputs → same log and final hash")
	var c: Dictionary = await record(squad_snapshot("43"))
	check(c["actionLog"]["claimedFinalHash"] != a["actionLog"]["claimedFinalHash"], "a different seed changes the battle")


func test_wire_json_writes_whole_numbers_as_integers() -> void:
	var parsed: Variant = JSON.parse_string("{\"schemaVersion\":1,\"turn\":12,\"ratio\":0.5,\"list\":[3]}")
	eq(WireJson.stringify(parsed), "{\"schemaVersion\":1,\"turn\":12,\"ratio\":0.5,\"list\":[3]}",
		"a parsed request re-serializes with integers, as the C# records require")


func test_record_then_replay_verifies() -> void:
	for snap in [snapshot("duel", [[1, "striker"]], "1"), squad_snapshot()]:
		var request: Dictionary = await record(snap)
		var result := await replay(request)
		eq(result.get("verdict"), "Verified", "%s verdict" % snap["battleId"])
		eq(result.get("errorCode"), null, "%s no error code" % snap["battleId"])
		eq(result.get("finalStateHash"), request["actionLog"]["claimedFinalHash"], "%s final hash" % snap["battleId"])
		eq(result.get("outcome"), request["actionLog"]["claimedOutcome"], "%s outcome" % snap["battleId"])


func test_tamper_target() -> void:
	var request := copy(await record(squad_snapshot()))
	var index := _first_entry(request, "Fixture.Ability.Strike")
	var entry: Dictionary = request["actionLog"]["actions"][index]
	entry["target"] = "E3" if entry["target"] != "E3" else "E1"
	# Spec atomic-battles: a still-valid target plays on and is caught later (a dead target, the outcome or the hash).
	await _expect_rejected(request, ["InvalidTarget", "OutcomeMismatch", "FinalHashMismatch"], -1, "tampered target")
	entry["target"] = "P2"
	await _expect_rejected(request, ["InvalidTarget"], int(entry["turn"]), "ally as an enemy target")


func test_tamper_ability() -> void:
	var request := copy(await record(squad_snapshot()))
	var entry: Dictionary = request["actionLog"]["actions"][0]
	entry["ability"] = "Fixture.Ability.Slam"  # an enemy ability the party unit doesn't have
	await _expect_rejected(request, ["IllegalAbility"], int(entry["turn"]), "ability not granted")


func test_tamper_actor() -> void:
	var request := copy(await record(squad_snapshot()))
	var entry: Dictionary = request["actionLog"]["actions"][0]
	entry["actor"] = "P1" if entry["actor"] != "P1" else "P2"
	await _expect_rejected(request, ["ActorMismatch"], int(entry["turn"]), "wrong actor")


func test_tamper_turn() -> void:
	var request := copy(await record(squad_snapshot()))
	var entry: Dictionary = request["actionLog"]["actions"][0]
	var real_turn := int(entry["turn"])
	entry["turn"] = real_turn + 1
	await _expect_rejected(request, ["TurnMismatch"], real_turn, "wrong turn number")


func test_log_exhausted() -> void:
	var request := copy(await record(squad_snapshot()))
	var actions: Array = request["actionLog"]["actions"]
	var dropped: Dictionary = actions.pop_back()
	await _expect_rejected(request, ["LogExhausted"], int(dropped["turn"]), "truncated log")


func test_trailing_actions() -> void:
	var request := copy(await record(squad_snapshot()))
	var actions: Array = request["actionLog"]["actions"]
	actions.append(actions.back().duplicate())
	await _expect_rejected(request, ["TrailingActions"], -1, "extra entries")


func test_claim_mismatch() -> void:
	var request := copy(await record(squad_snapshot()))
	request["actionLog"]["claimedOutcome"] = "Defeat" if request["actionLog"]["claimedOutcome"] != "Defeat" else "Victory"
	await _expect_rejected(request, ["OutcomeMismatch"], -1, "wrong claimed outcome")
	request = copy(await record(squad_snapshot()))
	request["actionLog"]["claimedFinalHash"] = "0".repeat(64)
	await _expect_rejected(request, ["FinalHashMismatch"], -1, "wrong claimed final hash")


func test_turn_limit() -> void:
	var request: Dictionary = await record(snapshot("stalemate", [[1, "pacifist"]]))
	eq(request["actionLog"]["claimedOutcome"], "TurnLimit", "nobody can deal damage")
	# Spec skill-points D15: the cap is 500 turns and a TurnLimit battle is a legal loss, so it verifies.
	var result := await replay(request)
	eq(result.get("verdict"), "Verified", "turn limit verdict")
	eq(result.get("outcome"), "TurnLimit", "turn limit outcome")
	eq(result.get("mismatch"), null, "no mismatch")
	eq(result.get("turns"), 500, "stopped at 500 turns")


func test_zero_frame_rule() -> void:
	var request: Dictionary = await record(snapshot("duel", [[1, "sleeper"]]))
	var runner := ReplayRunner.new()
	var result := await runner.run(request, FIXTURES, host)
	check(String(result.get("runnerError", "")).begins_with("ContentAwaitedFrame"), "runner error, not a verdict: %s" % [result])
	eq(runner.exit_code, ReplayRunner.EXIT_RUNNER_ERROR, "exit code 1")


func test_malformed_input() -> void:
	var good: Dictionary = await record(snapshot("duel", [[1, "striker"]]))
	var bad_version := copy(good)
	bad_version["snapshot"]["schemaVersion"] = 3  # 1 and 2 are valid (spec game-skeleton 3.5)
	var missing_field := copy(good)
	missing_field["actionLog"]["actions"][0].erase("ability")
	var bad_seed := copy(good)
	bad_seed["snapshot"]["seed"] = "-5"
	# Spec atomic-battles: the runner reads v2 logs only, and a v2 entry may not carry a checkpoint (or any unknown key).
	var log_v1 := copy(good)
	log_v1["actionLog"]["schemaVersion"] = 1
	var leftover_checkpoint := copy(good)
	leftover_checkpoint["actionLog"]["actions"][0]["checkpoint"] = "ab12"
	# Spec run-verify 3.6: a request the runner refuses is a Rejected verdict (MalformedRequest, exit 3), never a runner
	# error the worker would retry five times.
	for request in [{}, bad_version, missing_field, bad_seed, log_v1, leftover_checkpoint]:
		var runner := ReplayRunner.new()
		var result := await runner.run(request, FIXTURES, host)
		eq(result.get("verdict"), "Rejected", "malformed input is a rejection: %s" % [result])
		eq(result["mismatch"]["reason"], "MalformedRequest", "with its own reason")
		eq(result.get("errorCode"), 2002, "2002 like every rejection")
		eq(runner.exit_code, ReplayRunner.EXIT_MALFORMED, "exit code 3")
		eq(runner.runner_error, "", "and not a runner error")
