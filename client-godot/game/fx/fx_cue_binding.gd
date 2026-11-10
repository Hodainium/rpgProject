## Feeds one FxDefinition parameter from a gameplay cue (spec vfx-framework 3.3): a literal, a key of the cue's
## payload, or the target's gameplay tags (first matching tag wins: {"Status.Debuff.Burn": Color.ORANGE}). The same
## effect then serves many cues. Presentation only.
class_name FxCueBinding
extends Resource

enum Source { LITERAL, PAYLOAD, TARGET_TAGS }

@export var param: StringName
@export var source: Source = Source.LITERAL
## LITERAL: the value. PAYLOAD / TARGET_TAGS: the fallback when nothing matches (null = leave the default).
@export var value: Variant = null
@export var payload_key: StringName
## TARGET_TAGS: tag → value. A tag matches by hierarchy (the unit has Status.Debuff.Burn.Strong → "Status.Debuff.Burn").
@export var tag_values: Dictionary = {}


## The value to give the parameter, or null to leave its default. `target` is the cue's target node.
func resolve(target: Node, payload: Dictionary) -> Variant:
	match source:
		Source.PAYLOAD:
			return payload.get(payload_key, value)
		Source.TARGET_TAGS:
			# The target's own ability system, else the payload's "asc" (review fix: a tag cue runs on the unit's view, which has
			# none, and FxTagCues passes the unit's ability system in the payload).
			var asc: Object = target.get("asc") if target != null and "asc" in target else payload.get("asc")
			if asc != null and not is_instance_valid(asc):
				asc = null
			if asc != null:
				for tag in tag_values:
					if asc.has_tag(StringName(tag)):
						return tag_values[tag]
			return value
	return value
