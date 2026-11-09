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
