## Spec food-items (section 6): food is passive, eaten on pickup (ApplyHolderEffect heals the holder), keeps a stacking
## bonus, every drop waits for the player's choice, the bots feed the lowest HP share, the mirror skips food but counts it,
## and a run with food drops verifies step by step. The system part runs on the fixtures with a food item built in memory
## (its bonus is the saved fixture effect elite.tres, +50% max HP); the demo part reads res://content/ and is skipped
## without it.
extends TestCase

const StepRunnerTest := preload("res://tests/game/test_step_runner.gd")
const MirrorTest := preload("res://tests/combat/test_mirror.gd")
const DemoItems := preload("res://tests/game/test_demo_items.gd")
const PARTY: Array = ["fixture.character.knight", "fixture.character.medic", "fixture.character.rogue"]
const DEMO: String = "res://content/demo/"
const DEMO_PARTY: Array = ["demo.character.warrior", "demo.character.cleric", "demo.character.bard"]
const FOOD_TAG: StringName = &"Item.Food"
const DEMO_FOODS: Array[String] = ["rations", "roast_haunch", "honey_cake", "hearty_feast"]

var _runs: Array[RunController] = []
var _helpers: Array[TestCase] = []


func after_each() -> void:
	for helper in _helpers:
		helper.after_each()
	_helpers.clear()
	for run in _runs:
		if is_instance_valid(run):
			run.free()
	_runs.clear()
	super()


# --- Fixture food -------------------------------------------------------------------------------------------------------

## A passive fixture food: on pickup the holder heals far past any maximum (so HP lands on the maximum it reads), and it
## grants +50% max HP (the saved fixture effect elite.tres) with the set tag Item.Food.
static func food(name: String = "snack") -> ItemDefinition:
	var item := ItemDefinition.new()
	item.id = StringName("fixture.item." + name)
	item.display_name = name.capitalize()
	item.description = "test food"
	item.tags.assign([&"Pool.Food"])
	item.kind = ItemDefinition.Kind.PASSIVE
	var grants := AbilitySet.new()
	grants.effects.assign([load(FIXTURES + "effects/elite.tres")])
	grants.tags.assign([FOOD_TAG])
	item.grants = grants
	var eat := ApplyHolderEffect.new()
	eat.effect = big_heal()
	item.on_pickup.assign([eat])
	return item


static func big_heal() -> GameplayEffect:
	var heal := GameplayEffect.new()
	var modifier := CombatModifier.new()
	modifier.attribute_name = "hp"
	modifier.operation = GameplayEffectModifier.Operation.ADD
	modifier.value_x100 = 100000000
	heal.modifiers.append(modifier)
	return heal


func _run(content: ContentIndex, party: Array = PARTY, seed_text: String = "7") -> RunController:
	var run := RunController.new()
	host.add_child(run)
	_runs.append(run)
	var error := run.start_run(content, party, seed_text)
	check(error == "", "the run starts: " + error)
	return run


func _max_hp(run: RunController, slot: int) -> int:
	return int(run.party_stats().get(slot, {}).get(BattleUnit.MAX_HP, 0))


## Every member down to 1 HP, so a heal shows.
static func _hurt_all(run: RunController) -> void:
	for member in run.state.party:
		member["hp"] = 100


## An enemy (a copy of a fixture one, under a new id) that always drops `item`.
static func _dropper(id: String, item: ItemDefinition) -> EnemyDefinition:
	var enemy: EnemyDefinition = fixtures().units[&"fixture.enemy.grunt"].duplicate()
	enemy.id = StringName(id)
	enemy.drop_item = item
	enemy.drop_chance_x100 = 10000
	return enemy


# --- ApplyHolderEffect --------------------------------------------------------------------------------------------------

