## Spec bot-play 6: the smart run bot: exploration by what a floor can hold (ExplorePlan), placement by tags and roles
## (LootScorer), gear and use-item moves (BotGear.improve), shops and field actions, the profiles' determinism, the
## validator's bot codes, the fit pass and the play report's bot blocks. Fixtures only: the world is built in memory
## (BotWorld).
extends TestCase

const DAMAGE: Array = [&"Item.Fit.Damage"]
const SURVIVAL: Array = [&"Item.Fit.Survival"]

var _runs: Array[RunController] = []


func after_each() -> void:
	for run in _runs:
		if is_instance_valid(run):
			run.free()
	_runs.clear()
	super()


func _run(seed_text: String = "5", run_id: StringName = BotWorld.RUN_ID) -> RunController:
	var run := BotWorld.start(host, seed_text, run_id)
	_runs.append(run)
	return run


func _member(run: RunController, slot: int) -> Dictionary:
	return run.state.member(slot)


# --- Exploration ---------------------------------------------------------------------------------------------------

func test_loot_value_and_mode_come_from_the_floor_rules() -> void:
	var bot := BotWorld.profile()
	var run := _run()
	eq(ExplorePlan.loot_value(run, bot), 160, "chapter A's rules place an item room (100) and a shop (60)")
	eq(ExplorePlan.mode(run, bot), ExplorePlan.FULL, "a loot floor is explored fully")
	var boss_first := _run("5", BotWorld.BOSS_RUN_ID)
	eq(ExplorePlan.loot_value(boss_first, bot), 20, "a challenge room alone is worth 20")
	eq(ExplorePlan.mode(boss_first, bot), ExplorePlan.BOSS, "under the threshold the bot goes for the boss")
	bot.explore = BotProfile.EXPLORE_FULL
	eq(ExplorePlan.mode(boss_first, bot), ExplorePlan.FULL, "--explore full forces FULL")
	bot.explore = BotProfile.EXPLORE_BOSS
	eq(ExplorePlan.mode(run, bot), ExplorePlan.BOSS, "--explore boss forces BOSS")


## The synthetic floor: S(0) - A(1) - B(2) - Boss(3) along the top row; D(9) under S; E(10) under A; C(19, a challenge
## room) under E.
func _line_map(run: RunController) -> void:
	BotWorld.map(run, {0: FloorMap.ROLE_START, 1: FloorMap.ROLE_NORMAL, 2: FloorMap.ROLE_NORMAL, 3: FloorMap.ROLE_BOSS,
		9: FloorMap.ROLE_NORMAL, 10: FloorMap.ROLE_NORMAL, 19: [FloorMap.ROLE_SPECIAL, "waves"]})


func test_full_takes_the_nearest_room_and_the_boss_last() -> void:
	var bot := BotWorld.profile()
	var run := _run()
	_line_map(run)
	BotWorld.visit(run, [1, 2], 2)
	# From B: E (10) is two steps (B, A, E), D (9) three (B, A, S, D); the boss (3) is next door but comes last.
	eq(ExplorePlan.next_room(run, bot, ExplorePlan.FULL), 10, "the nearest unvisited room, not the lowest index")
	BotWorld.visit(run, [9, 10, 19], 19)
	eq(ExplorePlan.next_room(run, bot, ExplorePlan.FULL), 3, "the boss once every other room is visited")


func test_boss_goes_for_the_boss_and_takes_a_challenge_found_on_the_way() -> void:
	var bot := BotWorld.profile()
	var run := _run()
	_line_map(run)
	eq(ExplorePlan.next_room(run, bot, ExplorePlan.BOSS), 1, "the boss room not seen yet: explore the nearest room")
	BotWorld.visit(run, [1, 2], 2)
	eq(ExplorePlan.next_room(run, bot, ExplorePlan.BOSS), 3, "the boss once it shows; no detour for rooms elsewhere")
	BotWorld.visit(run, [10], 10)
	eq(ExplorePlan.next_room(run, bot, ExplorePlan.BOSS), 19, "a challenge room found on the way is fought first")
	run.state.map.cells[19]["cleared"] = true
	run.state.map.cells[19]["visited"] = true
	eq(ExplorePlan.next_room(run, bot, ExplorePlan.BOSS), 3, "then the boss")


func test_boss_falls_back_to_exploring_when_no_path_shows() -> void:
	var bot := BotWorld.profile()
	var run := _run()
	BotWorld.map(run, {0: FloorMap.ROLE_START, 1: FloorMap.ROLE_NORMAL, 2: FloorMap.ROLE_BOSS})
	BotWorld.visit(run, [1], 1)
	eq(ExplorePlan.next_room(run, bot, ExplorePlan.BOSS), 2, "the boss next door")
	BotWorld.map(run, {0: FloorMap.ROLE_START})
	eq(ExplorePlan.next_room(run, bot, ExplorePlan.BOSS), -1, "nothing to enter: stuck, like today")


## S(0) - A(1) - T(2, item room) - Boss(3) on the top row; D(9) under S, H(10, shop) under A, E(11) under T.
func _loot_map(run: RunController) -> void:
	BotWorld.map(run, {0: FloorMap.ROLE_START, 1: FloorMap.ROLE_NORMAL,
		2: [FloorMap.ROLE_SPECIAL, "pickups", BotWorld.TREASURE_TAG], 3: FloorMap.ROLE_BOSS, 9: FloorMap.ROLE_NORMAL,
		10: [FloorMap.ROLE_SPECIAL, "pickups", BotWorld.SHOP_TAG], 11: FloorMap.ROLE_NORMAL})


func test_not_exploratory_heads_for_the_boss_once_the_loot_rooms_are_done() -> void:
	var bot := BotWorld.profile()
	bot.exploratory = false
	var run := _run()
	_loot_map(run)
	eq(ExplorePlan.next_room(run, bot, ExplorePlan.FULL), 1, "no loot room shows yet: explore the nearest room")
	BotWorld.visit(run, [1], 1)
	eq(ExplorePlan.next_room(run, bot, ExplorePlan.FULL), 2, "a loot room the map shows comes first")
	BotWorld.visit(run, [2], 2)
	check(not ExplorePlan.loot_done(run, bot), "chapter A's rules place an item room and a shop: one is left")
	eq(ExplorePlan.next_room(run, bot, ExplorePlan.FULL), 10, "the shop next")
	BotWorld.visit(run, [10], 10)
	check(ExplorePlan.loot_done(run, bot), "both loot rooms visited")
	eq(ExplorePlan.next_room(run, bot, ExplorePlan.FULL), 3, "then the boss, leaving D and E unvisited")
	bot.exploratory = true
	eq(ExplorePlan.next_room(run, bot, ExplorePlan.FULL), 9, "an exploratory bot visits every room first")


