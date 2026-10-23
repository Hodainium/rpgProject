## Spec ult-interrupts: ults cast out of turn at the two HSR windows (BETWEEN actions, DECISION on a party turn), enemy
## interrupts, retargeting, the "interrupt" log field and its replay. Fixtures only (ultists vs the ult trial).
extends TestCase

const STRIKE: StringName = &"Fixture.Ability.Strike"
const NOVA: StringName = &"Fixture.Ability.UltNova"
const SNIPE: StringName = &"Fixture.Ability.UltSnipe"
const WARD: StringName = &"Fixture.Ability.UltWard"
const RAISE: StringName = &"Fixture.Ability.UltRaise"
const RAGE: StringName = &"Fixture.Ability.UltRage"
const SACRIFICE: StringName = &"Fixture.Ability.UltSacrifice"


## Ultists (full ult charge at battle start, +50 per action) against the ult trial: E1 sprinter (SPD 200, acts first),
## E2 brittle (weak to Fire), E3 raging (its ult charges +50 per hit taken).
static func ult_snapshot(party: Array = ["ultist", "ultist"], encounter: String = "ult_trial", seed_text: String = "7") -> Dictionary:
	var members := []
	for index in party.size():
		members.append({"slot": index + 1, "unitDefId": "fixture.character." + party[index], "level": 1, "skills": [],
			"equipmentIds": [], "items": [], "useSlots": []})
	return {"schemaVersion": 2, "battleId": "ult-seed-%s" % seed_text, "seed": seed_text,
		"encounterId": "fixture.encounter." + encounter, "party": members}


## Plays a battle with an ActionRecorder whose party always strikes the first enemy; `setup` presses ults.
func _play(snap: Dictionary, setup: Callable = Callable()) -> Dictionary:
	var battle := new_battle(snap)
	var recorder := ActionRecorder.new()
	var events := []
	battle.turn_started.connect(func(unit_id, turn): events.append(["turn", unit_id, turn]))
	battle.interrupt_started.connect(func(unit_id, ability): events.append(["ult", unit_id, ability, battle.turn]))
	if setup.is_valid():
		setup.call(battle, recorder)
	recorder.action_requested.connect(func(unit_id, _turn): _strike(battle, recorder, unit_id))
	await battle.run(recorder)
	check(battle.runner_error == "", "no runner error: " + battle.runner_error)
	return {"battle": battle, "recorder": recorder, "events": events,
		"request": {"snapshot": snap, "actionLog": recorder.action_log(battle)}}


static func _strike(battle: Battle, recorder: ActionRecorder, unit_id: StringName) -> void:
	if recorder.waiting_for != unit_id or recorder.pending_interrupts() > 0:
		return
	var unit := battle.unit_by_id(unit_id)
	var targets := battle.target_candidates(unit, unit.ability_by_tag(STRIKE))
	if not targets.is_empty():
		recorder.submit_action(STRIKE, targets[0].unit_id)


static func _shape(entries: Array) -> Array:
	return entries.map(func(entry): return [int(entry["turn"]), entry["actor"], entry["ability"], entry["target"],
		entry.get("interrupt", false), entry.get("extra", false)])


func _verified(request: Dictionary, message: String) -> void:
	var result := await replay(request)
	eq([result.get("verdict"), result.get("mismatch")], ["Verified", null], message)


func _rejected(request: Dictionary, reasons: Array, message: String) -> void:
	var result := await replay(request)
	var reason: Variant = result.get("mismatch", {}).get("reason") if result.get("mismatch") is Dictionary else null
	check(result.get("errorCode") == 2002 and reasons.has(reason), "%s: expected 2002 %s, got %s %s" % [message, reasons,
		result.get("errorCode"), result.get("mismatch")])


static func _remaining(unit: BattleUnit, effect_file: String) -> int:
	for active_effect in unit.asc._active_effects:
		if active_effect.spec.effect_def.resource_path.ends_with(effect_file):
			return active_effect.spec.remaining_turns
	return 0


