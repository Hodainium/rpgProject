## Spec keys-and-gear 2.7 (Isaac's mapping items): EVENTS shows the event rooms' type on this floor; ALL shows the
## whole floor (layout and types). Put it on an item's on_pickup and on_floor_start hooks for "every floor".
@tool
class_name RevealRooms
extends RunOutcome

enum Mode { EVENTS, ALL }

@export var mode: Mode = Mode.EVENTS


func apply(run: Object) -> void:
	run.reveal_rooms(mode == Mode.ALL)
