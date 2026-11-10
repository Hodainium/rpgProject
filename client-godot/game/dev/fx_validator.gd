## The effects pass of the content validator (spec vfx-framework 6, item 8). Turns the problems an FxDefinition reports
## ("fx_param_missing: …") into ValidationIssues, and checks the registry as a whole (duplicate ids). Dev tooling:
## not shipped in the player build.
class_name FxValidator
extends RefCounted


## Every issue in the registry's effects (includes too).
static func validate(registry: FxRegistry) -> Array[ValidationIssue]:
	var issues: Array[ValidationIssue] = []
	var seen := {}
	for definition in registry.definitions:
		if definition == null:
			issues.append(ValidationIssue.new(ValidationIssue.ERROR, "fx_layer_empty", "fx_registry", "the registry has an empty slot"))
			continue
		if seen.has(definition.id):
			issues.append(ValidationIssue.new(ValidationIssue.ERROR, "fx_duplicate_id", _where(definition),
				"%s is defined twice in the registry" % definition.id))
		seen[definition.id] = true
	for definition in _every_definition(registry):
		if definition != null:
			issues.append_array(check(definition))
	return issues


## Desync alarm (user, 2026-11-09): builders create new files but never rewrite a registry, so a registry can lag behind the files it should list.
## This finds it: an effect or a rule set in `fx_dir` that the effect registry does not list, a cue scene in `cue_dir` with no cue registry entry, a cue
## registry entry whose scene is gone, and a cue tag that a rule or a tag cue names but the cue registry does not have. All errors; the content validator
## and a test run it, so a forgotten registry line fails loudly instead of silently showing nothing.
static func sync_problems(fx_dir: String, cue_dir: String, registry: FxRegistry, cue_registry: GameplayCueRegistry) -> Array[ValidationIssue]:
	var issues: Array[ValidationIssue] = []
	var effects := registry.all()
	var rule_sets := registry.all_rule_sets()
	# Review fix: subfolders too, matched by path (an id says nothing about which file is listed): an effect with no id can
	# never be played, and a second file with a listed effect's id would replace it.
	for path in fx_files(fx_dir):
		var resource := load(path)
		if resource is FxDefinition:
			var listed: FxDefinition = effects.get(resource.id)
			if resource.id == &"":
				issues.append(ValidationIssue.new(ValidationIssue.ERROR, "fx_id_missing", path, "this effect has no id"))
			elif listed == null:
				issues.append(ValidationIssue.new(ValidationIssue.ERROR, "fx_unregistered", path,
					"%s is not in the effect registry: add it to fx_registry.tres" % resource.id))
			elif listed.resource_path != path:
				issues.append(ValidationIssue.new(ValidationIssue.ERROR, "fx_id_taken", path,
					"its id %s belongs to %s, which the registry lists: give this effect its own id" % [resource.id, listed.resource_path]))
		elif resource is FxRuleSet and not rule_sets.has(resource):
			issues.append(ValidationIssue.new(ValidationIssue.ERROR, "fx_rule_set_unregistered", path,
				"this rule set is not in the registry's rule_sets, so nothing attaches it"))
	var registered_scenes := {}
	var registered_tags := {}
	for entry in cue_registry.entries:
		registered_tags[entry.tag] = true
		# scene_ref is a uid:// (what the inspector and the dashboard save, GodotGAS patch 3) or a res:// path: compare paths.
		var path := entry.scene_path()
		registered_scenes[path] = true
		if path == "" or not ResourceLoader.exists(path):
			issues.append(ValidationIssue.new(ValidationIssue.ERROR, "cue_scene_missing", "cue_registry", "%s: its scene %s does not exist" % [entry.tag, entry.scene_ref]))
	for file in DirAccess.get_files_at(cue_dir):
		if file.ends_with(".tscn") and not registered_scenes.has(cue_dir.path_join(file)):
			issues.append(ValidationIssue.new(ValidationIssue.ERROR, "cue_scene_unregistered", cue_dir.path_join(file),
				"this cue scene has no entry in godot_gas/cue_registry.tres"))
	for rules in rule_sets:
		for rule in rules.rules:
			if rule != null and rule.cue != &"" and not registered_tags.has(rule.cue):
				issues.append(ValidationIssue.new(ValidationIssue.ERROR, "cue_unknown", rules.resource_path, "a rule executes %s, which the cue registry does not have" % rule.cue))
	for rule in registry.all_tag_cues():
		for tag in [rule.added_cue, rule.present_cue, rule.removed_cue]:
			if tag != &"" and not registered_tags.has(tag):
				issues.append(ValidationIssue.new(ValidationIssue.ERROR, "cue_unknown", "fx_registry (tag cue %s)" % rule.tag, "it names %s, which the cue registry does not have" % tag))
	return issues


## Every .tres under `fx_dir` and its subfolders, sorted.
static func fx_files(fx_dir: String) -> Array[String]:
	var found: Array[String] = []
	var queue: Array[String] = [fx_dir.trim_suffix("/")]
	while not queue.is_empty():
		var dir: String = queue.pop_front()
		for file in DirAccess.get_files_at(dir):
			if file.ends_with(".tres"):
				found.append(dir.path_join(file))
		for sub in DirAccess.get_directories_at(dir):
			queue.append(dir.path_join(sub))
	found.sort()
	return found


## Every definition in the registry and the ones it includes, overridden or not.
static func _every_definition(registry: FxRegistry) -> Array:
	var out: Array = []
	for other in registry.includes:
		if other != null:
			out.append_array(_every_definition(other))
	out.append_array(registry.definitions)
	return out


## The issues of one effect.
static func check(definition: FxDefinition) -> Array[ValidationIssue]:
	var issues: Array[ValidationIssue] = []
	for problem in definition.problems():
		var parts := problem.split(": ", true, 1)
		var code := parts[0] if parts.size() == 2 else "fx_invalid"
		issues.append(ValidationIssue.new(ValidationIssue.ERROR, code, _where(definition), parts[parts.size() - 1]))
	return issues


static func _where(definition: FxDefinition) -> String:
	return definition.resource_path if definition.resource_path != "" else String(definition.id)