func test_a_locked_loot_room_with_no_key_counts_as_done() -> void:
	var bot := BotWorld.profile()
	var run := FloorRoomsWorld.start(host)
	_runs.append(run)
	var locked := -1
	for index in run.state.map.sorted_indices():
		if run.room_locked(index):
			locked = index
			break
	check(locked != -1, "the floor-rooms world locks a loot room")
	bot.room_values = {FloorRoomsWorld.TREASURE_TAG: 100, FloorRoomsWorld.SHOP_TAG: 60, FloorRoomsWorld.ARMORY_TAG: 60}
	run.state.keys = 0
	run.state.golden_key = false
	run.state.revealed = true
	for index in run.state.map.sorted_indices():
		var data: Dictionary = run.state.map.cells[index]
		if data["role"] == FloorMap.ROLE_SPECIAL and bot.room_value(data["special_tag"]) > 0 and not run.room_locked(index):
			data["visited"] = true
	check(ExplorePlan.loot_done(run, bot), "every open loot room visited, the locked ones out of reach: done")
	run.state.keys = 1
	check(not ExplorePlan.loot_done(run, bot), "with a key, a locked loot room is still to do")


func test_an_item_price_is_paid_only_for_an_item_worth_it() -> void:
	var bot := BotWorld.profile()
	var run := _run()
	BotWorld.strip(run)
	var data: Dictionary = run.state.map.cells[run.state.current_cell]
	data["cleared"] = true
	data["pickups"] = [{"placement": 1, "item": &"fixture.item.crest", "price": 0, "priceItem": &"fixture.item.leech",
		"taken": false}, {"placement": 2, "item": &"fixture.item.satchel", "price": 0, "priceItem": &"fixture.item.leech",
		"taken": false}]
	bot.altar_floor = 50
	BotGear.take_free(run, bot, {"refused": {}})
	check(data["pickups"][0]["taken"], "the crest (Survival, worth 80+) is worth a scar")
	check(not data["pickups"][1]["taken"], "an untagged item (worth 0) is not")
	bot.altar_floor = 0
	BotGear.take_free(run, bot, {"refused": {}})
	check(data["pickups"][1]["taken"], "altar_floor 0 takes them all (the old rule)")


func test_full_floor_visits_every_room_before_the_boss() -> void:
	var bot := BotWorld.profile()
	var run := _run("9")
	var entered_boss_with: Array = []
	for step in 300:
		if run.state.floor_index != 0 or run.state.status != RunState.ACTIVE:
			break
		if not run.pending_battle.is_empty():
			await run.fight(ScriptedController.new())
			continue
		if not run.state.event.is_empty():
			run.choose(0)
			continue
		if not run.state.pending_gifts.is_empty():
			run.give_to(RunPlayer.gift_holder(run, run.pending_gift()))
			continue
		var next := ExplorePlan.next_room(run, bot, ExplorePlan.FULL)
		if next == -1:
			break
		if run.state.map.cells[next]["role"] == FloorMap.ROLE_BOSS:
			for index in run.state.map.sorted_indices():
				if not run.state.map.cells[index]["visited"] and index != next:
					entered_boss_with.append(index)
			break
		eq(run.enter_room(next), "", "the bot's pick can be entered")
	eq(entered_boss_with, [], "every room was visited before the boss")


# --- Placement -------------------------------------------------------------------------------------------------------

func test_values_follow_fit_and_role() -> void:
	var bot := BotWorld.profile()
	var run := _run()
	BotWorld.strip(run)
	var ctx := BotWorld.context(run, bot)
	eq(LootScorer.value(ctx, DAMAGE, BotWorld.ROGUE), 100, "Damage on the Damage dealer: 100")
	eq(LootScorer.value(ctx, DAMAGE, BotWorld.KNIGHT), 30, "Damage on a Tank: the '*' weight")
	eq(LootScorer.value(ctx, SURVIVAL, BotWorld.KNIGHT), 100, "Survival on the Tank: 100")
	eq(LootScorer.value(ctx, SURVIVAL, BotWorld.MEDIC), 80, "Survival on anyone else: 80")
	eq(LootScorer.value(ctx, [], BotWorld.ROGUE), 0, "an untagged thing scores 0")
	var whetstone: ItemDefinition = run.content.items[&"fixture.item.whetstone"]
	eq(LootScorer.best_holder(LootScorer.context(run, bot), whetstone), BotWorld.ROGUE, "the whetstone goes to the rogue")
	_member(run, BotWorld.ROGUE)["alive"] = false
	eq(LootScorer.value(ctx, DAMAGE, BotWorld.ROGUE), 0, "the dead value nothing")


func test_live_roles_gain_a_granted_role() -> void:
	var bot := BotWorld.profile()
	var run := _run()
	BotWorld.strip(run)
	eq(LootScorer.roles_of(run, BotWorld.MEDIC), [&"Unit.Role.Healer"], "the medic is a Healer")
	var charm: ItemDefinition = run.content.items[&"fixture.item.chaser_charm"]
	var ctx := BotWorld.context(run, bot)
	# FollowUp on a Healer is the '*' weight (30), plus the new role (50).
	eq(LootScorer.value(ctx, charm.tags, BotWorld.MEDIC), 80, "a grant the member lacks adds new_role_value")
	_member(run, BotWorld.MEDIC)["items"].append(charm.id)
	eq(LootScorer.roles_of(run, BotWorld.MEDIC), [&"Unit.Role.FollowUp", &"Unit.Role.Healer"],
		"holding it makes the medic a follow-up character")
	eq(LootScorer.value(ctx, DAMAGE, BotWorld.MEDIC), 80, "Damage now weighs by the FollowUp role (80)")


func test_spread_sends_a_second_survival_item_elsewhere() -> void:
	var bot := BotWorld.profile()
	var run := _run()
	BotWorld.strip(run)
	var ctx := BotWorld.context(run, bot)
	var crest: ItemDefinition = run.content.items[&"fixture.item.crest"]
	var first := _best(ctx, run, crest.tags)
	eq(first, BotWorld.KNIGHT, "the first survival item goes to the Tank")
	_member(run, first)["items"].append(crest.id)
	eq(LootScorer.value(ctx, crest.tags, BotWorld.KNIGHT), 75, "a second one is worth less there (SPREAD, step 25)")
	check(_best(ctx, run, crest.tags) != first, "so the second goes to another member")


func test_carry_sends_a_second_damage_item_to_the_same_member() -> void:
	var bot := BotWorld.profile("res://game/auto/profiles/carry.tres")
	var run := _run()
	BotWorld.strip(run)
	var ctx := BotWorld.context(run, bot)
	_member(run, BotWorld.ROGUE)["items"].append(&"fixture.item.whetstone")
	eq(LootScorer.value(ctx, DAMAGE, BotWorld.ROGUE), 125, "CARRY: worth more where the same kind sits")
	eq(_best(ctx, run, DAMAGE), BotWorld.ROGUE, "the second damage item goes to the carry")
	var spread := BotWorld.context(run, BotWorld.profile())
	eq(LootScorer.value(spread, DAMAGE, BotWorld.ROGUE), 100, "the spread profile keeps damage FLAT")


