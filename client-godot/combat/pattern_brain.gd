## Spec content-pass 2.2: an enemy that follows a fixed rotation of actions (a boss's "every third turn, Quake").
##
## Step n of `pattern` is the unit's n-th action (its pattern_step, hashed when non-zero). A step whose ability the
## unit lacks, can't activate now, or can't find a target for falls back to the default choice; the step still counts.
## A step naming an ult is returned as-is, so the battle stops with a runner error (ults are never turn actions); the
## content validator reports it first.
class_name PatternBrain
extends EnemyBrain

## Ability tags in order; the rotation repeats.
@export_custom(PROPERTY_HINT_NONE, "gas::tag") var pattern: Array[StringName] = []


func choose(unit: BattleUnit, battle: Battle) -> Dictionary:
	if pattern.is_empty():
		return super(unit, battle)
	var tag := pattern[unit.pattern_step % pattern.size()]
	unit.pattern_step += 1
	var ability := unit.ability_by_tag(tag)
	if ability != null and not ability.is_triggered() and unit.asc.can_activate_ability(ability):
		var choice := choice_for(unit, battle, ability)
		if not choice.is_empty():
			return choice
	return super(unit, battle)
