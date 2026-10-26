## Spec content-pass 2.2: the default choice with two refinements, both read from battle state (no extra RNG draws).
##
## Targets: among the valid candidates (taunters first, which the battle already enforces), it skips units that drain
## the ability's damage type, then units that resist it, as long as another candidate is left (Persona enemies learn
## affinities). Ults: held until a condition holds, when any is set: a party unit is Downed (hit on a weakness, spec
## content-pass H7) or Broken, or a unit on its own side
## (itself included) is below `ult_when_ally_hp_below` % HP. With neither set it casts as soon as it can, like the
## default brain.
@tool
class_name TacticalBrain
extends EnemyBrain

const DRAIN_PREFIX: String = "Drain."
const RESIST_PREFIX: String = "Resist."

## Cast the ult while a party unit is Downed or Broken.
@export var ult_when_party_down: bool = false
## Cast the ult while an ally (or itself) is below this share of max HP, as typed (40 = 40%). 0 = no such condition.
@export_custom(PROPERTY_HINT_NONE, "suffix:%", PROPERTY_USAGE_EDITOR) var ult_when_ally_hp_below: float:
	get:
		return Fixed.to_display(ult_when_ally_hp_below_x100)
	set(typed):
		ult_when_ally_hp_below_x100 = Fixed.from_typed(typed)

@export_storage var ult_when_ally_hp_below_x100: int = 0


func choose_interrupt(unit: BattleUnit, battle: Battle) -> Dictionary:
	if not _ult_wanted(unit, battle):
		return {}
	return super(unit, battle)


func target_pool(unit: BattleUnit, battle: Battle, ability: BattleAbility) -> Array[BattleUnit]:
	var candidates := battle.target_candidates(unit, ability)
	var types := _damage_types(ability)
	if types.is_empty():
		return candidates
	for prefix in [DRAIN_PREFIX, RESIST_PREFIX]:
		var kept: Array[BattleUnit] = []
		for candidate in candidates:
			if not _has_affinity(candidate, prefix, types):
				kept.append(candidate)
		if not kept.is_empty():
			candidates = kept
	return candidates


func _ult_wanted(unit: BattleUnit, battle: Battle) -> bool:
	if not ult_when_party_down and ult_when_ally_hp_below_x100 <= 0:
		return true
	for other in battle.units():
		if not other.alive:
			continue
		if ult_when_party_down and other.is_party() \
				and (other.asc.has_tag_exact(Battle.DOWNED_TAG) or other.asc.has_tag_exact(Battle.BROKEN_TAG)):
			return true
		if ult_when_ally_hp_below_x100 > 0 and other.side == unit.side \
				and other.stat(BattleUnit.HP) * Fixed.ONE_HUNDRED_PERCENT < ult_when_ally_hp_below_x100 * other.stat(BattleUnit.MAX_HP):
			return true
	return false


static func _damage_types(ability: BattleAbility) -> Array[String]:
	var types: Array[String] = []
	for row in ability.executions:
		if row == null:
			continue
		for damage_type in row.damage_types():
			if not types.has(damage_type):
				types.append(damage_type)
	return types


static func _has_affinity(unit: BattleUnit, prefix: String, types: Array[String]) -> bool:
	for damage_type in types:
		if unit.asc.has_tag_exact(StringName(prefix + damage_type)):
			return true
	return false
