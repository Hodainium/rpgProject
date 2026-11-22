## Spec event-pass 2.3: party position `slot` holds a member (living, with alive_only) with at least `hp_at_least` of
## their max HP (0 = any).
@tool
class_name MemberAt
extends RunCondition

@export_range(1, 4) var slot: int = 1
@export var alive_only: bool = true
@export_custom(PROPERTY_HINT_NONE, "suffix:%", PROPERTY_USAGE_EDITOR) var hp_at_least: float:
	get:
		return Fixed.to_display(hp_at_least_x100)
	set(typed):
		hp_at_least_x100 = Fixed.from_typed(typed)

@export_storage var hp_at_least_x100: int = 0


func holds(run: Object) -> bool:
	return run.member_at(slot, alive_only, hp_at_least_x100)
