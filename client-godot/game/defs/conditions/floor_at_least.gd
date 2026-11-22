## Spec event-pass 2.3: the run is on floor `min_floor` or deeper (1-based, as the player counts floors). Named
## min_floor, not floor, so it never shadows the global floor().
@tool
class_name FloorAtLeast
extends RunCondition

@export_range(1, 99) var min_floor: int = 1


func holds(run: Object) -> bool:
	return run.state.floor_index + 1 >= min_floor
