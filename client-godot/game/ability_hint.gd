## Spec ff7-ui 2.6: what the battle hint window and the menu screens say about an ability: its name, cost, description,
## who it targets and where it can be used. Presentation only: no rule reads it.
class_name AbilityHint
extends RefCounted

const TARGET_TEXT := {
	BattleAbility.Targeting.SINGLE_ENEMY: "ONE ENEMY",
	BattleAbility.Targeting.ALL_ENEMIES: "ALL ENEMIES",
	BattleAbility.Targeting.BLAST_ENEMY: "ONE ENEMY AND ITS NEIGHBOURS",
	BattleAbility.Targeting.SINGLE_ALLY: "ONE ALLY",
	BattleAbility.Targeting.ALL_ALLIES: "ALL ALLIES",
	BattleAbility.Targeting.SELF: "SELF",
	BattleAbility.Targeting.SINGLE_DEAD_ALLY: "ONE FALLEN ALLY",
	BattleAbility.Targeting.ALL_DEAD_ALLIES: "ALL FALLEN ALLIES",
}
## Spec keys-and-gear 2.6: from BattleAbility.usage() (the Ability.Usage.* tags; untagged: ff7-ui F14's rule).
const USAGE_FIELD := "[Field Only]"
const USAGE_BATTLE := "[Battles Only]"
const USAGE_BOTH := "[Field and Battles]"
const USAGE_TEXT := {
	BattleAbility.USAGE_FIELD: USAGE_FIELD, BattleAbility.USAGE_BATTLE: USAGE_BATTLE, BattleAbility.USAGE_BOTH: USAGE_BOTH,
}


## {"name", "cost", "description", "target", "usage", "unit", "spCost"} for `ability` (unit may be null; with one,
## the cost is that unit's, after its cost multiplier). "unit" (its id, "" without one) and "spCost" (whole SP, 0 when
## free) let the party window preview the SP the move would spend (spec skill-points).
static func of(unit: BattleUnit, ability: BattleAbility) -> Dictionary:
	if ability == null:
		return {"name": "?", "cost": "", "description": "", "target": "", "usage": "", "unit": "", "spCost": 0}
	@warning_ignore("integer_division")
	var sp := CostReader.sp_cost(ability, unit.asc if unit != null else null) / 100
	return {
		"name": AbilityName.of(ability),
		"cost": cost_text(ability, unit),
		"description": ability.description,
		"target": TARGET_TEXT.get(ability.targeting, ""),
		"usage": USAGE_TEXT[ability.usage()],
		"unit": String(unit.unit_id) if unit != null else "",
		"spCost": sp,
	}


## "12 SP", "ULT 100%" or "" from the ability's cost effect (spec skill-points D10: the player sees SP; the attribute
## stays mp). With a unit, its cost multiplier applies (CostReader, the number the battle subtracts).
static func cost_text(ability: GameplayAbility, unit: BattleUnit = null) -> String:
	var costs := CostReader.cost_of(ability, unit.asc if unit != null else null)
	var parts := PackedStringArray()
	for pair in [["mp", "%s SP"], ["energy", "ULT %s%%"], ["hp", "%s HP"]]:
		if not costs.has(pair[0]):
			continue
		var amount := Fixed.to_display(int(costs[pair[0]]))
		parts.append(pair[1] % (str(int(amount)) if amount == int(amount) else str(amount)))
	return " · ".join(parts)
