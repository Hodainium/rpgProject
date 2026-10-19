## Battle snapshot v2 (spec game-skeleton 3.4/3.5): inventory capture, enemy loadouts, variants, scaling, carry-over,
## death and revive, usable items, triggered passives, field mode.
extends TestCase


## The v2 scenario also used by the golden (test_golden "run-v2-seed-7").
static func v2_snapshot(seed_text: String = "7") -> Dictionary:
	return {
		"schemaVersion": 2,
		"battleId": "run-v2-seed-%s" % seed_text,
		"seed": seed_text,
		"encounterId": "fixture.encounter.pack",
		"party": [
			{"slot": 1, "unitDefId": "fixture.character.knight", "level": 1, "energy": 1000,
				"skills": ["Fixture.Ability.Frost"], "equipmentIds": ["fixture.equipment.blade"],
				"items": ["fixture.item.whetstone", "fixture.item.banner", "fixture.item.ember_charm"],
				"useSlots": [{"itemId": "fixture.item.flask", "ready": true}, {"itemId": "fixture.item.feather", "ready": true}]},
			{"slot": 2, "unitDefId": "fixture.character.medic", "level": 1, "hp": 40000, "mp": 5000, "energy": 3000,
				"skills": ["Fixture.Ability.Mend"], "equipmentIds": [], "items": [], "useSlots": []},
			{"slot": 3, "unitDefId": "fixture.character.rogue", "level": 1, "hp": 0, "mp": 10000,
				"skills": [], "equipmentIds": [], "items": [], "useSlots": []},
		],
		"enemies": [
			{"slot": 1, "unitDefId": "fixture.enemy.grunt", "loadoutRef": "fixture.loadout.tough", "variantId": "fixture.variant.elite"},
			{"slot": 2, "unitDefId": "fixture.enemy.grunt", "loadoutRef": "fixture.encounter.pack#2", "variantId": null},
		],
		"scalingId": "fixture.scaling.a",
		"depth": 1,
	}


func test_inventory_capture_and_enemy_kit() -> void:
	var battle := new_battle(v2_snapshot())
	var knight := battle.unit_by_id(&"P1")
	var medic := battle.unit_by_id(&"P2")
	var rogue := battle.unit_by_id(&"P3")
	var tough := battle.unit_by_id(&"E1")
	var strong := battle.unit_by_id(&"E2")
	check(knight.ability_by_tag(&"Fixture.Ability.Frost") != null, "learned skill granted")
	check(knight.ability_by_tag(&"Fixture.Ability.Ember") != null, "item passive ability granted")
	check(knight.ability_by_tag(&"Fixture.Ability.Flask") != null, "ready use slot grants its ability")
	# ATK 500 + 50 (blade), then +20% (whetstone) = 660.
	eq(knight.stat("atk"), 66000, "equipment and holder passive stack through GAS")
	# Party-wide banner: +10% DEF on everyone.
	eq(medic.stat("def"), 30800, "party passive reaches other members")
	eq(knight.stat("hp"), 100000, "null HP means full")
	eq(medic.stat("hp"), 40000, "carried HP")
	eq(medic.stat("mp"), 5000, "carried MP")
	eq(medic.stat("energy"), 3000, "carried ult charge")
	check(not rogue.alive and rogue.asc.has_tag_exact(BattleUnit.DEAD_TAG), "a member at 0 HP starts dead")
	check(not battle.turn_manager.av.has(rogue), "the dead never act")
	eq(tough.stat("def"), 50000 + 0, "enemy loadout file overrides DEF (depth 1 scaling only touches ATK)")
	eq(tough.stat("max_hp"), 90000, "elite variant: +50% MaxHP")
	eq(tough.stat("hp"), 90000, "enemies start full after their bonuses")
	eq(strong.stat("atk"), 48000, "inline encounter loadout (ATK 400) plus depth-1 scaling (+20%)")


func test_record_replay_verifies_and_tamper_rejects() -> void:
	var request: Dictionary = await record(v2_snapshot())
	var result := await replay(request)
	eq(result.get("verdict"), "Verified", "a v2 battle replays")
	var tampered := copy(request)
	var actions: Array = tampered["actionLog"]["actions"]
	check(not actions.is_empty(), "the party acted")
	if not actions.is_empty():
		actions[0]["ability"] = "Fixture.Ability.Mend"
		var rejected := await replay(tampered)
		eq(rejected.get("errorCode"), 2002, "tampered v2 log → 2002")


