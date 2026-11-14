## Spec event-items: GiveItem's recipient (FIRST, RANDOM, CHOOSE), the logged give_to, chests that always let the
## player pick (D5), the item toast for gifts (D2) and its order after a chest's own toast, one possible holder (D4),
## refused actions while a gift waits, the Gift UI state, the validator (D3) and the bots. Events and chests are built
## in memory over the fixtures; nothing is saved.
extends TestCase

const PARTY: Array = ["fixture.character.knight", "fixture.character.medic", "fixture.character.rogue"]

var _runs: Array[RunController] = []
var _handles: Array[GameplayMessageHandle] = []
## [channel, target, data, instigator] of every run message heard, in order.
var _heard: Array = []


func after_each() -> void:
	for handle in _handles:
		handle.unregister()
	_handles.clear()
	_heard.clear()
	for run in _runs:
		if is_instance_valid(run):
			run.free()
	_runs.clear()
	super()


func _item(name: String) -> ItemDefinition:
	return fixtures().items[StringName("fixture.item." + name)]


func _gift(item: ItemDefinition, recipient: int) -> GiveItem:
	var outcome := GiveItem.new()
	outcome.item = item
	outcome.recipient = recipient
	return outcome


## An event whose page 0 has one choice running `outcomes`, and a page 1 to go to.
func _event(id: String, outcomes: Array) -> EventDefinition:
	var event := EventDefinition.new()
	event.id = StringName(id)
	event.display_name = id
	var choice := EventChoice.new()
	choice.label = "take it"
	choice.outcomes.assign(outcomes)
	var first := EventPage.new()
	first.text = "a gift"
	first.choices.assign([choice])
	var leave := EventChoice.new()
	leave.label = "leave"
	var second := EventPage.new()
	second.text = "page two"
	second.choices.assign([leave])
	event.pages.assign([first, second])
	return event


func _chest(id: String, outcomes: Array) -> ChestDefinition:
	var chest := ChestDefinition.new()
	chest.id = StringName(id)
	chest.display_name = id
	var reward := ChestReward.new()
	reward.outcomes.assign(outcomes)
	chest.rewards.assign([reward])
	return chest


## A fixture run (seed 7) whose content also holds `resources`; it listens to the run's item and chest messages.
func _run(resources: Array = []) -> RunController:
	var run := RunController.new()
	host.add_child(run)
	_runs.append(run)
	var error := run.start_run(fixtures().overlay(resources), PARTY, "7")
	check(error == "", "the run starts: " + error)
	for channel in [GameplayMessageRouter.RUN_ITEM_TAKEN, GameplayMessageRouter.RUN_CHEST_OPENED]:
		_handles.append(GameplayMessages.listen(channel, func(heard: StringName, message: VerbMessage):
			_heard.append([heard, String(message.target), message.data, String(message.instigator)]),
			GameplayMessageRouter.Match.EXACT, VerbMessage))
	return run


func _open(run: RunController, event: EventDefinition, cell: int = -2) -> void:
	run.state.event = {"cell": run.state.current_cell if cell == -2 else cell, "event": event.id, "page": 0}


func _holder(run: RunController, item: ItemDefinition) -> int:
	return run.state.holder_of(item.id)


func _taken() -> Array:
	return _heard.filter(func(entry) -> bool: return entry[0] == GameplayMessageRouter.RUN_ITEM_TAKEN)


# --- RANDOM ---------------------------------------------------------------------------------------------------------

func test_random_recipient() -> void:
	var whetstone := _item("whetstone")
	var event := _event("fixture.event.random", [_gift(whetstone, GiveItem.Recipient.RANDOM)])
	var holders := {}
	var first_pick := []
	for attempt in 2:
		var run := _run([event])
		var picks := []
		for cell in run.state.map.sorted_indices():
			_open(run, event, cell)
			eq(run.choose(0), "", "choose")
			picks.append(_slot_of(_taken()[-1]))  # the toast names the holder ("slot:<n>")
		if attempt == 0:
			first_pick = picks
			for slot in picks:
				holders[slot] = true
		else:
			eq(picks, first_pick, "the same seed picks the same members")
	check(holders.size() >= 2, "different cells can pick different members: %s" % [holders.keys()])
	check(not holders.has(0), "every pick is a party member")


## The holder's slot from a heard ItemTaken message (its instigator is "slot:<n>").
static func _slot_of(heard: Array) -> int:
	return int(String(heard[3]).trim_prefix("slot:"))


# --- CHOOSE in an event ---------------------------------------------------------------------------------------------