func test_food_heals_only_its_holder_and_reads_the_raised_maximum() -> void:
	var snack := food()
	var run := _run(fixtures().overlay([snack]))
	var before := {}
	for member in run.state.party:
		before[member["slot"]] = _max_hp(run, member["slot"])
	_hurt_all(run)
	eq(run.can_hold(2, snack), "", "food is always holdable (passive, no use slot)")
	run.give_item(snack, null, fixtures().characters[&"fixture.character.medic"])
	var slot := run.state.member_slot(&"fixture.character.medic")
	eq(run.state.holder_of(snack.id), slot, "the medic holds it")
	check(run.state.member(slot)["use_slots"].is_empty(), "food takes no use slot")
	eq(_max_hp(run, slot), before[slot] * 3 / 2, "the bonus raises the holder's max HP by half")
	eq(int(run.state.member(slot)["hp"]), before[slot] * 3 / 2, "the heal reads the raised maximum")
	for member in run.state.party:
		if member["slot"] != slot:
			eq(int(member["hp"]), 100, "slot %d is not healed" % member["slot"])
			eq(_max_hp(run, member["slot"]), before[member["slot"]], "slot %d gets no bonus" % member["slot"])
	eq(run.hook_slot, 0, "the holder is cleared after the hook")


func test_food_copies_stack() -> void:
	var snack := food()
	var run := _run(fixtures().overlay([snack]))
	var knight: CharacterDefinition = fixtures().characters[&"fixture.character.knight"]
	var slot := run.state.member_slot(knight.id)
	var base := _max_hp(run, slot)
	run.give_item(snack, null, knight)
	run.give_item(snack, null, knight)
	eq(_max_hp(run, slot), base * 2, "two copies give the bonus twice (+50% and +50%)")


func test_holder_effect_outside_an_item_hook_does_nothing() -> void:
	var run := _run(fixtures())
	_hurt_all(run)
	var eat := ApplyHolderEffect.new()
	eat.effect = big_heal()
	eat.apply(run)
	for member in run.state.party:
		eq(int(member["hp"]), 100, "slot %d is not healed" % member["slot"])
	check(Array(run.warnings).any(func(text: String) -> bool: return text.contains("ApplyHolderEffect")), "it warns")


# --- Drops (Q2) ---------------------------------------------------------------------------------------------------------

func test_drops_wait_for_the_players_choice_in_roll_order() -> void:
	var snack := food()
	var whetstone: ItemDefinition = fixtures().items[&"fixture.item.whetstone"]
	var run := _run(fixtures().overlay([snack, _dropper("fixture.enemy.snack_grunt", snack),
		_dropper("fixture.enemy.whet_grunt", whetstone)]))
	run._roll_drops([{"unitDefId": "fixture.enemy.snack_grunt"}, {"unitDefId": "fixture.enemy.whet_grunt"}],
		run.state.current_cell)
	eq(run.state.pending_gifts, [snack.id, whetstone.id] as Array[StringName], "both drops wait, in roll order")
	check(run.next_floor().begins_with("choose who gets"), "other actions are refused meanwhile")
	eq(run.give_to(3), "", "the first goes to slot 3")
	eq(run.state.holder_of(snack.id), 3, "who the player picked")
	eq(run.state.pending_gifts, [whetstone.id] as Array[StringName], "the second still waits")
	eq(run.give_to(1), "", "then slot 1")
	eq(run.state.holder_of(whetstone.id), 1, "the second goes to its pick")
	eq(run.run_log.filter(func(entry) -> bool: return entry["type"] == "give_to").size(), 2, "two logged give_to")


func test_the_battle_that_wins_the_run_drops_nothing() -> void:
	var snack := food()
	var run := _run(fixtures().overlay([snack, _dropper("fixture.enemy.snack_grunt", snack)]))
	var boss := -1
	for index in run.state.map.sorted_indices():
		if run.state.map.cells[index]["role"] == FloorMap.ROLE_BOSS:
			boss = index
	check(boss >= 0, "the floor has a boss room")
	var last := run.structure.floors.size() - 1
	if run.state.floor_index < last:
		run._roll_drops([{"unitDefId": "fixture.enemy.snack_grunt"}], boss)
		eq(run.state.pending_gifts.size(), 1, "a boss before the last floor still drops")
		eq(run.give_to(run.state.party[0]["slot"]), "", "give_to")
	run.state.floor_index = last
	run._roll_drops([{"unitDefId": "fixture.enemy.snack_grunt"}], boss)
	check(run.state.pending_gifts.is_empty(), "the last floor's boss drops nothing")
	run._roll_drops([{"unitDefId": "fixture.enemy.snack_grunt"}], run.state.current_cell)
	eq(run.state.pending_gifts.size(), 1, "another room of the last floor still drops")


