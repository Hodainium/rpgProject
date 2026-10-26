## Whole runs (spec game-skeleton sections 2, 3.6, 4, 6): run start from loadouts, navigation, carry-over, usable items,
## field actions, item pools and hooks, shop/treasure, coin drops, events, losing, runner errors, a scripted run.
extends TestCase

const GAME_GOLDEN: String = GOLDEN + "game/"

var _runs: Array[RunController] = []


func after_each() -> void:
	super()
	for run in _runs:
		if is_instance_valid(run):
			run.free()
	_runs.clear()


func _start(seed_text: String = "7", party: Array = ["fixture.character.knight", "fixture.character.medic",
		"fixture.character.rogue"]) -> RunController:
	var run := start_run(host, seed_text, party)
	_runs.append(run)
	return run


## Puts a battle against `encounter_id` in the current room (bypasses the map so tests pick the fight).
func _inject_battle(run: RunController, encounter_id: String, variant_id: Variant = null) -> void:
	var encounter: EncounterDefinition = run.content.encounters[StringName(encounter_id)]
	var generator := FloorGenerator.new(run.content, run.structure, run.state.run_seed, run.state.floor_index)
	var enemies: Array = generator.resolve_enemies(encounter, null, true, null, RunSeeds.rng(1, "test"))
	for enemy in enemies:
		enemy["variantId"] = variant_id
	var cell := run.state.current_cell
	run.state.map.cells[cell]["content"]["enemies"] = enemies
	run.pending_battle = {"cell": cell, "encounter": encounter.id, "enemies": enemies, "label": "/test"}


## Enters `index` from wherever the party is (marks a neighbour visited so the Isaac adjacency rule allows it).
func _go(run: RunController, index: int) -> String:
	run.state.map.cells[run.state.map.neighbours(index)[0]]["visited"] = true
	return run.enter_room(index)


func _cell_with_room(run: RunController, room_id: String) -> int:
	for index in run.state.map.sorted_indices():
		if run.state.map.cells[index]["room"] == StringName(room_id):
			return index
	return -1


func _item(name: String) -> ItemDefinition:
	return fixtures().items[StringName("fixture.item." + name)]


func _character(name: String) -> CharacterDefinition:
	return fixtures().characters[StringName("fixture.character." + name)]


func _kill(run: RunController, slot: int) -> void:
	run.state.member(slot)["hp"] = 0
	run.state.member(slot)["alive"] = false


func test_run_start_from_loadout() -> void:
	var run := _start()
	eq(run.runner_error, "", "the fixture run starts")
	var knight := run.state.member(1)
	eq(knight["skills"], [&"Fixture.Ability.Frost"], "the loadout teaches a learnable skill")
	eq(knight["use_slots"], [{"item": &"fixture.item.feather", "cooldown": 0}], "the loadout's usable item fills the use slot")
	eq(knight["equipment"], {&"Fixture.Equipment.Slot.Weapon": &"fixture.equipment.blade"}, "the loadout's equipment")
	eq(run.state.member(2)["skills"], [&"Fixture.Ability.Mend"], "medic kit")
	eq(run.state.member(3)["skills"], [], "no loadout, no extras")
	eq([knight["hp"], knight["mp"], knight["energy"]], [100000, 10000, 0], "full HP/MP read through GAS at start")
	eq([run.state.coins, run.state.floor_index, run.state.status], [0, 0, RunState.ACTIVE], "fresh run")
	eq(run.run_log[0]["type"], "start_run", "logged")
	check(run.state.map.cells[run.state.map.start]["cleared"], "the start room is cleared")


func test_run_navigation_and_refusals() -> void:
	var run := _start()
	var map := run.state.map
	var far := -1
	var distances := map.distances()
	for index in map.sorted_indices():
		if distances[index] >= 2:
			far = index
			break
	var logged := run.run_log.size()
	check(far != -1 and not run.can_enter(far), "a room not next to a visited one is closed")
	eq(run.enter_room(far), "can't enter that room now", "clicking it is refused")
	eq(run.enter_room(run.state.current_cell), "can't enter that room now", "the current room is not a move")
	eq(run.run_log.size(), logged, "refusals are not logged")
	var next := RunPlayer.next_room(run)
	eq(run.enter_room(next), "", "a neighbour opens")
	eq(run.run_log[-1], {"type": "enter_room", "floor": 0, "cell": next}, "entering is logged")
	_inject_battle(run, "fixture.encounter.lone")
	check(not run.can_enter(map.start), "no moving while a battle waits")
	eq(run.take(1, 1), "not now", "no shopping during a battle")
	eq(run.next_floor(), "the next floor is not open", "the boss is not beaten")


