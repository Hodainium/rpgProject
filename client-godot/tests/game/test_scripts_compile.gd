## Every script under res://game/ compiles (spec dev-tools 6): a tool or command that no test loads can't hide a parse
## error. (addons/rpg_dev/ uses editor-only classes; it is checked inside the editor.)
extends TestCase


func test_game_scripts_compile() -> void:
	for path in _scripts("res://game/"):
		var script := load(path) as GDScript
		check(script != null and script.can_instantiate(), "%s compiles" % path)


static func _scripts(directory: String) -> PackedStringArray:
	var found := PackedStringArray()
	for name in ResourceLoader.list_directory(directory):
		if name.ends_with("/"):
			found.append_array(_scripts(directory + name))
		elif name.ends_with(".gd"):
			found.append(directory + name)
	return found