func test_action_abilities_exclude_ults() -> void:
	var battle := new_battle(ult_snapshot())
	var ultist := battle.unit_by_id(&"P1")
	eq(ultist.action_abilities().map(func(a): return a.ability_tag), [STRIKE], "ults and passives are never turn actions")
	eq(ultist.ultimate_abilities().map(func(a): return a.ability_tag), [NOVA, SNIPE, WARD, RAISE], "ults in grant order")
	eq(battle.unit_by_id(&"E3").action_abilities().map(func(a): return a.ability_tag), [&"Fixture.Ability.Claw"],
		"an enemy brain never picks its ult as a turn action")
	eq(battle.validate_action(ultist, {"ability": SNIPE, "target": &"E1"})[0], "IllegalAbility", "an ult as a turn action")


func test_interrupt_entry_shape() -> void:
	var entry := ActionRecorder.entry(3, &"P1", {"ability": NOVA, "target": &""}, false, true)
	eq(entry.keys(), ["turn", "actor", "ability", "target", "interrupt"], "field order matches the C# record")
	eq(entry["interrupt"], true, "interrupt written when true")
	check(not ActionRecorder.entry(3, &"P1", {"ability": STRIKE, "target": &"E1"}).has("interrupt"),
		"and only then")


## A press during an enemy's turn fires after that action, before the next turn starts (BETWEEN window).
func test_ult_between_turns() -> void:
	var played := await _play(ult_snapshot(), func(battle: Battle, recorder: ActionRecorder):
		var pressed := [false]
		battle.turn_started.connect(func(unit_id, _turn):
			if unit_id == &"E1" and not pressed[0]:
				pressed[0] = true
				recorder.submit_ult(&"P1", SNIPE, &"E2")))
	var events: Array = played["events"]
	var ult := events.find(["ult", &"P1", SNIPE, 1])
	check(ult > 0 and events[ult - 1] == ["turn", &"E1", 1] and events[ult + 1][2] == 2,
		"the ult fires between enemy turn 1 and turn 2: %s" % [events.slice(0, 4)])
	var entries: Array = played["request"]["actionLog"]["actions"]
	eq(_shape(entries)[0], [1, "P1", String(SNIPE), "E2", true, false], "logged with its window's turn and interrupt")
	await _verified(played["request"], "a BETWEEN interrupt replays")


## On your own turn the ult goes first and the turn is not spent. A self-buff cast there skips that turn's countdown;
## cast in BETWEEN it counts down at the caster's next turn end.
func test_ult_on_own_turn_keeps_turn() -> void:
	var seen := {}
	var played := await _play(ult_snapshot(), func(battle: Battle, recorder: ActionRecorder):
		var state := {"own": false, "between": false}
		battle.turn_started.connect(func(unit_id, turn):
			if unit_id == &"E1" and not state["between"]:
				state["between"] = true
				recorder.submit_ult(&"P2", WARD)
			if turn == 3:
				seen["p1_after_own_turn"] = _remaining(battle.unit_by_id(&"P1"), "effects/guard.tres")
			if turn == 4:
				seen["p2_after_its_turn"] = _remaining(battle.unit_by_id(&"P2"), "effects/guard.tres"))
		recorder.action_requested.connect(func(unit_id, _turn):
			if unit_id == &"P1" and not state["own"]:
				state["own"] = true
				recorder.submit_ult(&"P1", WARD)))
	var shape := _shape(played["request"]["actionLog"]["actions"])
	eq(shape.slice(0, 3), [[1, "P2", String(WARD), null, true, false], [2, "P1", String(WARD), null, true, false],
		[2, "P1", String(STRIKE), "E1", false, false]], "P2 wards in BETWEEN 1; P1 wards on its turn 2, then still strikes")
	eq(seen.get("p1_after_own_turn"), 2, "an own-turn ult's self-buff skips that turn's countdown")
	eq(seen.get("p2_after_its_turn"), 1, "a BETWEEN ult's self-buff counts down at the caster's next turn end")
	await _verified(played["request"], "DECISION interrupts replay")


