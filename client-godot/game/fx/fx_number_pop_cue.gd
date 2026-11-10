## The damage and heal number as a GameplayCue (Lyra: a damage cue notify hands a number pop request to its number pop component,
## which styles it by tag with ULyraDamagePopStyle). Register a scene with this script under a cue tag (Cue.Fx.Number) and point
## FxListeners at that cue: the message reaches the cue as MessageCueParams (verb, magnitude x100, tags), and this cue fills the
## number effect's `text` (magnitude / divisor, with the first matching style's prefix) and every parameter its styles set.
## The effect itself is pooled by the effects service, as Lyra pools its pop components. Presentation only.
class_name FxNumberPopCue
extends FxCueNotify

## In order: for each parameter, the first matching style that sets it wins (see FxNumberStyle).
@export var styles: Array[FxNumberStyle] = []
## The effect parameter that shows the number.
@export var text_param: StringName = &"text"
## Battle numbers are x100: 2345 is shown as 23.
@export var text_divisor: float = 100.0


func _extra_params(_target: Node, payload: Dictionary) -> Dictionary:
	var tags: Array = payload.get("tags", [])
	var verb: StringName = payload.get("verb", &"")
	var chosen := {}
	var prefix := ""
	var prefix_set := false
	for style in styles:
		if style == null or not style.matches(tags, verb):
			continue
		for key in style.params:
			if not chosen.has(key):
				chosen[key] = style.params[key]
		if not prefix_set and style.prefix != "":
			prefix = style.prefix
			prefix_set = true
	chosen[text_param] = "%s%d" % [prefix, int(float(payload.get("magnitude", 0)) / text_divisor)]
	return chosen
