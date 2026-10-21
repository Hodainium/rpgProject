## Attribute checkpoint: the GodotGAS dashboard's "Generate" (Attribute Sets tab) without a window. Reads the drafts
## (`attributes_draft.cfg`) and writes `<set>_attribute_set.gd` per set into the attributes output dir, as the button does.
##
## The addon builds the script inside its dashboard UI (editor dialogs, no callable function), so `generate()` repeats
## its text builder line for line. `test_attribute_generator` pins it byte for byte against a file the dashboard wrote;
## after a GodotGAS upgrade, regenerate once from the dashboard and refresh that fixture.
## Writes only files whose text changed. --check writes nothing and exits 1 while any set is out of date.
##   godot --headless --path client-godot --quit-after 600 res://game/tools/generate_attributes.tscn [-- --check] [--set Unit]
extends Node

const SETTINGS := preload("res://addons/GodotGAS/utilities/project_settings.gd")


func _ready() -> void:
	var args := OS.get_cmdline_user_args()
	var check := args.has("--check")
	var only := args[args.find("--set") + 1] if args.has("--set") and args.find("--set") + 1 < args.size() else ""
	var drafts := ConfigFile.new()
	var draft_path: String = SETTINGS.get_attributes_draft_config_path()
	if drafts.load(draft_path) != OK:
		push_error("generate_attributes: can't read " + draft_path)
		get_tree().quit(2)
		return
	var output_dir: String = SETTINGS.get_attributes_output_dir_path()
	var stale := 0
	for set_name in drafts.get_sections():
		if only != "" and set_name != only:
			continue
		var path := output_dir.path_join(set_name.to_snake_case() + "_attribute_set.gd")
		var text := generate(drafts, set_name)
		if FileAccess.file_exists(path) and FileAccess.get_file_as_string(path) == text:
			print("up to date: ", path)
			continue
		stale += 1
		if check:
			print("OUT OF DATE: ", path)
			continue
		DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(output_dir))
		var file := FileAccess.open(path, FileAccess.WRITE)
		if file == null:
			push_error("generate_attributes: can't write " + path)
			get_tree().quit(2)
			return
		file.store_string(text)
		file.close()
		print("generated: ", path)
	get_tree().quit(1 if check and stale > 0 else 0)


## The script text the dashboard writes for `set_name` (addons/GodotGAS/editor/dashboard_tabs/attribute_sets_tab.gd,
## `_on_generate_script_pressed`, GodotGAS v1.1.2).
static func generate(drafts: ConfigFile, set_name: String) -> String:
	var script_text := "## An extended class for the attribute module: %s \n" % set_name
	script_text += "##\n"
	script_text += "## @meta_addon: GodotGAS\n"
	script_text += "## @meta_author: YulRun (https://YulRun.Dev) & 'Your Name Here'\n"
	script_text += "## @meta_license: MIT (Default)\n\n"
	script_text += "@tool\nclass_name " + set_name + "AttributeSet extends AttributeSet\n\n"

	var valid_attributes: Array[String] = []
	for key in drafts.get_section_keys(set_name):
		if key == "_initialized":
			continue
		valid_attributes.append(key)
		var raw_val = drafts.get_value(set_name, key)
		var val: float = 0.0
		if typeof(raw_val) == TYPE_DICTIONARY:
			val = raw_val.get("value", 0.0)
		else:
			val = float(raw_val)
		script_text += "var %s: AttributeData = AttributeData.new(%s)\n" % [key, str(val)]

	script_text += "\n\n"
	script_text += "## The safety pipeline: Clamps stats before they are officially changed.\n"
	script_text += "func pre_attribute_change(attribute_name: String, proposed_value: float) -> float:\n"
	script_text += "\tmatch attribute_name:\n"
	var has_match := false
	for key in valid_attributes:
		if not "max_" in key.to_lower() and not "min_" in key.to_lower():
			var max_k := "max_" + key
			if max_k in valid_attributes:
				var min_k := "min_" + key
				var min_val := min_k + ".current_value" if min_k in valid_attributes else "0.0"
				script_text += "\t\t\"%s\":\n" % key
				script_text += "\t\t\treturn clamp(proposed_value, %s, %s.current_value)\n" % [min_val, max_k]
				has_match = true
	if not has_match:
		script_text += "\t\t_:\n"
		script_text += "\t\t\tpass\n"
	script_text += "\n\treturn proposed_value\n\n\n"

	script_text += "## The reaction pipeline: Handles moving goalposts (e.g. MaxHealth dropping below Health).\n"
	script_text += "func post_attribute_change(asc: Node, attribute_name: String, old_value: float, new_value: float) -> void:\n"
	script_text += "\tmatch attribute_name:\n"
	var has_post_match := false
	for key in valid_attributes:
		if not "max_" in key.to_lower() and not "min_" in key.to_lower():
			var max_k := "max_" + key
			var min_k := "min_" + key
			if max_k in valid_attributes:
				script_text += "\t\t\"%s\":\n" % max_k
				script_text += "\t\t\tif %s.current_value > new_value:\n" % key
				script_text += "\t\t\t\tasc._apply_attribute_change(\"%s\", new_value - %s.current_value)\n" % [key, key]
				has_post_match = true
			if min_k in valid_attributes:
				script_text += "\t\t\"%s\":\n" % min_k
				script_text += "\t\t\tif %s.current_value < new_value:\n" % key
				script_text += "\t\t\t\tasc._apply_attribute_change(\"%s\", new_value - %s.current_value)\n" % [key, key]
				has_post_match = true
	if not has_post_match:
		script_text += "\t\t_:\n"
		script_text += "\t\t\tpass\n"
	return script_text