## Spec second-pack 2.7: the smart bot gathers Bleed and lifesteal on one carrier (both add up per holder).
func test_smart_carries_bleed_and_lifesteal() -> void:
	var bot := BotWorld.profile("res://game/auto/profiles/smart.tres")
	for fit in [LootScorer.FIT_BLEED, LootScorer.FIT_LIFESTEAL]:
		eq(bot.stack_mode(fit), BotProfile.CARRY, "%s stacks as CARRY" % fit)
		var held: Array = [[fit]]
		check(LootScorer.stack_factor(bot, fit, held) > LootScorer.stack_factor(bot, fit, []),
			"a member already holding %s values another one more" % fit)
		check(LootScorer.ALL_TAGS.has(fit), "%s is a tag the bots read" % fit)


## Spec second-pack 2.7: a crit item is worth more on a crit holder (base crit rate above 5%); an HP-cost item little on a class
## that pays no HP.
func test_crit_items_favour_a_crit_holder_and_hp_cost_items_a_payer() -> void:
	var bot := BotWorld.profile("res://game/auto/profiles/smart.tres")
	var run := _run()
	BotWorld.strip(run)
	var ctx := BotWorld.context(run, bot)
	var crit: Array = [LootScorer.FIT_DAMAGE, LootScorer.FIT_CRIT]
	var rogue: UnitDefinition = run.content.units[_member(run, BotWorld.ROGUE)["character"]]
	var kept: int = rogue.stats_x100.get("crit_rate", 0)
	rogue.stats_x100["crit_rate"] = 500
	var plain := LootScorer.value(ctx, crit, BotWorld.ROGUE)
	check(not LootScorer.crit_holder(run, BotWorld.ROGUE, bot), "5% is the default: no crit holder")
	rogue.stats_x100["crit_rate"] = 2000
	check(LootScorer.crit_holder(run, BotWorld.ROGUE, bot), "20% base crit: a crit holder")
	check(LootScorer.value(ctx, crit, BotWorld.ROGUE) > plain, "so a crit item is worth more there")
	rogue.stats_x100["crit_rate"] = kept
	check(not LootScorer.pays_hp(run, BotWorld.ROGUE), "the fixture classes pay no HP")
	var hp_cost: Array = [LootScorer.FIT_HP_COST]
	eq(LootScorer.value(ctx, hp_cost, BotWorld.ROGUE), bot.weight(LootScorer.FIT_HP_COST, []) * bot.hp_cost_other_percent / 100,
		"an HP-cost item is worth its small share to a class that pays no HP")
	eq(bot.stack_mode(LootScorer.FIT_CRIT), BotProfile.CARRY, "crit items gather on one holder")


func test_a_copy_stacks_like_any_item_of_its_kinds() -> void:
	var bot := BotWorld.profile("res://game/auto/profiles/carry.tres")
	var run := _run()
	BotWorld.strip(run)
	var ctx := BotWorld.context(run, bot)
	_member(run, BotWorld.ROGUE)["items"].append(&"fixture.item.whetstone")
	var whetstone: ItemDefinition = run.content.items[&"fixture.item.whetstone"]
	eq(LootScorer.value(ctx, whetstone.tags, BotWorld.ROGUE), LootScorer.value(ctx, DAMAGE, BotWorld.ROGUE),
		"a copy of a held item scores like another item of the same fit")


func test_party_items_go_to_the_sturdiest_and_run_items_to_the_first_living() -> void:
	var bot := BotWorld.profile()
	var run := _run()
	BotWorld.strip(run)
	var ctx := BotWorld.context(run, bot, {BotWorld.KNIGHT: 50000, BotWorld.MEDIC: 30000, BotWorld.ROGUE: 80000})
	var banner: Array = [&"Item.Fit.Party"]
	eq(_best(ctx, run, banner), BotWorld.KNIGHT, "a party item goes to the Tank (the Tank bonus)")
	var coin: Array = [&"Item.Fit.Run"]
	eq(_best(ctx, run, coin), BotWorld.KNIGHT, "a run item goes to the first living member")
	_member(run, BotWorld.KNIGHT)["alive"] = false
	eq(_best(ctx, run, banner), BotWorld.ROGUE, "without the Tank, the member with the most HP")
	eq(_best(ctx, run, coin), BotWorld.MEDIC, "the next one when the first is dead")
	_member(run, BotWorld.MEDIC)["items"].append(&"fixture.item.crest")
	ctx["max_hp"] = {BotWorld.KNIGHT: 50000, BotWorld.MEDIC: 80000, BotWorld.ROGUE: 80000}
	eq(_best(ctx, run, banner), BotWorld.MEDIC, "on equal HP, the one holding more Survival things")


func test_survival_goes_to_the_frailest_first() -> void:
	var bot := BotWorld.profile()
	var run := _run()
	BotWorld.strip(run)
	var ctx := BotWorld.context(run, bot, {BotWorld.KNIGHT: 100000, BotWorld.MEDIC: 40000, BotWorld.ROGUE: 100000})
	eq(LootScorer.value(ctx, SURVIVAL, BotWorld.MEDIC), 160, "80 × the frailty extra, capped at 200%")
	eq(_best(ctx, run, SURVIVAL), BotWorld.MEDIC, "the frailest member first")


func test_ties_go_to_the_lowest_slot() -> void:
	var bot := BotWorld.profile()
	var run := _run()
	BotWorld.strip(run)
	var hood: EquipmentDefinition = run.content.equipment[&"fixture.equipment.hood"]
	eq(_best(BotWorld.context(run, bot), run, hood.tags), BotWorld.KNIGHT, "an untagged thing: everyone 0, the lowest slot")


## The living member with the highest value (ties to the lowest slot), like best_holder without the hold check.
func _best(ctx: Dictionary, run: RunController, tags: Array) -> int:
	return int(LootScorer.best_value(ctx, tags)[1])


# --- Gear ------------------------------------------------------------------------------------------------------------

func test_gear_fills_empty_slots_by_value() -> void:
	var bot := BotWorld.profile()
	var run := _run()
	BotWorld.strip(run)
	run.state.armor.append_array([&"fixture.equipment.blade", &"fixture.equipment.mail"])
	var moves := BotGear.improve(run, bot, {})
	check(moves >= 2, "both pieces worn")
	eq(_member(run, BotWorld.ROGUE)["equipment"].get(&"Fixture.Equipment.Slot.Weapon"), &"fixture.equipment.blade",
		"the blade on the Damage dealer")
	eq(_member(run, BotWorld.KNIGHT)["equipment"].get(&"Fixture.Equipment.Slot.Body"), &"fixture.equipment.mail",
		"the mail on the Tank")
	eq(run.state.armor, [], "nothing left in the bag while a slot is free")


