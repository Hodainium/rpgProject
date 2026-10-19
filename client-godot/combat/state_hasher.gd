## State hash v1 (spec section 3.3): SHA-256 over a canonical UTF-8 text, lowercase hex.
##
## Excluded on purpose: GameplayEffectSpec.application_time (wall clock), cue state, node names and paths,
## anything in presentation/.
class_name StateHasher
extends RefCounted

const VERSION_LINE: String = "hash-v1"


## {"hash": String, "error": String}. The error is set (and the hash empty) when the state can't be hashed:
## a fractional attribute (NonIntegerAttribute) or an active effect without a saved resource (AnonymousActiveEffect).
static func compute(battle: Battle) -> Dictionary:
	var collected := canonical_lines(battle)
	if collected["error"] != "":
		return {"hash": "", "error": collected["error"]}
	return {"hash": sha256_hex("\n".join(collected["lines"])), "error": ""}


static func canonical_lines(battle: Battle) -> Dictionary:
	var lines := PackedStringArray([
		VERSION_LINE,
		"turn=%d" % battle.turn,
		"rng=%d" % battle.rng.state,
		"outcome=%s" % battle.outcome,
	])
	for unit in battle.units():  # sorted by unit id
		var id := String(unit.unit_id)
		lines.append("unit=%s|alive=%d|av=%d" % [id, 1 if unit.alive else 0, battle.turn_manager.av.get(unit, 0)])

		for attribute_name in _attribute_names(unit.asc):
			var data := unit.asc.get_attribute(attribute_name)
			for value in [data.base_value, data.current_value]:
				if not Fixed.is_whole(value):
					return {"lines": lines, "error": "NonIntegerAttribute: %s.%s = %s" % [id, attribute_name, value]}
			lines.append("attr=%s|%s|%d|%d" % [id, attribute_name, int(data.base_value), int(data.current_value)])

		var tags: Array = unit.asc._active_tags.keys()
		tags.sort_custom(func(a, b) -> bool: return String(a) < String(b))
		for tag in tags:
			lines.append("tag=%s|%s|%d" % [id, tag, unit.asc._active_tags[tag]])

		var effects := PackedStringArray()
		for active_effect: ActiveGameplayEffect in unit.asc._active_effects:
			var path := active_effect.get_effect_def().resource_path
			if path == "" or path.contains("::"):
				return {"lines": lines, "error": "AnonymousActiveEffect on %s (active effects must be saved .tres files)" % id}
			effects.append("effect=%s|%s|%d|%d|%d" % [id, path, active_effect.spec.remaining_turns,
				active_effect.stack_count, 1 if active_effect.is_suppressed else 0])
		effects.sort()
		lines.append_array(effects)
	return {"lines": lines, "error": ""}


static func sha256_hex(text: String) -> String:
	var context := HashingContext.new()
	context.start(HashingContext.HASH_SHA256)
	context.update(text.to_utf8_buffer())
	return context.finish().hex_encode()


## Attribute names on the ASC's sets (GodotGAS-generated sets declare them as AttributeData script variables).
static func _attribute_names(asc: AbilitySystemComponent) -> PackedStringArray:
	var names := PackedStringArray()
	for attribute_set in asc.attribute_sets:
		for property in attribute_set.get_property_list():
			if property["usage"] & PROPERTY_USAGE_SCRIPT_VARIABLE and attribute_set.get(property["name"]) is AttributeData:
				names.append(property["name"])
	names.sort()
	return names
