## Spec keys-and-gear D7. A golden key does not count (it opens locks, it isn't spent).
@tool
class_name KeysAtLeast
extends RunCondition

@export var amount: int = 1


func holds(run: Object) -> bool:
	return run.state.keys >= amount