## User, 2026-11-13: an encounter reward may be CHOOSE; it waits like a drop, except in the battle that wins the run,
## where it goes to the first member who can hold it.
func test_choose_encounter_rewards_wait_except_in_the_winning_battle() -> void:
	var whetstone: ItemDefinition = fixtures().items[&"fixture.item.whetstone"]
	var gift := GiveItem.new()
	gift.item = whetstone
	gift.recipient = GiveItem.Recipient.CHOOSE
	var encounter: EncounterDefinition = fixtures().encounters[&"fixture.encounter.pack"].duplicate()
	encounter.rewards = [gift] as Array[RunOutcome]
	var run := _run(fixtures().overlay([encounter]))
	run._grant_rewards(encounter, run.state.current_cell)
	eq(run.state.pending_gifts, [whetstone.id] as Array[StringName], "the reward waits for give_to")
	eq(run.give_to(2), "", "give_to")
	eq(run.state.holder_of(whetstone.id), 2, "who the player picked")
	var boss := -1
	for index in run.state.map.sorted_indices():
		if run.state.map.cells[index]["role"] == FloorMap.ROLE_BOSS:
			boss = index
	run.state.floor_index = run.structure.floors.size() - 1
	run._grant_rewards(encounter, boss)
	check(run.state.pending_gifts.is_empty(), "in the winning battle nothing waits")
	eq(run.state.member(1)["items"].count(whetstone.id), 1, "the first member got it")
	eq(run._choose_off, false, "the flag is cleared after the rewards")


func test_a_drop_with_one_possible_holder_is_given_at_once() -> void:
	var snack := food()
	var run := _run(fixtures().overlay([snack, _dropper("fixture.enemy.snack_grunt", snack)]),
		["fixture.character.knight"])
	run._roll_drops([{"unitDefId": "fixture.enemy.snack_grunt"}], run.state.current_cell)
	check(run.state.pending_gifts.is_empty(), "nothing waits")
	eq(run.state.holder_of(snack.id), run.state.party[0]["slot"], "the only member got it")


# --- The bots (D4) ------------------------------------------------------------------------------------------------------

func test_bots_feed_the_lowest_hp_share() -> void:
	var snack := food()
	var run := _run(fixtures().overlay([snack]))
	var shares := {1: 50, 2: 30, 3: 30}
	for member in run.state.party:
		member["hp"] = _max_hp(run, member["slot"]) * shares[member["slot"]] / 100
	eq(RunPlayer.gift_holder(run, snack), 2, "food to the lowest HP share, ties to the lowest slot")
	run.state.member(2)["alive"] = false
	run.state.member(2)["hp"] = 0
	eq(RunPlayer.gift_holder(run, snack), 3, "a dead member is never fed")
	var whetstone: ItemDefinition = fixtures().items[&"fixture.item.whetstone"]
	eq(RunPlayer.gift_holder(run, whetstone), 1, "anything else to the first member who can hold it")


# --- The mirror (D5) ----------------------------------------------------------------------------------------------------

