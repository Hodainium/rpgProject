## Spec food-items 3.1: applies a GameplayEffect to the member holding the item whose hook runs (on_pickup,
## on_floor_start, on_room_cleared), through the field context: a food's pickup heal or restore. Outside an item hook it
## does nothing and warns (the validator reports holder_effect_outside_item).
@tool
class_name ApplyHolderEffect
extends RunOutcome

@export var effect: GameplayEffect


func apply(run: Object) -> void:
	run.apply_holder_effect(effect)
