## Spec dev-tools E6: the end-to-end harness's pieces without a server (fixtures, the fake bridge from
## test_server_mode): `wait`, `expect`, `e2e`, `server check`, `new` in server mode, RunPlayer stopping at the stairs
## of a server run, the report's server block, ServerLink.create writing no Settings, the scenario files, and
## tools/e2e.sh --check.
extends TestCase

const ServerTests := preload("res://tests/game/test_server_mode.gd")
const PARTY: String = "fixture.character.knight,fixture.character.medic"
const RUN_ID: String = "019a2b3c-4d5e-7f60-8a7b-8c9d0e1f2a3b"
## Per process: test shards run this file's tests in parallel processes that share user://.
var CONTROL: String = "user://test_e2e_tools/control_%d" % OS.get_process_id()
const SCENARIOS: String = "res://tests/e2e/"

var _games: Array[GameMain] = []
var _nodes: Array[Node] = []


func after_each() -> void:
	for game in _games:
		if is_instance_valid(game):
			game.free()
	_games.clear()
	for node in _nodes:
		if is_instance_valid(node):
			node.free()
	_nodes.clear()
	for file in ["request", "done"]:
		if FileAccess.file_exists(CONTROL.path_join(file)):
			DirAccess.remove_absolute(CONTROL.path_join(file))
	super()


## A GameMain on the fixtures with a console; with `bridge`, in server mode through a ServerLink over it.
func _session(bridge: Object = null) -> Array:
	var game: GameMain = load("res://game/game_main.tscn").instantiate()
	game.skip_animations = true
	host.add_child(game)
	game.content_root = FIXTURES
	game.load_content()
	_games.append(game)
	if bridge != null:
		var link := ServerLink.new(bridge)
		link.retry_base_seconds = 0.01
		link.saves_dir = "user://test_e2e_tools/saves_%d_%d" % [OS.get_process_id(), Time.get_ticks_usec()]
		game.use_server(link)
	var console := DevConsole.new(host.get_tree())
	console.keep_history = false
	console.load_commands(false)
	console.attach(game)
	console.auto_battle = true
	return [game, console]


static func _bridge() -> RefCounted:
	var bridge: RefCounted = ServerTests.FakeBridge.new()
	bridge.answers = {
		"StartRun": [[true, {"runId": RUN_ID, "floor": 0, "floorSeed": "5150", "startedAt": "2026-10-27T12:00:00+00:00"}]],
		"GetFloorSeed": [[true, {"runId": RUN_ID, "floor": 0, "floorSeed": "5150"}]],
		"GetRun": [[true, {"runId": RUN_ID, "status": "Active", "currentFloor": 0, "lastSeq": 0,
			"rulesetVersion": "x", "startedAt": "2026-10-27T12:00:00+00:00", "endedAt": null}]],
		"GetCurrentRun": [[true, null]],
	}
	return bridge


func _run(session: Array, line: String) -> Dictionary:
	return await session[1].execute(line)


func test_new_and_wait_in_server_mode() -> void:
	var session := _session(_bridge())
	var started := await _run(session, "new %s run=fixture.run.two_floors" % PARTY)
	check(started["ok"] and started["text"].contains("starting on the server"), "new hands over to the server: " + started["text"])
	var ready := await _run(session, "wait run 5")
	check(ready["ok"], "wait run: " + ready["text"])
	eq(session[0].run.state.run_id, RUN_ID, "the run is the server's")
	check((await _run(session, "wait floor 0 1"))["ok"], "wait floor 0 holds at once")
	var stopped := await _run(session, "wait stopped 0.2")
	check(not stopped["ok"] and stopped["text"].contains("waited"), "a wait that never holds fails with the state: " + stopped["text"])
	check(not (await _run(session, "wait notice nothing-like-this 0.2"))["ok"], "an absent notice fails")
	check(not (await _run(session, "wait"))["ok"], "usage")
	check(not (await _run(session, "wait floor x"))["ok"], "floor takes a number")


func test_wait_notice_sees_a_refusal() -> void:
	var bridge := _bridge()
	bridge.answers["StartRun"] = [ServerTests._error(409, 1001, "Ruleset not accepted")]
	var session := _session(bridge)
	check((await _run(session, "new %s run=fixture.run.two_floors" % PARTY))["ok"], "new returns at once")
	var notice := await _run(session, "wait notice 1001 5")
	check(notice["ok"], "the refusal arrives as a notice: " + notice["text"])
	check((await _run(session, "expect run \"\""))["ok"], "and no run started")