func test_choose_waits_for_give_to() -> void:
	var whetstone := _item("whetstone")
	var go := GoToPage.new()
	go.page = 1
	var event := _event("fixture.event.choose", [_gift(whetstone, GiveItem.Recipient.CHOOSE), go])
	var run := _run([event])
	_open(run, event)
	eq(run.choose(0), "", "choose")
	eq(run.state.pending_gifts, [whetstone.id] as Array[StringName], "the item waits for its holder")
	eq(int(run.state.event["page"]), 0, "the event waits too (no page 1 yet)")
	eq(_taken().size(), 0, "no toast before it has a holder")
	check(UIState.compute("run", run).has(UIState.GIFT), "the UI state has %s" % UIState.GIFT)
	var log_size := run.run_log.size()
	var hash_before := run.state.run_hash()
	check(run.choose(0).begins_with("choose who gets"), "choose is refused while a gift waits")
	check(run.take(1, 1).begins_with("choose who gets"), "take is refused")
	check(run.next_floor().begins_with("choose who gets"), "next_floor is refused")
	check(not run.can_enter(run.state.map.sorted_indices()[0]), "travel is refused")
	check(run.give_to(9) != "", "an unknown slot is refused")
	run.state.member(2)["alive"] = false
	check(run.give_to(2) != "", "a dead member is refused")
	run.state.member(2)["alive"] = true
	eq(run.run_log.size(), log_size, "nothing refused was logged")
	eq(run.state.run_hash(), hash_before, "nothing refused changed the run")
	eq(run.give_to(2), "", "give_to the medic")
	eq(run.run_log[-1], {"type": "give_to", "floor": 0, "cell": run.state.current_cell, "item": String(whetstone.id),
		"slot": 2}, "give_to is logged")
	eq(_holder(run, whetstone), 2, "the medic holds it")
	eq(int(run.state.event["page"]), 1, "then the choice's next step runs: page 1")
	check(not UIState.compute("run", run).has(UIState.GIFT), "and the Gift state is gone")
	var taken := _taken()
	eq(taken.size(), 1, "one toast, after the pick")
	eq([taken[0][2].get("instigatorName"), taken[0][2].get("source")], ["Medic", "gift"], "it names the holder")
	eq(run.run_summary().get("giftsGiven"), 1, "the summary counts it")


func test_choose_then_encounter_or_end() -> void:
	var whetstone := _item("whetstone")
	var fight := StartEncounter.new()
	fight.encounter = fixtures().encounters[&"fixture.encounter.pack"]
	var run := _run([_event("fixture.event.fight", [_gift(whetstone, GiveItem.Recipient.CHOOSE), fight]),
		_event("fixture.event.end", [_gift(whetstone, GiveItem.Recipient.CHOOSE)])])
	_open(run, run.content.events[&"fixture.event.fight"])
	run.choose(0)
	check(run.pending_battle.is_empty(), "no battle while the gift waits")
	eq(run.give_to(1), "", "give_to")
	check(not run.pending_battle.is_empty(), "then the encounter starts")
	var ended := _run([_event("fixture.event.end", [_gift(whetstone, GiveItem.Recipient.CHOOSE)])])
	_open(ended, ended.content.events[&"fixture.event.end"])
	ended.choose(0)
	check(not ended.state.event.is_empty(), "the event stays open while the gift waits")
	eq(ended.give_to(3), "", "give_to")
	check(ended.state.event.is_empty(), "then it ends")


func test_one_holder_gives_at_once() -> void:
	var whetstone := _item("whetstone")
	var event := _event("fixture.event.single", [_gift(whetstone, GiveItem.Recipient.CHOOSE)])
	var run := _run([event])
	run.state.member(2)["alive"] = false
	run.state.member(3)["alive"] = false
	_open(run, event)
	run.choose(0)
	eq(run.state.pending_gifts.size(), 0, "only the knight can hold it: no prompt (D4)")
	eq(_holder(run, whetstone), 1, "the knight got it")
	check(not run.run_log.any(func(entry) -> bool: return entry["type"] == "give_to"), "no give_to entry")
	eq(_taken().size(), 1, "and it toasts")


func test_first_still_gives_and_toasts() -> void:
	var whetstone := _item("whetstone")
	var event := _event("fixture.event.first", [_gift(whetstone, GiveItem.Recipient.FIRST)])
	var run := _run([event])
	_open(run, event)
	run.choose(0)
	eq(_holder(run, whetstone), 1, "FIRST: the first member, at once")
	eq(_taken().size(), 1, "an event item toasts like a pickup (D2)")


