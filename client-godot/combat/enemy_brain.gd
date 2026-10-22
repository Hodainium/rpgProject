## Decides an enemy's action. Content can subclass it; the default is deliberately simple.
##
## Default: the first action ability (in grant order, ults excluded) that can activate; a target that needs choosing is drawn with the
## battle RNG over the living candidates in slot order. Any RNG use here is part of the replay.
class_name EnemyBrain
extends Resource


## Returns {"ability": StringName, "target": StringName or &""}. An empty ability means the unit passes its turn.
func choose(unit: BattleUnit, battle: Battle) -> Dictionary:
	for ability in unit.action_abilities():
		if not unit.asc.can_activate_ability(ability):
			continue
		var target: StringName = &""
		if ability.needs_target():
			var candidates := battle.target_candidates(unit, ability)
			if candidates.is_empty():
				continue
			target = candidates[battle.rng.randi_range(0, candidates.size() - 1)].unit_id
		return {"ability": ability.ability_tag, "target": target}
	return {"ability": &"", "target": &""}


## Spec ult-interrupts: asked at each BETWEEN ult window. Returns {"ability", "target"} to cast an ult out of turn, or
## {} to hold. Default: the first ult (grant order) that can activate, its target drawn like choose(). Nothing is drawn
## from the RNG unless an ult is cast, so enemies without a ready ult never change a replay.
func choose_interrupt(unit: BattleUnit, battle: Battle) -> Dictionary:
	for ability in unit.ultimate_abilities():
		if not unit.asc.can_activate_ability(ability):
			continue
		var target: StringName = &""
		if ability.needs_target():
			var candidates := battle.target_candidates(unit, ability)
			if candidates.is_empty():
				continue
			target = candidates[battle.rng.randi_range(0, candidates.size() - 1)].unit_id
		return {"ability": ability.ability_tag, "target": target}
	return {}
