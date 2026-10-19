@tool
class_name GainCoins
extends RunOutcome

@export var amount: int = 1


func apply(run: Object) -> void:
	run.add_coins(amount)