func test_a_piece_worth_nothing_is_still_worn_but_a_curse_is_not() -> void:
	var bot := BotWorld.profile()
	var run := _run()
	BotWorld.strip(run)
	run.state.armor.append(&"fixture.equipment.hood")
	BotGear.improve(run, bot, {})
	eq(_member(run, BotWorld.KNIGHT)["equipment"].get(&"Fixture.Equipment.Slot.Head"), &"fixture.equipment.hood",
		"an untagged piece goes on the first living member with the slot free")
	var cursed: EquipmentDefinition = run.content.equipment[&"fixture.equipment.cap"]
	var tags: Array[StringName] = cursed.tags.duplicate()
	tags.append(LootScorer.CURSE_TAG)
	cursed.tags = tags
	run.state.armor.append(cursed.id)
	BotGear.improve(run, bot, {})
	check(run.state.armor.has(cursed.id), "a piece marked Item.Curse stays in the bag")


func test_an_upgrade_over_the_margin_replaces_the_worn_piece() -> void:
	var bot := BotWorld.profile()
	var run := _run()
	BotWorld.strip(run)
	for slot in [BotWorld.KNIGHT, BotWorld.MEDIC, BotWorld.ROGUE]:
		_member(run, slot)["equipment"][&"Fixture.Equipment.Slot.Head"] = &"fixture.equipment.helm"
	_member(run, BotWorld.KNIGHT)["equipment"][&"Fixture.Equipment.Slot.Head"] = &"fixture.equipment.hood"
	run.state.armor.append(&"fixture.equipment.cap")
	var stats := {"refused": {}, "moves": {}}
	BotGear.improve(run, bot, stats)
	eq(_member(run, BotWorld.KNIGHT)["equipment"][&"Fixture.Equipment.Slot.Head"], &"fixture.equipment.cap",
		"the knight's worthless hood gives way to the cap")
	eq(run.state.armor, [&"fixture.equipment.hood"], "the old piece goes back to the bag (no head slot is free)")
	eq(stats["refused"], {}, "nothing refused")


func test_no_swap_under_the_margin_and_no_oscillation() -> void:
	var bot := BotWorld.profile()
	var run := _run()
	BotWorld.strip(run)
	_member(run, BotWorld.KNIGHT)["equipment"][&"Fixture.Equipment.Slot.Head"] = &"fixture.equipment.cap"
	_member(run, BotWorld.MEDIC)["equipment"][&"Fixture.Equipment.Slot.Head"] = &"fixture.equipment.helm"
	_member(run, BotWorld.ROGUE)["equipment"][&"Fixture.Equipment.Slot.Head"] = &"fixture.equipment.hood"
	var log_size := run.run_log.size()
	eq(BotGear.improve(run, bot, {}), 0, "two Survival pieces of equal value never swap")
	eq(BotGear.improve(run, bot, {}), 0, "and a second pass makes no move either")
	eq(run.run_log.size(), log_size, "nothing logged")


func test_max_hp_never_moves_a_worn_piece() -> void:
	var bot := BotWorld.profile()
	bot.fit_weight = {&"Item.Fit.Survival": {"*": 80}}  # only frailty could tell the members apart
	var run := _run()
	BotWorld.strip(run)
	_member(run, BotWorld.KNIGHT)["equipment"][&"Fixture.Equipment.Slot.Head"] = &"fixture.equipment.helm"
	_member(run, BotWorld.MEDIC)["equipment"][&"Fixture.Equipment.Slot.Head"] = &"fixture.equipment.hood"
	_member(run, BotWorld.ROGUE)["equipment"][&"Fixture.Equipment.Slot.Head"] = &"fixture.equipment.hood"
	var ctx := LootScorer.context(run, bot)
	var survival: Array = [&"Item.Fit.Survival"]
	check(LootScorer.value(ctx, survival, BotWorld.MEDIC) * 100 > LootScorer.value(ctx, survival, BotWorld.KNIGHT) * 115,
		"the frail medic would value the helm more by the margin")
	eq(BotGear.improve(run, bot, {}), 0, "but a worn piece never moves for max HP (it would move back)")


func test_a_swap_between_wearers_that_raises_the_pair_is_made() -> void:
	var bot := BotWorld.profile()
	var run := _run()
	BotWorld.strip(run)
	var dagger: EquipmentDefinition = run.content.equipment[&"fixture.equipment.dagger"]
	var bare: Array[StringName] = []
	dagger.tags = bare  # an untagged weapon: worth 0 to everyone
	_member(run, BotWorld.KNIGHT)["equipment"][&"Fixture.Equipment.Slot.Weapon"] = &"fixture.equipment.blade"
	_member(run, BotWorld.ROGUE)["equipment"][&"Fixture.Equipment.Slot.Weapon"] = &"fixture.equipment.dagger"
	BotGear.improve(run, bot, {})
	eq(_member(run, BotWorld.ROGUE)["equipment"][&"Fixture.Equipment.Slot.Weapon"], &"fixture.equipment.blade",
		"the blade moves to the Damage dealer")


func test_a_swap_only_trades_with_the_wearer_swap_gear_picks() -> void:
	var bot := BotWorld.profile()
	var run := _run()
	BotWorld.strip(run)
	var dagger: EquipmentDefinition = run.content.equipment[&"fixture.equipment.dagger"]
	var bare: Array[StringName] = []
	dagger.tags = bare
	# The medic and the rogue wear the same blade; the knight a worthless dagger. A trade knight <-> rogue scores best,
	# but swap_gear(knight, blade) would take the medic's: only that trade may be scored.
	_member(run, BotWorld.KNIGHT)["equipment"][&"Fixture.Equipment.Slot.Weapon"] = &"fixture.equipment.dagger"
	_member(run, BotWorld.MEDIC)["equipment"][&"Fixture.Equipment.Slot.Weapon"] = &"fixture.equipment.blade"
	_member(run, BotWorld.ROGUE)["equipment"][&"Fixture.Equipment.Slot.Weapon"] = &"fixture.equipment.blade"
	var stats := {"refused": {}, "moves": {}}
	BotGear.improve(run, bot, stats)
	eq(_member(run, BotWorld.ROGUE)["equipment"][&"Fixture.Equipment.Slot.Weapon"], &"fixture.equipment.blade",
		"the Damage dealer keeps its blade")
	eq(int(stats["moves"].get("swaps", 0)) <= 1, true, "no swapping back and forth")


