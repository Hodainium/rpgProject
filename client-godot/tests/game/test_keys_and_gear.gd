## Spec keys-and-gear 6: keys and the golden key, locked rooms, chests, run modifiers, the one-action gear swap, moving
## use items, Field / Battle usage tags, the room reveal, the bots (smart and chaos) and the validator checks. Fixtures
## only: the keyed run is built in memory over them (KeysWorld).
extends TestCase

const TREASURE: StringName = &"Fixture.Room.Type.Treasure"
const SHOP: StringName = &"Fixture.Room.Type.Shop"

var _runs: Array[RunController] = []
var _handles: Array = []


func after_each() -> void:
	for handle in _handles:
		handle.unregister()
	_handles.clear()
	for run in _runs:
		if is_instance_valid(run):
			run.free()
	_runs.clear()
	super()


func _keyed(seed_text: String = "7", tweak: Callable = Callable()) -> RunController:
	var run := KeysWorld.start(host, seed_text, tweak)
	_runs.append(run)
	return run


func _plain(seed_text: String = "7") -> RunController:
	var run := start_run(host, seed_text)
	_runs.append(run)
	return run


## Enters `index` from wherever the party is (marks a neighbour visited so the Isaac adjacency rule allows it).
func _go(run: RunController, index: int) -> String:
	run.state.map.cells[run.state.map.neighbours(index)[0]]["visited"] = true
	return run.enter_room(index)


func _item(name: String) -> ItemDefinition:
	return fixtures().items[StringName("fixture.item." + name)]


func _chest(name: String) -> ChestDefinition:
	return fixtures().chests[StringName("fixture.chest." + name)]


## Listens on `channel` and returns the array the heard messages land in.
func _hear(channel: StringName) -> Array:
	var heard := []
	_handles.append(GameplayMessages.listen(channel, func(_on: StringName, message): heard.append(message)))
	return heard


## A refusal changes nothing: the reply is not "", the log and the run hash are as before.
func _refused(run: RunController, action: Callable, label: String) -> String:
	var before_hash := run.state.run_hash()
	var before_log := run.run_log.size()
	var reply: String = action.call()
	check(reply != "", "%s is refused" % label)
	eq([run.run_log.size(), run.state.run_hash()], [before_log, before_hash], "%s changes nothing" % label)
	return reply


# --- Keys, the golden key, drops ------------------------------------------------------------------------------------

func test_runs_without_keys_hash_as_before() -> void:
	var run := _plain()
	check(not "\n".join(run.state.canonical_lines()).contains("keys="), "no keys line on a run without keys")
	check(not run.run_summary().has("keysFound"), "no key counters in its summary")
	check(not DevReport.state_of(run).has("keys"), "nor in its state report")
	run._clear_room(KeysWorld.normal(run), true)
	eq([run.state.keys, run.state.chests.size()], [0, 0], "chance 0: no key or chest drops")


func test_key_and_chest_drops() -> void:
	var found := []
	for attempt in 2:
		var run := _keyed()
		var keys := _hear(GameplayMessageRouter.RUN_KEY_FOUND)
		var chests := _hear(GameplayMessageRouter.RUN_CHEST_FOUND)
		var cell := KeysWorld.normal(run)
		run._clear_room(cell, true)
		eq(run.state.keys, 1, "a cleared room drops a key (100% here)")
		eq(run.state.chests.size(), 1, "and a chest")
		eq([keys.size(), keys[0].data["targetName"]], [1, "a key"], "Message.Run.KeyFound: 'a key'")
		eq(chests.size(), 1, "Message.Run.ChestFound")
		check("\n".join(run.state.canonical_lines()).contains("keys=1|golden=0|chests="), "keys and chests are hashed")
		found.append([run.state.chests[0]["chest"], run.state.run_hash()])
		run._clear_room(run.state.map.boss, true)
		eq(run.state.keys, 1, "the boss room drops no key (D2)")
		_handles.map(func(handle): handle.unregister())
		_handles.clear()
	eq(found[0], found[1], "drops are seeded per cell")
	var quiet := _keyed("7", func(structure: RunStructure): structure.key_drop_chance_x100 = 0)
	var silent := _hear(GameplayMessageRouter.RUN_KEY_FOUND)
	quiet._clear_room(KeysWorld.normal(quiet), true)
	eq(silent.size(), 0, "no key, no toast")


