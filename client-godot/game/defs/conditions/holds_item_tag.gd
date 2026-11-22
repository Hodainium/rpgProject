## Spec event-pass 2.3: a member (any, or the one at party position `slot`) holds an item matching `query`.
@tool
class_name HoldsItemTag
extends RunCondition

@export var query: GameplayTagQuery
## 0: anyone.
@export_range(0, 4) var slot: int = 0


func holds(run: Object) -> bool:
	return query != null and not run.held_items_matching(query, slot).is_empty()
