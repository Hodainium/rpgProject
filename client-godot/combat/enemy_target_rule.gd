## Playtest-fixes B30: "use this ability on a target that has these tags" (a Cultist attacks a member who already has
## Vulnerable, else follows its rotation). An EnemyBrain checks its rules in order before its usual choice: the first rule whose
## ability can activate and that has a matching living target fires, its target drawn with the battle RNG from the matching
## candidates (slot order). Checking draws nothing, so a rule that never fires never changes a replay. A PatternBrain's step
## does not advance when a rule fires. Data only: no unit-specific code.
class_name EnemyTargetRule
extends Resource

## The ability to use (an action the unit has; never an ult or a passive).
@export_custom(PROPERTY_HINT_NONE, "gas::tag") var ability: StringName = &""
## The target must have every one of these tags (or a child of each: Status.Debuff matches any debuff).
@export_custom(PROPERTY_HINT_NONE, "gas::tag") var target_has: Array[StringName] = []


## True when `target` carries every tag of `target_has` (and the list is not empty).
func matches(target: BattleUnit) -> bool:
	return not target_has.is_empty() and target.asc.has_all_tags(target_has)
