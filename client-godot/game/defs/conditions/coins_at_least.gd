@tool
class_name CoinsAtLeast
extends RunCondition

@export var amount: int = 1


func holds(run: Object) -> bool:
	return run.state.coins >= amount