func test_ult_chain() -> void:
	var played := await _play(ult_snapshot(), func(_battle: Battle, recorder: ActionRecorder):
		recorder.submit_ult(&"P2", SNIPE, &"E1")
		recorder.submit_ult(&"P1", NOVA))
	eq(_shape(played["request"]["actionLog"]["actions"]).slice(0, 2), [[0, "P2", String(SNIPE), "E1", true, false],
		[0, "P1", String(NOVA), null, true, false]], "two presses fire back to back in the first window, in press order")
	# Spec atomic-battles: the log has no per-entry hash; the trace shows each interrupt as its own state.
	var runner := ReplayRunner.new()
	runner.trace = BattleTrace.new()
	await runner.run(copy(played["request"]), FIXTURES, host)
	var chain := runner.trace.points.filter(func(entry) -> bool: return entry["kind"] == "interrupt" and entry["turn"] == 0)
	check(chain.size() >= 2 and chain[0]["hash"] != chain[1]["hash"], "each interrupt has its own trace point")
	await _verified(played["request"], "a chain replays")


## Two snipes fill E3's charge (+50 per hit) in the window before turn 1; E3 answers at the next window, before the
## party press queued during turn 1 (enemies first). Enemy ults are re-simulated, never logged.
func test_enemy_interrupt() -> void:
	var played := await _play(ult_snapshot(["ultist", "ultist", "ultist"]), func(battle: Battle, recorder: ActionRecorder):
		recorder.submit_ult(&"P1", SNIPE, &"E3")
		recorder.submit_ult(&"P2", SNIPE, &"E3")
		var pressed := [false]
		battle.turn_started.connect(func(unit_id, _turn):
			if unit_id == &"E1" and not pressed[0]:
				pressed[0] = true
				recorder.submit_ult(&"P3", SNIPE, &"E1")))
	var events: Array = played["events"]
	var ults := events.filter(func(event): return event[0] == "ult").map(func(event): return [event[1], event[3]])
	eq(ults.slice(0, 4), [[&"P1", 0], [&"P2", 0], [&"E3", 1], [&"P3", 1]],
		"E3 is full after the window that charged it, ults at the next one, before the party's press")
	var actors: Array = played["request"]["actionLog"]["actions"].map(func(entry): return entry["actor"])
	check(not actors.has("E3"), "enemy interrupts are not logged")
	await _verified(played["request"], "an enemy interrupt is re-simulated in replay")


func test_no_enemy_ult_no_rng() -> void:
	var battle := new_battle(ult_snapshot())
	var state := battle.rng.state
	var brain := EnemyBrain.new()
	eq(brain.choose_interrupt(battle.unit_by_id(&"E1"), battle), {}, "no ult: nothing to cast")
	eq(brain.choose_interrupt(battle.unit_by_id(&"E3"), battle), {}, "an ult without a full charge: nothing to cast")
	eq(battle.rng.state, state, "and no RNG draw")
	var request: Dictionary = await record(preload("res://tests/combat/test_item_pass_combat.gd").break_snapshot())
	check(not WireJson.stringify(request).contains("interrupt"), "a battle without ults logs no interrupt")