## Spec keys-and-gear 3.2 / D7: the outcome and condition classes events, chests and item hooks use.
func test_outcomes_and_conditions() -> void:
	var run := _keyed()
	var two := KeysAtLeast.new()
	two.amount = 2
	check(not two.holds(run), "KeysAtLeast 2 fails with no keys")
	var gain := GainKeys.new()
	gain.amount = 3
	gain.apply(run)
	eq(run.state.keys, 3, "GainKeys 3")
	check(two.holds(run), "KeysAtLeast 2 holds with 3")
	var lose := LoseKeys.new()
	lose.amount = 5
	lose.apply(run)
	eq(run.state.keys, 0, "LoseKeys never goes below 0")
	run.give_golden_key()
	check(not two.holds(run), "a golden key is not counted as keys")
	run.state.golden_key = false
	GiveGoldenKey.new().apply(run)
	check(run.state.golden_key, "GiveGoldenKey")
	var give := GiveChest.new()
	give.chest = _chest("crate")
	give.apply(run)
	eq(run.state.chests.map(func(held: Dictionary) -> StringName: return held["chest"]), [&"fixture.chest.crate"],
		"GiveChest puts the chest in the inventory")
	GiveChest.new().apply(run)
	eq(run.state.chests.size(), 1, "a GiveChest without a chest does nothing")
	# PartyHpAtLeast: every living member has at least that share of max HP; the dead don't count.
	var half := PartyHpAtLeast.new()
	half.percent = 50
	check(half.holds(run), "a full party has 50%")
	var max_hp: int = run.party_stats()[2][BattleUnit.MAX_HP]
	run.state.member(2)["hp"] = int(max_hp * 0.4)
	check(not half.holds(run), "one member at 40% fails it")
	run.state.member(2)["alive"] = false
	check(half.holds(run), "a dead member doesn't count")


func test_keys_cap_and_double() -> void:
	var run := _keyed()
	run.add_keys(120)
	eq(run.state.keys, RunStructure.MAX_KEYS, "keys stop at 99")
	run.add_keys(-200)
	eq(run.state.keys, 0, "and never go below 0")
	run.give_item(_item("key_fob"), null, null)
	var keys := _hear(GameplayMessageRouter.RUN_KEY_FOUND)
	run._clear_room(KeysWorld.normal(run), true)
	eq(run.state.keys, 2, "Run.Keys.Double: a found key counts twice")
	eq(keys[0].data["targetName"], "a key ring", "and the toast says so")


func test_golden_key() -> void:
	var run := _keyed("7", func(structure: RunStructure): structure.golden_key_chance_x100 = 10000)
	var keys := _hear(GameplayMessageRouter.RUN_KEY_FOUND)
	run._clear_room(KeysWorld.normal(run), true)
	eq([run.state.golden_key, run.state.keys], [true, 0], "a golden key instead of a key")
	check(keys[0].data["golden"], "the toast knows it is golden")
	var vault := KeysWorld.special(run, TREASURE)
	eq(_go(run, vault), "", "a golden key opens a locked room")
	eq([run.run_log[-1]["unlock"], run.state.keys], ["golden", 0], "for free, logged as golden")
	run.give_chest(_chest("strongbox"))
	eq(run.open_chest(0), "", "and a chest that needs a key")
	run.dev_boss_done()
	run.next_floor()
	check(not run.state.golden_key, "it is gone after the stairs")


# --- Locked rooms ---------------------------------------------------------------------------------------------------

func test_locked_rooms() -> void:
	var run := _keyed()
	var vault := KeysWorld.special(run, TREASURE)
	var market := KeysWorld.special(run, SHOP)
	check(run.room_locked(vault) and run.room_locked(market), "item rooms and shops are locked")
	check(not run.room_locked(run.state.map.boss), "the boss room never is")
	run.state.map.cells[run.state.map.neighbours(vault)[0]]["visited"] = true
	eq(_refused(run, run.enter_room.bind(vault), "a locked room without a key"), "Locked: you need a key", "the reason")
	var cells := MapCells.of(run)
	eq([cells[vault]["kind"], cells[vault]["locked"]], ["lock", true], "the map shows the lock")
	run.add_keys(1)
	eq(run.enter_room(vault), "", "a key opens it")
	eq([run.state.keys, run.run_log[-1]["unlock"], run.state.map.cells[vault]["opened"]], [0, "key", true],
		"one key spent, logged, the room stays open")
	check(not run.room_locked(vault), "no longer locked")
	check(Array(run.state.map.canonical_lines()).any(func(line: String) -> bool: return line.contains("opened=1")),
		"an opened room is hashed")
	eq(run.enter_room(run.state.map.start), "", "back to the start")
	eq(run.enter_room(vault), "", "re-entering")
	eq(run.state.keys, 0, "costs nothing")
	check(not run.run_log[-1].has("unlock"), "and logs no unlock")
	var early := _keyed("7", func(structure: RunStructure): structure.unlocked_floors = 1)
	check(not early.room_locked(KeysWorld.special(early, TREASURE)), "floors before unlocked_floors have no locks")