func test_free_keys_are_left_at_the_cap() -> void:
	var bot := BotWorld.profile()
	var run := _run()
	var data: Dictionary = run.state.map.cells[run.state.current_cell]
	data["cleared"] = true
	data["pickups"] = [{"placement": 1, "kind": FloorGenerator.KEYS_KIND, "keys": 1, "price": 0, "taken": false}]
	run.state.keys = RunStructure.MAX_KEYS
	var stats := {"refused": {}}
	BotGear.take_free(run, bot, stats)
	eq(stats["refused"], {}, "no refused take at 99 keys")
	check(not data["pickups"][0]["taken"], "the keys stay on the floor")


func test_a_dead_members_pieces_go_to_the_living() -> void:
	var bot := BotWorld.profile()
	var run := _run()
	BotWorld.strip(run)
	_member(run, BotWorld.MEDIC)["equipment"][&"Fixture.Equipment.Slot.Weapon"] = &"fixture.equipment.blade"
	_member(run, BotWorld.MEDIC)["alive"] = false
	BotGear.improve(run, bot, {})
	eq(_member(run, BotWorld.MEDIC)["equipment"], {}, "the dead medic's blade comes off")
	eq(_member(run, BotWorld.ROGUE)["equipment"].get(&"Fixture.Equipment.Slot.Weapon"), &"fixture.equipment.blade",
		"and goes on the living Damage dealer")


func test_only_as_many_dead_pieces_come_off_as_the_living_can_wear() -> void:
	var bot := BotWorld.profile()
	var run := _run()
	BotWorld.strip(run)
	for slot in [BotWorld.KNIGHT, BotWorld.MEDIC]:
		_member(run, slot)["equipment"][&"Fixture.Equipment.Slot.Weapon"] = &"fixture.equipment.blade"
		_member(run, slot)["alive"] = false
	BotGear.improve(run, bot, {})
	check(_member(run, BotWorld.ROGUE)["equipment"].has(&"Fixture.Equipment.Slot.Weapon"), "the rogue wears one")
	eq(run.state.armor, [], "the other stays on its dead wearer for a revive")
	check(_member(run, BotWorld.MEDIC)["equipment"].has(&"Fixture.Equipment.Slot.Weapon"), "the second dead member keeps theirs")


func test_no_trade_with_a_member_over_their_use_capacity() -> void:
	var bot := BotWorld.profile()
	bot.fit_weight = {&"Item.Fit.Party": {&"Unit.Role.Tank": 200, "*": 10}}  # the knight wants the flask
	var run := _run()
	BotWorld.strip(run)
	var blank: ItemDefinition = run.content.items[&"fixture.item.feather"].duplicate()
	blank.id = &"fixture.item.blank"
	blank.tags = [] as Array[StringName]
	run.content = run.content.overlay([blank])
	_member(run, BotWorld.MEDIC)["use_slots"] = [{"item": &"fixture.item.flask", "cooldown": 0}]
	_member(run, BotWorld.KNIGHT)["use_slots"] = [{"item": &"fixture.item.blank", "cooldown": 0}]
	_member(run, BotWorld.ROGUE)["use_slots"] = [{"item": &"fixture.item.blank", "cooldown": 0}]
	var ctx := LootScorer.context(run, bot)
	check(not BotGear._use_item_move(run, ctx, bot).is_empty(), "at capacity, the trade is proposed")
	# Two use items with one slot (a Satchel lost to an event): the run refuses any trade with the medic.
	_member(run, BotWorld.MEDIC)["use_slots"].append({"item": &"fixture.item.blank", "cooldown": 0})
	var stats := {"refused": {}, "moves": {}}
	BotGear.improve(run, bot, stats)
	eq(stats["refused"], {}, "no trade the run refuses")
	eq(_member(run, BotWorld.KNIGHT)["use_slots"][0]["item"], &"fixture.item.blank", "nothing traded")


func test_a_use_item_moves_where_it_is_worth_more() -> void:
	var bot := BotWorld.profile()
	var run := _run()
	BotWorld.strip(run)
	_member(run, BotWorld.MEDIC)["use_slots"].append({"item": &"fixture.item.flask", "cooldown": 0})
	_member(run, BotWorld.MEDIC)["alive"] = false
	var stats := {"refused": {}, "moves": {}}
	BotGear.improve(run, bot, stats)
	check(_member(run, BotWorld.MEDIC)["use_slots"].is_empty(), "a dead member's use item moves to the living")
	eq(stats["refused"], {}, "nothing refused")


# --- Shop and field --------------------------------------------------------------------------------------------------

## Puts pickups in the (cleared) current room: [[placement, item id, price], ...].
func _shelf(run: RunController, rows: Array) -> void:
	var data: Dictionary = run.state.map.cells[run.state.current_cell]
	data["cleared"] = true
	data["pickups"] = []
	for row in rows:
		data["pickups"].append({"placement": row[0], "item": row[1], "price": row[2], "taken": false})


func test_shop_buys_by_value_over_price_and_keeps_the_floor() -> void:
	var bot := BotWorld.profile()
	var run := _run()
	BotWorld.strip(run)
	_shelf(run, [[1, &"fixture.item.crest", 9], [2, &"fixture.item.whetstone", 4], [3, &"fixture.item.satchel", 1]])
	run.state.coins = 9
	var stats := {"refused": {}, "shop": {}}
	BotGear.shop(run, bot, stats)
	var data: Dictionary = run.state.map.cells[run.state.current_cell]
	check(data["pickups"][1]["taken"], "the whetstone (100 for 4) beats the crest (at most 200 for 9)")
	check(not data["pickups"][0]["taken"], "the crest is left: 5 coins are not enough")
	check(not data["pickups"][2]["taken"], "an untagged item is under the buy floor")
	check(_member(run, BotWorld.ROGUE)["items"].has(&"fixture.item.whetstone"), "bought for the Damage dealer")
	eq(stats["shop"]["bought"], {"Item.Fit.Damage": 1}, "counted by fit kind")
	eq(stats["refused"], {}, "nothing refused")


func test_a_key_too_dear_does_not_stop_the_shopping() -> void:
	var bot := BotWorld.profile()
	var run := FloorRoomsWorld.start(host)
	_runs.append(run)
	run.state.keys = 0
	run.state.golden_key = false
	run.state.revealed = true
	check(BotGear.keys_needed(run) > 0, "a locked loot room shows")
	_shelf(run, [[1, &"fixture.item.whetstone", 4]])
	run.state.map.cells[run.state.current_cell]["pickups"].append({"placement": 2, "kind": FloorGenerator.KEYS_KIND,
		"keys": 1, "price": 15, "taken": false})
	run.state.coins = 14
	var thing: ItemDefinition = run.content.items[&"fixture.item.whetstone"]
	thing = thing.duplicate()
	var tags: Array[StringName] = thing.tags.duplicate()
	tags.append(&"Item.Fit.Damage")
	thing.tags = tags
	run.content = run.content.overlay([thing])
	BotGear.shop(run, bot, {"refused": {}, "shop": {}})
	check(run.state.map.cells[run.state.current_cell]["pickups"][0]["taken"], "the whetstone is bought with the 14 coins")