func test_carry_over_and_dead_stay_dead() -> void:
	var run := _start()
	run.state.member(1)["use_slots"].clear()  # no feather, so nobody can revive the rogue
	_kill(run, 3)
	run.state.member(2)["hp"] = 40000
	_inject_battle(run, "fixture.encounter.lone")
	var party: Array = run.battle_snapshot()["party"]
	eq([party[1]["hp"], party[2]["hp"]], [40000, 0], "the snapshot carries the run's HP")
	eq(await run.fight(ScriptedController.new()), "", "the fight runs")
	eq(run.run_log[-1]["outcome"], Battle.VICTORY, "the party wins")
	check(not run.state.member(3)["alive"] and run.state.member(3)["hp"] == 0, "a dead member stays dead")
	var knight := run.state.member(1)
	_inject_battle(run, "fixture.encounter.lone")
	var next: Array = run.battle_snapshot()["party"]
	eq([next[0]["hp"], next[0]["mp"], next[0]["energy"]], [knight["hp"], knight["mp"], knight["energy"]],
		"battle → run state → next battle")


func test_usable_items_and_slots() -> void:
	var run := _start()
	_kill(run, 3)
	var feather := run.field_options().filter(func(o): return o["ability"] == &"Fixture.Ability.Feather")
	eq(feather, [{"slot": 1, "ability": &"Fixture.Ability.Feather", "item": &"fixture.item.feather", "targets": [3]}],
		"the feather is a field option aimed only at the dead")
	eq(await run.use_field(1, &"Fixture.Ability.Feather", 3), [], "revive on the map")
	eq([run.state.member(3)["alive"], run.state.member(3)["hp"]], [true, 20000], "revived with the effect's HP")
	eq(run.state.member(1)["use_slots"], [], "a consumable is gone after use")
	eq(run.run_log[-1]["item"], "fixture.item.feather", "the item use is logged")
	# One use slot by default; a Schoolbag-like passive adds one.
	run.give_item(_item("feather"), null, _character("knight"))
	eq(run.can_hold(1, _item("flask")), "fixture.character.knight has no free use slot", "the slot is full")
	run.give_item(_item("satchel"), null, _character("knight"))
	eq(run.use_capacity(1), 2, "extra use slot")
	run.give_item(_item("flask"), null, _character("knight"))
	eq(run.state.member(1)["use_slots"].size(), 2, "two usable items held")
	# Cooldown: used on the map → not offered until a battle is won.
	eq(await run.use_field(1, &"Fixture.Ability.Flask"), [], "blast heal on the map")
	eq(run.state.member(1)["use_slots"][1], {"item": &"fixture.item.flask", "cooldown": 1}, "cooldown starts")
	check(run.field_options().all(func(o): return o["ability"] != &"Fixture.Ability.Flask"), "a cooling item is not offered")
	_inject_battle(run, "fixture.encounter.lone")
	check(run.battle_snapshot()["party"][0]["useSlots"][1] == {"itemId": "fixture.item.flask", "ready": false},
		"the battle sees it cooling")
	await run.fight(ScriptedController.new())
	eq(run.state.member(1)["use_slots"][1]["cooldown"], 0, "a won battle counts the cooldown down")


func test_field_actions_and_refusals() -> void:
	var run := _start()
	run.state.member(2)["hp"] = 10000
	var logged := run.run_log.size()
	eq((await run.use_field(1, &"Fixture.Ability.Strike", 2))[0], "InvalidTarget", "no enemy skills on the map")
	eq([run.run_log.size(), run.state.field_actions_on_floor], [logged, 0], "a refusal changes nothing")
	eq(await run.use_field(2, &"Fixture.Ability.Mend", 2), [], "the field heal works")
	eq([run.state.member(2)["hp"], run.state.member(2)["mp"]], [40000, 8000], "healed, MP spent through GAS")
	eq(run.state.field_actions_on_floor, 1, "the field counter moves")
	for use in 4:
		await run.use_field(2, &"Fixture.Ability.Mend", 2)
	eq(run.state.member(2)["mp"], 0, "MP runs out")
	check(not (await run.use_field(2, &"Fixture.Ability.Mend", 2)).is_empty(), "no MP, no spell")
	_inject_battle(run, "fixture.encounter.lone")
	eq((await run.use_field(2, &"Fixture.Ability.Mend", 2))[0], "NotNow", "not while a battle waits")


