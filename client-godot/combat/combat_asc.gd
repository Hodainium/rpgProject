## Project-specific AbilitySystemComponent (Lyra-style extension, client-godot/CLAUDE.md section 2).
##
## Adds two things GodotGAS doesn't have, without editing the addon:
## - Split turn timing: DoTs/HoTs tick at the start of the unit's turn, buffs/debuffs count down at the end of it.
##   GodotGAS's advance_turn() does both in one call and is never used in combat.
## - Whole-number snap: attribute values produced by GodotGAS's float aggregation are snapped to whole numbers,
##   so percentage modifiers stay deterministic (spec "Number format").
##
## Relies on addon internals (_active_effects, _evaluate_spec, _commit_spec_math, _trigger_effect_events,
## _aggregate_attribute_value, _calculate_base_targets). tests/combat/test_combat_asc.gd pins that behaviour.
class_name CombatASC
extends AbilitySystemComponent

## Effects applied while this unit is taking its own turn skip that turn's countdown (HSR rule), so a 2-turn
## self-buff covers the unit's next two turns.
var _skip_countdown: Dictionary = {}  # ActiveGameplayEffect -> true
var _in_own_turn: bool = false


func _ready() -> void:
	super()
	active_effect_added.connect(_on_active_effect_added)


## Turn start: tick periodic TURN_BASED effects (DoTs/HoTs), then count down their duration.
func turn_start() -> void:
	_in_own_turn = true
	for i in range(_active_effects.size() - 1, -1, -1):
		var active_effect: ActiveGameplayEffect = _active_effects[i]
		var spec := active_effect.spec
		if spec.effect_def.policy != GameplayEffect.DurationPolicy.TURN_BASED or spec.period <= 0.0:
			continue
		if spec.effect_def.tick_on_turn_start and not active_effect.is_suppressed:
			for cue_tag in spec.effect_def.periodic_cue_tags:
				execute_cue(cue_tag, {"target": get_parent()})
			_trigger_effect_events(spec)
			_evaluate_spec(spec)
			_commit_spec_math(spec)
		spec.remaining_turns -= 1
		if spec.remaining_turns <= 0:
			remove_active_effect(active_effect)


## Turn end: count down non-periodic TURN_BASED effects (buffs/debuffs) and remove the expired ones.
func turn_end() -> void:
	for i in range(_active_effects.size() - 1, -1, -1):
		var active_effect: ActiveGameplayEffect = _active_effects[i]
		var spec := active_effect.spec
		if spec.effect_def.policy != GameplayEffect.DurationPolicy.TURN_BASED or spec.period > 0.0:
			continue
		if _skip_countdown.has(active_effect):
			continue
		spec.remaining_turns -= 1
		if spec.remaining_turns <= 0:
			remove_active_effect(active_effect)
	_skip_countdown.clear()
	_in_own_turn = false


func _on_active_effect_added(active_effect: ActiveGameplayEffect) -> void:
	if _in_own_turn:
		_skip_countdown[active_effect] = true


## Snap aggregated current values (e.g. +20% of 33333) to whole numbers.
func _aggregate_attribute_value(attribute_name: String, base_value: float, extra_spec: GameplayEffectSpec = null) -> float:
	return Fixed.snap(super(attribute_name, base_value, extra_spec))


## Snap new base values from instant/periodic math to whole numbers before they are committed.
func _calculate_base_targets(spec: GameplayEffectSpec) -> Dictionary:
	var targets := super(spec)
	for attribute_name in targets:
		targets[attribute_name] = Fixed.snap(float(targets[attribute_name]))
	return targets