func test_keys_for_sale() -> void:
	var run := _keyed()
	var market := KeysWorld.special(run, SHOP)
	var cell: Dictionary = run.state.map.cells[market]
	cell["pickups"].append({"placement": 9, "item": FloorGenerator.KEYS_KIND, "price": 2, "taken": false,
		"kind": FloorGenerator.KEYS_KIND, "keys": 3})
	run.add_keys(1)
	_go(run, market)
	eq(run.take(9, 1), "not enough coins", "keys cost coins")
	run.add_coins(5)
	eq(run.take(9, 1), "", "bought")
	eq([run.state.keys, run.state.coins, run.run_log[-1]["kind"]], [3, 3, "keys"], "three keys for two coins, logged")
	eq(run.run_summary()["itemsTaken"], 0, "keys are not counted as items")


# --- Chests ---------------------------------------------------------------------------------------------------------

func test_chest_contents_are_the_chests_own() -> void:
	var pieces := []
	for later in [false, true]:
		var run := _keyed()
		run.give_chest(_chest("crate"))
		if later:
			run.dev_boss_done()
			run.next_floor()
		var opened := _hear(GameplayMessageRouter.RUN_CHEST_OPENED)
		eq(run.open_chest(0), "", "a free chest opens")
		eq([run.state.chests.size(), run.run_log[-1]["type"], run.run_log[-1]["serial"]], [0, "open_chest", 0],
			"it is gone and logged with its serial")
		eq(run.state.armor.size(), 1, "one piece of crate gear, into the bag")
		check(opened[0].data["description"].contains(fixtures().equipment[run.state.armor[0]].display_name),
			"the toast lists what came out")
		pieces.append(run.state.armor[0])
		_handles.map(func(handle): handle.unregister())
		_handles.clear()
	eq(pieces[0], pieces[1], "the same chest gives the same piece on another floor")
	# prefer_open_slot: the knight wears a weapon, nobody wears a head piece; crate gear is a dagger or a hood.
	var run := _keyed()
	run.state.party[1]["equipment"][&"Fixture.Equipment.Slot.Weapon"] = &"fixture.equipment.blade"
	run.state.party[2]["equipment"][&"Fixture.Equipment.Slot.Weapon"] = &"fixture.equipment.blade"
	run.give_chest(_chest("crate"))
	run.open_chest(0)
	eq(run.state.armor, [&"fixture.equipment.hood"], "a piece for a slot someone has empty comes first")


func test_chest_refusals_and_keys() -> void:
	var run := _keyed()
	run.give_chest(_chest("strongbox"))
	eq(_refused(run, run.open_chest.bind(0), "a strongbox with no key"), "Locked: you need a key", "the reason")
	_refused(run, run.open_chest.bind(3), "a chest number past the end")
	run.pending_battle = {"cell": run.state.current_cell}
	_refused(run, run.open_chest.bind(0), "a chest during a battle")
	run.pending_battle = {}
	run.add_keys(1)
	eq(run.open_chest(0), "", "a key opens it")
	check(run.state.keys == 0 and run.state.coins >= 2 and run.state.coins <= 3, "one key spent, 2-3 coins (got %d)"
		% run.state.coins)
	var lockpicked := _keyed()
	lockpicked.give_item(_item("lockpick"), null, null)
	lockpicked.give_chest(_chest("strongbox"))
	eq(lockpicked.open_chest(0), "", "Run.Chest.NoKey: opens with 0 keys")
	var doubled := _keyed()
	doubled.give_item(_item("warden_key"), null, null)
	eq(doubled.state.keys, 2, "the warden key gives two keys on pickup")
	doubled.give_chest(_chest("crate"))
	doubled.open_chest(0)
	eq(doubled.state.armor.size(), 2, "Run.Chest.Double: the crate rolls twice")
	var summary := doubled.run_summary()
	eq([summary["chestsOpened"], summary["keysFound"]], [1, 2], "the summary counts chests and keys")