func test_item_pools() -> void:
	var run := _start("7", ["fixture.character.medic"])
	var generator := FloorGenerator.new(run.content, run.structure, 1, 0)
	var treasure := GameplayTagQuery.new()
	treasure.require_all_tags.assign([&"Fixture.Pool.Treasure"])
	var last := generator.pick_item(null, treasure, RunSeeds.rng(1, "t"), {"party": [&"fixture.character.medic"],
		"held": [&"fixture.item.whetstone", &"fixture.item.banner"], "seen": [&"fixture.item.ember_charm"]})
	eq(last.id, &"fixture.item.crest", "held and seen items are excluded; the crest is offered to any party")
	var empty := generator.pick_item(null, treasure, RunSeeds.rng(1, "t"), {"party": [&"fixture.character.knight"],
		"held": [&"fixture.item.whetstone", &"fixture.item.banner", &"fixture.item.crest"],
		"seen": [&"fixture.item.ember_charm"]})
	eq(empty.id, &"fixture.item.crumb", "an empty pool gives the fallback item")
	var seen := {}
	for index in run.state.map.sorted_indices():
		for pickup in run.state.map.cells[index]["pickups"]:
			if pickup["item"] != &"fixture.item.crumb":
				check(not seen.has(pickup["item"]), "%s placed twice on a floor" % pickup["item"])
				seen[pickup["item"]] = true


func test_items_hooks_and_remove() -> void:
	var plain := _start()
	var lucky := _start()
	lucky.give_item(_item("lucky_coin"), null, null)
	eq(lucky.state.holder_of(&"fixture.item.lucky_coin"), 1, "given to the first member who can hold it")
	for run in [plain, lucky]:
		_inject_battle(run, "fixture.encounter.lone")
		await run.fight(ScriptedController.new())
	eq(lucky.state.coins - plain.state.coins, 1, "on_room_cleared gains a coin")
	lucky.give_item(_item("whetstone"), null, _character("knight"))
	_inject_battle(lucky, "fixture.encounter.lone")
	check(lucky.battle_snapshot()["party"][0]["items"].has("fixture.item.whetstone"), "a passive reaches the battle")
	var remove := RemoveItem.new()
	remove.item = _item("whetstone")
	remove.apply(lucky)
	check(not lucky.battle_snapshot()["party"][0]["items"].has("fixture.item.whetstone"), "RemoveItem drops its grants")


## Spec 3.1: enemy loadouts resolve default → encounter slot → room placement, the last one set wins.
func test_loadout_precedence() -> void:
	var run := _start()
	var generator := FloorGenerator.new(run.content, run.structure, 1, 0)
	var tough: Loadout = run.content.loadouts[&"fixture.loadout.tough"]
	var enemy := EnemyDefinition.new()
	enemy.id = &"test.enemy"
	enemy.default_loadout = Loadout.new()  # inline default
	var encounter := EncounterDefinition.new()
	encounter.id = &"test.encounter"
	for loadout in [null, Loadout.new()]:  # slot 1: default only; slot 2: inline encounter override
		var slot := EncounterSlot.new()
		slot.enemy = enemy
		slot.loadout = loadout
		encounter.slots.append(slot)
	var plain: Array = generator.resolve_enemies(encounter, null, true, null, RunSeeds.rng(1, "t"))
	eq([plain[0]["loadoutRef"], plain[1]["loadoutRef"]], ["test.enemy#default", "test.encounter#2"],
		"the encounter's slot override beats the enemy's default")
	var room := RoomDefinition.new()
	room.id = &"test.room"
	var spawn := RoomPlacement.new()
	spawn.kind = RoomPlacement.Kind.ENEMY_SPAWN
	spawn.slot = 2
	spawn.loadout = tough
	room.placements.append(spawn)
	var placed: Array = generator.resolve_enemies(encounter, room, true, null, RunSeeds.rng(1, "t"))
	eq([placed[0]["loadoutRef"], placed[1]["loadoutRef"]], ["test.enemy#default", "fixture.loadout.tough"],
		"the room placement beats the encounter (an asset loadout is referenced by its id)")