func test_mirror_skips_food_and_still_counts_it() -> void:
	var snack := food()
	var content := fixtures().overlay([snack])
	var snap: Dictionary = MirrorTest.mirror_snapshot()
	for member in snap["party"]:
		member["items"] = []
		member["equipmentIds"] = []
		member["useSlots"] = []
	snap["party"][0]["items"] = [String(snack.id)]
	var battle := Battle.new()
	host.add_child(battle)
	_battles.append(battle)
	var skip: Array[StringName] = [FOOD_TAG]
	var skipped: Dictionary = battle._mirror_of_party(snap, content, skip)
	eq(skipped["count"], 1, "the food still counts as a piece held (per_item_effect)")
	check(skipped["holder"].is_empty() and skipped["party"].is_empty(), "its bonus is not copied")
	var copied: Dictionary = battle._mirror_of_party(snap, content, [] as Array[StringName])
	eq(copied["holder"].size(), 1, "without the skip tag it would be copied")


# --- Validator ----------------------------------------------------------------------------------------------------------

func _codes(content: ContentIndex) -> Array:
	return ContentValidator.validate(content, {"tags": false}).map(func(issue: ValidationIssue) -> String: return issue.code)


func test_validator_food_rules() -> void:
	var eat := ApplyHolderEffect.new()
	eat.effect = big_heal()
	var reward: EncounterDefinition = fixtures().encounters[&"fixture.encounter.pack"].duplicate()
	var rewards: Array[RunOutcome] = [eat]
	reward.rewards = rewards
	var codes := _codes(fixtures().overlay([reward]))
	check(codes.has("holder_effect_outside_item"), "ApplyHolderEffect in an encounter reward is an error")
	var tonic: ItemDefinition = fixtures().items[&"fixture.item.field_tonic"].duplicate()
	tonic.id = &"fixture.item.usable_food"
	tonic.tags = [&"Pool.Food"] as Array[StringName]
	tonic.on_pickup = [] as Array[RunOutcome]
	codes = _codes(fixtures().overlay([tonic]))
	check(tonic.is_usable(), "the copy is USABLE")
	check(codes.has("food_usable"), "a usable food is an error")
	check(codes.has("food_no_pickup"), "a food with no on_pickup is an error")
	var fine := _codes(fixtures().overlay([food()]))
	for code in ["holder_effect_outside_item", "food_usable", "food_no_pickup"]:
		check(not fine.has(code), "a proper food raises no %s" % code)


# --- A run with food drops verifies -------------------------------------------------------------------------------------

## Every fixture enemy drops the fixture food; a server-mode run played by the bots, cut into steps as the server cuts
## them, verifies step by step (the give_to entries and the eaten food replay like any run action).
func test_a_run_with_food_drops_verifies_step_by_step() -> void:
	var snack := food()
	var droppers: Array = [snack]
	for id in fixtures().units:
		var unit = fixtures().units[id]
		if unit is EnemyDefinition:
			var copy: EnemyDefinition = unit.duplicate()
			copy.drop_item = snack
			copy.drop_chance_x100 = 10000
			droppers.append(copy)
	var content := fixtures().overlay(droppers)
	var helper: TestCase = StepRunnerTest.new()
	helper.host = host
	_helpers.append(helper)
	var played: Dictionary = await helper._play(content, StepRunnerTest.TWO_FLOORS)
	var run: RunController = played["run"]
	var gifts: int = run.run_log.filter(func(entry) -> bool: return entry["type"] == "give_to").size()
	check(gifts > 0, "the bots gave dropped food (%d give_to)" % gifts)
	# The battle that wins the run drops nothing, so no gift is left waiting at the end.
	check(run.state.pending_gifts.is_empty(), "no gift waits (stopped: %s, status %s, pending %s)" % [played["stopped"],
		run.state.status, run.state.pending_gifts])
	var steps: Array[Dictionary] = helper._steps(content, StepRunnerTest.TWO_FLOORS, played)
	check(steps.size() > 1, "the run has steps")
	for step in steps:
		var verdict: Dictionary = await helper._verify(content, step)
		eq(verdict.get("status"), "Verified", "step %s..%s (%s): %s" % [step["fromSeq"], step["toSeq"], step["kind"],
			verdict.get("mismatch", verdict)])
	failures.append_array(helper.failures)


