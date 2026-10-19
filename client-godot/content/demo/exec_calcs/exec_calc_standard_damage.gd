## ExecCalc_StandardDamage (specs/design/combat-design.md) on x100 whole numbers, truncating toward zero:
##
##   BaseDmg        = atk x SkillMultiplier%   (the execution row's SCALED multiplier; default 100%)  or the row's FLAT damage
##   DefMultiplier% = 100% - def x 100% / (def + 1000)
##   RawDmg         = BaseDmg x DefMultiplier%
##   crit: rng.randi_range(0, 9999) < crit_rate  ->  RawDmg x (100% + crit_dmg)
##
## One RNG roll per hit, from the battle's seeded RNG.
class_name ExecCalcStandardDamage
extends GameplayExecutionCalculation

const DEF_CONSTANT: int = 100000  # 1000.00


@warning_ignore("integer_division")
func execute(spec: GameplayEffectSpec, target_asc: AbilitySystemComponent) -> Dictionary:
	var source := BattleContext.source_asc(spec)
	var atk := int(source.get_attribute("atk").current_value)
	var def := int(target_asc.get_attribute("def").current_value)
	var crit_rate := int(source.get_attribute("crit_rate").current_value)
	var crit_dmg := int(source.get_attribute("crit_dmg").current_value)

	var base: int
	if spec.set_by_caller_magnitudes.has(ExecutionRow.DAMAGE_FLAT_TAG):
		base = int(spec.get_set_by_caller_magnitude(ExecutionRow.DAMAGE_FLAT_TAG))
	else:
		var multiplier := int(spec.get_set_by_caller_magnitude(ExecutionRow.DAMAGE_MULTIPLIER_TAG, Fixed.ONE_HUNDRED_PERCENT))
		base = Fixed.pct(atk, multiplier)

	var def_multiplier := Fixed.ONE_HUNDRED_PERCENT - def * Fixed.ONE_HUNDRED_PERCENT / (def + DEF_CONSTANT)
	var damage := Fixed.pct(base, def_multiplier)
	if BattleContext.rng_for(target_asc).randi_range(0, 9999) < crit_rate:
		damage = Fixed.pct(damage, Fixed.ONE_HUNDRED_PERCENT + crit_dmg)
	return {"hp": float(-damage)}