# --- Chests (D5) ----------------------------------------------------------------------------------------------------

func test_chest_always_asks() -> void:
	var whetstone := _item("whetstone")
	var crest := _item("crest")
	var coins := GainCoins.new()
	coins.amount = 3
	var chest := _chest("fixture.chest.gifts", [_gift(whetstone, GiveItem.Recipient.FIRST),
		_gift(crest, GiveItem.Recipient.FIRST), coins])
	var run := _run([chest])
	run.give_chest(chest)
	run.give_chest(chest)
	eq(run.open_chest(0), "", "open the chest")
	eq(run.state.pending_gifts, [whetstone.id, crest.id] as Array[StringName],
		"both items wait for a holder even though they say FIRST (D5)")
	var opened := _heard.filter(func(entry) -> bool: return entry[0] == GameplayMessageRouter.RUN_CHEST_OPENED)
	eq(opened.size(), 1, "the chest toast came at once")
	check(str(opened[0][2]["description"]).contains(whetstone.display_name)
		and str(opened[0][2]["description"]).contains(crest.display_name), "and lists both items")
	eq(_taken().size(), 0, "no item toast yet")
	check(run.open_chest(0).begins_with("choose who gets"), "the next chest waits too")
	eq(run.give_to(3), "", "the whetstone to the rogue")
	eq(run.give_to(2), "", "the crest to the medic")
	eq([_holder(run, whetstone), _holder(run, crest)], [3, 2], "each went where it was given")
	eq(_taken().map(func(entry) -> String: return entry[1]), [String(whetstone.id), String(crest.id)],
		"one item toast after each pick, in order")


func test_chest_one_holder_toasts_after_the_chest() -> void:
	var whetstone := _item("whetstone")
	var chest := _chest("fixture.chest.single", [_gift(whetstone, GiveItem.Recipient.FIRST)])
	var run := _run([chest])
	run.state.member(2)["alive"] = false
	run.state.member(3)["alive"] = false
	run.give_chest(chest)
	run.open_chest(0)
	eq(run.state.pending_gifts.size(), 0, "one possible holder: given at once (D4)")
	eq(_heard.map(func(entry) -> StringName: return entry[0]),
		[GameplayMessageRouter.RUN_CHEST_OPENED, GameplayMessageRouter.RUN_ITEM_TAKEN],
		"the chest toast first, then the item's (D2)")


# --- Validator and bots ---------------------------------------------------------------------------------------------

func test_validator_choose_outside_event() -> void:
	var codes := func(index: ContentIndex) -> Array:
		return ContentValidator.validate(index, {"tags": false}).map(func(issue: ValidationIssue) -> String:
			return issue.code)
	var whetstone := _item("whetstone")
	var reward: EncounterDefinition = fixtures().encounters[&"fixture.encounter.pack"].duplicate()
	var rewards: Array[RunOutcome] = [_gift(whetstone, GiveItem.Recipient.CHOOSE)]
	reward.rewards = rewards  # a new array: duplicate() shares the cached fixture's
	var hooked: ItemDefinition = whetstone.duplicate()
	hooked.id = &"fixture.item.choose_hook"
	hooked.on_room_cleared = [_gift(whetstone, GiveItem.Recipient.CHOOSE)] as Array[RunOutcome]
	check(codes.call(fixtures().overlay([hooked])).has("give_choose_outside_event"),
		"CHOOSE in an item hook is an error (D3)")
	var fine: Array = codes.call(fixtures().overlay([reward,
		_chest("fixture.chest.choose", [_gift(whetstone, GiveItem.Recipient.CHOOSE)]),
		_event("fixture.event.choose", [_gift(whetstone, GiveItem.Recipient.CHOOSE)])]))
	check(not fine.has("give_choose_outside_event"),
		"CHOOSE in a chest, an event or an encounter reward is fine (user, 2026-11-13)")


func test_bot_gives_pending_gifts() -> void:
	var whetstone := _item("whetstone")
	var chest := _chest("fixture.chest.bot", [_gift(whetstone, GiveItem.Recipient.CHOOSE)])
	var run := _run([chest])
	run.give_chest(chest)
	run.open_chest(0)
	eq(run.state.pending_gifts.size(), 1, "a gift waits")
	await RunPlayer.play(run, 1)
	eq(run.state.pending_gifts.size(), 0, "the bot gave it")
	eq(_holder(run, whetstone), 1, "to the first member who can hold it")
	eq(run.run_log.filter(func(entry) -> bool: return entry["type"] == "give_to").size(), 1, "logged as give_to")