func test_revive_and_used_items_in_battle() -> void:
	var battle := new_battle(v2_snapshot())
	var knight := battle.unit_by_id(&"P1")
	var feather := knight.ability_by_tag(&"Fixture.Ability.Feather")
	eq(battle.target_candidates(knight, feather), [battle.unit_by_id(&"P3")], "dead-ally targeting reaches only the dead")
	var strike := knight.ability_by_tag(&"Fixture.Ability.Strike")
	check(not battle.target_candidates(knight, strike).has(battle.unit_by_id(&"P3")), "normal targeting skips the dead")
	await battle._activate(knight, feather, battle.unit_by_id(&"P3"))
	var rogue := battle.unit_by_id(&"P3")
	check(rogue.alive and not rogue.asc.has_tag_exact(BattleUnit.DEAD_TAG), "the feather revives")
	eq(rogue.stat("hp"), 20000, "revived with the effect's HP")
	check(battle.turn_manager.av.has(rogue), "a revived unit is back in the turn queue")
	eq(battle.used_items, [{"unit": &"P1", "item": &"fixture.item.feather"}], "the use is recorded")
	check(knight.ability_by_tag(&"Fixture.Ability.Feather") == null, "a usable item works once per battle")


func test_death_keeps_item_effects() -> void:
	var battle := new_battle(v2_snapshot())
	var knight := battle.unit_by_id(&"P1")
	knight.asc.initialize_attribute_overrides({"hp": 0.0})
	battle._check_deaths()
	check(not knight.alive and knight.asc.has_tag_exact(BattleUnit.DEAD_TAG), "v2 death tags the unit")
	eq(knight.stat("atk"), 66000, "infinite item and equipment effects stay on the dead")


func test_triggered_passive_fires_from_data() -> void:
	var battle := new_battle(v2_snapshot())
	var burns := []
	battle.execution_resolved.connect(func(unit_id, row_id, _targets): if row_id == &"burn": burns.append(unit_id))
	var knight := battle.unit_by_id(&"P1")
	await battle._activate(knight, knight.ability_by_tag(&"Fixture.Ability.Frost"), battle.unit_by_id(&"E2"))
	eq(burns, [], "triggers wait in the queue until the battle drains it")
	await battle._drain_triggers()
	eq(burns, [&"P1"], "Ice damage triggers the Ember charm once")
	check(not knight.action_abilities().has(knight.ability_by_tag(&"Fixture.Ability.Ember")), "a triggered passive is never an action")
	eq(battle.validate_action(knight, {"ability": &"Fixture.Ability.Ember", "target": &"E1"})[0], "IllegalAbility",
		"choosing a triggered passive is illegal")


## Birthright-like (spec decision, 2026-10-19): one item, a different effect per holder, through character tags.
func test_item_effect_depends_on_holder() -> void:
	var snap := v2_snapshot()
	snap["party"][0]["items"] = ["fixture.item.crest"]
	snap["party"][1]["items"] = ["fixture.item.crest"]
	var battle := new_battle(snap)
	var knight := battle.unit_by_id(&"P1")
	var medic := battle.unit_by_id(&"P2")
	check(knight.asc.can_activate_ability(knight.ability_by_tag(&"Fixture.Ability.CrestKnight")), "the knight's crest effect works for the knight")
	check(not knight.asc.can_activate_ability(knight.ability_by_tag(&"Fixture.Ability.CrestMedic")), "the medic's does not")
	check(medic.asc.can_activate_ability(medic.ability_by_tag(&"Fixture.Ability.CrestMedic")), "the medic's crest effect works for the medic")
	check(not medic.asc.can_activate_ability(medic.ability_by_tag(&"Fixture.Ability.CrestKnight")), "the knight's does not")
	var request: Dictionary = await record(snap)
	eq((await replay(request)).get("verdict"), "Verified", "the crest's battle-start triggers replay")


## Ult charge (2026-10-19): Event.Ability.Used feeds a triggered energy listener; an ult's cost is energy, so GAS
## blocks it until the bar is full and empties it on use. Map actions don't charge.
func test_ult_charge_and_cost() -> void:
	var battle := new_battle(v2_snapshot())
	var knight := battle.unit_by_id(&"P1")  # carries energy 1000 (10%)
	var listener := _runtime_ability(&"Test.Ability.UltCharge", BattleAbility.Targeting.SELF, _energy_effect(2500))
	listener.trigger_event_tag = Battle.EVENT_ABILITY_USED
	knight.asc.add_child(listener)
	var ult := _runtime_ability(&"Test.Ability.Ult", BattleAbility.Targeting.SINGLE_ENEMY, load(FIXTURES + "effects/damage.tres"))
	ult.cost_effect = _energy_effect(-10000)
	knight.asc.add_child(ult)
	check(not knight.asc.can_activate_ability(ult), "the ult needs a full bar")
	await battle._activate(knight, knight.ability_by_tag(&"Fixture.Ability.Strike"), battle.unit_by_id(&"E2"))
	await battle._drain_triggers()
	eq(knight.stat(BattleUnit.ENERGY), 3500, "using an ability charges the bar")
	knight.asc.initialize_attribute_overrides({BattleUnit.ENERGY: 10000.0})
	check(knight.asc.can_activate_ability(ult), "a full bar unlocks the ult")
	await battle._activate(knight, ult, battle.unit_by_id(&"E2"))
	await battle._drain_triggers()
	eq(knight.stat(BattleUnit.ENERGY), 2500, "the ult spends the bar, then charges like any ability")

	var field := Battle.new()
	host.add_child(field)
	_battles.append(field)
	field.setup_field(v2_snapshot(), fixtures())
	var medic := field.unit_by_id(&"P2")
	var map_listener := _runtime_ability(&"Test.Ability.UltCharge", BattleAbility.Targeting.SELF, _energy_effect(2500))
	map_listener.trigger_event_tag = Battle.EVENT_ABILITY_USED
	medic.asc.add_child(map_listener)
	await field.perform(&"P2", &"Fixture.Ability.Mend", &"P2")
	await field._drain_triggers()
	eq(medic.stat(BattleUnit.ENERGY), 3000, "map actions don't charge the ult")


