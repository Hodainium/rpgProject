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


## {"name", "cost", "description", "target", "usage"} for `ability` (unit may be null).
static func of(_unit: BattleUnit, ability: BattleAbility) -> Dictionary:
	if ability == null:
		return {"name": "?", "cost": "", "description": "", "target": "", "usage": ""}
	return {
		"name": AbilityName.of(ability),
		"cost": cost_text(ability),
		"description": ability.description,
		"target": TARGET_TEXT.get(ability.targeting, ""),
		"usage": USAGE_TEXT[ability.usage()],
	}


## "12 MP", "ULT 100%" or "" from the ability's cost effect.
static func cost_text(ability: GameplayAbility) -> String:
	if ability == null or ability.cost_effect == null:
		return ""
	var parts := PackedStringArray()
	for modifier in ability.cost_effect.modifiers:
		if not modifier is CombatModifier or modifier.value_x100 >= 0:
			continue
		var amount := Fixed.to_display(-modifier.value_x100)
		var shown := str(int(amount)) if amount == int(amount) else str(amount)
		match modifier.attribute_name:
			"mp":
				parts.append("%s MP" % shown)
			"energy":
				parts.append("ULT %s%%" % shown)
			"hp":
				parts.append("%s HP" % shown)
	return " · ".join(parts)
