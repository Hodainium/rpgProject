## The damage and heal number as a GameplayCue (Lyra: a damage cue notify hands a number pop request to its number pop component,
## which styles it by tag with ULyraDamagePopStyle). Register a scene with this script under a cue tag (Cue.Fx.Number) and point
## FxListeners at that cue: the message reaches the cue as MessageCueParams (verb, magnitude x100, tags), and this cue fills the
## number effect's `text` (magnitude / divisor, with the first matching style's prefix) and every parameter its styles set.
## The effect itself is pooled by the effects service, as Lyra pools its pop components.
## Like Lyra's pop component, a unit's numbers do not pile up on one spot: each new one starts `stack_step` above the ones still
## showing on that unit, and past `per_unit_cap` the oldest fades out quickly (a soft cap: never cut off at once).
## Presentation only.
class_name FxNumberPopCue
extends FxCueNotify

## In order: for each parameter, the first matching style that sets it wins (see FxNumberStyle).
@export var styles: Array[FxNumberStyle] = []
## The effect parameter that shows the number.
@export var text_param: StringName = &"text"
## Battle numbers are x100: 2345 is shown as 23.
@export var text_divisor: float = 100.0
## How far above the numbers still showing on the same unit a new one starts (world units).
@export var stack_step: Vector3 = Vector3(0, 0.35, 0)
## Numbers showing at once on one unit before the oldest is faded out. 0 = no cap.
@export var per_unit_cap: int = 4
## How long the oldest takes to fade when the cap pushes it out.
@export var cap_fade: float = 0.12

## Unit id -> the handles of its numbers, oldest first (shared by every pooled node of this cue).
static var _showing: Dictionary = {}


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


## The anchor of the base cue, lifted by one step per number still showing on this unit.
func _anchor_for(target: Node) -> FxAnchor:
	var anchor := super(target)
	var showing := _live_on(_unit_of(target))
	anchor.offset += stack_step * showing.size()
	return anchor


func _played(target: Node, handle: FxHandle) -> void:
	var unit := _unit_of(target)
	if unit == &"" or handle == null or not handle.is_playing():
		return
	var showing := _live_on(unit)
	showing.append(handle)
	while per_unit_cap > 0 and showing.size() > per_unit_cap:
		var oldest: FxHandle = showing.pop_front()
		oldest.stop(cap_fade)
	_showing[unit] = showing


## The unit's numbers that are still playing (finished ones are dropped).
static func _live_on(unit: StringName) -> Array:
	var showing: Array = _showing.get(unit, [])
	showing = showing.filter(func(handle: FxHandle) -> bool: return handle != null and handle.is_playing() and not handle.stopping)
	_showing[unit] = showing
	return showing


static func _unit_of(target: Node) -> StringName:
	return target.unit_id if target != null and "unit_id" in target else &""