func test_expect_command() -> void:
	var session := _session()
	check((await _run(session, "expect run \"\""))["ok"], "no run yet")
	check((await _run(session, "new %s 7" % PARTY))["ok"], "a local run")
	check((await _run(session, "expect floor 0"))["ok"], "floor 0")
	check((await _run(session, "expect status Active"))["ok"], "Active")
	var wrong := await _run(session, "expect floor 3")
	check(not wrong["ok"] and wrong["text"].contains("is 0, expected 3"), "a wrong value fails with both: " + wrong["text"])
	check(not (await _run(session, "expect nothing 1"))["ok"], "an unknown field fails")
	check(not (await _run(session, "expect server.runId x"))["ok"], "a local run has no server block")


func test_e2e_command() -> void:
	var session := _session()
	var no_control := await _run(session, "e2e redis-flush")
	check(not no_control["ok"] and no_control["text"].contains("--control"), "needs a control folder: " + no_control["text"])
	check(not (await _run(session, "e2e reboot-the-moon"))["ok"], "only known actions")
	session[1].control_dir = CONTROL
	var seen := []
	var answer := func(text: String) -> void:
		seen.append(FileAccess.get_file_as_string(CONTROL.path_join("request")))
		var file := FileAccess.open(CONTROL.path_join("done"), FileAccess.WRITE)
		file.store_string(text)
		file.close()
	host.get_tree().create_timer(0.3).timeout.connect(answer.bind("ok"))
	var done := await _run(session, "e2e redis-flush 5")
	check(done["ok"], "the harness acted: " + done["text"])
	eq(seen, ["redis-flush"], "it asked for the action")
	check(not FileAccess.file_exists(CONTROL.path_join("done")), "and cleaned up")
	host.get_tree().create_timer(0.3).timeout.connect(answer.bind("flush failed"))
	var refused := await _run(session, "e2e redis-flush 5")
	check(not refused["ok"] and refused["text"].contains("flush failed"), "the harness's error fails it: " + refused["text"])
	var late := await _run(session, "e2e server-stop 0.3")
	check(not late["ok"] and late["text"].contains("didn't do"), "no answer in time fails: " + late["text"])


func test_server_check_command() -> void:
	var bridge := _bridge()
	var session := _session(bridge)
	await _run(session, "new %s run=fixture.run.two_floors" % PARTY)
	await _run(session, "wait run 5")
	bridge.answers["GetRun"][0][1]["lastSeq"] = 1  # spec Part B: the start_run is the log so far
	var agrees := await _run(session, "server check")
	check(agrees["ok"] and agrees["text"].contains("server agrees"), "the server agrees: " + agrees["text"])
	bridge.answers["GetFloorSeed"] = [[true, {"runId": RUN_ID, "floor": 0, "floorSeed": "999"}]]
	bridge.answers["GetRun"][0][1]["currentFloor"] = 2
	bridge.answers["GetRun"][0][1]["lastSeq"] = 5
	var differs := await _run(session, "server check")
	check(not differs["ok"] and differs["text"].contains("server floor 2") and differs["text"].contains("seed")
		and differs["text"].contains("lastSeq 5"), "every difference is named: " + differs["text"])
	check(not (await _run(_session(), "server check"))["ok"], "local mode has nothing to check")
	await host.get_tree().process_frame  # don't end inside the link's signal: after_each frees it


func test_run_player_stops_waiting() -> void:
	var run := RunController.new()
	host.add_child(run)
	_nodes.append(run)
	eq(run.start_server_run(fixtures(), PARTY.split(","), RUN_ID, 5150, &"fixture.run.two_floors"), "", "a server run")
	run.state.boss_cleared = true
	var stop: String = await RunPlayer.play(run, 50)
	eq(stop, "waiting for floor 1's seed", "autorun stops at the stairs instead of spinning")
	eq(run.waiting_for_floor(), 1, "the run waits for floor 1")


func test_dev_report_server_block() -> void:
	var run := RunController.new()
	host.add_child(run)
	_nodes.append(run)
	run.start_server_run(fixtures(), PARTY.split(","), RUN_ID, 5150, &"fixture.run.two_floors")
	var report := DevReport.state_of(run)
	eq(report.get("server"), {"runId": RUN_ID, "floorSeeds": {"0": "5150"}, "waitingForFloor": -1}, "server mode adds it")
	var local := RunController.new()
	host.add_child(local)
	_nodes.append(local)
	local.start_run(fixtures(), PARTY.split(","), "7", &"fixture.run.two_floors")
	check(not DevReport.state_of(local).has("server"), "a local report is unchanged")


