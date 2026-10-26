## In-house GDScript test runner (spec "Test runner"). Runs as a scene so GodotGAS's autoloads exist:
##   godot --headless --path client-godot res://tests/run_tests.tscn [-- --filter <text>] [-- --update-goldens]
##     [-- --shard i/n]   (only the tests whose index in file-then-method order is i mod n; tools/godot_tests.sh)
## Discovers res://tests/**/test_*.gd, runs every test_* method, exits 1 on any failure.
extends Node

const TEST_ROOT: String = "res://tests/"


func _ready() -> void:
	var args := OS.get_cmdline_user_args()
	var filter := ""
	if args.has("--filter") and args.find("--filter") + 1 < args.size():
		filter = args[args.find("--filter") + 1]
	TestCase.update_goldens = args.has("--update-goldens")
	var shard := [0, 1]
	if args.has("--shard") and args.find("--shard") + 1 < args.size():
		var parts := args[args.find("--shard") + 1].split("/")
		if parts.size() == 2 and parts[0].is_valid_int() and parts[1].is_valid_int() and int(parts[1]) > 0:
			shard = [int(parts[0]), int(parts[1])]

	var passed := 0
	var failed := PackedStringArray()
	var index := -1
	for path in _test_scripts(TEST_ROOT):
		var script := load(path) as GDScript
		if script == null or not script.can_instantiate():
			# A test file that doesn't compile is a failure, never a silent skip (reported by shard 0 only).
			if shard[0] != 0:
				continue
			failed.append(path)
			print("  FAIL  ", path, " (does not compile)")
			continue
		var methods := PackedStringArray()
		for method in script.get_script_method_list():
			if String(method["name"]).begins_with("test_") and not methods.has(method["name"]):
				methods.append(method["name"])
		for method in methods:
			var label := "%s::%s" % [path.get_file().get_basename(), method]
			if filter != "" and not label.contains(filter):
				continue
			index += 1
			if index % shard[1] != shard[0]:
				continue
			Watchdog.beat(label)
			var test: TestCase = script.new()
			test.host = self
			await test.call(method)
			test.after_each()
			if test.failures.is_empty():
				passed += 1
				print("  ok    ", label)
			else:
				failed.append(label)
				print("  FAIL  ", label)
				for failure in test.failures:
					print("          ", failure)

	print("\n%d passed, %d failed" % [passed, failed.size()])
	get_tree().quit(1 if not failed.is_empty() or passed == 0 else 0)


static func _test_scripts(directory: String) -> PackedStringArray:
	var found := PackedStringArray()
	for name in ResourceLoader.list_directory(directory):
		if name.ends_with("/"):
			if name != "fixtures/":
				found.append_array(_test_scripts(directory + name))
		elif name.begins_with("test_") and name.ends_with(".gd"):
			found.append(directory + name)
	found.sort()
	return found
