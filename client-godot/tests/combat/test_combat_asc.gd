## Effect timing and whole-number snap (spec "Effect timing: CombatASC", "Number format").
extends TestCase


func _unit(battle: Battle, id: StringName) -> BattleUnit:
	return battle.unit_by_id(id)


func _effect(name: String) -> GameplayEffect:
	return load(FIXTURES + "effects/%s.tres" % name)


func test_dot_ticks_at_turn_start_for_its_duration() -> void:
	var battle := new_battle(snapshot("duel", [[1, "striker"]]))
	var dummy := _unit(battle, &"E1")
	dummy.asc.apply_gameplay_effect(_effect("poison"))
	eq(dummy.stat("hp"), 80000, "no damage on application")
	for tick in 3:
		dummy.asc.turn_start()
		eq(dummy.stat("hp"), 80000 - 3000 * (tick + 1), "tick %d at turn start" % (tick + 1))
		dummy.asc.turn_end()
	eq(dummy.asc._active_effects.size(), 0, "a 3-turn DoT is gone after 3 ticks")
	dummy.asc.turn_start()
	eq(dummy.stat("hp"), 71000, "no 4th tick")


func test_debuff_ends_at_end_of_the_targets_second_turn() -> void:
	var battle := new_battle(snapshot("duel", [[1, "striker"]]))
	var dummy := _unit(battle, &"E1")
	dummy.asc.apply_gameplay_effect(_effect("weaken"))  # applied on someone else's turn
	eq(dummy.stat("def"), 16000, "DEF 200 - 20%")
	dummy.asc.turn_start()
	dummy.asc.turn_end()
	eq(dummy.stat("def"), 16000, "still active after the target's 1st turn")
	dummy.asc.turn_start()
	eq(dummy.stat("def"), 16000, "active during the target's 2nd turn")
	dummy.asc.turn_end()
	eq(dummy.stat("def"), 20000, "gone at the end of the target's 2nd turn")


func test_self_buff_on_own_turn_covers_next_two_turns() -> void:
	var battle := new_battle(snapshot("duel", [[1, "striker"]]))
	var striker := _unit(battle, &"P1")
	striker.asc.turn_start()
	striker.asc.apply_gameplay_effect(_effect("guard"))  # cast during its own turn
	striker.asc.turn_end()
	eq(striker.stat("def"), 45000, "the casting turn doesn't count down")
	for turn in 2:
		striker.asc.turn_start()
		eq(striker.stat("def"), 45000, "active during next turn %d" % (turn + 1))
		striker.asc.turn_end()
	eq(striker.stat("def"), 30000, "gone after the next two turns")


func test_dot_that_kills_at_turn_start_stops_the_unit_acting() -> void:
	var battle := new_battle(snapshot("duel", [[1, "striker"]]))
	var dummy := _unit(battle, &"E1")
	dummy.asc.initialize_attribute_overrides({"hp": 2000.0})
	dummy.asc.apply_gameplay_effect(_effect("poison"))
	var acted := []
	battle.execution_resolved.connect(func(unit_id, _row, _targets): acted.append(unit_id))
	# Give the dummy the first turn.
	battle.turn_manager.av[dummy] = 0
	await battle.run(ScriptedController.new())
	check(not acted.has(&"E1"), "a unit killed by its DoT at turn start never acts")
	eq(battle.outcome, Battle.VICTORY, "the DoT kill ends the battle")


func test_percent_modifiers_snap_to_whole_numbers() -> void:
	var battle := new_battle(snapshot("duel", [[1, "striker"]]))
	var striker := _unit(battle, &"P1")
	for typed in [33.33, 12.5, -7.77]:
		var effect := GameplayEffect.new()
		effect.policy = GameplayEffect.DurationPolicy.INFINITE
		var modifier := CombatModifier.new()
		modifier.attribute_name = "atk"
		modifier.operation = GameplayEffectModifier.Operation.PERCENT_ADD
		modifier.value = typed
		effect.modifiers.append(modifier)
		striker.asc.apply_gameplay_effect(effect)
		var atk := striker.asc.get_attribute("atk").current_value
		check(Fixed.is_whole(atk), "ATK is whole after +%s%%: %s" % [typed, atk])
	eq(striker.stat("atk"), 50000 * (10000 + 3333 + 1250 - 777) / 10000, "500 x (1 + 0.3333 + 0.125 - 0.0777)")


func test_addon_internals_we_rely_on_still_exist() -> void:
	var battle := new_battle(snapshot("duel", [[1, "striker"]]))
	var asc := _unit(battle, &"P1").asc
	for method in ["_evaluate_spec", "_commit_spec_math", "_trigger_effect_events", "_aggregate_attribute_value",
			"_calculate_base_targets", "remove_active_effect", "initialize_attribute_overrides"]:
		check(asc.has_method(method), "GodotGAS still has %s (CombatASC depends on it)" % method)
	check("_active_effects" in asc and "_active_tags" in asc, "GodotGAS still has _active_effects and _active_tags")


## A persistent cue node freed before its effect is removed (a battle being freed) is dropped first: GodotGAS's
## remove_persistent_cue(cue: GameplayCueNotify) would refuse the freed node with a script error (2026-11-13).
func test_freed_persistent_cues_are_dropped_before_removal() -> void:
	var effect := ActiveGameplayEffect.new(GameplayEffectSpec.new(GameplayEffect.new(), GameplayEffectContext.new(null, null)))
	var live := GameplayCueNotify.new()
	var gone := GameplayCueNotify.new()
	effect.active_cues.append(live)
	effect.active_cues.append(gone)
	gone.free()
	CombatASC.drop_freed_cues(effect)
	eq(effect.active_cues.size(), 1, "the freed cue is dropped")
	check(effect.active_cues[0] == live, "the live one stays for the addon to end")
	live.free()