func test_dev_run_server_flag_keeps_settings() -> void:
	var before := FileAccess.get_file_as_string(GameMain.SETTINGS_PATH)
	var link := ServerLink.create("http://127.0.0.1:1", "e2e-test")
	if link != null:
		link.free()
	else:
		expect_error("is not built")  # no C# assembly: create() says so and links nothing
	eq(FileAccess.get_file_as_string(GameMain.SETTINGS_PATH), before, "ServerLink.create writes no Settings")


func test_e2e_scenarios_lint() -> void:
	var console := DevConsole.new(host.get_tree())
	console.keep_history = false
	console.load_commands(false)
	var env_line := RegEx.create_from_string("^#! (env [A-Za-z_][A-Za-z0-9_]*=.*|worker|content real)$")
	var names := Array(DirAccess.get_files_at(SCENARIOS)).filter(func(file: String) -> bool: return file.ends_with(".txt"))
	check(names.size() >= 4, "the scenarios are there: %s" % [names])
	for file in names:
		for line in FileAccess.get_file_as_string(SCENARIOS + file).split("\n"):
			var text := line.strip_edges()
			if text.begins_with("#! "):
				check(env_line.search(text) != null, "%s: a well-formed directive: %s" % [file, text])
			elif text != "" and not text.begins_with("#"):
				var command := DevConsole.tokenize(text)[0].to_lower()
				check(console.commands.has(command), "%s: '%s' is a known command" % [file, command])
		var sql: String = SCENARIOS + str(file).get_basename() + ".sql"
		if FileAccess.file_exists(sql):
			for line in FileAccess.get_file_as_string(sql).split("\n"):
				if line.strip_edges() != "":
					check(line.to_lower().begins_with("select") and not line.contains(";"), "%s: one select per line" % sql)


func test_e2e_check() -> void:
	if skip_in_export():
		return
	var bash := OS.get_environment("RPG_BASH")
	if bash == "":
		bash = OS.get_environment("ProgramFiles").path_join("Git/bin/bash.exe")
	check(FileAccess.file_exists(bash), "Git Bash found at %s (set RPG_BASH otherwise)" % bash)
	var script := ProjectSettings.globalize_path("res://").path_join("../tools/e2e.sh").simplify_path()
	var output := []
	var code := OS.execute(bash, [script, "--check"], output, true)
	eq(code, 0, "tools/e2e.sh --check: %s" % "".join(output).strip_edges())


const VERIFIED: Dictionary = {"status": "Verified", "errorCode": null, "error": null, "mismatch": null, "outcome": "Victory",
	"turns": 12, "finalStateHash": "abc", "verifierRulesetVersion": "x", "engineVersion": "y", "verifiedAt": "2026-11-01T12:00:00+00:00"}
const REJECTED: Dictionary = {"status": "Rejected", "errorCode": 2002, "error": "ReplayMismatch",
	"mismatch": {"reason": "FinalHashMismatch", "turn": 3, "detail": "d"}, "outcome": "Victory", "turns": 3,
	"finalStateHash": "abc", "verifierRulesetVersion": "x", "engineVersion": "y", "verifiedAt": "2026-11-01T12:00:00+00:00"}


static func _battle_answer(status: String, verdict: Variant) -> Array:
	return [true, {"battleId": "b1", "runId": RUN_ID, "runSeq": 2, "status": status, "verdict": verdict}]


## A server run with one battle in its log (seq 2 after the start_run), as the journal numbers it.
func _session_with_a_battle(bridge: RefCounted) -> Array:
	var session := _session(bridge)
	await _run(session, "new %s run=fixture.run.two_floors" % PARTY)
	await _run(session, "wait run 5")
	session[0].run.run_log.append({"type": "battle", "battleId": "b1"})
	return session