## Four snipes on E1 (the next actor): three kill it before its turn, the fourth was aimed at a dead unit and is
## retargeted to the nearest slot (E2). The log holds the target actually hit, so the replay just checks it.
func test_ult_kills_next_actor_and_retargets() -> void:
	var played := await _play(ult_snapshot(["ultist", "ultist", "ultist", "ultist"]),
		func(_battle: Battle, recorder: ActionRecorder):
			for slot in [1, 2, 3, 4]:
				recorder.submit_ult(StringName("P%d" % slot), SNIPE, &"E1"))
	var battle: Battle = played["battle"]
	var targets := _shape(played["request"]["actionLog"]["actions"]).slice(0, 4).map(func(entry): return entry[3])
	eq(targets, ["E1", "E1", "E1", "E2"], "the last press is retargeted once E1 is dead")
	var turns: Array = played["events"].filter(func(event): return event[0] == "turn")
	check(not turns.is_empty() and turns[0][1] != &"E1", "the dead next actor never takes its turn: %s" % [turns.slice(0, 1)])
	check(not battle.unit_by_id(&"E1").alive, "E1 died in the window")
	await _verified(played["request"], "a retargeted interrupt replays")


func test_retarget_rules() -> void:
	var battle := new_battle(ult_snapshot(["ultist", "ultist", "ultist"]))
	var p1 := battle.unit_by_id(&"P1")
	var snipe := p1.ability_by_tag(SNIPE)
	var raise := p1.ability_by_tag(RAISE)
	var e1 := battle.unit_by_id(&"E1")
	var e2 := battle.unit_by_id(&"E2")
	var e3 := battle.unit_by_id(&"E3")
	eq(battle.retarget(p1, snipe, e2), e2, "a valid target stays")
	_kill(battle, [e2])
	eq(battle.retarget(p1, snipe, e2), e1, "both neighbours alive: the lower slot")
	_kill(battle, [e1])
	eq(battle.retarget(p1, snipe, e1), e3, "else the nearest living one")
	var p2 := battle.unit_by_id(&"P2")
	var p3 := battle.unit_by_id(&"P3")
	_kill(battle, [p2, p3])
	eq(battle.retarget(p1, raise, p2), p2, "a revive keeps its dead ally")
	p2.asc.initialize_attribute_overrides({BattleUnit.HP: 50000.0})
	battle._check_revives()
	eq(battle.retarget(p1, raise, p2), p3, "an ally already back: the next dead ally")
	p3.asc.initialize_attribute_overrides({BattleUnit.HP: 50000.0})
	battle._check_revives()
	eq(battle.retarget(p1, raise, p2), null, "no dead ally left: nothing")
	eq(battle.resolve_press({"unit": &"P1", "ability": RAISE, "target": &"P2"}).get("problem", [""])[0], "InvalidTarget",
		"so the press can't fire")


## A press that can't fire any more at its window is dropped with action_rejected and never logged.
func test_queued_ult_dropped() -> void:
	var battle := new_battle(ult_snapshot())
	var recorder := ActionRecorder.new()
	var rejected := []
	recorder.action_rejected.connect(func(unit_id, reason, _detail): rejected.append([unit_id, reason]))
	battle.unit_by_id(&"P1").asc.initialize_attribute_overrides({BattleUnit.ENERGY: 10000.0})
	recorder.submit_ult(&"P1", SNIPE, &"E1")
	recorder.submit_ult(&"P1", SNIPE, &"E1")
	var first := recorder.interrupt(battle)
	eq(first.get("unit"), &"P1", "the first press fires")
	await battle._interrupt(battle.unit_by_id(&"P1"), first, recorder)
	eq(recorder.interrupt(battle), {}, "the second has no charge left")
	_kill(battle, [battle.unit_by_id(&"P2")])
	recorder.submit_ult(&"P2", NOVA)
	eq(recorder.interrupt(battle), {}, "a dead caster's press")
	eq(rejected, [[&"P1", "IllegalAbility"], [&"P2", "ActorMismatch"]], "both dropped with action_rejected")
	eq(recorder.entries.size(), 1, "only the cast press is logged")


