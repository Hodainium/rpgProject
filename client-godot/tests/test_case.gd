## Base class for the in-house GDScript tests (spec "Test runner"). Every method named test_* is a test.
## Tests may await; run_tests.gd awaits each one.
class_name TestCase
extends RefCounted

const FIXTURES: String = "res://tests/fixtures/"
const GOLDEN: String = "res://tests/fixtures/golden/"

## Set by the runner: a node inside the scene tree to hang battles on.
var host: Node
## Set by the runner when started with --update-goldens.
static var update_goldens: bool = false

var failures := PackedStringArray()
var _battles: Array[Battle] = []
static var _content: ContentIndex


func check(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)


func eq(actual: Variant, expected: Variant, message: String = "") -> void:
	if typeof(actual) != typeof(expected) and not (_is_number(actual) and _is_number(expected)):
		failures.append("%s: expected %s (%s), got %s (%s)" % [message, expected, type_string(typeof(expected)), actual, type_string(typeof(actual))])
	elif actual != expected:
		failures.append("%s: expected %s, got %s" % [message, expected, actual])


func after_each() -> void:
	for battle in _battles:
		if is_instance_valid(battle):
			battle.free()
	_battles.clear()


static func fixtures() -> ContentIndex:
	if _content == null:
		_content = ContentIndex.new(FIXTURES)
	return _content


## A RunController under `host`, started on the fixtures with the given party and seed (for RunPlayer runs).
static func start_run(host_node: Node, seed_text: String, party: Array = ["fixture.character.knight",
		"fixture.character.medic", "fixture.character.rogue"]) -> RunController:
	var run := RunController.new()
	host_node.add_child(run)
	var error := run.start_run(fixtures(), party, seed_text)
	if error != "":
		push_error("TestCase.start_run: " + error)
	return run


## A BattleSnapshot dictionary in the C# field order. party: [[slot, "unit name"], ...].
static func snapshot(encounter: String, party: Array, seed_text: String = "1", battle_id: String = "") -> Dictionary:
	var members: Array = []
	for member in party:
		members.append({"slot": member[0], "unitDefId": "fixture.unit." + member[1], "level": 1})
	return {
		"schemaVersion": 1,
		"battleId": battle_id if battle_id != "" else "%s-seed-%s" % [encounter, seed_text],
		"seed": seed_text,
		"encounterId": "fixture.encounter." + encounter,
		"party": members,
	}


static func squad_snapshot(seed_text: String = "42") -> Dictionary:
	return snapshot("squad", [[1, "striker"], [2, "sweeper"], [3, "support"], [4, "poisoner"]], seed_text)


func new_battle(snap: Dictionary, gate: PresentationGate = null) -> Battle:
	var battle := Battle.new()
	host.add_child(battle)
	_battles.append(battle)
	var error := battle.setup(snap, fixtures(), gate)
	check(error == "", "battle setup failed: " + error)
	return battle


## Plays a battle with the scripted party policy and returns the ReplayRequest it produced.
func record(snap: Dictionary, gate: PresentationGate = null) -> Dictionary:
	var battle := new_battle(snap, gate)
	var controller := ScriptedController.new()
	await battle.run(controller)
	check(battle.runner_error == "", "recording hit a runner error: " + battle.runner_error)
	return {
		"snapshot": snap,
		"actionLog": ActionRecorder.build_log(controller.entries, battle.outcome, battle.final_hash),
	}


## Replays a request in this process.
func replay(request: Dictionary) -> Dictionary:
	var runner := ReplayRunner.new()
	return await runner.run(request, FIXTURES, host)


## A deep copy that is safe to tamper with (parsed back like a received request: numbers become floats).
static func copy(request: Dictionary) -> Dictionary:
	return JSON.parse_string(WireJson.stringify(request))


static func _is_number(value: Variant) -> bool:
	return typeof(value) in [TYPE_INT, TYPE_FLOAT]