## Spec battle-verify 2.2: `server verdict [seq]` reports what the verifier decided; a pending or rejected battle is
## information, an unreadable one fails.
func test_server_verdict_command() -> void:
	var bridge := _bridge()
	var session := _session(bridge)
	await _run(session, "new %s run=fixture.run.two_floors" % PARTY)
	await _run(session, "wait run 5")
	var none := await _run(session, "server verdict")
	check(not none["ok"] and none["text"].contains("no battle"), "a run without battles has no verdicts: " + none["text"])
	session[0].run.run_log.append({"type": "battle", "battleId": "b1"})
	bridge.answers["GetBattle"] = [_battle_answer("Submitted", null)]
	var pending := await _run(session, "server verdict")
	check(pending["ok"] and pending["text"].contains("seq 2 (b1): Submitted"), "pending: " + pending["text"])
	bridge.answers["GetBattle"] = [_battle_answer("Verified", VERIFIED)]
	var verified := await _run(session, "server verdict 2")
	check(verified["ok"] and verified["text"].contains("Verified (12 turns, outcome Victory)"), "verified: " + verified["text"])
	bridge.answers["GetBattle"] = [_battle_answer("Rejected", REJECTED)]
	var rejected := await _run(session, "server verdict")
	check(rejected["ok"] and rejected["text"].contains("Rejected 2002 ReplayMismatch FinalHashMismatch at turn 3"),
		"a rejection is reported with its reason, not an error: " + rejected["text"])
	check(not (await _run(session, "server verdict x"))["ok"], "the seq is a number")
	var wrong := await _run(session, "server verdict 1")
	check(not wrong["ok"] and wrong["text"].contains("no battle at seq 1"), "seq 1 is not a battle: " + wrong["text"])
	bridge.answers["GetBattle"] = [ServerTests._error(404, null, "Battle not found")]
	var unreadable := await _run(session, "server verdict")
	check(not unreadable["ok"] and unreadable["text"].contains("unreadable"), "an unreadable battle fails: " + unreadable["text"])
	check(not (await _run(_session(), "server verdict"))["ok"], "local mode has no verdicts")
	await host.get_tree().process_frame  # don't end inside the link's signal: after_each frees it


## Spec settlement-outbox: `server wallet` shows the gems and the ledger; `wait gems` polls until the worker paid.
func test_server_wallet_and_wait_gems() -> void:
	var bridge := _bridge()
	var session := _session(bridge)
	bridge.answers["GetWallet"] = [[true, {"gems": 20, "version": 2, "recent": [
		{"currency": "gems", "delta": 10, "reason": "boss_mark", "refBattleId": "b1", "at": "2026-11-02T10:00:00+00:00"}]}]]
	var shown := await _run(session, "server wallet")
	check(shown["ok"] and shown["text"].contains("gems 20 (version 2)") and shown["text"].contains("+10 gems boss_mark (battle b1)"),
		"the wallet is shown: " + shown["text"])
	var paid := await _run(session, "wait gems 20 2")
	check(paid["ok"], "enough gems: " + paid["text"])
	var short := await _run(session, "wait gems 30 0.6")
	check(not short["ok"] and short["text"].contains("waited") and short["text"].contains("20 gems"), "too few gems fail with the balance: " + short["text"])
	check(not (await _run(session, "wait gems x"))["ok"], "gems takes a number")
	await host.get_tree().process_frame