func test_a_piece_nobody_would_wear_is_not_bought() -> void:
	var bot := BotWorld.profile()
	var run := _run()
	BotWorld.strip(run)
	for slot in [BotWorld.KNIGHT, BotWorld.MEDIC, BotWorld.ROGUE]:
		_member(run, slot)["equipment"][&"Fixture.Equipment.Slot.Weapon"] = &"fixture.equipment.blade"
	_shelf(run, [[1, &"fixture.equipment.dagger", 2]])
	var pickup: Dictionary = run.state.map.cells[run.state.current_cell]["pickups"][0]
	pickup["kind"] = FloorGenerator.EQUIPMENT_KIND
	run.state.coins = 9
	BotGear.shop(run, bot, {"refused": {}, "shop": {}})
	check(not pickup["taken"], "everyone wears a Damage weapon already")
	_member(run, BotWorld.ROGUE)["equipment"] = {}
	run.state.armor.append(&"fixture.equipment.blade")
	BotGear.shop(run, bot, {"refused": {}, "shop": {}})
	check(not pickup["taken"], "nor when a piece in the bag fills the only empty slot")
	run.state.armor.clear()
	BotGear.shop(run, bot, {"refused": {}, "shop": {}})
	check(pickup["taken"], "but for an empty slot, yes")


func test_keys_needed_counts_the_floors_locked_rooms() -> void:
	var run := FloorRoomsWorld.start(host)
	_runs.append(run)
	var locked := 0
	var shown := 0
	for index in run.state.map.sorted_indices():
		if run.room_locked(index):
			locked += 1
			if BotGear.shown(run, index):
				shown += 1
	run.state.keys = 0
	eq(BotGear.keys_needed(run), shown, "one key per locked room the map shows")
	run.state.revealed = true
	eq(BotGear.keys_needed(run), locked, "a revealed map shows them all")
	check(locked > 0, "the floor-rooms world locks rooms")
	run.state.keys = locked + 2
	eq(BotGear.keys_needed(run), 0, "none with keys to spare")
	run.state.keys = 0
	run.state.golden_key = true
	eq(BotGear.keys_needed(run), 0, "none with the golden key")


func test_a_key_is_bought_for_the_next_floors_locked_item_room() -> void:
	var bot := BotWorld.profile()
	var run := FloorRoomsWorld.start(host)
	_runs.append(run)
	for index in run.state.map.sorted_indices():
		run.state.map.cells[index]["opened"] = true  # nothing locked left on this floor
	run.state.keys = 0
	run.state.golden_key = false
	eq(BotGear.keys_needed(run), 0, "this floor needs no key")
	eq(BotGear.keys_wanted(run, bot), 0, "the profile names the demo's item room tag, which the fixture rules don't lock")
	var tags: Array[StringName] = [FloorRoomsWorld.TREASURE_TAG]
	bot.next_floor_key_rooms = tags
	eq(BotGear.keys_wanted(run, bot), 1, "no key held and the next floor locks its item room: buy one")
	run.state.keys = 1
	eq(BotGear.keys_wanted(run, bot), 0, "not with a key in hand")
	run.state.keys = 0
	run.state.floor_index = run.structure.floors.size() - 1
	eq(BotGear.keys_wanted(run, bot), 0, "no next floor on the last one")


## Synthetic field options: [slot, ability, roles, targets].
func _options(rows: Array) -> Array[Dictionary]:
	var options: Array[Dictionary] = []
	for row in rows:
		options.append({"slot": row[0], "ability": row[1], "item": &"", "targets": row[3], "roles": row[2],
			"targeting": BattleAbility.Targeting.SINGLE_ALLY})
	return options


func _stats(hp: Array, mp: Array = [100, 100, 100]) -> Dictionary:
	var stats := {}
	for index in 3:
		stats[index + 1] = {"hp": hp[index] * 1000, "max_hp": 100000, "mp": mp[index] * 1000, "max_mp": 100000}
	return stats


func test_field_revives_heals_before_a_fight_and_rests_when_healthy() -> void:
	var bot := BotWorld.profile()
	var run := _run()
	_line_map(run)
	var options := _options([[2, &"Fixture.Heal", [&"Ability.Role.Heal"], [1, 2, 3]],
		[2, &"Fixture.Raise", [&"Ability.Role.Revive"], [3]]])
	_member(run, BotWorld.ROGUE)["alive"] = false
	eq(BotGear.choose_field(run, bot, 1, options, _stats([100, 100, 0])),
		{"slot": 2, "ability": &"Fixture.Raise", "target": 3}, "a dead member is revived first")
	_member(run, BotWorld.ROGUE)["alive"] = true
	eq(BotGear.choose_field(run, bot, 1, options, _stats([40, 90, 100])),
		{"slot": 2, "ability": &"Fixture.Heal", "target": 1}, "a member under 50% is healed before a battle room")
	eq(BotGear.choose_field(run, bot, 1, options, _stats([90, 90, 100])), {}, "nothing when healthy")
	BotWorld.visit(run, [1], 1)
	eq(BotGear.choose_field(run, bot, 1, options, _stats([40, 90, 100])), {}, "no heal before a room already cleared")
	eq(BotGear.choose_field(run, bot, 2, options, _stats([40, 90, 100])),
		{"slot": 2, "ability": &"Fixture.Heal", "target": 1}, "but before the next unvisited room")
	BotWorld.visit(run, [2], 2)
	eq(BotGear.choose_field(run, bot, 3, options, _stats([95, 90, 100])),
		{"slot": 2, "ability": &"Fixture.Heal", "target": 2}, "before the boss, anyone hurt (the lowest share first)")


func test_a_self_heal_only_heals_its_caster() -> void:
	var bot := BotWorld.profile()
	var run := _run()
	_line_map(run)
	var options: Array[Dictionary] = [{"slot": 1, "ability": &"Fixture.Mend", "item": &"", "targets": [],
		"roles": [&"Ability.Role.Heal"], "targeting": BattleAbility.Targeting.SELF}]
	eq(BotGear.choose_field(run, bot, 1, options, _stats([100, 30, 100])), {}, "the knight's self heal can't help the medic")
	eq(BotGear.choose_field(run, bot, 1, options, _stats([30, 100, 100])),
		{"slot": 1, "ability": &"Fixture.Mend", "target": 0}, "but heals the knight")


