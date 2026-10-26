## ExecCalc_StandardDamage (specs/design/combat-design.md) on x100 whole numbers, truncating toward zero:
##
##   BaseDmg        = atk x SkillMultiplier%   (the execution row's SCALED multiplier; default 100%)  or the row's FLAT damage
##   def            = target.def x (100% - source.def_pen)   (def_pen capped at 100%)
##   DefMultiplier% = 100% - def x 100% / (def + 1000)
##   RawDmg         = BaseDmg x DefMultiplier%
##   weakness: the row's Damage.Type.<X> and the target's Weakness.<X>  ->  RawDmg x target.weakness_dmg, a weakness hit,
##             and unless the target is Broken: toughness -= row toughness x (100% + source.toughness_dmg)
##   broken: target is State.Broken  ->  RawDmg x (100% + source.broken_dmg)
##   crit: rng.randi_range(0, 9999) < crit_rate  ->  RawDmg x (100% + crit_dmg), a critical hit
##   final: RawDmg x source.dmg_mult x target.dmg_taken   (both 100% by default, never below 0%)
## Affinities (spec content-pass 2.4, Drain > Weak > Resist), by the row's Damage.Type.<X>:
##   drain:  target has Drain.<X>  ->  no damage: the target heals RawDmg x target.heal_taken, a drained hit; nothing
##           else applies (no toughness, no crit roll)
##   resist: not a weakness hit and target has Resist.<X>  ->  RawDmg x target.resist_dmg, a resisted hit (no toughness)
##
## One RNG roll per hit, from the battle's seeded RNG. Weakness, toughness and Broken use no RNG.
## Hit tags (spec item-pass): the ExecCalc marks the hit, the battle turns each mark into Event.Damage.Dealt/Taken.<X>.
class_name ExecCalcStandardDamage
extends GameplayExecutionCalculation

const DEF_CONSTANT: int = 100000  # 1000.00
const WEAKNESS_PREFIX: String = "Weakness."
const DRAIN_PREFIX: String = "Drain."
const RESIST_PREFIX: String = "Resist."

## The tags this calc puts on a hit (spec.inject_tag); as fields, so sync_tags registers them.
@export_custom(PROPERTY_HINT_NONE, "gas::tag") var weakness_hit_tag: StringName = &"Hit.Weakness"
@export_custom(PROPERTY_HINT_NONE, "gas::tag") var critical_hit_tag: StringName = &"Hit.Critical"
@export_custom(PROPERTY_HINT_NONE, "gas::tag") var drained_hit_tag: StringName = &"Hit.Drained"
@export_custom(PROPERTY_HINT_NONE, "gas::tag") var resisted_hit_tag: StringName = &"Hit.Resisted"


@warning_ignore("integer_division")
func execute(spec: GameplayEffectSpec, target_asc: AbilitySystemComponent) -> Dictionary:
	var source := BattleContext.source_asc(spec)
	var atk := int(source.get_attribute("atk").current_value)
	var def := int(target_asc.get_attribute("def").current_value)
	def = Fixed.pct(def, Fixed.ONE_HUNDRED_PERCENT - mini(_stat(source, "def_pen", 0), Fixed.ONE_HUNDRED_PERCENT))
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
	var result := {}
	var broken := target_asc.has_tag_exact(Battle.BROKEN_TAG)
	if _hits_affinity(spec, target_asc, DRAIN_PREFIX):
		spec.inject_tag(drained_hit_tag)
		return {"hp": float(Fixed.pct(damage, maxi(_stat(target_asc, "heal_taken", Fixed.ONE_HUNDRED_PERCENT), 0)))}
	if _hits_weakness(spec, target_asc):
		damage = Fixed.pct(damage, _stat(target_asc, "weakness_dmg", Fixed.ONE_HUNDRED_PERCENT))
		spec.inject_tag(weakness_hit_tag)
		var toughness := int(spec.get_set_by_caller_magnitude(ExecutionRow.TOUGHNESS_TAG))
		if toughness > 0 and not broken and _stat(target_asc, "max_toughness", 0) > 0:
			toughness = Fixed.pct(toughness, Fixed.ONE_HUNDRED_PERCENT + _stat(source, "toughness_dmg", 0))
			result["toughness"] = float(-toughness)
	elif _hits_affinity(spec, target_asc, RESIST_PREFIX):
		damage = Fixed.pct(damage, _stat(target_asc, "resist_dmg", Fixed.ONE_HUNDRED_PERCENT / 2))
		spec.inject_tag(resisted_hit_tag)
	if broken:
		damage = Fixed.pct(damage, Fixed.ONE_HUNDRED_PERCENT + _stat(source, "broken_dmg", 0))
	if BattleContext.rng_for(target_asc).randi_range(0, 9999) < crit_rate:
		damage = Fixed.pct(damage, Fixed.ONE_HUNDRED_PERCENT + crit_dmg)
		spec.inject_tag(critical_hit_tag)
	damage = Fixed.pct(damage, maxi(_stat(source, "dmg_mult", Fixed.ONE_HUNDRED_PERCENT), 0))
	damage = Fixed.pct(damage, maxi(_stat(target_asc, "dmg_taken", Fixed.ONE_HUNDRED_PERCENT), 0))
	result["hp"] = float(-damage)
	return result


## The row's damage type (a Damage.Type.<X> tag on the spec) matches one of the target's Weakness.<X> tags.
static func _hits_weakness(spec: GameplayEffectSpec, target_asc: AbilitySystemComponent) -> bool:
	return _hits_affinity(spec, target_asc, WEAKNESS_PREFIX)


## The row's damage type matches one of the target's <prefix><X> tags (Weakness., Drain., Resist.).
static func _hits_affinity(spec: GameplayEffectSpec, target_asc: AbilitySystemComponent, prefix: String) -> bool:
	for tag in spec.dynamic_tags:
		if String(tag).begins_with(Battle.DAMAGE_TYPE_PREFIX):
			if target_asc.has_tag_exact(StringName(prefix + String(tag).trim_prefix(Battle.DAMAGE_TYPE_PREFIX))):
				return true
	return false


## An attribute's current value, or `fallback` while the unit's set doesn't have it.
static func _stat(asc: AbilitySystemComponent, attribute_name: String, fallback: int) -> int:
	var data := asc.get_attribute(attribute_name)
	return int(data.current_value) if data != null else fallback