## Spec economy-challenges: `server reward` lists the ladders, sets one (a boss through boss/<id>), and reports a refusal instead of swallowing it.
func test_server_reward_command() -> void:
	var bridge := _bridge()
	var session := _session(bridge)
	var rule := {"challengeId": "boss/demo.enemy.lich", "currency": "gems", "tiers": [25], "cycle": "once", "generation": 2, "version": 3,
		"effectiveFrom": "2026-11-03T10:00:00+00:00", "createdBy": "designer"}
	bridge.answers["ListRewardRules"] = [[true, {"rules": [rule]}]]
	var listed := await _run(session, "server reward")
	check(listed["ok"] and listed["text"].contains("boss/demo.enemy.lich: 25 gems once (version 3, generation 2, by designer)"), "the ladders are listed: " + listed["text"])
	bridge.answers["ListRewardRules"] = [[true, {"rules": []}]]
	var none := await _run(session, "server reward")
	check(none["ok"] and none["text"].contains("no reward rules"), "an empty table: " + none["text"])
	bridge.answers["PutRewardRule"] = [[true, rule]]
	var set := await _run(session, "server reward boss demo.enemy.lich 25")
	check(set["ok"] and set["text"].contains("version 3"), "a rule is set and its version printed: " + set["text"])
	var puts := func() -> Array: return bridge.calls.filter(func(call: Array) -> bool: return call[0] == "PutRewardRule")
	var sent: Dictionary = JSON.parse_string(puts.call()[0][1])
	check(sent.get("challengeId") == "boss/demo.enemy.lich" and sent.get("currency") == "gems" and sent.get("tiers") == [25.0] and not sent.has("cycle"), "the boss PUT body: " + str(sent))
	await _run(session, "server reward event.spring.trial-3 10,10,15 cycle=weekly ends=2026-12-01T00:00:00Z")
	var ladder: Dictionary = JSON.parse_string(puts.call()[1][1])
	check(ladder.get("challengeId") == "event.spring.trial-3" and ladder.get("tiers") == [10.0, 10.0, 15.0] and ladder.get("cycle") == "weekly" and ladder.get("endsAt") == "2026-12-01T00:00:00Z", "the ladder PUT body: " + str(ladder))
	await _run(session, "server reward boss demo.enemy.lich 0")
	check(JSON.parse_string(puts.call()[2][1]).get("tiers") == [], "a lone 0 retires the ladder")
	bridge.answers["PutRewardRule"] = [ServerTests._error(403, 1302, "Economy admin required")]
	var refused := await _run(session, "server reward boss demo.enemy.lich 5")
	check(not refused["ok"] and refused["text"].contains("403") and refused["text"].contains("1302"), "a refusal is reported: " + refused["text"])
	check(not (await _run(session, "server reward demo.enemy.lich"))["ok"], "usage: an amount is needed")
	check(not (await _run(session, "server reward boss demo.enemy.lich x"))["ok"], "usage: the amount is a number")
	check(not (await _run(session, "server reward boss demo.enemy.lich 10,-1"))["ok"], "usage: not negative")
	check(not (await _run(session, "server reward boss demo.enemy.lich 10 colour=red"))["ok"], "usage: unknown option")
	await host.get_tree().process_frame


## Spec economy-challenges 2.2: `server reward-reset` for everyone, for me, for a player id, and a boss.
func test_server_reward_reset_command() -> void:
	var bridge := _bridge()
	var session := _session(bridge)
	bridge.answers["ResetRewardCycle"] = [[true, {"challengeId": "event.spring.trial-3", "generation": 1, "resetAt": "2026-11-06T10:00:00+00:00", "resetBy": "designer"}]]
	var everyone := await _run(session, "server reward-reset event.spring.trial-3")
	check(everyone["ok"] and everyone["text"].contains("everyone") and everyone["text"].contains("generation 1"), "a reset for everyone: " + everyone["text"])
	var resets := func() -> Array: return bridge.calls.filter(func(call: Array) -> bool: return call[0] == "ResetRewardCycle")
	check(JSON.parse_string(resets.call()[0][1]) == {"challengeId": "event.spring.trial-3"}, "no player and no reason are sent: " + str(resets.call()[0][1]))
	await _run(session, "server reward-reset boss demo.enemy.lich player=11111111-1111-1111-1111-111111111111 support asked")
	var one: Dictionary = JSON.parse_string(resets.call()[1][1])
	check(one.get("challengeId") == "boss/demo.enemy.lich" and one.get("playerId") == "11111111-1111-1111-1111-111111111111" and one.get("reason") == "support asked", "a boss, a player and a reason: " + str(one))
	session[0].server.player_id = "22222222-2222-2222-2222-222222222222"
	await _run(session, "server reward-reset event.spring.trial-3 player=me")
	check(JSON.parse_string(resets.call()[2][1]).get("playerId") == "22222222-2222-2222-2222-222222222222", "player=me sends the signed-in player's id")
	bridge.answers["ResetRewardCycle"] = [ServerTests._error(403, 1302, "Economy admin required")]
	var refused := await _run(session, "server reward-reset event.spring.trial-3")
	check(not refused["ok"] and refused["text"].contains("403"), "a refusal is reported: " + refused["text"])
	check(not (await _run(session, "server reward-reset"))["ok"], "usage: an id is needed")
	await host.get_tree().process_frame


