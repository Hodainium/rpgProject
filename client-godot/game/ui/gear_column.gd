## Spec ff7-ui 2.8: one column of a gear screen (Equipment, Armor). Either an equipment slot tag, or a use-item slot
## number: a use-item column shows only while some party member has that many use slots, LOCKED for the others.
class_name GearColumn
extends Resource

@export var title: String = ""
## An Equipment.Slot.* tag; empty for a use-item column.
@export_custom(PROPERTY_HINT_NONE, "gas::tag") var slot: StringName = &""
## 1, 2, …: the use-item slot this column shows (0: an equipment column).
@export var use_slot: int = 0


func is_use_slot() -> bool:
	return use_slot > 0