# --- Gear swap and item moves ---------------------------------------------------------------------------------------

func test_swap_gear() -> void:
	var run := _plain()
	var weapon := &"Fixture.Equipment.Slot.Weapon"
	eq(run.swap_gear(2, &"fixture.equipment.blade"), "", "the medic takes the knight's blade")
	eq([run.state.member(2)["equipment"].get(weapon), run.state.member(1)["equipment"].has(weapon)],
		[&"fixture.equipment.blade", false], "the knight had nothing to give back")
	eq(run.run_log[-1], {"type": "swap_gear", "floor": 0, "slot": 2, "from": 1, "equipment": "fixture.equipment.blade"},
		"one logged action")
	run.give_equipment(fixtures().equipment[&"fixture.equipment.dagger"])
	eq(run.equip(1, &"fixture.equipment.dagger"), "", "the knight wears a dagger")
	eq(run.swap_gear(1, &"fixture.equipment.blade"), "", "and swaps it for the blade")
	eq([run.state.member(1)["equipment"][weapon], run.state.member(2)["equipment"][weapon], run.state.armor],
		[&"fixture.equipment.blade", &"fixture.equipment.dagger", []], "a trade: nothing passes through the bag")
	_refused(run, run.swap_gear.bind(1, &"fixture.equipment.blade"), "a swap with yourself")
	run.give_equipment(fixtures().equipment[&"fixture.equipment.hood"])
	_refused(run, run.swap_gear.bind(1, &"fixture.equipment.hood"), "a swap for a piece nobody wears")
	_refused(run, run.swap_gear.bind(9, &"fixture.equipment.blade"), "a swap to nobody")
	# Two members wearing the same piece (as starting loadouts can): neither can "swap" for it.
	run.state.member(3)["equipment"][weapon] = &"fixture.equipment.blade"
	_refused(run, run.swap_gear.bind(3, &"fixture.equipment.blade"), "a swap for a piece you already wear")


func test_move_item() -> void:
	var run := _plain()
	var feather := &"fixture.item.feather"
	run.state.member(1)["use_slots"][0]["cooldown"] = 1
	eq(run.move_item(1, feather, 2), "", "the feather moves to the medic's free slot")
	eq([run.state.member(1)["use_slots"], run.state.member(2)["use_slots"]], [[], [{"item": feather, "cooldown": 1}]],
		"with its cooldown")
	eq(run.run_log[-1], {"type": "move_item", "floor": 0, "slot": 1, "item": "fixture.item.feather", "to": 2, "swap": null},
		"one logged action")
	run.give_item(_item("flask"), null, fixtures().characters[&"fixture.character.rogue"])
	_refused(run, run.move_item.bind(3, &"fixture.item.flask", 2), "a move into a full item slot")
	eq(run.move_item(3, &"fixture.item.flask", 2, feather), "", "a swap instead")
	eq([run.state.member(2)["use_slots"][0]["item"], run.state.member(3)["use_slots"][0]["item"]],
		[&"fixture.item.flask", feather], "each takes the other's place")
	_refused(run, run.move_item.bind(1, feather, 2), "moving an item someone else holds")
	_refused(run, run.move_item.bind(3, feather, 3), "a move to yourself")
	# Capacity: a satchel-like use item can't leave its holder over the limit.
	var satchel_user := _plain()
	satchel_user.give_item(_item("satchel"), null, fixtures().characters[&"fixture.character.knight"])
	satchel_user.give_item(_item("flask"), null, fixtures().characters[&"fixture.character.knight"])
	eq(satchel_user.state.member(1)["use_slots"].size(), 2, "two use items with the satchel")
	eq(satchel_user.move_item(1, &"fixture.item.flask", 2), "", "the passive satchel stays, so one moves fine")


# --- Usage tags -----------------------------------------------------------------------------------------------------