## Spec 3.1 items: on_pickup runs when an item is received, on_floor_start when each floor begins.
func test_items_pickup_and_floor_hooks() -> void:
	var content := ContentIndex.new(FIXTURES)  # own index: the test adds an item to it
	var bonus := GainCoins.new()
	bonus.amount = 3
	var item := ItemDefinition.new()
	item.id = &"test.item.hooks"
	item.on_pickup.assign([bonus])
	item.on_floor_start.assign([bonus])
	content.items[item.id] = item
	var run := RunController.new()
	host.add_child(run)
	_runs.append(run)
	eq(run.start_run(content, ["fixture.character.knight"], "7"), "", "run starts")
	run.give_item(item, null, null)
	eq(run.state.coins, 3, "on_pickup ran")
	run.state.boss_cleared = true
	eq(run.next_floor(), "", "next floor")
	eq(run.state.coins, 6, "on_floor_start ran")


## Spec section 4: a usable item on cooldown is refused on the map, and nothing is logged.
func test_cooling_item_refused_on_map() -> void:
	var run := _start()
	run.state.member(1)["use_slots"] = [{"item": &"fixture.item.flask", "cooldown": 1}]
	var logged := run.run_log.size()
	check(not (await run.use_field(1, &"Fixture.Ability.Flask")).is_empty(), "a cooling item can't be used")
	eq([run.run_log.size(), run.state.member(1)["use_slots"][0]["cooldown"]], [logged, 1], "nothing changed")


func test_shop_and_treasure() -> void:
	var run := _start()
	var market := _cell_with_room(run, "fixture.room.market")
	eq(_go(run, market), "", "into the shop")
	var crumb := 3
	eq(run.take(crumb, 1), "not enough coins", "no coins, no sale")
	var logged := run.run_log.size()
	run.add_coins(5)
	eq(run.take(crumb, 1), "", "the bargain sells")
	eq(run.state.coins, 4, "price paid")
	eq(run.take(crumb, 1), "already taken", "each slot sells once")
	eq(run.run_log.size(), logged + 1, "only the sale is logged")
	check(run.state.member(1)["items"].has(&"fixture.item.crumb"), "bought for the chosen member")
	run.add_coins(-100)
	eq(run.state.coins, 0, "coins never go negative")
	var vault := _cell_with_room(run, "fixture.room.vault")
	eq(_go(run, vault), "", "into the treasure room")
	var pickup: Dictionary = run.state.map.cells[vault]["pickups"][0]
	eq(pickup["price"], 0, "treasure is free")
	var holder := 1 if run.can_hold(1, _item(String(pickup["item"]).get_slice(".", 2))) == "" else 2
	eq(run.take(1, holder), "", "take the treasure")
	eq(run.state.holder_of(pickup["item"]), holder, "the treasure is held")


func test_coin_drops() -> void:
	var coins := []
	for variant in [null, null, "fixture.variant.elite"]:
		var run := _start()
		_inject_battle(run, "fixture.encounter.lone", variant)
		await run.fight(ScriptedController.new())
		coins.append(run.state.coins)
	eq(coins[1], coins[0], "drops are seeded")
	check(coins[0] >= 1 and coins[0] <= 2, "drop within the scaling range")
	eq(coins[2] - coins[0], 2, "an elite adds its coin bonus")


func test_event_flow() -> void:
	var run := _start()
	run.state.member(2)["hp"] = 10000
	run.state.event = {"cell": run.state.current_cell, "event": &"fixture.event.toll", "page": 0}
	check(not run.choice_enabled(0), "Pay needs 3 coins")
	eq(run.choose(0), "that choice isn't available", "a disabled choice is refused")
	run.add_coins(5)
	eq(run.choose(0), "", "pay")
	eq([run.state.coins, run.state.event["page"]], [2, 1], "outcomes in order: lose coins, then go to page 2")
	eq(run.choose(0), "", "rest")
	eq(run.state.member(2)["hp"], 40000, "ApplyPartyEffect heals through GAS")
	eq(run.state.event, {}, "the event ends")
	run.state.event = {"cell": run.state.current_cell, "event": &"fixture.event.toll", "page": 0}
	eq(run.choose(1), "", "fight")
	eq(run.pending_battle["encounter"], &"fixture.encounter.lone", "StartEncounter opens a battle")
	check(run.battle_snapshot()["battleId"].ends_with("/event"), "the event battle has its own id and seed")
	eq(await run.fight(ScriptedController.new()), "", "the event battle runs")
	run.state.event = {"cell": run.state.current_cell, "event": &"fixture.event.coin", "page": 0}
	var before := run.state.coins
	run.choose(0)
	eq(run.state.coins, before + 5, "the coin event pays")