func test_ult_break_one_more_and_ult_during_it() -> void:
	var played := await _play(ult_snapshot(), func(battle: Battle, recorder: ActionRecorder):
		recorder.submit_ult(&"P1", NOVA)
		var pressed := [false]
		recorder.action_requested.connect(func(_unit_id, _turn):
			if battle.extra_action and not pressed[0]:
				pressed[0] = true
				recorder.submit_ult(&"P2", WARD)))
	eq(_shape(played["request"]["actionLog"]["actions"]).slice(0, 3), [[0, "P1", String(NOVA), null, true, false],
		[1, "P2", String(WARD), null, true, false], [1, "P1", String(STRIKE), "E1", false, true]],
		"the nova breaks E2: One More for P1 (turn 1), and P2 ults inside that decision")
	check(played["events"].has(["turn", &"P1", 1]), "the One More runs before any normal turn")
	await _verified(played["request"], "an ult break with a One More replays")


func test_ult_ends_battle() -> void:
	var played := await _play(ult_snapshot(["ultist", "ultist", "ultist"], "lone"), func(_battle: Battle, recorder: ActionRecorder):
		recorder.submit_ult(&"P1", SNIPE, &"E1")
		recorder.submit_ult(&"P2", SNIPE, &"E1")
		recorder.submit_ult(&"P3", SNIPE, &"E1"))
	var battle: Battle = played["battle"]
	eq([battle.outcome, battle.turn], ["Victory", 0], "two snipes win before the first turn")
	eq(played["request"]["actionLog"]["actions"].size(), 2, "no interrupt after the end")
	eq(played["recorder"].pending_interrupts(), 1, "the last press is left unfired")
	await _verified(played["request"], "a battle won by interrupts replays")


## The martyr ults itself to death inside its own DECISION window: no action that turn; the press queued with it
## fires at the BETWEEN window of the same turn, and client and replay agree.
func test_actor_dies_in_decision_window() -> void:
	var played := await _play(ult_snapshot(["martyr", "ultist"]), func(_battle: Battle, recorder: ActionRecorder):
		var pressed := [false]
		recorder.action_requested.connect(func(unit_id, _turn):
			if unit_id == &"P1" and not pressed[0]:
				pressed[0] = true
				recorder.submit_ult(&"P1", SACRIFICE)
				recorder.submit_ult(&"P2", NOVA)))
	var shape := _shape(played["request"]["actionLog"]["actions"])
	eq(shape.slice(0, 3), [[2, "P1", String(SACRIFICE), null, true, false], [2, "P2", String(NOVA), null, true, false],
		[3, "P2", String(STRIKE), "E1", false, true]],
		"the martyr dies at its decision; P2's nova follows in BETWEEN 2 and breaks E2 (One More, turn 3)")
	check(not played["battle"].unit_by_id(&"P1").alive, "the martyr is dead")
	await _verified(played["request"], "a death inside the DECISION window replays")


## The scripted policy covers both windows (odd turns BETWEEN, even turns DECISION) and the raging dummy's ult.
func test_record_replay_roundtrip_with_interrupts() -> void:
	var battle := new_battle(ult_snapshot())
	var enemy_ults := []
	battle.interrupt_started.connect(func(unit_id, _ability):
		if not String(unit_id).begins_with("P"):
			enemy_ults.append(unit_id))
	var controller := ScriptedController.new()
	await battle.run(controller)
	check(battle.runner_error == "", "no runner error: " + battle.runner_error)
	var entries := controller.entries
	var by_actor := {}
	for entry in entries:
		if entry.get("interrupt", false):
			by_actor[entry["actor"]] = by_actor.get(entry["actor"], 0) + 1
	check(by_actor.get("P1", 0) > 0 and by_actor.get("P2", 0) > 0,
		"interrupts in both windows (P1 casts in BETWEEN, P2 in DECISION): %s" % [by_actor])
	check(not enemy_ults.is_empty(), "the raging dummy ulted")
	var request := {"snapshot": ult_snapshot(), "actionLog": ActionRecorder.build_log(entries, battle.outcome, battle.final_hash)}
	await _verified(request, "a scripted battle full of interrupts replays")