func test_usage_tags() -> void:
	var run := _plain()
	run.give_item(_item("field_tonic"), null, fixtures().characters[&"fixture.character.medic"])
	run.give_item(_item("battle_tonic"), null, fixtures().characters[&"fixture.character.rogue"])
	var options := run.field_options().map(func(option: Dictionary) -> StringName: return option["ability"])
	check(options.has(&"Fixture.Ability.FieldMend"), "a Field-only item works on the map")
	check(not options.has(&"Fixture.Ability.BattleFlask"), "a Battle-only one doesn't")
	eq((await run.use_field(3, &"Fixture.Ability.BattleFlask"))[0], "IllegalAbility", "and the map refuses it")
	var labels := {}
	for entry in run.field_catalog():
		labels[entry["ability"]] = entry["hint"]["usage"]
	eq([labels[&"Fixture.Ability.FieldMend"], labels[&"Fixture.Ability.BattleFlask"], labels[&"Fixture.Ability.Feather"]],
		[AbilityHint.USAGE_FIELD, AbilityHint.USAGE_BATTLE, AbilityHint.USAGE_BOTH], "[Field Only], [Battles Only], untagged both")
	eq(labels[&"Fixture.Ability.Strike"], AbilityHint.USAGE_BATTLE, "untagged enemy moves: [Battles Only] (today's rule)")
	# In battle: the Field-only tonic is never a legal action, the Battle-only one is.
	var snapshot := {}
	var probe := func(battle: Battle) -> void:
		var medic := battle.unit_by_id(&"P2")
		var rogue := battle.unit_by_id(&"P3")
		snapshot["field"] = battle.validate_action(medic, {"ability": &"Fixture.Ability.FieldMend", "target": &"P2"})
		snapshot["battle"] = battle.validate_action(rogue, {"ability": &"Fixture.Ability.BattleFlask", "target": &""})
	run.battle_started.connect(probe, CONNECT_ONE_SHOT)
	var cell := KeysWorld.normal(run)
	var encounter: EncounterDefinition = run.content.encounters[&"fixture.encounter.lone"]
	var generator := FloorGenerator.new(run.content, run.structure, run.state.run_seed, 0)
	var enemies := generator.resolve_enemies(encounter, null, true, null, RunSeeds.rng(1, "test"))
	run.pending_battle = {"cell": cell, "encounter": encounter.id, "enemies": enemies, "label": "/test"}
	await run.fight(ScriptedController.new())
	eq(snapshot["field"][0], "IllegalAbility", "a Field-only ability is refused in battle")
	eq(snapshot["battle"], [], "a Battle-only one is legal there")


func test_room_reveal() -> void:
	var run: RunController = null
	var events: Array[int] = []
	for seed_value in range(1, 30):  # the first seed whose first floor has an event room
		run = _keyed(str(seed_value))
		for index in run.state.map.sorted_indices():
			if run.state.map.cells[index]["content"]["kind"] == "event" and not run.state.map.cells[index]["visited"]:
				events.append(index)
		if not events.is_empty():
			break
	check(not events.is_empty(), "a keyed floor with an event room")
	if events.is_empty():
		return
	check(not run.room_type_known(events[0]), "an unvisited event room is unknown")
	run.give_item(_item("dowsing"), null, null)
	check(run.room_type_known(events[0]), "the dowsing item reveals it")
	run.dev_boss_done()
	run.next_floor()
	check(run.state.reveal_events, "and does again on the next floor (on_floor_start)")


# --- Bots -----------------------------------------------------------------------------------------------------------

func test_bots_use_keys_and_chests() -> void:
	var hashes := []
	for attempt in 2:
		var run := _keyed("11")
		var stop := await RunPlayer.play(run)
		eq([stop, run.runner_error], ["", ""], "the bot finishes the keyed run")
		var summary := run.run_summary()
		check(summary["keysFound"] > 0 and summary["keysSpent"] > 0, "it finds and spends keys (%s)" % summary)
		check(summary["chestsOpened"] > 0, "it opens chests")
		check(run.run_log.any(func(entry: Dictionary) -> bool: return entry.get("unlock", "") == "key"), "it opens a lock")
		check(run.run_log.any(func(entry: Dictionary) -> bool: return entry["type"] == "equip"), "it wears found gear")
		hashes.append(run.state.run_hash())
	eq(hashes[0], hashes[1], "same seed, same bot: the same run")


