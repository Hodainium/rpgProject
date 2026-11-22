## Spec hash-id-lists 6: the run hash's one-to-one encoder (RunCanonical) on plain values: H3 types, H4 escapes, H5 values it
## refuses, H9 key order, and a property test (generated values never encode alike, and every encoding reads back to its value).
extends TestCase


static func _e(value: Variant) -> String:
	return RunCanonical.encode(value)


func test_types_change_the_hash() -> void:
	check(_e("1") != _e(1), "a string is not a number")
	check(_e(true) != _e(1), "a boolean is not a number")
	check(_e(false) != _e(0), "false is not 0")
	check(_e(null) != _e("null"), "null is not the string null")
	check(_e(null) != _e(0) and _e(null) != _e(false), "null is neither 0 nor false")
	check(_e([]) != _e({}) and _e([]) != _e(""), "an empty list is not an empty dictionary or string")
	check(_e(["1"]) != _e([1]), "inside a list too")
	check(_e({"a": "1"}) != _e({"a": 1}), "inside a dictionary too")
	eq(_e(&"fixture.item.flask"), _e("fixture.item.flask"), "a StringName encodes like its String (restored ids)")
	eq(_e(12.0), _e(12), "a whole float encodes as its int (JSON-parsed snapshots)")
	eq(_e(-3.0), "-3", "negative too")
	eq(RunCanonical.encode({"b": [1, true, null], "a": "x"}), '{"a":"x","b":[1,true,null]}', "the written form")


func test_run_canonical_escapes() -> void:
	check(_e(["a,b"]) != _e(["a", "b"]), "a comma inside an id is not two ids")
	check(_e(["a|b"]) != _e(["a", "b"]) and _e(["a=b"]) != _e(["a", "b"]), "nor a pipe or an equals sign")
	check(_e({"a": "b:c"}) != _e({"a:b": "c"}), "a colon cannot move a key boundary")
	check(_e(["a\",\"b"]) != _e(["a", "b"]), "a quote cannot close a string")
	check(_e(["a\\", "b"]) != _e(["a\\\", \"b"]), "a backslash cannot escape the closing quote")
	check(_e(["[1]"]) != _e([[1]]) and _e(["{}"]) != _e([{}]), "brackets inside a string stay text")
	for text in ["a\nb", "line\r\nrun.coins=999", "tab\there", "\u0001"]:
		var written: String = _e(text)
		check(not written.contains("\n") and not written.contains("\r"), "no raw line break: %s" % written)
		eq(JSON.parse_string(written), text, "and it reads back: %s" % written)
	eq(_e("é ✓"), JSON.stringify("é ✓"), "any other character as JSON writes it")


func test_run_canonical_refuses_objects() -> void:
	expect_hash_refusals(5)  # the refusals below are the point of this test
	var before := RunCanonical.failures
	var object := RefCounted.new()
	var written := RunCanonical.encode({"cell": [object]})
	check(written.contains("!Object"), "an Object is written as !Object: %s" % written)
	check(RunCanonical.encode(Vector2i(1, 2)).begins_with("!"), "a Vector2i is refused (the snapshot writes [x, y])")
	check(RunCanonical.encode(0.5) == "!float", "a float that is not whole is refused")
	check(RunCanonical.encode(INF) == "!float" and RunCanonical.encode(NAN) == "!float", "infinities and NaN too")
	eq(RunCanonical.failures, before + 5, "every refusal is counted (the step runner and the play report fail on it)")


func test_run_canonical_key_order() -> void:
	var stamp := Time.get_ticks_usec()
	var zeta := StringName("Test.Canonical.Zeta%d" % stamp)  # interned first: a pointer sort would put it first
	var alpha := StringName("Test.Canonical.Alpha%d" % stamp)
	var one := {zeta: 1, alpha: 2}
	var other := {alpha: 2, zeta: 1}
	eq(RunCanonical.encode(one), RunCanonical.encode(other), "the same text in any insertion order")
	check(RunCanonical.encode(one).find(String(alpha)) < RunCanonical.encode(one).find(String(zeta)), "keys sorted by name")
	eq(RunCanonical.encode({String(alpha): 2, String(zeta): 1}), RunCanonical.encode(one), "String and StringName keys alike")
	check(RunCanonical.encode({1: "a"}) != RunCanonical.encode({"1": "a"}), "an int key is not a string key")


# --- The property test ------------------------------------------------------------------------------------------------------