## A window asks again after each interrupt, so consecutive calls of one kind and turn are one window.
func test_window_order() -> void:
	var battle := new_battle(ult_snapshot())
	var controller := ProbeController.new()
	await battle.run(controller)
	var calls := []
	for call in controller.calls:
		if calls.is_empty() or calls[calls.size() - 1] != call:
			calls.append(call)
	eq(calls[0], ["between", 0], "the first window opens before the first turn")
	var between_turns: Array = calls.filter(func(call): return call[0] == "between").map(func(call): return call[1])
	var increasing := true
	for index in range(1, between_turns.size()):
		increasing = increasing and between_turns[index] > between_turns[index - 1]
	check(increasing, "one BETWEEN window per turn number: %s" % [between_turns])
	for index in calls.size():
		if calls[index][0] == "decision":
			var later_between: int = calls.slice(index).map(func(call): return call[0]).find("between")
			check(later_between == -1 or calls[index + later_between][1] == calls[index][1],
				"the DECISION of turn %d comes before BETWEEN %d" % [calls[index][1], calls[index][1]])


func test_tampered_interrupts() -> void:
	var request := await record(ult_snapshot())
	var actions: Array = request["actionLog"]["actions"]
	var first := -1
	var strike := -1
	for index in actions.size():
		if actions[index].get("interrupt", false) and first < 0:
			first = index
		if not actions[index].get("interrupt", false) and actions[index]["ability"] == String(STRIKE) and strike < 0:
			strike = index
	check(first >= 0 and strike >= 0, "the recording has interrupts and strikes")
	await _verified(request, "the untouched recording replays")

	var twice := copy(request)
	twice["actionLog"]["actions"].insert(first + 1, twice["actionLog"]["actions"][first].duplicate())
	await _rejected(twice, ["IllegalAbility"], "the same ult again with its charge spent")
	var moved := copy(request)
	moved["actionLog"]["actions"][first]["turn"] = int(moved["actionLog"]["actions"][first]["turn"]) + 1
	# Spec atomic-battles: without checkpoints a removed or moved interrupt surfaces at the next structural check.
	await _rejected(moved, ["TurnMismatch"], "an interrupt moved one turn")
	var removed := copy(request)
	removed["actionLog"]["actions"].remove_at(first)
	await _rejected(removed, ["TurnMismatch"], "an interrupt deleted")
	var enemy := copy(request)
	enemy["actionLog"]["actions"][first]["actor"] = "E1"
	await _rejected(enemy, ["ActorMismatch"], "an interrupt by an enemy")
	var both := copy(request)
	both["actionLog"]["actions"][first]["extra"] = true
	await _rejected(both, ["TurnMismatch"], "interrupt and extra together")
	var as_action := copy(request)
	as_action["actionLog"]["actions"][strike]["ability"] = String(SNIPE)
	await _rejected(as_action, ["IllegalAbility"], "an ult logged as a turn action")


## Two full enemies in one window: slot order, one ult each, no loop.
func test_enemy_interrupts_slot_order() -> void:
	var battle := new_battle(ult_snapshot(["ultist", "ultist"], "rage_pair"))
	var cast := []
	battle.interrupt_started.connect(func(unit_id, ability): cast.append([unit_id, ability]))
	for id in [&"E2", &"E1"]:
		_set_stat(battle.unit_by_id(id), BattleUnit.ENERGY, 10000.0)
	await battle._ult_window(ActionRecorder.new())
	eq(cast, [[&"E1", RAGE], [&"E2", RAGE]], "slot order, one ult each")
	await battle._ult_window(ActionRecorder.new())
	eq(cast.size(), 2, "spent charges: the next window casts nothing")


