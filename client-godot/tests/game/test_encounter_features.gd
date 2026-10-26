## Spec playable-demo 3.7 (amendment C2): encounter and slot grants, a slot's brain override, victory rewards, armor
## to the inventory and rarity weights. Fixtures only; changed content lives in memory (ContentIndex.overlay).
extends TestCase

const PARTY: Array = ["fixture.character.knight", "fixture.character.medic", "fixture.character.rogue"]
const GRANTED_TAG: StringName = &"Weakness.Ice"
const SLOT_TAG: StringName = &"Weakness.Fire"
const CAP: StringName = &"fixture.equipment.cap"

var _runs: Array[RunController] = []


func after_each() -> void:
	for run in _runs:
		if is_instance_valid(run):
			run.free()
	_runs.clear()
	super()


## A fixture run (seed 7) standing before its first battle, on `content`.
func _run_to_battle(content: ContentIndex) -> RunController:
	var run := RunController.new()
	host.add_child(run)
	_runs.append(run)
	eq(run.start_run(content, PARTY, "7"), "", "the fixture run starts")
	for step in 50:
		if not run.pending_battle.is_empty():
			break
		if not run.state.event.is_empty():
			for choice in run.current_page().choices.size():
				if run.choice_enabled(choice):
					run.choose(choice)
					break
			continue
		var next := RunPlayer.next_room(run)
		if next == -1:
			break
		run.enter_room(next)
	check(not run.pending_battle.is_empty(), "the fixture run reaches a battle")
	return run


## The fixtures with the first battle's encounter replaced by a copy changed by `change` (encounter -> void).
func _with_encounter(change: Callable) -> Array:
	var probe := _run_to_battle(fixtures())
	var id: StringName = probe.pending_battle["encounter"]
	var changed: EncounterDefinition = fixtures().encounters[id].duplicate(true)
	change.call(changed)
	return [fixtures().overlay([changed]), id]


static func _tag_set(tags: Array) -> AbilitySet:
	var ability_set := AbilitySet.new()
	ability_set.tags.assign(tags)
	return ability_set


func test_encounter_grants_replay() -> void:
	var setup := _with_encounter(func(encounter: EncounterDefinition) -> void:
		encounter.grants = _tag_set([GRANTED_TAG])
		encounter.slots[0].grants = _tag_set([SLOT_TAG])
		var brain := PatternBrain.new()
		brain.pattern.assign([SkillTags.tag_of(encounter.slots[0].enemy.abilities[0])])
		encounter.slots[0].brain = brain)
	var content: ContentIndex = setup[0]
	var run := _run_to_battle(content)
	var snapshot := run.battle_snapshot()
	var battle := Battle.new()
	host.add_child(battle)
	eq(battle.setup(snapshot, content), "", "the battle builds")
	for unit in battle.units():
		if not unit.is_party():
			check(unit.asc.has_tag_exact(GRANTED_TAG), "%s has the encounter's tag" % unit.unit_id)
			eq(unit.asc.has_tag_exact(SLOT_TAG), unit.unit_id == &"E1", "%s: the slot's tag only on E1" % unit.unit_id)
	check(battle.unit_by_id(&"E1").brain_override is PatternBrain, "E1 uses its slot's brain")
	var controller := ScriptedController.new()
	await battle.run(controller)
	var request := {"snapshot": snapshot, "actionLog": ActionRecorder.build_log(controller.entries, battle.outcome,
		battle.final_hash)}
	battle.queue_free()
	var verified: Dictionary = await ReplayRunner.new().run_on(JSON.parse_string(WireJson.stringify(request)), content, host)
	eq(verified.get("verdict"), "Verified", "grants and the slot brain are rebuilt from content on replay")
	var plain: Dictionary = await ReplayRunner.new().run_on(JSON.parse_string(WireJson.stringify(request)), fixtures(), host)
	check(plain.get("verdict") != "Verified" or plain.get("finalStateHash") != verified.get("finalStateHash"),
		"without the grants the state differs (they are part of the battle)")


## A test controller: one dev decision (kill a side) first, then the scripted policy.
class DevFirst extends ScriptedController:
	var _decision: Dictionary

	func _init(targets: String) -> void:
		_decision = {"dev": &"Dev.Kill", "effect": RunController.dev_effect("dev_kill"), "targets": targets}

	func choose(battle: Battle, unit: BattleUnit) -> Dictionary:
		if not _decision.is_empty():
			var decision := _decision
			_decision = {}
			return decision
		return super(battle, unit)


func test_encounter_rewards() -> void:
	var setup := _with_encounter(func(encounter: EncounterDefinition) -> void:
		var coins := GainCoins.new()
		coins.amount = 7
		var cap := GiveEquipment.new()
		cap.equipment = fixtures().equipment[CAP]
		encounter.rewards.assign([coins, cap]))
	var run := _run_to_battle(setup[0])
	var coins_before := run.state.coins
	await run.fight(DevFirst.new("enemies"))
	eq(run.state.status, RunState.ACTIVE, "the battle is won")
	check(run.state.coins >= coins_before + 7, "the reward coins arrive (plus any drop)")
	eq(run.state.armor.count(CAP), 1, "the reward piece goes to the armor inventory")
	var lost := _run_to_battle(setup[0])
	await lost.fight(DevFirst.new("party"))
	eq(lost.state.status, RunState.LOST, "the battle is lost")
	check(not lost.state.armor.has(CAP), "no reward on a loss")


func test_rarity_weights() -> void:
	var common: Array = []
	var rare: Array = []
	var items: Array = []
	var ids: Array = fixtures().items.keys()
	ids.sort()
	for index in ids.size():
		var item: ItemDefinition = fixtures().items[ids[index]].duplicate()
		if not item.tags.has(&"Fixture.Pool.Treasure"):
			continue
		var tags: Array[StringName] = item.tags.duplicate()
		tags.append(&"Item.Rarity.Rare" if index % 2 == 0 else &"Item.Rarity.Common")
		item.tags = tags
		(rare if index % 2 == 0 else common).append(item.id)
		items.append(item)
	check(not rare.is_empty() and not common.is_empty(), "treasure items of both rarities")
	var structure: RunStructure = fixtures().runs.values()[0]
	var plain_content := fixtures().overlay(items)
	var weighted_run: RunStructure = structure.duplicate()
	weighted_run.rarity_weights_x100 = {&"Item.Rarity.Common": 10000, &"Item.Rarity.Rare": 0}
	var weighted_content := fixtures().overlay(items + [weighted_run])
	var query := GameplayTagQuery.new()
	query.require_all_tags.assign([&"Fixture.Pool.Treasure"])
	var pools := {"party": [], "held": [], "seen": []}
	for seed_value in range(1, 41):
		var before := FloorGenerator.new(fixtures(), structure, seed_value, 0).pick_item(null, query,
			RunSeeds.rng(seed_value, "test/rarity"), pools)
		var tagged := FloorGenerator.new(plain_content, structure, seed_value, 0).pick_item(null, query,
			RunSeeds.rng(seed_value, "test/rarity"), pools)
		eq(tagged.id, before.id, "seed %d: rarity tags without weights pick as before" % seed_value)
		var weighted := FloorGenerator.new(weighted_content, weighted_run, seed_value, 0).pick_item(null, query,
			RunSeeds.rng(seed_value, "test/rarity"), pools)
		check(common.has(weighted.id), "seed %d: Rare weighs 0, so only Commons are picked (got %s)" % [seed_value, weighted.id])
	eq(weighted_run.weighted(items[0]), items[0].weight_x100 * (0 if rare.has(items[0].id) else 100), "weighted()")
