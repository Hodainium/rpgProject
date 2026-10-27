## Spec skill-points 3.2: what an ability costs a unit, without activating it: {attribute: amount ×100, positive}.
## Reads the cost effect's negative modifiers (plain costs, e.g. the ult's energy) and every execution calc that offers
## cost_of(caster) (the SP cost ExecCalc in content, its fixture copy), so the cost hint and the bots see the same
## number the battle subtracts. Never activates anything and never draws from the RNG.
class_name CostReader
extends RefCounted


static func cost_of(ability: GameplayAbility, caster: AbilitySystemComponent = null) -> Dictionary:
	var costs := {}
	if ability == null or ability.cost_effect == null:
		return costs
	for modifier in ability.cost_effect.modifiers:
		if modifier is CombatModifier and modifier.value_x100 < 0:
			costs[modifier.attribute_name] = int(costs.get(modifier.attribute_name, 0)) - modifier.value_x100
	for execution in ability.cost_effect.executions:
		if execution != null and execution.has_method("cost_of"):
			var part: Dictionary = execution.cost_of(caster)
			for attribute_name in part:
				costs[attribute_name] = int(costs.get(attribute_name, 0)) + int(part[attribute_name])
	return costs


## The ability's SP cost for `caster` (×100; 0 when it costs no SP).
static func sp_cost(ability: GameplayAbility, caster: AbilitySystemComponent = null) -> int:
	return int(cost_of(ability, caster).get(BattleUnit.MP, 0))
