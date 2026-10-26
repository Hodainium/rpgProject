## Clean shutdown: a Godot run leaks nothing at exit. Godot 4.7.2 keeps a script alive at exit when it @exports a
## typed array of its own class (GodotGAS's GameplayEffect.overflow_effects did; patched in the addon, see
## client-godot/CLAUDE.md section 0); the cause is guarded in test_godotgas_patches.
extends TestCase

const LEAK_LINES: Array[String] = ["leaked at exit", "still in use at exit"]


## The game, started in a child process and quit after a few hundred frames, prints no leak at exit.
func test_no_leak_at_exit() -> void:
	var output: Array = []
	var args := PackedStringArray(["--headless", "--quit-after", "300"]) + scene_args("res://game/game_main.tscn", [])
	var exit_code := OS.execute(OS.get_executable_path(), args, output, true)
	eq(exit_code, 0, "the game quits cleanly")
	var text := "".join(output)
	for line in LEAK_LINES:
		check(not text.contains(line), "no '%s' at exit:\n%s" % [line, text.right(600)])
