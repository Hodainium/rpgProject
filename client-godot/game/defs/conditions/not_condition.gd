## Spec event-pass 2.3: true when `condition` does not hold (none set: true).
@tool
class_name NotCondition
extends RunCondition

@export var condition: RunCondition


func holds(run: Object) -> bool:
	return condition == null or not condition.holds(run)
