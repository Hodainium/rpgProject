## Spec event-pass 2.3: true when any of `conditions` holds (none listed: false).
@tool
class_name AnyOf
extends RunCondition

@export var conditions: Array[RunCondition] = []


func holds(run: Object) -> bool:
	for condition in conditions:
		if condition != null and condition.holds(run):
			return true
	return false
