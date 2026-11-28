## Spec second-pack P1 (cube-style's "state looks"): a look that replaces one unit's own look while the unit carries any of `tags`
## (the Werewolf's Wolf Form: the timed status or the always-on low-HP part), swapped with a short transform: the cube squashes,
## a small burst plays (`enter_color` going in, `leave_color` going back) with a light screen shake, the look swaps while it is
## squashed, then it springs up and settles. Presentation only: listed in the StyleRegistry, read by the unit's view from its
## battle unit's GAS tags; never in a hash, a snapshot or an upload, and a headless run loads no registry, so no look.
@tool
class_name StateLook
extends Resource

## The unit (definition id) this look is for.
@export var unit_id: StringName
## The look is on while the unit carries any of these tags (exact).
@export var tags: Array[StringName] = []
## The look while on, over the unit's own look (a field left unset keeps the unit's own).
@export var look: UnitLook
@export var enter_color: Color = Color(0.95, 0.08, 0.1)
@export var leave_color: Color = Color(0.85, 0.8, 0.7)
## The burst at each change (its `color` parameter set from the colours above), played on an anchor scaled by `burst_scale`
## so the burst and how far its sparks fly shrink together.
@export var burst: FxDefinition
@export var burst_params: Dictionary = {}
@export var burst_scale: float = 0.55
@export var shake: FxDefinition
@export var shake_params: Dictionary = {}
## The squash (scale) the change goes through, how long it takes, the stretch it springs to and the settle time.
@export var squash: Vector3 = Vector3(1.1, 0.8, 1.1)
@export var squash_seconds: float = 0.16
@export var stretch: Vector3 = Vector3(0.92, 1.18, 0.92)
@export var stretch_seconds: float = 0.12
@export var settle_seconds: float = 0.22


## True while `asc` carries one of the tags.
func applies(asc: AbilitySystemComponent) -> bool:
	if asc == null or not is_instance_valid(asc):
		return false
	for tag in tags:
		if asc.has_tag_exact(tag):
			return true
	return false