func _energy_effect(amount_x100: int) -> GameplayEffect:
	var effect := GameplayEffect.new()
	effect.policy = GameplayEffect.DurationPolicy.INSTANT
	var modifier := CombatModifier.new()
	modifier.attribute_name = BattleUnit.ENERGY
	modifier.operation = GameplayEffectModifier.Operation.ADD
	modifier.value_x100 = amount_x100
	effect.modifiers.append(modifier)
	return effect


## An in-memory ability with one USE_EFFECT row (or SCALED for the damage effect) and its execute key.
func _runtime_ability(tag: StringName, targeting: BattleAbility.Targeting, effect: GameplayEffect,
		row_id: StringName = &"go") -> BattleAbility:
	var ability := BattleAbility.new()
	ability.ability_tag = tag
	ability.targeting = targeting
	var row := ExecutionRow.new()
	row.id = row_id
	row.effect = effect
	row.damage_mode = ExecutionRow.DamageMode.SCALED if effect.executions.size() > 0 else ExecutionRow.DamageMode.USE_EFFECT
	ability.executions = [row]
	var animation := Animation.new()
	var track := animation.add_track(Animation.TYPE_METHOD)
	animation.track_insert_key(track, 0.1, {"method": &"execute", "args": [row_id]})
	ability.animation = animation
	return ability


## Spec 3.4: triggers run in queue order: grant order on one unit, then event order across units (Dealt before Taken).
func test_trigger_order() -> void:
	var battle := new_battle(v2_snapshot())
	var knight := battle.unit_by_id(&"P1")
	var target := battle.unit_by_id(&"E2")
	var noop: GameplayEffect = load(FIXTURES + "effects/noop.tres")
	for spec in [[knight, &"Test.Ability.First", &"first", Battle.EVENT_DAMAGE_DEALT],
			[knight, &"Test.Ability.Second", &"second", Battle.EVENT_DAMAGE_DEALT],
			[target, &"Test.Ability.Hurt", &"hurt", Battle.EVENT_DAMAGE_TAKEN]]:
		var ability := _runtime_ability(spec[1], BattleAbility.Targeting.SELF, noop, spec[2])
		ability.trigger_event_tag = spec[3]
		spec[0].asc.add_child(ability)
	var order := []
	battle.execution_resolved.connect(func(_unit, row_id, _targets): order.append(row_id))
	await battle._activate(knight, knight.ability_by_tag(&"Fixture.Ability.Strike"), target)
	order.clear()
	await battle._drain_triggers()
	eq(order, [&"first", &"second", &"hurt"], "grant order on the dealer, then the target's Taken trigger")


## Spec section 4: an unknown variant, equipment or scaling id is a runner error, not a 2002.
func test_unknown_variant_equipment_scaling() -> void:
	for change in [["enemies", 0, "variantId", "fixture.variant.nope", "variant"],
			["party", 0, "equipmentIds", ["fixture.equipment.nope"], "equipment"]]:
		var bad := v2_snapshot()
		bad[change[0]][change[1]][change[2]] = change[3]
		var broken := Battle.new()
		host.add_child(broken)
		_battles.append(broken)
		check(broken.setup(bad, fixtures()).contains(change[4]), "unknown %s is a runner error" % change[4])
	var bad_scaling := v2_snapshot()
	bad_scaling["scalingId"] = "fixture.scaling.nope"
	var broken_scaling := Battle.new()
	host.add_child(broken_scaling)
	_battles.append(broken_scaling)
	check(broken_scaling.setup(bad_scaling, fixtures()).contains("scaling"), "unknown scaling is a runner error")