func test_before_the_boss_a_consumable_is_kept_for_a_small_wound() -> void:
	var bot := BotWorld.profile()
	var run := _run()
	_line_map(run)
	BotWorld.visit(run, [1, 2], 2)
	var options: Array[Dictionary] = [{"slot": 1, "ability": &"Fixture.Potion", "item": &"fixture.item.feather",
		"targets": [1, 2, 3], "roles": [&"Ability.Role.Heal"], "targeting": BattleAbility.Targeting.SINGLE_ALLY}]
	eq(BotGear.choose_field(run, bot, 3, options, _stats([95, 100, 100])), {}, "no consumable to top up 5%")
	eq(BotGear.choose_field(run, bot, 3, options, _stats([40, 100, 100])),
		{"slot": 1, "ability": &"Fixture.Potion", "target": 1}, "but under the threshold, yes")


func test_field_restores_sp_before_the_boss() -> void:
	var bot := BotWorld.profile()
	var run := _run()
	_line_map(run)
	BotWorld.visit(run, [1, 2], 2)
	var options := _options([[1, &"Fixture.Ether", [&"Ability.Role.RestoreMP"], [1, 2, 3]]])
	eq(BotGear.choose_field(run, bot, 3, options, _stats([100, 100, 100], [100, 20, 100])),
		{"slot": 1, "ability": &"Fixture.Ether", "target": 2}, "SP under 30% before the boss")
	eq(BotGear.choose_field(run, bot, 9, options, _stats([100, 100, 100], [100, 20, 100])), {},
		"not before another room")


func test_sp_comes_before_small_heals_at_the_boss() -> void:
	var bot := BotWorld.profile()
	var run := _run()
	_line_map(run)
	BotWorld.visit(run, [1, 2], 2)
	var options := _options([[1, &"Fixture.Mend", [&"Ability.Role.Heal"], [1, 2, 3]],
		[1, &"Fixture.Ether", [&"Ability.Role.RestoreMP"], [1, 2, 3]]])
	eq(BotGear.choose_field(run, bot, 3, options, _stats([95, 95, 95], [100, 20, 100])),
		{"slot": 1, "ability": &"Fixture.Ether", "target": 2}, "SP first, the small top-ups after")
	eq(BotGear.choose_field(run, bot, 3, options, _stats([40, 95, 95], [100, 20, 100])),
		{"slot": 1, "ability": &"Fixture.Mend", "target": 1}, "a real wound still comes first")
	eq(BotGear.choose_field(run, bot, 3, options, _stats([95, 100, 100], [100, 100, 100])),
		{"slot": 1, "ability": &"Fixture.Mend", "target": 1}, "a top-up once SP is fine")


# --- Whole runs ------------------------------------------------------------------------------------------------------

func _play(seed_value: int, profile_path: String, explore: String = BotProfile.EXPLORE_SMART) -> Dictionary:
	var opts := {"run": String(BotWorld.RUN_ID), "party": BotWorld.PARTY, "policy": "smart", "check": true,
		"bot_profile": profile_path, "explore": explore, "max_steps": 600}
	return await PlayReport.play_one(BotWorld.content(), host, seed_value, opts)


func test_each_profile_decides_the_same_twice() -> void:
	for path in ["res://game/auto/profiles/smart.tres", "res://game/auto/profiles/spread.tres",
			"res://game/auto/profiles/carry.tres"]:
		var first := await _play(3, path)
		var second := await _play(3, path)
		eq(first["runHash"], second["runHash"], "%s: the same seed gives the same run" % path.get_file())
		eq(first["violations"], [], "%s: no violation (no bot action refused)" % path.get_file())
		eq(first["stop"], "", "%s: the run ends on its own" % path.get_file())
		check(first.has("bot"), "%s: the run has a bot record" % path.get_file())


func test_a_bot_with_every_part_off_plays_like_no_bot() -> void:
	var opts := {"run": String(BotWorld.RUN_ID), "party": BotWorld.PARTY, "policy": "smart", "max_steps": 600,
		"bot_parts": "none"}
	check(PlayReport.bot_for(opts).parts.is_empty(), "--bot-parts none turns every part off")
	var hashes: Array = []
	for bot in [null, PlayReport.bot_for(opts)]:
		var run := _run("4")
		await RunPlayer.play(run, 600, Callable(), {}, EventScorer.POLICY_SMART, bot, {})
		hashes.append(run.state.run_hash())
	eq(hashes[1], hashes[0], "the same run as RunPlayer without a bot")


func test_the_bot_cache_changes_no_decision() -> void:
	for seed_text in ["3", "4"]:
		var hashes: Array = []
		for cached in [false, true]:
			var run := _run(seed_text)
			if cached:
				await RunPlayer.play(run, 600, Callable(), {}, EventScorer.POLICY_SMART, BotWorld.profile(), {})
				check(not run.has_meta(BotCache.META), "the cache is off again once the play is over")
			else:
				await RunPlayer._play(run, 600, Callable(), {}, EventScorer.POLICY_SMART, BotWorld.profile(),
					{"floors": [], "refused": {}, "moves": {}, "shop": {}})
			hashes.append(run.state.run_hash())
		eq(hashes[1], hashes[0], "seed %s: the same run with and without the cache" % seed_text)


func test_the_bot_cache_is_kept_until_an_action_is_logged() -> void:
	var run := _run()
	var fresh := BotCache.party_stats(run)
	check(not is_same(fresh, BotCache.party_stats(run)), "off: every read is fresh")
	BotCache.begin(run)
	var first := BotCache.party_stats(run)
	eq(first, run.party_stats(), "the cache holds what the run says")
	check(is_same(first, BotCache.party_stats(run)), "on: nothing logged, the same read")
	check(is_same(BotCache.field_options(run), BotCache.field_options(run)), "field options too")
	run.state.armor.append(&"fixture.equipment.mail")
	run.state.member(BotWorld.KNIGHT)["equipment"] = {}
	eq(run.equip(BotWorld.KNIGHT, &"fixture.equipment.mail"), "", "a logged action")
	var after := BotCache.party_stats(run)
	check(not is_same(first, after), "read again after a logged action")
	eq(after, run.party_stats(), "and fresh")
	BotCache.end(run)


func test_a_what_if_on_a_bot_profile_reaches_the_bot() -> void:
	var path := "res://game/auto/profiles/carry.tres"
	var report: Node = load("res://game/tools/seed_report.gd").new()
	check(report._apply_sets(PackedStringArray(["--set", path + ":exploratory=false"])), "the setting applies")
	check(not PlayReport.bot_for({"policy": "smart", "bot_profile": path}).exploratory, "the bot plays with it")
	report.free()
	check(PlayReport.bot_for({"policy": "smart", "bot_profile": path}).exploratory, "and it ends with the report")


func test_auto_policy_plays_without_the_bot() -> void:
	var opts := {"run": String(BotWorld.RUN_ID), "party": BotWorld.PARTY, "policy": "auto", "max_steps": 600}
	var record := await PlayReport.play_one(BotWorld.content(), host, 3, opts)
	check(not record.has("bot"), "auto keeps today's run decisions (no bot record)")
	check(PlayReport.bot_for({"policy": "auto"}) == null, "no profile for auto")
	check(PlayReport.bot_for({"policy": "chaos"}) != null, "chaos plays the smart bot")


