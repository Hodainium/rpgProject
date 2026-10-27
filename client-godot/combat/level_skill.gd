## Spec skill-points D17, D24, D25: one row of a unit's level table (UnitDefinition.level_skills). From `level` on, the
## unit has `ability` (an action or a triggered passive); `replaces` names the ability tag it supersedes, so a stronger
## rank takes the old one's place (Fireburst II replaces Fireburst). Characters and enemies share it: an enemy's level
## comes from the floor depth and its variant and slot (spec skill-points D19).
@tool
class_name LevelSkill
extends Resource

@export_range(2, 99) var level: int = 2
@export var ability: PackedScene
## The ability tag this row supersedes ("" = none): that ability is not granted once the row is reached.
@export_custom(PROPERTY_HINT_NONE, "gas::tag") var replaces: StringName = &""