## The keyed scripted run as a golden (game-skeleton's test_run_scripted, on the keyed run): keys, golden-key-free
## locks, chests, gear worn and the hash lines that carry them are pinned. Re-record with --update-goldens.
func test_keyed_run_golden() -> void:
	var results := []
	for attempt in 2:
		var run := _keyed("7")
		await RunPlayer.play(run)
		eq(run.runner_error, "", "the keyed scripted run has no runner error")
		check(run.state.status != RunState.ACTIVE, "the keyed scripted run ends (got %s)" % run.state.status)
		results.append({"status": run.state.status, "runHash": run.state.run_hash(), "log": run.run_log,
			"summary": run.run_summary()})
	var text := WireJson.stringify(results[0])
	eq(WireJson.stringify(results[1]), text, "same seed and choices: identical keyed run")
	for kind in ["open_chest", "equip", "battle"]:
		check(results[0]["log"].any(func(entry: Dictionary) -> bool: return entry["type"] == kind),
			"the keyed run includes a %s" % kind)
	check(results[0]["log"].any(func(entry: Dictionary) -> bool: return entry.get("unlock", "") == "key"),
		"the keyed run opens a lock with a key")
	var path := GOLDEN + "game/run_keyed.json"
	if update_goldens:
		DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(GOLDEN + "game/"))
		var file := FileAccess.open(path, FileAccess.WRITE)
		file.store_string(text)
		file.close()
	eq(text, FileAccess.get_file_as_string(path), "the keyed run matches its golden")


## Every chaos run case (RunPlayer.RUN_CASES) builds on a prepared run and is refused cleanly, whatever the seed.
func test_chaos_run_cases_all_build() -> void:
	var run := _keyed()
	run.give_chest(_chest("strongbox"))  # chest_no_key: 0 keys
	var vault := KeysWorld.special(run, TREASURE)  # locked_no_key: a locked room next to a visited one
	run.state.map.cells[run.state.map.neighbours(vault)[0]]["visited"] = true
	run.give_equipment(fixtures().equipment[&"fixture.equipment.hood"])  # swap_not_worn: a piece in the bag
	run.give_item(_item("flask"), null, fixtures().characters[&"fixture.character.medic"])  # move_full: both slots full
	for case in RunPlayer.RUN_CASES:
		var action := RunPlayer._illegal_action(run, case)
		check(action.is_valid(), "%s builds on the prepared run" % case)
		if action.is_valid():
			_refused(run, action, case)
	var refused := {}
	var violations := []
	for attempt in 40:
		RunPlayer.try_illegal(run, {"rng": RunSeeds.rng(attempt, "cases"), "illegal_x100": 10000,
			"violations": violations, "refused": refused})
	eq(violations, [], "chaos on the prepared run: no violation")
	eq(refused.keys().size(), RunPlayer.RUN_CASES.size(), "and it tries all seven cases (%s)" % refused)


func test_chaos_refuses_run_actions() -> void:
	var refused := {}
	var violations := []
	for seed_value in [3, 7, 11]:
		var run := _keyed(str(seed_value))
		run.give_item(_item("flask"), null, fixtures().characters[&"fixture.character.medic"])
		var chaos := {"rng": RunSeeds.rng(seed_value, "dev/chaos/run"), "illegal_x100": 10000, "violations": violations,
			"refused": refused}
		await RunPlayer.play(run, 400, Callable(), chaos)
	eq(violations, [], "every illegal run action is refused cleanly")
	for case in ["chest_index", "swap_self", "move_full"]:
		check(refused.get(case, 0) > 0, "chaos tried %s (%s)" % [case, refused])
	check(refused.size() >= 4, "and most of the other cases (%s)" % refused)
	# A refusal that changes state is caught.
	var leaky := LeakyRun.new()
	host.add_child(leaky)
	_runs.append(leaky)
	leaky.start_run(KeysWorld.content(), ["fixture.character.knight"], "7", KeysWorld.RUN_ID)
	var caught := []
	for attempt in 20:
		RunPlayer.try_illegal(leaky, {"rng": RunSeeds.rng(attempt, "x"), "illegal_x100": 10000, "violations": caught,
			"refused": {}})
	check(caught.any(func(violation: Dictionary) -> bool: return violation["case"] == "chest_index"),
		"a refusal that changes the run is a violation (%s)" % [caught])
	if not caught.is_empty():
		for key in ["seed", "floor", "battle", "encounter", "invariant", "detail"]:
			check(caught[0].has(key), "a run violation has the report's %s field" % key)


## A run whose open_chest leaks a coin while refusing (an injected bug for the chaos check).
class LeakyRun extends RunController:
	func open_chest(_index: int) -> String:
		state.coins += 1
		return "refused, but leaked"


