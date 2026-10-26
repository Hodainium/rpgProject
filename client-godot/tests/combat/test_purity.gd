## Purity guards: determinism rules that are easiest to break by accident (spec "Unit tests", "Purity guards").
extends TestCase

const COMBAT: String = "res://combat/"


static func _sources(directory: String) -> PackedStringArray:
	var found := PackedStringArray()
	for name in ResourceLoader.list_directory(directory):
		if name.ends_with("/"):
			found.append_array(_sources(directory + name))
		elif name.ends_with(".gd") or name.ends_with(".tres") or name.ends_with(".tscn"):
			found.append(directory + name)
	return found


static func _code_lines(path: String) -> PackedStringArray:
	var lines := PackedStringArray()
	for line in FileAccess.get_file_as_string(path).split("\n"):
		var code := line.split("#")[0]  # ignore comments and doc comments
		if code.strip_edges() != "":
			lines.append(code)
	return lines


func _forbid(directories: Array, pattern: String, what: String, allowed: Array = []) -> void:
	var regex := RegEx.create_from_string(pattern)
	for directory in directories:
		for path in _sources(directory):
			if not path.ends_with(".gd") or allowed.has(path):
				continue
			for line in _code_lines(path):
				check(regex.search(line) == null, "%s in %s: %s" % [what, path, line.strip_edges()])


func test_no_global_or_extra_randomness() -> void:
	_forbid([COMBAT, FIXTURES], "\\b(randf|randi|randomize|randf_range|randfn)\\s*\\(", "global RNG")
	_forbid([COMBAT, FIXTURES], "RandomNumberGenerator\\.new\\s*\\(", "extra RNG instance", [COMBAT + "battle.gd"])


func test_no_platform_dependent_math() -> void:
	_forbid([COMBAT, FIXTURES + "exec_calcs/"], "(?<![A-Za-z_.])(pow|sqrt|exp|log|sin|cos|tan|atan2|posmod)\\s*\\(",
		"math-library function")


func test_advance_turn_is_never_called() -> void:
	_forbid([COMBAT, FIXTURES], "\\.advance_turn\\s*\\(", "GodotGAS advance_turn (use CombatASC.turn_start/turn_end)")


func test_fixtures_never_reference_content() -> void:
	for path in _sources(FIXTURES):
		check(not FileAccess.get_file_as_string(path).contains("res://content/"), "%s references res://content/" % path)


func test_fixture_effects_are_turn_based_or_instant() -> void:
	for name in ResourceLoader.list_directory(FIXTURES + "effects"):
		var effect := load(FIXTURES + "effects/" + name) as GameplayEffect
		check(effect.policy != GameplayEffect.DurationPolicy.DURATION, "%s uses real-time DURATION" % name)
		check(effect.period <= 0.0 or effect.policy == GameplayEffect.DurationPolicy.TURN_BASED,
			"%s has a real-time period" % name)


## Dev tools (spec dev-tools 3.2): combat never reaches into the console or the dev content.
func test_combat_never_references_dev_tools() -> void:
	_forbid([COMBAT], "res://game/dev|\\bDev\\.|DevConsole|DevContext|RunController", "dev tools in combat")


## The Dev autoload is inert headless: no console UI, no input (so the verifier never runs dev code).
func test_dev_inert_headless() -> void:
	var dev := host.get_node_or_null("/root/Dev")
	check(dev != null, "the Dev autoload exists")
	if dev != null and DisplayServer.get_name() == "headless":
		eq(dev.get_child_count(), 0, "no console UI headless")
		check(not dev.is_processing_input(), "no input handling headless")


## Spec playable-demo F4: the rule the exported release build relies on (no export needed to check it).
func test_dev_inert_rule() -> void:
	var dev_script: GDScript = load("res://game/dev/dev.gd")
	check(dev_script.is_inert_for("headless", true), "inert headless (the verifier, tests)")
	check(dev_script.is_inert_for("headless", false), "inert headless in release")
	check(dev_script.is_inert_for("Windows", false), "inert in a release window build")
	check(not dev_script.is_inert_for("Windows", true), "active only in a debug window build")
