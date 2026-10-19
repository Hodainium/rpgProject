## Never takes coins below 0.
@tool
class_name LoseCoins
extends RunOutcome

@export var amount: int = 1


func apply(run: Object) -> void:
	run.add_coins(-amount)
