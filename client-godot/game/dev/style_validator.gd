## Spec cube-style 3.8: checks a StyleRegistry against the content: looks keyed by unknown units, moods keyed by unknown chapters,
## empty entries, and (a warning) units that get only the default look. Used by validate_content.tscn and the console's `style check`.
class_name StyleValidator
extends RefCounted


## Every registry file under `directory` (a round's variants), sorted.
static func registries_under(directory: String) -> PackedStringArray:
	var found := PackedStringArray()
	# ResourceLoader.list_directory, like ContentIndex: an exported build lists "x.tres.remap" and load() resolves it.
	for entry in ResourceLoader.list_directory(directory):
		if entry.ends_with("/"):
			found.append_array(registries_under(directory.path_join(entry.trim_suffix("/"))))
			continue
		var file := entry.trim_suffix(".remap")
		if file.ends_with(".tres") and load(directory.path_join(file)) is StyleRegistry:
			found.append(directory.path_join(file))
	found.sort()
	return found


static func validate(registry: StyleRegistry, content: ContentIndex, path: String = "") -> Array[ValidationIssue]:
	var issues: Array[ValidationIssue] = []
	if registry == null:
		return issues
	var where := path if path != "" else (registry.resource_path if registry.resource_path != "" else "style registry")
	# Only this registry's own entries: a base is validated on its own, so its problems are never reported again per variant.
	var last: StyleRegistry = registry.chain().back()
	if last.base != null:
		issues.append(ValidationIssue.new(ValidationIssue.ERROR, "style_base_cycle", where, "the registry's `base` chain loops"))
		return issues
	for id in registry.looks:
		if registry.looks[id] == null:
			issues.append(ValidationIssue.new(ValidationIssue.ERROR, "style_look_empty", where + "::looks[%s]" % id, "an empty look"))
		elif content != null and not content.units.has(id):
			issues.append(ValidationIssue.new(ValidationIssue.ERROR, "style_look_unknown_unit", where + "::looks[%s]" % id,
				"no unit '%s' in the content" % id))
	for id in registry.moods:
		if registry.moods[id] == null:
			issues.append(ValidationIssue.new(ValidationIssue.ERROR, "style_mood_empty", where + "::moods[%s]" % id, "an empty mood"))
		elif content != null and not content.chapters.has(id):
			issues.append(ValidationIssue.new(ValidationIssue.ERROR, "style_mood_unknown_chapter", where + "::moods[%s]" % id,
				"no chapter '%s' in the content" % id))
	for i in registry.tag_rules.size():
		var rule := registry.tag_rules[i]
		if rule == null or rule.query == null or rule.look == null:
			issues.append(ValidationIssue.new(ValidationIssue.ERROR, "style_rule_incomplete", where + "::tag_rules[%d]" % i,
				"a rule needs a query and a look"))
	if registry.base != null:
		return issues  # the unit warning belongs to the registry that holds the looks, not to each variant over it
	# Once a registry gives units looks of their own, a character or enemy left on the default look is probably forgotten.
	if content != null and not registry.look_ids().is_empty():
		for id in content.units:
			var unit: UnitDefinition = content.units[id]
			if (content.characters.has(id) or unit is EnemyDefinition) and registry.look_source(unit) == "default":
				issues.append(ValidationIssue.new(ValidationIssue.WARNING, "style_unit_without_look", where,
					"unit '%s' gets only the default look" % id))
	return issues
