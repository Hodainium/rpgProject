@tool
class_name HasItem
extends RunCondition

@export var item: ItemDefinition


func holds(run: Object) -> bool:
	return item != null and run.state.holder_of(item.id) > 0
