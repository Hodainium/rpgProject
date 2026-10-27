## Project-specific AbilitySystemComponent (Lyra-style extension, client-godot/CLAUDE.md section 2).
##
## Adds two things GodotGAS doesn't have, without editing the addon:
## - Split turn timing: DoTs/HoTs tick at the start of the unit's turn, buffs/debuffs count down at the end of it.
##   GodotGAS's advance_turn() does both in one call and is never used in combat.
## - Whole-number snap: attribute values produced by GodotGAS's float aggregation are snapped to whole numbers,
##   so percentage modifiers stay deterministic (spec "Number format").
##
## - Deterministic triggers (spec game-skeleton 3.4): inside a battle, abilities whose trigger_event_tag matches a
##   gameplay event are queued on the battle's TriggerQueue instead of being activated at once without an await.
##
## Relies on addon internals (_active_effects, _active_abilities, _evaluate_spec, _commit_spec_math,
## _trigger_effect_events, _aggregate_attribute_value, _calculate_base_targets). tests/combat/test_combat_asc.gd and
## tests/combat/test_triggers.gd pin that behaviour.
class_name CombatASC
extends AbilitySystemComponent

## Effects applied while this unit is taking its own turn skip that turn's countdown (HSR rule), so a 2-turn
## self-buff covers the unit's next two turns.
var _skip_countdown: Dictionary = {}  # ActiveGameplayEffect -> true
var _in_own_turn: bool = false


func _ready() -> void:
	super()
	active_effect_added.connect(_on_active_effect_added)


## Spec keys-and-gear 2.6: GodotGAS's gatekeeper plus the Ability.Usage.* rule, so every caller (battle actions, ult
## windows, brains, Auto, field mode) refuses a Field-only ability in battle and a Battle-only one on the map.
func can_activate_ability(ability: GameplayAbility, emit_failure: bool = false) -> bool:
	if ability is BattleAbility and not usage_allows(ability):
		if emit_failure:
			ability_activation_failed.emit(ability, ActivationError.FAILED_QUERY, {"message": "usage"})
		return false
	return super(ability, emit_failure)


## Only tagged abilities are checked: Field-only needs State.Infield, Battle-only needs it absent.
func usage_allows(ability: BattleAbility) -> bool:
	var field := ability.asset_tags.has(BattleAbility.USAGE_FIELD_TAG)
	var battle := ability.asset_tags.has(BattleAbility.USAGE_BATTLE_TAG)
	if field == battle:
		return true
	return has_tag_exact(Battle.IN_FIELD_TAG) == field


## Turn start: tick periodic TURN_BASED effects (DoTs/HoTs), then count down their duration.
## Spec content-pass H3: a stacked periodic effect (REFRESH_DURATION with max_stacks) ticks once per stack, in stack
## order; GodotGAS keeps every stack's spec in stack_specs (the first is the wrapper's own spec) but would tick only
## one. One countdown per effect, since stacking refreshes the wrapper's duration.
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
			for stack_spec in active_effect.stack_specs:
				_trigger_effect_events(stack_spec)
				_evaluate_spec(stack_spec)
				_commit_spec_math(stack_spec)
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


## A One More action (spec item-pass 3.2) counts as the unit's own turn for effects it applies, so a self-buff from it
## also skips one countdown. The skip list is cleared at the unit's next turn_end(), as for a normal turn.
func begin_extra_action() -> void:
	_in_own_turn = true


func end_extra_action() -> void:
	_in_own_turn = false


## Same announcement as GodotGAS, but triggered abilities go on the battle's queue (grant order) instead of running now.
## Outside a battle (no Battle ancestor) the addon's own behaviour applies.
func send_gameplay_event(event_tag: StringName, payload: Variant = null) -> void:
	if event_tag == &"":
		return
	var battle := BattleContext.battle_for(self)
	if battle == null:
		super(event_tag, payload)
		return
	gameplay_event_received.emit(event_tag, payload)
	for ability in _active_abilities:
		if ability is BattleAbility and ability.trigger_event_tag == event_tag:
			battle.triggers.push(get_parent(), ability, event_tag, payload)


## Spec content-pass (cleanse and dispel): removes every active effect granting `tag` or one of its children, as UE
## GAS does, so a Cleanse lists Status.Debuff instead of every debuff. GodotGAS alone matches the exact tag only.
## Also used by GameplayEffect.remove_effects_with_tags.
func remove_effects_with_tag(tag: StringName) -> void:
	var prefix := String(tag) + "."
	for i in range(_active_effects.size() - 1, -1, -1):
		var active_effect: ActiveGameplayEffect = _active_effects[i]
		for granted in active_effect.get_effect_def().granted_tags:
			if granted == tag or String(granted).begins_with(prefix):
				remove_active_effect(active_effect)
				break


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