const ATOMS: Array = ["", "a", "b", "a,b", ",", "\"", "\\", "\\\"", "\n", "=", ":", "{", "}", "[", "]", "|", "1", "true", "null",
	"fixture.item.flask", "é", " "]


static func _value(rng: RandomNumberGenerator, depth: int) -> Variant:
	var pick := rng.randi_range(0, 9 if depth < 3 else 5)
	match pick:
		0, 1, 2:
			return ATOMS[rng.randi_range(0, ATOMS.size() - 1)] + (ATOMS[rng.randi_range(0, ATOMS.size() - 1)] if rng.randi_range(0, 1) == 1 else "")
		3:
			return rng.randi_range(-3, 12)
		4:
			return rng.randi_range(0, 1) == 1
		5:
			return null
		6, 7:
			var list: Array = []
			for _index in rng.randi_range(0, 3):
				list.append(_value(rng, depth + 1))
			return list
		_:
			var dict := {}
			for _index in rng.randi_range(0, 3):
				dict[ATOMS[rng.randi_range(0, ATOMS.size() - 1)]] = _value(rng, depth + 1)
			return dict


## A few hundred generated values (nested lists and dictionaries of ids holding separators, numbers, booleans, nulls): two values
## encode alike only when they are the same value, and every encoding is JSON that reads back to its value.
func test_run_canonical_is_one_to_one() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 20261122
	var by_text := {}
	var distinct := 0
	for _index in 1200:
		var value: Variant = _value(rng, 0)
		var written := RunCanonical.encode(value)
		var identity := JSON.stringify(value, "", true)  # a faithful form for these types: equal exactly when the values are
		if by_text.has(written):
			eq(by_text[written], identity, "only the same value encodes as %s" % written)
		else:
			by_text[written] = identity
			distinct += 1
		var parsed: Variant = JSON.parse_string(written)
		check(written == "null" or parsed != null, "the encoding is JSON: %s" % written)
		eq(JSON.stringify(RunSnapshot._ints(parsed), "", true), identity, "and reads back to its value: %s" % written)
	check(distinct > 400, "many distinct values (%d)" % distinct)


# --- The test runner's safety net (spec hash-id-lists H5) -----------------------------------------------------------------

const NET_CHILD_ENV: String = "RPG_TEST_HASH_NET_CHILD"
const NET_CHILD_TEST: String = "test_run_canonical::test_child_refuses_without_declaring"


## TestCase's half: an undeclared refusal is a failure naming the cause, a declared one is not, and the count must match.
func test_an_undeclared_hash_refusal_fails_the_test() -> void:
	var undeclared := TestCase.new()
	undeclared.check_hash_refusals(1)
	eq(undeclared.failures.size(), 1, "one undeclared refusal fails the test")
	check(not undeclared.failures.is_empty() and undeclared.failures[0].contains("the run hash refused 1 value"),
		"with a message naming the cause: %s" % [undeclared.failures])
	var declared := TestCase.new()
	declared.expect_hash_refusals(1)
	declared.check_hash_refusals(1)
	check(declared.failures.is_empty(), "a declared refusal does not")
	var fewer := TestCase.new()
	fewer.expect_hash_refusals(2)
	fewer.check_hash_refusals(1)
	eq(fewer.failures.size(), 1, "and the count must match")
	var clean := TestCase.new()
	clean.check_hash_refusals(0)
	check(clean.failures.is_empty(), "a test that refuses nothing passes")


## The child of the test below: refuses a value without declaring it. In the ordinary suite (no NET_CHILD_ENV) it does nothing.
func test_child_refuses_without_declaring() -> void:
	if OS.get_environment(NET_CHILD_ENV) != "1":
		return
	RunCanonical.encode({"cell": RefCounted.new()})


## The runner's half, end to end: a real child run of the suite on the child test above fails, and says why.
func test_the_runner_fails_a_test_that_refuses_without_declaring() -> void:
	var output: Array = []
	var args := PackedStringArray(["--headless", "--quit-after", "100000"]) + scene_args("res://tests/run_tests.tscn",
		["--filter", NET_CHILD_TEST])
	OS.set_environment(NET_CHILD_ENV, "1")
	var code := OS.execute(OS.get_executable_path(), args, output, true)
	OS.unset_environment(NET_CHILD_ENV)
	var text := "\n".join(output)
	eq(code, 1, "the child run fails")
	check(text.contains("FAIL") and text.contains(NET_CHILD_TEST.get_slice("::", 1)), "on the child test")
	check(text.contains("the run hash refused 1 value"), "naming the cause")
