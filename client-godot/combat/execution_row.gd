## One line of an ability's execution table (Dark Souls-style; spec "Execution table and animation events").
##
## The ability's animation fires rows by id with `execute(&"<id>")` method-track keys. A row says what one hit does:
## which effect it applies, an optional flat or scaled damage override, and which of the ability's targets it hits.
@tool
class_name ExecutionRow
extends Resource

enum DamageMode {
	USE_EFFECT,  ## No override: the effect's own math decides.
	FLAT,        ## Fixed damage: flat_damage.
	SCALED,      ## Percentage of the attacker's ATK: multiplier.
	EVENT_AMOUNT,  ## Spec item-power K6: the triggering event's amount (a hit, a tick) × multiplier; 0 outside a trigger.
}

enum Targets {
	ALL,       ## The ability's full target list.
	PRIMARY,   ## Only the primary target (or the first target when the ability has none).
	ADJACENT,  ## Everyone in the target list except the primary (blast neighbours).
	RANDOM,    ## Spec second-pack: one unit of the target list that is up, drawn for this row on the battle RNG (a flurry).
}

## SetByCaller tags the damage ExecCalc reads (values stored ×100).
const DAMAGE_FLAT_TAG: StringName = &"Data.Damage.Flat"
const DAMAGE_MULTIPLIER_TAG: StringName = &"Data.Damage.Multiplier"
## Spec item-pass 3.1: the toughness a weakness hit removes, read by the damage ExecCalc.
const TOUGHNESS_TAG: StringName = &"Data.Toughness"
## Spec item-power K6: the event's amount × multiplier of an EVENT_AMOUNT row, for effects that are not damage (a heal).
const EVENT_AMOUNT_TAG: StringName = &"Data.Event.Amount"
## Spec item-power K7: an echo's scale (×100 percent), set on every spec an echo applies; restores read it.
const ECHO_SCALE_TAG: StringName = &"Data.Echo.Scale"

## Name the animation's execute keys refer to. Unique within the ability.
@export var id: StringName = &""
## The effect this row applies (a damage effect, a buff, a DoT...).
@export var effect: GameplayEffect
@export var damage_mode: DamageMode = DamageMode.USE_EFFECT
@export var targets: Targets = Targets.ALL
## Spec game-skeleton 3.4: e.g. Damage.Type.Ice. A damaging hit also sends Event.Damage.Dealt.Ice /
## Event.Damage.Taken.Ice, so triggered passives can react to a damage type with no code.
@export_custom(PROPERTY_HINT_NONE, "gas::tag") var tags: Array[StringName] = []

## Flat damage as typed (e.g. 80.5), used when damage_mode is FLAT. Editor-only view of flat_damage_x100.
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR) var flat_damage: float:
	get:
		return Fixed.to_display(flat_damage_x100)
	set(typed):
		_warn_decimals("flat_damage", typed)
		flat_damage_x100 = Fixed.from_typed(typed)

## Percentage of the attacker's ATK (SCALED) or of the event's amount (EVENT_AMOUNT) as typed (150 = 150%).
@export_custom(PROPERTY_HINT_NONE, "suffix:%", PROPERTY_USAGE_EDITOR) var multiplier: float:
	get:
		return Fixed.to_display(multiplier_x100)
	set(typed):
		_warn_decimals("multiplier", typed)
		multiplier_x100 = Fixed.from_typed(typed)

## Toughness damage as typed (e.g. 30), dealt only by a hit on the target's weakness (spec item-pass 3.3).
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR) var toughness: float:
	get:
		return Fixed.to_display(toughness_x100)
	set(typed):
		_warn_decimals("toughness", typed)
		toughness_x100 = Fixed.from_typed(typed)

## Spec content-pass H2 / D13: the chance (typed %, e.g. 65) that this row's effect lands; one battle-RNG roll per
## target when it is below 100%. 0 (the default) always lands and draws nothing.
@export_custom(PROPERTY_HINT_NONE, "suffix:%", PROPERTY_USAGE_EDITOR) var chance: float:
	get:
		return Fixed.to_display(chance_x100)
	set(typed):
		_warn_decimals("chance", typed)
		chance_x100 = Fixed.from_typed(typed)

## Spec content-pass H6: when this row's effect lands, the target's action is delayed by this share (typed %, e.g. 30)
## of its full action value; a negative value advances it (never past 0). 0 = no change.
@export_custom(PROPERTY_HINT_NONE, "suffix:%", PROPERTY_USAGE_EDITOR) var delay: float:
	get:
		return Fixed.to_display(delay_x100)
	set(typed):
		_warn_decimals("delay", typed)
		delay_x100 = Fixed.from_typed(typed)

## Spec item-power (Plague Crown): the row applies the effect the triggering event is about (a DoT tick's own effect, with
## its damage values and types) instead of `effect`; an event without one applies `effect`.
@export var event_effect: bool = false

## Saved forms (×100 whole numbers).
@export_storage var flat_damage_x100: int = 0
@export_storage var multiplier_x100: int = 10000
@export_storage var toughness_x100: int = 0
@export_storage var chance_x100: int = 0
@export_storage var delay_x100: int = 0