## An enemy ult in the window kills the ally a queued party ult was aimed at; the press retargets (nearest slot, the
## lower one on a tie) and the log holds the ally actually shielded.
func test_queued_ult_retargets_after_enemy_ult() -> void:
	var battle := new_battle(ult_snapshot(["warden", "ultist", "ultist"]))
	await battle._drain_triggers()
	_set_stat(battle.unit_by_id(&"P1"), BattleUnit.ENERGY, 10000.0)
	_set_stat(battle.unit_by_id(&"P2"), BattleUnit.HP, 100.0)
	_set_stat(battle.unit_by_id(&"E3"), BattleUnit.ENERGY, 10000.0)
	var recorder := ActionRecorder.new()
	var cast := []
	battle.interrupt_started.connect(func(unit_id, _ability): cast.append(unit_id))
	recorder.submit_ult(&"P1", &"Fixture.Ability.UltShield", &"P2")
	await battle._ult_window(recorder)
	eq(cast, [&"E3", &"P1"], "the enemy ult first, then the press")
	check(not battle.unit_by_id(&"P2").alive, "the enemy ult killed P2")
	eq(recorder.entries.map(func(entry): return [entry["actor"], entry["target"], entry.get("interrupt")]),
		[["P1", "P1", true]], "the shield went to the nearest living ally (P1 and P3 tie: the lower slot)")


## An enemy ult that kills the last party member ends the battle at once: Defeat before the first turn, and the
## party's queued press never fires.
func test_enemy_ult_ends_battle() -> void:
	var played := await _play(ult_snapshot(["ultist"]), func(battle: Battle, recorder: ActionRecorder):
		_set_stat(battle.unit_by_id(&"P1"), BattleUnit.HP, 100.0)
		_set_stat(battle.unit_by_id(&"E3"), BattleUnit.ENERGY, 10000.0)
		recorder.submit_ult(&"P1", SNIPE, &"E1"))
	var battle: Battle = played["battle"]
	eq([battle.outcome, battle.turn], ["Defeat", 0], "Defeat in the first window")
	eq(played["request"]["actionLog"]["actions"], [], "nothing logged")
	eq(played["recorder"].pending_interrupts(), 1, "the party's press is left unfired")


## A logged interrupt by a party member who is already dead: 2002 ActorMismatch.
func test_tamper_ult_dead_actor() -> void:
	var played := await _play(ult_snapshot(["martyr", "ultist"]), func(_battle: Battle, recorder: ActionRecorder):
		var pressed := [false]
		recorder.action_requested.connect(func(unit_id, _turn):
			if unit_id == &"P1" and not pressed[0]:
				pressed[0] = true
				recorder.submit_ult(&"P1", SACRIFICE)
				recorder.submit_ult(&"P2", NOVA)))
	var request: Dictionary = played["request"]
	await _verified(request, "the untouched martyr battle replays")
	var tampered := copy(request)
	var nova: Dictionary = tampered["actionLog"]["actions"][1]
	check(nova["ability"] == String(NOVA), "the second entry is P2's nova")
	nova["actor"] = "P1"
	nova["ability"] = String(SACRIFICE)
	await _rejected(tampered, ["ActorMismatch"], "the dead martyr casting again")


static func _set_stat(unit: BattleUnit, attribute_name: String, value: float) -> void:
	var values: Dictionary[String, float] = {attribute_name: value}
	unit.asc.initialize_attribute_overrides(values)


static func _kill(battle: Battle, units: Array) -> void:
	var dead: Dictionary[String, float] = {BattleUnit.HP: 0.0}
	for unit in units:
		unit.asc.initialize_attribute_overrides(dead)
	battle._check_deaths()


## Logs which window asks when (test_window_order), then plays the scripted policy.
class ProbeController:
	extends ScriptedController

	var calls := []

	func interrupt(battle: Battle) -> Dictionary:
		calls.append(["between", battle.turn])
		return super(battle)

	func choose(battle: Battle, unit: BattleUnit) -> Dictionary:
		calls.append(["decision", battle.turn])
		return super(battle, unit)