# --- Validator ------------------------------------------------------------------------------------------------------

func test_validator_checks() -> void:
	var codes := func(index: ContentIndex) -> Array:
		return ContentValidator.validate(index, {"tags": false}).map(func(issue: ValidationIssue) -> String: return issue.code)
	var clean: Array = codes.call(KeysWorld.content())
	for code in ["bad_chest", "locked_room_tag_bad", "run_modifier_unknown", "usage_mismatch"]:
		check(not clean.has(code), "the keyed fixtures have no %s" % code)
	var empty := ChestDefinition.new()
	empty.id = &"fixture.chest.empty"
	var weightless := ChestDefinition.new()
	weightless.id = &"fixture.chest.weightless"
	var reward := ChestReward.new()
	reward.weight_x100 = 0
	reward.outcomes.assign([GainCoins.new()])
	weightless.rewards.assign([reward])
	var odd := ItemDefinition.new()
	odd.id = &"fixture.item.odd"
	odd.description = "test"
	var odd_tags: Array[StringName] = [&"Run.Keys.Triple"]
	odd.tags = odd_tags
	var inline := (fixtures().equipment[&"fixture.equipment.dagger"] as EquipmentDefinition).duplicate()
	inline.id = &"fixture.equipment.inline"
	inline.grants = AbilitySet.new()
	inline.grants.effects.append(GameplayEffect.new())  # never saved: the state hash can't name it
	var broken := KeysWorld.content(func(structure: RunStructure):
		var rules: FloorGenRules = structure.floors[0].chapters[0].floor_gen_rules
		var locked: Array[StringName] = [&"Fixture.Room.Type.Boss", &"Fixture.Room.Type.Nope"]
		rules.locked_room_tags = locked).overlay([empty, weightless, odd, inline])
	var found: Array = codes.call(broken)
	for code in ["bad_chest", "locked_room_tag_bad", "locked_room_tag_unknown", "run_modifier_unknown", "inline_effect"]:
		check(found.has(code), "the validator reports %s" % code)
	check(found.count("bad_chest") >= 2, "an empty chest and a weightless reward")


func test_validator_usage() -> void:
	var issues := ContentValidator.validate(fixtures(), {"tags": false})
	var usage := issues.filter(func(issue: ValidationIssue) -> bool: return issue.code.begins_with("usage_"))
	check(usage.any(func(issue: ValidationIssue) -> bool: return issue.code == "usage_missing"),
		"untagged party abilities are warned about")
	check(not usage.any(func(issue: ValidationIssue) -> bool: return issue.code == "usage_mismatch"),
		"the tagged fixtures agree with what they do")
	var wrong := (fixtures().items[&"fixture.item.field_tonic"] as ItemDefinition).duplicate()
	wrong.id = &"fixture.item.wrong_tonic"
	var mismatched: PackedScene = _repacked("res://tests/fixtures/abilities/strike.tscn", [BattleAbility.USAGE_FIELD_TAG])
	wrong.use_ability = mismatched
	var found := ContentValidator.validate(fixtures().overlay([wrong]), {"tags": false})
	check(found.any(func(issue: ValidationIssue) -> bool: return issue.code == "usage_mismatch"),
		"a Field tag on an enemy move is a usage_mismatch")
	var strike: BattleAbility = load("res://tests/fixtures/abilities/strike.tscn").instantiate()
	var mend: BattleAbility = load("res://tests/fixtures/abilities/mend.tscn").instantiate()
	var flask: BattleAbility = load("res://tests/fixtures/abilities/flask.tscn").instantiate()
	eq([UsagePass.usage_of(strike), UsagePass.usage_of(mend), UsagePass.usage_of(flask)],
		[[BattleAbility.USAGE_BATTLE_TAG], [BattleAbility.USAGE_FIELD_TAG],
		[BattleAbility.USAGE_BATTLE_TAG, BattleAbility.USAGE_FIELD_TAG]],
		"the pass proposes Battle (enemy move), Field (needs State.Infield), both (an ally heal)")
	for ability in [strike, mend, flask]:
		ability.free()


## The ability scene at `path` with extra asset tags, packed in memory.
func _repacked(path: String, tags: Array) -> PackedScene:
	var ability: BattleAbility = load(path).instantiate()
	ability.asset_tags.append_array(tags)
	var scene := PackedScene.new()
	scene.pack(ability)
	ability.free()
	return scene