func test_run_lost() -> void:
	var run := _start()
	_kill(run, 1)
	_kill(run, 2)
	run.state.member(3)["hp"] = 1
	_inject_battle(run, "fixture.encounter.boss")
	await run.fight(ScriptedController.new())
	eq(run.state.status, RunState.LOST, "a lost battle ends the run")
	eq(run.run_log[-1], {"type": "end", "status": RunState.LOST}, "logged")
	eq(RunPlayer.next_room(run), -1, "nothing more to do")
	var field := _start()
	var doom := GameplayEffect.new()
	doom.policy = GameplayEffect.DurationPolicy.INSTANT
	var modifier := CombatModifier.new()
	modifier.attribute_name = "hp"
	modifier.operation = GameplayEffectModifier.Operation.ADD
	modifier.value_x100 = -10000000
	doom.modifiers.append(modifier)
	field.apply_party_effect(doom, false)
	eq(field.state.status, RunState.LOST, "a party wiped outside battle loses too")


func test_run_battle_runner_error() -> void:
	var run := _start()
	_inject_battle(run, "fixture.encounter.lone")
	run.pending_battle["enemies"] = [{"slot": 1, "unitDefId": "fixture.enemy.nope", "loadoutRef": null, "variantId": null}]
	check((await run.fight(ScriptedController.new())).contains("battle "), "the error names the battle")
	check(run.runner_error != "", "the run stops")
	eq(run.state.status, RunState.ACTIVE, "a runner error is not a loss")
	eq(RunPlayer.next_room(run), -1, "nothing more to do")


func test_content_problems() -> void:
	var broken := ContentIndex.new(FIXTURES)
	broken.problems.append("two items share an id")
	for case in [[broken, ["fixture.character.knight"], "1", "content problems"],
			[fixtures(), ["fixture.character.knight"], "abc", "the seed must be"],
			[fixtures(), [], "1", "pick 1 to 4"],
			[fixtures(), ["a", "b", "c", "d", "e"], "1", "pick 1 to 4"],
			[fixtures(), ["fixture.character.nope"], "1", "unknown character"]]:
		var run := RunController.new()
		host.add_child(run)
		_runs.append(run)
		var error := run.start_run(case[0], case[1], case[2])
		check(error.contains(case[3]), "'%s' expected, got '%s'" % [case[3], error])


## Spec "Done when": the 2-floor fixture run can be won (seed 11: both bosses beaten, run Won on the last floor).
func test_run_won() -> void:
	var run := _start("11")
	await RunPlayer.play(run)
	eq([run.state.status, run.state.floor_index, run.runner_error], [RunState.WON, 1, ""], "the fixture run is won on floor 2")
	eq(run.run_log[-1], {"type": "end", "status": RunState.WON}, "the win is logged")


func test_run_scripted() -> void:
	var results := []
	for attempt in 2:
		var run := _start("7")
		await RunPlayer.play(run)
		eq(run.runner_error, "", "the scripted run has no runner error")
		check(run.state.status != RunState.ACTIVE, "the scripted run ends (got %s)" % run.state.status)
		results.append({"status": run.state.status, "runHash": run.state.run_hash(), "log": run.run_log})
	var text := WireJson.stringify(results[0])
	eq(WireJson.stringify(results[1]), text, "same seed and choices: identical run log and run hash")
	var kinds := {}
	for entry in results[0]["log"]:
		kinds[entry["type"]] = true
	for kind in ["battle", "enter_room", "field"]:
		check(kinds.has(kind), "the scripted run includes a %s" % kind)
	if update_goldens:
		DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(GAME_GOLDEN))
		var file := FileAccess.open(GAME_GOLDEN + "run_scripted.json", FileAccess.WRITE)
		file.store_string(text)
		file.close()
	eq(text, FileAccess.get_file_as_string(GAME_GOLDEN + "run_scripted.json"), "the scripted run matches its golden")