## Spec battle-verify 2.2: `wait verdict` polls until the verifier has decided (Verified or Rejected).
func test_wait_verdict() -> void:
	var bridge := _bridge()
	var session := await _session_with_a_battle(bridge)
	bridge.answers["GetBattle"] = [_battle_answer("Submitted", null), _battle_answer("Rejected", REJECTED)]
	var decided := await _run(session, "wait verdict all 10")
	check(decided["ok"] and decided["text"].contains("Rejected 2002"), "it waited for the worker: " + decided["text"])
	check(bridge.count("GetBattle") >= 2, "and polled")
	bridge.answers["GetBattle"] = [_battle_answer("Submitted", null)]
	var never := await _run(session, "wait verdict 2 0.3")
	check(not never["ok"] and never["text"].contains("waited") and never["text"].contains("Submitted"),
		"a battle that stays Submitted fails with its state: " + never["text"])
	check(not (await _run(session, "wait verdict"))["ok"], "usage")
	check(not (await _run(session, "wait verdict nope"))["ok"], "all or a seq")
	check(not (await _run(session, "wait verdict 1 0.2"))["ok"], "seq 1 is not a battle")
	check(not (await _run(_session(), "wait verdict all 0.2"))["ok"], "local mode has nothing to wait for")
	await host.get_tree().process_frame


## Spec battle-verify 6: the harness's worker and tamper steps are known actions, answered like the others.
func test_e2e_worker_actions() -> void:
	var session := _session()
	session[1].control_dir = CONTROL
	var seen := []
	var answer := func() -> void:
		seen.append(FileAccess.get_file_as_string(CONTROL.path_join("request")))
		var file := FileAccess.open(CONTROL.path_join("done"), FileAccess.WRITE)
		file.store_string("ok")
		file.close()
	for action in ["worker-start", "worker-stop", "tamper-battle"]:
		host.get_tree().create_timer(0.3).timeout.connect(answer)
		var done := await _run(session, "e2e %s 5" % action)
		check(done["ok"], "%s: %s" % [action, done["text"]])
	eq(seen, ["worker-start", "worker-stop", "tamper-battle"], "each asked for its own action")


## Spec dev-tools E9: `wait ended` holds until the end screen (a death here; a win only after the verdict).
func test_wait_ended() -> void:
	var session := _session()
	await _run(session, "new %s 7 run=fixture.run.two_floors" % PARTY)
	check(not (await _run(session, "wait ended 0.1"))["ok"], "a run in progress has not ended")
	session[0].run._end(RunState.LOST)
	var ended := await _run(session, "wait ended 1")
	check(ended["ok"], "the run ended: " + ended["text"])


## Spec dev-tools E9: `server forget`, `server conflict` (a 1103 rebuilds the run from the server's log) and
## `server resume` (from the local save; nothing to resume fails).
func test_server_save_commands() -> void:
	var bridge: RefCounted = _bridge()
	var session := _session(bridge)
	await _run(session, "new %s run=fixture.run.two_floors" % PARTY)
	await _run(session, "wait run 5")
	var link: ServerLink = session[0].server
	await link.drained()
	check(FileAccess.file_exists(link.save_path()), "a linked run keeps a local save")
	var forgot := await _run(session, "server forget")
	check(forgot["ok"] and not FileAccess.file_exists(link.save_path()), "server forget deletes it")
	var start: Dictionary = JSON.parse_string(bridge.of("SendActions")[0][2])["actions"][0]
	bridge.answers["SendActions"] = [ServerTests._error(409, 1103, "Sequence conflict"), "default"]
	bridge.answers["Resume"] = [[true, {"runId": RUN_ID, "status": "Active",
		"floorSeeds": [{"runId": RUN_ID, "floor": 0, "floorSeed": "5150"}], "checkpointSeq": 1,
		"snapshot": start["snapshot"], "tail": []}]]
	var conflict := await _run(session, "server conflict")
	check(conflict["ok"], "server conflict resends an acknowledged action: " + conflict["text"])
	var rebuilt := await _run(session, "wait notice continues 5")
	check(rebuilt["ok"], "the 1103 rebuilds the run from the server's log: " + rebuilt["text"])
	eq(link.resumes, 1, "one rebuild")
	eq(session[0].run.state.run_hash(), str(start["stateHash"]), "at the server's state")
	bridge.answers["GetCurrentRun"] = [[true, {"runId": RUN_ID, "status": "Active", "currentFloor": 0, "lastSeq": 1,
		"rulesetVersion": "x", "startedAt": "2026-10-27T12:00:00+00:00", "endedAt": null}]]
	var resumed := await _run(session, "server resume")
	check(resumed["ok"] and resumed["text"].contains("from the save"), "server resume: " + resumed["text"])
	bridge.answers["GetCurrentRun"] = [[true, null]]
	check(not (await _run(session, "server resume"))["ok"], "nothing to resume fails")
	await host.get_tree().process_frame  # don't end inside the link's signal: after_each frees it
