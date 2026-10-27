## Decides an enemy's action. Content can subclass it; the default is deliberately simple.
##
## Default: the first action ability (in grant order, ults excluded) that can activate; a target that needs choosing is drawn with the
## battle RNG over the living candidates in slot order. Any RNG use here is part of the replay.
## Subclasses (spec content-pass 2.2): PatternBrain, TacticalBrain.
class_name EnemyBrain
extends Resource


## Spec skill-points D19: on battle turns divisible by this, the unit uses a level skill it has reached (its secret
## skill, the first in its table that can activate) instead of its usual choice. 0 = never (the default).
@export var level_skill_every: int = 0


## Returns {"ability": StringName, "target": StringName or &""}. An empty ability means the unit passes its turn.
func choose(unit: BattleUnit, battle: Battle) -> Dictionary:
	var secret := level_skill_choice(unit, battle)
	if not secret.is_empty():
		return secret
	for ability in unit.action_abilities():
		if not unit.asc.can_activate_ability(ability):
			continue
		var choice := choice_for(unit, battle, ability)
		if not choice.is_empty():
			return choice
	return {"ability": &"", "target": &""}


## Spec skill-points D19: {"ability", "target"} for a reached level skill when level_skill_every says so, else {}.
## Reads only the battle turn and the unit's kit, and draws from the RNG only for a chosen skill's target.
func level_skill_choice(unit: BattleUnit, battle: Battle) -> Dictionary:
	if level_skill_every <= 0 or battle.turn % level_skill_every != 0:
		return {}
	for row in unit.definition.level_skills:
		if row == null or row.ability == null or row.level > unit.level:
			continue
		var ability := unit.ability_by_tag(SkillTags.tag_of(row.ability))
		if ability != null and not ability.is_triggered() and not ability.is_ultimate() 				and unit.asc.can_activate_ability(ability):
			var choice := choice_for(unit, battle, ability)
			if not choice.is_empty():
				return choice
	return {}


## Spec ult-interrupts: asked at each BETWEEN ult window. Returns {"ability", "target"} to cast an ult out of turn, or
## {} to hold. Default: the first ult (grant order) that can activate, its target drawn like choose(). Nothing is drawn
## from the RNG unless an ult is cast, so enemies without a ready ult never change a replay.
func choose_interrupt(unit: BattleUnit, battle: Battle) -> Dictionary:
	for ability in unit.ultimate_abilities():
		if not unit.asc.can_activate_ability(ability):
			continue
		var choice := choice_for(unit, battle, ability)
		if not choice.is_empty():
			return choice
	return {}


## {"ability", "target"} for `ability`, the target drawn with the battle RNG from target_pool(); {} when it needs a
## target and none is left.
func choice_for(unit: BattleUnit, battle: Battle, ability: BattleAbility) -> Dictionary:
	var target: StringName = &""
	if ability.needs_target():
		var candidates := target_pool(unit, battle, ability)
		if candidates.is_empty():
			return {}
		target = candidates[battle.rng.randi_range(0, candidates.size() - 1)].unit_id
	return {"ability": ability.ability_tag, "target": target}


## The units a target is drawn from (slot order). Default: every valid candidate. Subclasses may narrow it; they must
## not draw from the RNG here.
func target_pool(unit: BattleUnit, battle: Battle, ability: BattleAbility) -> Array[BattleUnit]:
	return battle.target_candidates(unit, ability)
