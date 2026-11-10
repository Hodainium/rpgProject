class_name RegistryPatch
## The one approved way a builder changes the effect registry (user, 2026-11-09: "change files and their dependent registries in the same stroke").
## ADDITIVE ONLY, as text: it appends an ext_resource line and appends the new entry at the end of `definitions` or `rule_sets`.
## It never re-saves the file (no ResourceSaver, so no reformatting, reordering or lost hand edits) and never changes or removes an
## existing entry. It prints exactly what it added. `FxValidator.sync_problems` stays the backstop for anything it cannot place.

const REGISTRY := "res://presentation/demo/fx/fx_registry.tres"
const FX_DIR := "res://presentation/demo/fx/"


## Adds every FxDefinition and FxRuleSet in `FX_DIR` that the registry does not list. Returns the lines it added.
static func add_missing_effects(registry_path: String = REGISTRY, fx_dir: String = FX_DIR) -> PackedStringArray:
	var registry := ResourceLoader.load(registry_path, "", ResourceLoader.CACHE_MODE_IGNORE) as FxRegistry
	var effects := registry.all()
	var listed_rule_sets := {}
	for rules in registry.all_rule_sets():
		listed_rule_sets[rules.resource_path] = true
	var new_definitions: Array[String] = []
	var new_rule_sets: Array[String] = []
	for file in DirAccess.get_files_at(fx_dir):
		if not file.ends_with(".tres") or file == registry_path.get_file():
			continue
		var resource := ResourceLoader.load(fx_dir + file, "", ResourceLoader.CACHE_MODE_IGNORE)
		if resource is FxDefinition and not effects.has(resource.id):
			new_definitions.append(fx_dir + file)
		elif resource is FxRuleSet and not listed_rule_sets.has(fx_dir + file):
			new_rule_sets.append(fx_dir + file)
	new_definitions.sort()
	new_rule_sets.sort()
	var added := PackedStringArray()
	if new_definitions.is_empty() and new_rule_sets.is_empty():
		return added
	var text := FileAccess.get_file_as_string(registry_path)
	var serial := 0
	for kind in [["definitions", new_definitions], ["rule_sets", new_rule_sets]]:
		for path in kind[1]:
			serial += 1
			var ext_id := "add_%d_%s" % [serial, path.get_file().get_basename()]
			var patched := _append_to_array(text, kind[0], ext_id)
			if patched == "":
				push_error("RegistryPatch: no '%s = ' line in the registry; %s not added (add it by hand)" % [kind[0], path])
				continue
			text = _insert_ext_resource(patched, path, ext_id)
			added.append("%s += %s" % [kind[0], path.get_file()])
	var file := FileAccess.open(registry_path, FileAccess.WRITE)
	file.store_string(text)
	file.close()
	return added


static func _insert_ext_resource(text: String, path: String, ext_id: String) -> String:
	var lines := text.split("\n")
	var last := 0
	for index in lines.size():
		if lines[index].begins_with("[ext_resource"):
			last = index
	lines.insert(last + 1, '[ext_resource type="Resource" path="%s" id="%s"]' % [path, ext_id])
	return "\n".join(lines)


## Returns the text with ExtResource(ext_id) appended to the `field = Array[..]([...])` line, or "" if the line is missing.
static func _append_to_array(text: String, field: String, ext_id: String) -> String:
	var lines := text.split("\n")
	for index in lines.size():
		var line: String = lines[index]
		if not line.begins_with(field + " = "):
			continue
		if not line.ends_with("])"):
			return ""
		var body := line.substr(0, line.length() - 2)
		var separator := "" if body.ends_with("([") else ", "
		lines[index] = '%s%sExtResource("%s")])' % [body, separator, ext_id]
		return "\n".join(lines)
	# An empty untyped list is not saved at all: start it. Only rule_sets can be started this way (definitions is typed by a script id).
	if field == "rule_sets":
		var in_resource := false
		for index in lines.size():
			if lines[index] == "[resource]":
				in_resource = true
			elif in_resource and lines[index].begins_with("script = "):
				lines.insert(index + 1, 'rule_sets = Array[Resource]([ExtResource("%s")])' % ext_id)
				return "\n".join(lines)
	return ""
