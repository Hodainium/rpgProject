## An enemy wave (spec combat-replay-core section 3.1; game-skeleton section 3.1). Slot n gets unit id E<n>.
@tool
class_name EncounterDefinition
extends Resource

@export var id: StringName = &""
@export var display_name: String = ""
## Pool tags, e.g. Chapter.Basement, Encounter.Boss. Rooms and chapters pick encounters with tag queries.
@export_custom(PROPERTY_HINT_NONE, "gas::tag") var tags: Array[StringName] = []
@export var slots: Array[EncounterSlot] = []
## Spec playable-demo 3.7: granted to every enemy of the encounter (tags such as Drain.Ice, effects, abilities), after
## each enemy's variant. Run battles (v2 snapshots) only.
@export var grants: AbilitySet
## Spec playable-demo 3.7: applied in order after a won battle against this encounter (an item, armor, coins...).
@export var rewards: Array[RunOutcome] = []

## Pick weight as typed (1 = normal, 0.5 = half as likely). Editor-only view of weight_x100.
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR) var weight: float:
	get:
		return Fixed.to_display(weight_x100)
	set(typed):
		weight_x100 = Fixed.from_typed(typed)

@export_storage var weight_x100: int = 100


## The enemy definitions in slot order.
func enemies() -> Array[UnitDefinition]:
	var result: Array[UnitDefinition] = []
	for slot in slots:
		result.append(slot.enemy if slot != null else null)
	return result