## Spec 3.4 / section 4: an ability that ignores State.Infield is battle-only; the map refuses it.
func test_battle_only_ability_refused_in_field() -> void:
	var field := Battle.new()
	host.add_child(field)
	_battles.append(field)
	field.setup_field(v2_snapshot(), fixtures())
	var medic := field.unit_by_id(&"P2")
	var rally := _runtime_ability(&"Test.Ability.Rally", BattleAbility.Targeting.SELF, load(FIXTURES + "effects/noop.tres"))
	rally.activation_query = GameplayTagQuery.new()
	rally.activation_query.ignore_tags.assign([Battle.IN_FIELD_TAG])
	medic.asc.add_child(rally)
	var hp_before := medic.stat(BattleUnit.HP)
	check(not (await field.perform(&"P2", &"Test.Ability.Rally")).is_empty(), "a battle-only ability is refused on the map")
	eq(medic.stat(BattleUnit.HP), hp_before, "nothing changed")


func test_trigger_chain_cap() -> void:
	var battle := new_battle(v2_snapshot())
	var knight := battle.unit_by_id(&"P1")
	var echo := BattleAbility.new()
	echo.ability_tag = &"Test.Ability.Echo"
	echo.targeting = BattleAbility.Targeting.SINGLE_ENEMY
	echo.trigger_event_tag = &"Event.Damage.Dealt"
	var row := ExecutionRow.new()
	row.id = &"hit"
	row.effect = load(FIXTURES + "effects/damage.tres")
	row.damage_mode = ExecutionRow.DamageMode.FLAT
	row.flat_damage_x100 = 100
	echo.executions = [row]
	var animation := Animation.new()
	var track := animation.add_track(Animation.TYPE_METHOD)
	animation.track_insert_key(track, 0.1, {"method": &"execute", "args": [&"hit"]})
	echo.animation = animation
	knight.asc.add_child(echo)
	await battle._activate(knight, knight.ability_by_tag(&"Fixture.Ability.Strike"), battle.unit_by_id(&"E2"))
	await battle._drain_triggers()
	check(Array(battle.content_warnings).any(func(w): return w.contains("trigger chain")), "an endless chain stops with a warning")
	check(battle.triggers.is_empty(), "the queue is cleared")


func test_duplicate_grant_and_unknown_ids() -> void:
	var snap := v2_snapshot()
	snap["party"][0]["skills"] = ["Fixture.Ability.Frost", "Fixture.Ability.Strike"]
	var battle := new_battle(snap)
	check(Array(battle.content_warnings).any(func(w): return w.contains("already has Fixture.Ability.Strike")),
		"a duplicate grant is skipped with a warning")
	for change in [["party", 0, "items", ["fixture.item.nope"]], ["party", 0, "skills", ["Fixture.Ability.Sweep"]]]:
		var bad := v2_snapshot()
		bad[change[0]][change[1]][change[2]] = change[3]
		var broken := Battle.new()
		host.add_child(broken)
		_battles.append(broken)
		check(broken.setup(bad, fixtures()) != "", "%s %s is a runner error" % [change[2], change[3]])
	var bad_ref := v2_snapshot()
	bad_ref["enemies"][0]["loadoutRef"] = "fixture.loadout.nope"
	var broken_ref := Battle.new()
	host.add_child(broken_ref)
	_battles.append(broken_ref)
	check(broken_ref.setup(bad_ref, fixtures()).contains("loadoutRef"), "an unknown loadout ref is a runner error")


func test_field_mode() -> void:
	var snap := v2_snapshot()
	var battle := Battle.new()
	host.add_child(battle)
	_battles.append(battle)
	eq(battle.setup_field(snap, fixtures()), "", "field setup")
	var knight := battle.unit_by_id(&"P1")
	check(knight.asc.has_tag_exact(Battle.IN_FIELD_TAG), "field units carry State.Infield")
	eq(await battle.perform(&"P1", &"Fixture.Ability.Strike", &"P2"), ["InvalidTarget",
		"Fixture.Ability.Strike targets enemies; there are none outside battle"], "no enemy targeting in the field")
	eq(await battle.perform(&"P3", &"Fixture.Ability.Strike"), ["DeadActor", "P3 can't act"], "the dead can't act")
	var medic_before := battle.unit_by_id(&"P2").stat("hp")
	var problem: Array = await battle.perform(&"P2", &"Fixture.Ability.Mend", &"P2")
	eq(problem, [], "map-only spell works in the field")
	eq(battle.unit_by_id(&"P2").stat("hp"), medic_before + 30000, "healed")
	eq(battle.unit_by_id(&"P2").stat("mp"), 3000, "MP cost paid through GAS")
	var in_battle := new_battle(v2_snapshot())
	var medic := in_battle.unit_by_id(&"P2")
	check(not medic.asc.can_activate_ability(medic.ability_by_tag(&"Fixture.Ability.Mend")), "a map-only spell can't be used in battle")
