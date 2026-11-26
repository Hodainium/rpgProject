## Spec auto-support 3.2: what an ability would restore on a target if a source cast it now, without activating it:
## {attribute: amount ×100}, before the target's cap. Like CostReader: reads every execution row's effect, its positive
## CombatModifiers and every ExecCalc that offers restore_of(source_asc, target_asc) (the content's restore and
## percent-of-max ExecCalcs, the fixture copy). An instant effect counts once, a periodic TURN_BASED one (a HoT) once per
## tick over its duration_turns (a REFRESH_DURATION HoT already on the target at its stack cap: only the ticks the refresh
## adds), positive modifiers at the source's effect level (their scaling curve); a non-periodic TURN_BASED, DURATION or INFINITE effect restores nothing (its modifiers are
## a buff). Rows with a chance count fully. An ExecCalc without restore_of counts as 0. Never activates anything and never
## draws from the RNG.
class_name RestoreReader
extends RefCounted


## `first`: whether `target` is the ability's primary target, or its first one when it has none (an untargeted move);
## `has_primary`: whether the ability has a primary at all. As Battle applies rows: PRIMARY only on the first, ADJACENT on
## every target but the primary (so on every target of an untargeted move).
static func restore_of(ability: BattleAbility, source: BattleUnit, target: BattleUnit, first: bool = true,
		has_primary: bool = true) -> Dictionary:
	var restored := {}
	if ability == null or target == null:
		return restored
	var source_asc: AbilitySystemComponent = source.asc if source != null else null
	var level := float(source.effect_level) if source != null else 1.0
	for row in ability.executions:
		if row == null or row.effect == null or row.damage_mode != ExecutionRow.DamageMode.USE_EFFECT:
			continue
		if (row.targets == ExecutionRow.Targets.PRIMARY and not first) \
				or (row.targets == ExecutionRow.Targets.ADJACENT and first and has_primary):
			continue
		var part := effect_restore(row.effect, source_asc, target.asc, level)
		for attribute_name in part:
			restored[attribute_name] = int(restored.get(attribute_name, 0)) + int(part[attribute_name])
	return restored


## HP only (×100; 0 when the ability restores no HP).
static func hp_restore(ability: BattleAbility, source: BattleUnit, target: BattleUnit, first: bool = true,
		has_primary: bool = true) -> int:
	return maxi(int(restore_of(ability, source, target, first, has_primary).get(BattleUnit.HP, 0)), 0)


## Without any unit (the validator's heal_unreadable): true when some row's effect restores HP the reader can see: an
## instant or periodic effect with a positive ADD hp modifier, or with an ExecCalc offering restore_of on "hp".
static func reads_hp(ability: BattleAbility) -> bool:
	if ability == null:
		return false
	for row in ability.executions:
		if row == null or row.effect == null or row.damage_mode != ExecutionRow.DamageMode.USE_EFFECT:
			continue
		var effect := row.effect
		if effect.policy == GameplayEffect.DurationPolicy.TURN_BASED and (effect.period <= 0.0 or not effect.tick_on_turn_start):
			continue
		if effect.policy != GameplayEffect.DurationPolicy.INSTANT and effect.policy != GameplayEffect.DurationPolicy.TURN_BASED:
			continue
		for modifier in effect.modifiers:
			if _static_add(modifier) and modifier.attribute_name == BattleUnit.HP and modifier.value_x100 > 0:
				return true
		for execution in effect.executions:
			if execution != null and execution.has_method("restore_of") and str(execution.get("attribute")) == BattleUnit.HP:
				return true
	return false


## What one application of `effect` restores (positive amounts only), ticks included.
static func effect_restore(effect: GameplayEffect, source_asc: AbilitySystemComponent,
		target_asc: AbilitySystemComponent, level: float = 1.0) -> Dictionary:
	var restored := {}
	if effect == null or target_asc == null:
		return restored
	var times := 1
	if effect.policy == GameplayEffect.DurationPolicy.TURN_BASED:
		if effect.period <= 0.0 or not effect.tick_on_turn_start:
			return restored  # CombatASC ticks only on turn start
		times = new_ticks(effect, target_asc)
	elif effect.policy != GameplayEffect.DurationPolicy.INSTANT:
		return restored
	if times <= 0:
		return restored
	for modifier in effect.modifiers:
		if _static_add(modifier) and modifier.value_x100 > 0:
			var amount: int = modifier.value_x100 if modifier.scaling_curve == null else int(modifier.calculate_magnitude(level))
			restored[modifier.attribute_name] = int(restored.get(modifier.attribute_name, 0)) + amount * times
	for execution in effect.executions:
		if execution == null or not execution.has_method("restore_of"):
			continue
		var part: Dictionary = execution.restore_of(source_asc, target_asc)
		for attribute_name in part:
			var amount := int(part[attribute_name])
			if amount > 0:
				restored[attribute_name] = int(restored.get(attribute_name, 0)) + amount * times
	return restored


## The ticks one more application of a periodic TURN_BASED effect adds on `target_asc`: its duration_turns; for a
## REFRESH_DURATION effect already there, the refresh's extra turns for each stack it has, plus a new stack's full
## duration while it is under its stack cap (0 when a cast at the cap purges it). Reads the addon's active effects
## (CombatASC relies on them too). Instigator-independent stacking is read as shared (no demo HoT uses it).
static func new_ticks(effect: GameplayEffect, target_asc: AbilitySystemComponent) -> int:
	var duration := maxi(effect.duration_turns, 1)
	if effect.stacking_policy != GameplayEffect.StackingPolicy.REFRESH_DURATION:
		return duration
	for active_effect in target_asc._active_effects:
		if active_effect.get_effect_def() != effect:
			continue
		var refreshed := maxi(duration - active_effect.spec.remaining_turns, 0) * active_effect.stack_count
		var stacking := effect.max_stacks <= 0 or active_effect.stack_count < effect.max_stacks
		if not stacking and effect.clear_stack_on_overflow:
			return 0  # a cast at the cap purges the effect instead
		return refreshed + (duration if stacking else 0)
	return duration


## A plain typed ADD modifier (STATIC magnitude): the only kind whose amount the reader can know without applying it.
static func _static_add(modifier: Variant) -> bool:
	return modifier is CombatModifier and modifier.operation == GameplayEffectModifier.Operation.ADD \
		and modifier.magnitude_calculation == GameplayEffectModifier.MagnitudeCalculationType.STATIC