# --- Demo content -------------------------------------------------------------------------------------------------------

func _demo_ready() -> bool:
	if not ResourceLoader.exists(DEMO + "loadouts/food_rations.tres"):
		print("    skipped: no food-items content under ", DEMO)
		return false
	return true


func test_demo_foods_are_passive_with_a_pickup_and_a_bonus() -> void:
	if not _demo_ready():
		return
	var content := DemoItems._demo_content()
	for name in DEMO_FOODS:
		var item: ItemDefinition = content.items[StringName("demo.item." + name)]
		check(item.kind == ItemDefinition.Kind.PASSIVE and item.use_ability == null, "%s is passive" % name)
		check(not item.on_pickup.is_empty(), "%s has an on_pickup" % name)
		check(item.grants != null and not item.grants.effects.is_empty(), "%s grants a bonus" % name)
		check(item.grants != null and item.grants.tags.has(FOOD_TAG), "%s's set carries Item.Food" % name)


func test_demo_foods_heal_their_holder_and_add_their_bonus() -> void:
	if not _demo_ready():
		return
	var content := DemoItems._demo_content()
	for name in DEMO_FOODS:
		var item: ItemDefinition = content.items[StringName("demo.item." + name)]
		var run := _run(content, DEMO_PARTY, "3")
		var cleric: CharacterDefinition = content.characters[&"demo.character.cleric"]
		var slot := run.state.member_slot(cleric.id)
		var stats_before := run.party_stats()
		_hurt_all(run)
		for member in run.state.party:
			if member["mp"] != null:
				member["mp"] = 0
		run.give_item(item, null, cleric)
		var stats_after := run.party_stats()
		var party_wide := item.applies_to == ItemDefinition.AppliesTo.PARTY
		for member in run.state.party:
			var own: int = member["slot"]
			var mine := own == slot
			var max_before := int(stats_before[own][BattleUnit.MAX_HP])
			var max_after := int(stats_after[own][BattleUnit.MAX_HP])
			if name == "honey_cake":
				check(not mine or int(member["mp"]) > 0, "%s: the holder regains SP" % name)
				check(mine or int(member["mp"]) == 0, "%s: slot %d regains none" % [name, own])
				var mp_before := int(stats_before[own]["max_mp"])
				var mp_after := int(stats_after[own]["max_mp"])
				check(mp_after > mp_before if mine else mp_after == mp_before, "%s: max SP of slot %d" % [name, own])
				continue
			var healed := int(member["hp"]) > 100
			check(healed == (mine or party_wide), "%s: slot %d healed: %s" % [name, own, healed])
			check(max_after > max_before if (mine or party_wide) else max_after == max_before,
				"%s: max HP of slot %d %d -> %d" % [name, own, max_before, max_after])


func test_demo_rations_stack() -> void:
	if not _demo_ready():
		return
	var content := DemoItems._demo_content()
	var rations: ItemDefinition = content.items[&"demo.item.rations"]
	var run := _run(content, DEMO_PARTY, "3")
	var warrior: CharacterDefinition = content.characters[&"demo.character.warrior"]
	var slot := run.state.member_slot(warrior.id)
	var base := _max_hp(run, slot)
	run.give_item(rations, null, warrior)
	var one := _max_hp(run, slot) - base
	run.give_item(rations, null, warrior)
	check(one > 0, "one Rations raises max HP")
	eq(_max_hp(run, slot) - base, one * 2, "two Rations give the bonus twice")


func test_the_collector_skips_food() -> void:
	if not _demo_ready():
		return
	var collector: EnemyDefinition = DemoItems._demo_content().units[&"demo.enemy.collector"]
	check(collector.mirror_skip_tags.has(FOOD_TAG), "the Collector lists Item.Food in its skip tags")
	var rations: ItemDefinition = DemoItems._demo_content().items[&"demo.item.rations"]
	check(Battle._carries(rations.grants, collector.mirror_skip_tags), "so its mirror skips the Rations' bonus")