func test_report_blocks_merge_exactly_and_explore_is_honoured() -> void:
	var content := BotWorld.content()
	var opts := {"run": String(BotWorld.RUN_ID), "party": BotWorld.PARTY, "policy": "smart", "max_steps": 600,
		"explore": BotProfile.EXPLORE_BOSS}
	var whole := await PlayReport.many(content, host, 1, 2, opts, true)
	var one := await PlayReport.many(content, host, 1, 1, opts, true)
	var two := await PlayReport.many(content, host, 2, 1, opts, true)
	var merged := PlayReport.merge(JSON.parse_string(JSON.stringify([{"records": one["records"], "options": one["options"]},
		{"records": two["records"], "options": two["options"]}])))
	for key in ["explore", "placement", "itemLift", "shop", "botRefused", "untagged"]:
		check(whole.has(key), "the report has %s" % key)
		eq(JSON.stringify(merged.get(key)), JSON.stringify(whole.get(key)), "%s merges exactly across shards" % key)
	for chapter in whole["explore"]:
		eq(int(whole["explore"][chapter].get("full", 0)), 0, "--explore boss: no floor explored fully (%s)" % chapter)


func test_replayed_battles_are_freed_after_each_seed() -> void:
	var opts := {"run": String(BotWorld.RUN_ID), "party": BotWorld.PARTY, "policy": "smart", "max_steps": 600, "check": true}
	var content := BotWorld.content()
	var before := host.get_child_count()
	var report := await PlayReport.many(content, host, 1, 2, opts)
	check(report["won"] + report["lost"] == 2, "both seeds played")
	eq(host.get_child_count(), before, "no replayed battle waits in the tree for the shard to end")


func test_a_refused_bot_action_is_a_violation_under_check() -> void:
	var run := _run()
	BotGear._act(run, {}, "take", "no such pickup")  # no "refused" key: nothing collected
	var stats := {"refused": {}}
	check(not BotGear._act(run, stats, "take", "no such pickup"), "a refusal returns false")
	eq(stats["refused"], {"take: no such pickup": 1}, "counted by action and reason")
	check(BotGear._act(run, stats, "take", ""), "a done action returns true")


# --- Validator and the fit pass --------------------------------------------------------------------------------------

func _codes(content: ContentIndex) -> Dictionary:
	var found := {}
	for issue in ContentValidator.validate(content, {"tags": false}):
		found["%s|%s" % [issue.code, issue.path.get_file().get_slice("::", 0)]] = issue.is_error()
	return found


func test_the_fixtures_skip_the_bot_checks() -> void:
	var found := _codes(TestCase.fixtures())
	for key in found:
		check(not key.begins_with("fit_") and not key.begins_with("role_tag") and not key.begins_with("grant_"),
			"no bot code on content that uses no bot tags: " + key)


func test_validator_reports_the_bot_codes() -> void:
	var base := BotWorld.content()
	var bogus: ItemDefinition = base.items[&"fixture.item.crest"].duplicate()
	bogus.id = &"fixture.item.bogus_grant"
	var tags: Array[StringName] = [&"Fixture.Pool.Treasure", &"Item.Fit.Survival", &"Item.Grants.Bogus"]
	bogus.tags = tags
	bogus.resource_path = ""
	bogus.take_over_path("res://tests/fixtures/items/bogus_grant.tres")
	var bare: ItemDefinition = base.items[&"fixture.item.feather"].duplicate()
	bare.id = &"fixture.item.bare"
	var bare_tags: Array[StringName] = [&"Pool.Shop"]
	bare.tags = bare_tags
	bare.take_over_path("res://tests/fixtures/items/bare.tres")
	var roleless: CharacterDefinition = base.units[&"fixture.character.guard"].duplicate()
	roleless.selectable = true
	roleless.take_over_path("res://tests/fixtures/characters/roleless.tres")
	var found := _codes(base.overlay([bogus, bare, roleless]))
	eq(found.get("grant_unknown|bogus_grant.tres"), true, "grant_unknown: an Item.Grants.* naming no role")
	eq(found.get("fit_missing|bare.tres"), true, "fit_missing: a pooled item with no fit (an error)")
	eq(found.get("role_tag_missing|roleless.tres"), true, "role_tag_missing: a selectable character with no role")
	for key in found:
		if key.begins_with("fit_mismatch|"):
			eq(found[key], false, "fit_mismatch is a warning: " + key)


func test_fit_pass_proposes_by_kind() -> void:
	var content := TestCase.fixtures()
	var banner: ItemDefinition = content.items[&"fixture.item.banner"]
	check(FitProposal.propose(banner).has(LootScorer.FIT_PARTY), "a PARTY item proposes Item.Fit.Party")
	var coin: ItemDefinition = content.items[&"fixture.item.lucky_coin"]
	var dowsing: ItemDefinition = content.items[&"fixture.item.dowsing"]
	check(FitProposal.propose(dowsing).has(LootScorer.FIT_RUN), "a run hook proposes Item.Fit.Run")
	var satchel: ItemDefinition = content.items[&"fixture.item.satchel"]
	check(FitProposal.propose(satchel).has(LootScorer.FIT_RUN), "more use slots propose Item.Fit.Run")
	for item in [coin, banner]:
		for tag in FitProposal.propose(item):
			check(LootScorer.ALL_TAGS.has(tag), "%s: %s is a bot tag" % [item.id, tag])
	var whetstone: ItemDefinition = content.items[&"fixture.item.whetstone"]
	eq(FitProposal.missing(whetstone), FitProposal.propose(whetstone), "missing: what the untagged fixture lacks")


func test_fit_pass_write_touches_only_the_tags_line() -> void:
	if skip_in_export():
		return
	var source := "res://tests/fixtures/items/whetstone.tres"
	var copy := "user://fit_pass_whetstone.tres"
	DirAccess.copy_absolute(ProjectSettings.globalize_path(source), ProjectSettings.globalize_path(copy))
	eq(FitPass.add_tags(copy, [&"Item.Fit.Damage"]), "", "written")
	var before := FileAccess.get_file_as_string(source).split("\n")
	var after := FileAccess.get_file_as_string(copy).split("\n")
	eq(after.size(), before.size(), "the same number of lines")
	var changed: Array = []
	for index in mini(before.size(), after.size()):
		if before[index] != after[index]:
			changed.append(after[index])
	eq(changed, ["tags = Array[StringName]([&\"Fixture.Pool.Treasure\", &\"Item.Fit.Damage\"])"], "only the tags line changed")
	DirAccess.remove_absolute(ProjectSettings.globalize_path(copy))