## Puts this row's damage override and toughness damage on a spec through GodotGAS's SetByCaller mechanism, and its
## tags (damage types) on the spec as dynamic tags, so an ExecCalc can read them with spec.has_tag().
## Spec item-power: `event` is the triggering event's payload (K6; null outside a trigger), `echo_scale` an echo's scale
## (K7; 0 = not an echo), which scales the damage, the toughness damage and (through ECHO_SCALE_TAG) restores.
func apply_override(spec: GameplayEffectSpec, event: Variant = null, echo_scale: int = 0) -> void:
	var scale := echo_scale if echo_scale > 0 else Fixed.ONE_HUNDRED_PERCENT
	match damage_mode:
		DamageMode.FLAT:
			spec.set_set_by_caller_magnitude(DAMAGE_FLAT_TAG, float(Fixed.pct(flat_damage_x100, scale)))
		DamageMode.SCALED:
			spec.set_set_by_caller_magnitude(DAMAGE_MULTIPLIER_TAG, float(Fixed.pct(multiplier_x100, scale)))
		DamageMode.EVENT_AMOUNT:
			var amount: int = int(event.get("amount", 0)) if event is Dictionary else 0
			amount = Fixed.pct(Fixed.pct(amount, multiplier_x100), scale)
			spec.set_set_by_caller_magnitude(DAMAGE_FLAT_TAG, float(amount))
			spec.set_set_by_caller_magnitude(EVENT_AMOUNT_TAG, float(amount))
	if echo_scale > 0:
		spec.set_set_by_caller_magnitude(ECHO_SCALE_TAG, float(echo_scale))
		if damage_mode == DamageMode.USE_EFFECT:  # a damage ExecCalc without an override deals 100% ATK
			spec.set_set_by_caller_magnitude(DAMAGE_MULTIPLIER_TAG, float(echo_scale))
	if toughness_x100 > 0:
		spec.set_set_by_caller_magnitude(TOUGHNESS_TAG, float(Fixed.pct(toughness_x100, scale)))
	for tag in tags:
		spec.inject_tag(tag)


## Damage types on this row (Physical, Fire… from Damage.Type.<X> tags), in row order.
func damage_types() -> Array[String]:
	var result: Array[String] = []
	for tag in tags:
		if String(tag).begins_with(Battle.DAMAGE_TYPE_PREFIX):
			result.append(String(tag).trim_prefix(Battle.DAMAGE_TYPE_PREFIX))
	return result


## The effect this row applies for `event`: the event's own effect with `event_effect`, else `effect`.
func effect_for(event: Variant) -> GameplayEffect:
	if event_effect and event is Dictionary and event.get("effect") is GameplayEffect:
		return event["effect"]
	return effect


## Spec item-power: copies the damage values and Damage.Type.* tags of the event's spec onto `spec`, so a spread DoT ticks
## like the one it came from.
static func copy_event_values(spec: GameplayEffectSpec, event: Variant) -> void:
	var from: GameplayEffectSpec = event.get("spec") if event is Dictionary else null
	if from == null:
		return
	for tag in from.set_by_caller_magnitudes:
		spec.set_set_by_caller_magnitude(tag, from.set_by_caller_magnitudes[tag])
	for tag in from.dynamic_tags:
		if String(tag).begins_with(Battle.DAMAGE_TYPE_PREFIX):
			spec.inject_tag(tag)
	if from.effect_def == spec.effect_def:
		spec.mutated_magnitudes = from.mutated_magnitudes.duplicate()  # an echo's smaller tick stays small


## Spec item-power: the turns a spread turn-based effect without a stack limit (StackingPolicy.FREE) gets: what the tick it
## came from has left after it, so each spread is shorter; 0 = keep the effect's own turns (a stacking one is bounded by its stacks), -1 = it has none left to give.
static func spread_turns(spec: GameplayEffectSpec, event: Variant) -> int:
	var from: GameplayEffectSpec = event.get("spec") if event is Dictionary else null
	if from == null or from.effect_def != spec.effect_def or spec.effect_def.policy != GameplayEffect.DurationPolicy.TURN_BASED \
			or spec.effect_def.stacking_policy != GameplayEffect.StackingPolicy.FREE:
		return 0
	var left := int(event.get("turns", 0))
	return left if left > 0 else -1


## Spec item-power K7: scales the spec's own added amounts (a buff's +20% ATK, a poison's tick, a flat heal) by an echo's scale,
## through GodotGAS's mutable magnitudes; effects that only grant tags (a stun) land whole, overrides and factors are kept.
static func scale_modifiers(spec: GameplayEffectSpec, echo_scale: int) -> void:
	var uses := {}  # GodotGAS overrides by attribute: one that two modifiers change is left whole
	for modifier in spec.effect_def.modifiers:
		if modifier != null:
			uses[modifier.attribute_name] = int(uses.get(modifier.attribute_name, 0)) + 1
	for modifier in spec.effect_def.modifiers:
		if modifier == null or uses[modifier.attribute_name] > 1 or not spec.mutated_magnitudes.has(modifier.attribute_name) \
				or modifier.magnitude_calculation != GameplayEffectModifier.MagnitudeCalculationType.STATIC \
				or not modifier.operation in [GameplayEffectModifier.Operation.ADD, GameplayEffectModifier.Operation.PERCENT_ADD]:
			continue
		if not modifier is CombatModifier or modifier.scaling_curve != null:
			continue
		var scaled := CombatModifier.new()  # whole hundredths scaled with integers, then read the way the modifier is
		scaled.operation = modifier.operation
		scaled.value_x100 = Fixed.pct(modifier.value_x100, echo_scale)
		spec.mutated_magnitudes[modifier.attribute_name] = scaled.calculate_magnitude(spec.level)


## Whether this row's effect is a debuff.
func applies_debuff() -> bool:
	return is_debuff(effect)


## Whether an effect is a debuff: it grants a Status.Debuff.* tag (spec content-pass H8).
static func is_debuff(applied: GameplayEffect) -> bool:
	return applied != null and applied.granted_tags.any(
		func(tag) -> bool: return String(tag).begins_with(Battle.DEBUFF_TAG + "."))


func _warn_decimals(field: String, typed: float) -> void:
	if Fixed.has_extra_decimals(typed):
		push_warning("ExecutionRow '%s': %s keeps only 2 decimals (%s)." % [id, field, typed])
