## Frozen test-only damage ExecCalc: the formula from specs/design/combat-design.md on ×100 whole numbers.
##
##   BaseDmg        = ATK × multiplier%      (row SCALED override; default 100%)  or the row's FLAT damage
##   DefMultiplier% = 100% − DEF × 100% / (DEF + 1000)
##   RawDmg         = BaseDmg × DefMultiplier%
##   weakness: row has Damage.Type.<X>, target has Weakness.<X> → × target.weakness_dmg, Hit.Weakness, and unless the
##             target is Broken: toughness −= Data.Toughness × (100% + source.toughness_dmg)       (spec item-pass 3.3)
##   broken:   target has State.Broken → × (100% + source.broken_dmg)
##   crit: rng.randi_range(0, 9999) < crit_rate  →  RawDmg × (100% + crit_dmg), Hit.Critical
##
## Draws exactly one RNG value per hit, so every replay exercises the battle RNG. The weakness, toughness and broken
## parts only apply to units with those attributes (FixtureBreakAttributeSet), so older fixtures are unchanged.
class_name FixtureDamage
extends GameplayExecutionCalculation

const DEF_CONSTANT: int = 100000  # 1000.00
const WEAKNESS_PREFIX: String = "Weakness."


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
	var deltas := {}
	if _hits_weakness(spec, target_asc) and target_asc.has_attribute("weakness_dmg"):
		damage = Fixed.pct(damage, _stat(target_asc, "weakness_dmg"))
		spec.inject_tag(&"Hit.Weakness")
		var toughness := int(spec.get_set_by_caller_magnitude(ExecutionRow.TOUGHNESS_TAG))
		if toughness > 0 and _stat(target_asc, "max_toughness") > 0 and not target_asc.has_tag_exact(Battle.BROKEN_TAG):
			deltas["toughness"] = float(-Fixed.pct(toughness, Fixed.ONE_HUNDRED_PERCENT + _stat(source, "toughness_dmg")))
	if target_asc.has_tag_exact(Battle.BROKEN_TAG):
		damage = Fixed.pct(damage, Fixed.ONE_HUNDRED_PERCENT + _stat(source, "broken_dmg"))
	if BattleContext.rng_for(target_asc).randi_range(0, 9999) < crit_rate:
		damage = Fixed.pct(damage, Fixed.ONE_HUNDRED_PERCENT + crit_dmg)
		spec.inject_tag(&"Hit.Critical")
	deltas["hp"] = float(-damage)
	return deltas


## The spec carries a Damage.Type.<X> tag (from its execution row) and the target has Weakness.<X>.
static func _hits_weakness(spec: GameplayEffectSpec, target_asc: AbilitySystemComponent) -> bool:
	for tag in spec.dynamic_tags:
		if String(tag).begins_with(Battle.DAMAGE_TYPE_PREFIX):
			var weakness := StringName(WEAKNESS_PREFIX + String(tag).trim_prefix(Battle.DAMAGE_TYPE_PREFIX))
			if target_asc.has_tag_exact(weakness):
				return true
	return false


static func _stat(asc: AbilitySystemComponent, attribute_name: String) -> int:
	var data := asc.get_attribute(attribute_name)
	return int(data.current_value) if data != null else 0
