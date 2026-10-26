## Every script under res://game/ compiles (spec dev-tools 6): a tool or command that no test loads can't hide a parse
## error. (addons/rpg_dev/ uses editor-only classes; it is checked inside the editor.)
extends TestCase


func test_game_scripts_compile() -> void:
	for path in _scripts("res://game/"):
		var script := load(path) as GDScript
		check(script != null and script.can_instantiate(), "%s compiles" % path)


## Spec playable-demo 6: your screens under res://presentation/ compile and their scenes load. No test plays them, so
## a parse error there only showed in a window run (2026-10-26).
func test_presentation_scripts_compile() -> void:
	for path in _scripts("res://presentation/"):
		var script := load(path) as GDScript
		check(script != null and script.can_instantiate(), "%s compiles" % path)
	for path in _scripts("res://presentation/", ".tscn"):
		var scene := load(path) as PackedScene
		check(scene != null and scene.can_instantiate(), "%s loads" % path)


static func _scripts(directory: String, extension: String = ".gd") -> PackedStringArray:
	var found := PackedStringArray()
	for name in ResourceLoader.list_directory(directory):
		if name.ends_with("/"):
			found.append_array(_scripts(directory + name, extension))
		elif name.ends_with(extension):
			found.append(directory + name)
	return found
