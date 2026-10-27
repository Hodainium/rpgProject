## Spec keys-and-gear D7: never takes keys below 0.
@tool
class_name LoseKeys
extends RunOutcome

@export var amount: int = 1


func apply(run: Object) -> void:
	run.add_keys(-amount)
