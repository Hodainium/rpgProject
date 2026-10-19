## Execution table and animation events (spec "Execution table and animation events").
extends TestCase


func _anim(keys: Array) -> Animation:
	# keys: [[track, time, method, arg], ...]
	var animation := Animation.new()
	var tracks := {}
	for key in keys:
		while not tracks.has(key[0]):
			var track := animation.add_track(Animation.TYPE_METHOD)
			tracks[tracks.size()] = track
		animation.track_insert_key(tracks[key[0]], key[1], {"method": StringName(key[2]), "args": [StringName(key[3])]})
	return animation


func test_sequence_comes_from_execute_keys_in_time_order() -> void:
	var sequence := ExecutionReader.sequence_for(load(FIXTURES + "animations/combo.tres"))
	eq(Array(sequence), [&"slash_light", &"slash_light", &"slash_heavy", &"shockwave"],
		"execute keys only (play_sound ignored), a row may repeat")


func test_ties_resolve_by_track_then_key() -> void:
	var animation := _anim([[0, 0.5, "execute", "b"], [1, 0.5, "execute", "a"], [0, 0.1, "execute", "c"]])
	eq(Array(ExecutionReader.sequence_for(animation)), [&"c", &"b", &"a"], "time, then track index")


func test_sequence_is_cached_per_animation() -> void:
	var animation := _anim([[0, 0.1, "execute", "x"]])
	var first := ExecutionReader.sequence_for(animation)
	animation.track_insert_key(0, 0.2, {"method": &"execute", "args": [&"y"]})
	eq(ExecutionReader.sequence_for(animation).size(), first.size(), "second activation reuses the cached list")
	ExecutionReader.clear_cache()
	eq(ExecutionReader.sequence_for(animation).size(), 2, "re-read after clearing the cache")


func test_execution_table_valid() -> void:
	for path in ResourceLoader.list_directory(FIXTURES + "abilities"):
		if path.ends_with(".tscn"):
			var ability := (load(FIXTURES + "abilities/" + path) as PackedScene).instantiate() as BattleAbility
			eq(Array(ExecutionReader.validate(ability)), [], "fixture %s is valid" % path)
			ability.free()

	var ability := BattleAbility.new()
	ability.ability_tag = &"Fixture.Bad"
	check(ExecutionReader.validate(ability)[0].contains("no animation"), "an ability needs an animation")
	ability.animation = _anim([[0, 0.1, "play_sound", "x"]])
	check(ExecutionReader.validate(ability)[0].contains("no execute keys"), "animation needs execute keys")
	var row := ExecutionRow.new()
	row.id = &"hit"
	var rows: Array[ExecutionRow] = [row, row]
	ability.executions = rows
	ability.animation = _anim([[0, 0.1, "execute", "miss"]])
	var problems := ExecutionReader.validate(ability)
	check(problems.size() == 2, "duplicate id and missing row are both reported: %s" % [problems])
	ability.free()


## Resolves one row against E1 with crits disabled, returning the HP E1 lost (×100).
func _hit(mode: ExecutionRow.DamageMode, typed: float) -> int:
	var battle := new_battle(snapshot("duel", [[1, "striker"]]))
	var striker := battle.unit_by_id(&"P1")
	var dummy := battle.unit_by_id(&"E1")
	striker.asc.initialize_attribute_overrides({"CritRate": 0.0})
	var row := ExecutionRow.new()
	row.id = &"hit"
	row.effect = load(FIXTURES + "effects/damage.tres")
	row.damage_mode = mode
	if mode == ExecutionRow.DamageMode.FLAT:
		row.flat_damage = typed
	elif mode == ExecutionRow.DamageMode.SCALED:
		row.multiplier = typed
	var targets: Array[BattleUnit] = [dummy]
	var before := dummy.stat("HP")
	battle.resolve_execution(striker, striker.abilities()[0], row, {"primary": dummy, "targets": targets})
	return before - dummy.stat("HP")


func test_damage_modes() -> void:
	# Dummy DEF 200 → DefMultiplier = 100% − 20000×10000/120000 = 83.34%.
	eq(_hit(ExecutionRow.DamageMode.FLAT, 80.5), 6708, "FLAT 80.5 → 67.08")
	eq(_hit(ExecutionRow.DamageMode.SCALED, 150), 62505, "SCALED 150% of ATK 500 → 625.05")
	eq(_hit(ExecutionRow.DamageMode.USE_EFFECT, 0), 41670, "USE_EFFECT → the ExecCalc default 100% → 416.70")


func test_row_targets_primary_adjacent_all() -> void:
	var battle := new_battle(squad_snapshot())
	var striker := battle.unit_by_id(&"P1")
	var resolved: Array = []
	battle.execution_resolved.connect(func(_unit, row_id, target_ids): resolved.append([row_id, Array(target_ids)]))
	var combo := striker.ability_by_tag(&"Fixture.Ability.Combo")
	var action := battle._expand_targets(striker, combo, battle.unit_by_id(&"E2"))
	action["battle"] = battle
	action["unit"] = striker
	await combo.try_activate(action)
	eq(resolved, [
		[&"slash_light", [&"E2"]],
		[&"slash_light", [&"E2"]],
		[&"slash_heavy", [&"E2"]],
		[&"shockwave", [&"E1", &"E3"]],
	], "combo on E2: PRIMARY rows hit E2, the ADJACENT row hits its neighbours")


class DrivenGate:
	extends ClientGate
	## "keys": release key by key, a frame apart; "skip_after_first": release one then skip; "skip_now": skip.
	var mode: String
	var host: Node

	func begin_ability(unit_id: StringName, ability: BattleAbility, sequence: Array[StringName]) -> void:
		super(unit_id, ability, sequence)
		_play(sequence)

	func _play(sequence: Array[StringName]) -> void:
		await host.get_tree().process_frame
		match mode:
			"keys":
				for row_id in sequence:
					release_execution(row_id)
					await host.get_tree().process_frame
				release_finished()
			"skip_after_first":
				release_execution(sequence[0])
				await host.get_tree().process_frame
				skip()
			_:
				skip()


func test_gate_timing_never_changes_the_result() -> void:
	var expected: String = (await record(squad_snapshot("9")))["actionLog"]["claimedFinalHash"]
	for mode in ["keys", "skip_after_first", "skip_now"]:
		var gate := DrivenGate.new()
		gate.mode = mode
		gate.host = host
		var request: Dictionary = await record(squad_snapshot("9"), gate)
		eq(request["actionLog"]["claimedFinalHash"], expected, "client gate '%s' gives the headless result" % mode)
